/* eslint-disable no-bitwise */
/**
 * Context fitting (H9): system prompt + rolling summary + newest turns.
 *
 * Invariants:
 *  - The returned prompt never exceeds `budget.promptLimit`, measured with the
 *    counter it was given (the model's tokeniser on device).
 *  - History is only ever cut at the start of a user turn, so an assistant
 *    tool call is never separated from its tool results and the kept history
 *    always begins with a user message.
 *  - The newest user turn is always kept; it is shortened only when it alone
 *    does not fit.
 *  - Nothing changes until the prompt passes the trigger; then the history is
 *    cut to the target in one step. Between compactions the prefix is stable,
 *    so the KV cache keeps working.
 */
import type {ChatMessage, ToolDefinition} from '../prompt/types';
import type {ContextBudget} from './budget';
import {emptyContextState, type ContextState} from './summaryStore';
import {renderSummaryText} from './summary';
import {
  MESSAGE_OVERHEAD_TOKENS,
  messageText,
  type TokenCounter,
} from './tokenCounter';
import {shrinkMessage, truncateHead} from './truncation';

export const SUMMARY_BLOCK_HEADER = '# Earlier in this conversation';
export const SUMMARY_BLOCK_LEAD =
  'Older messages were removed to save memory. This is what they established; treat it as known.';
export const CARRIED_BLOCK_HEADER = '# Summary of the previous chat';
export const CARRIED_BLOCK_LEAD =
  'The user continued from an earlier chat. This is what it established; treat it as known.';

/** Compactions after which a fresh chat is the better offer. */
export const OFFER_NEW_CHAT_AFTER = 3;

export type Summarizer = (request: {
  messages: ChatMessage[];
  previousFacts: string[];
  previousSummary: string;
  maxTokens: number;
}) => Promise<{facts: string[]; summary: string} | null>;

export interface FitInput {
  /** The request as assembled: optional leading system message + history. */
  messages: ChatMessage[];
  tools?: readonly ToolDefinition[];
  budget: ContextBudget;
  counter: TokenCounter;
  state?: ContextState | null;
  /** Writes the summary of removed messages. Without it the window slides. */
  summarize?: Summarizer;
  /** Start compaction above this many tokens. Default `budget.triggerTokens`. */
  trigger?: number;
  now?: number;
}

export interface FitResult {
  messages: ChatMessage[];
  state: ContextState;
  /** Tokens of the returned prompt, by `counter`. */
  promptTokens: number;
  /** The cut moved on this call. */
  compacted: boolean;
  /** The summary was rewritten on this call. */
  summarized: boolean;
  /** The newest message had to be shortened. */
  shrunkNewest: boolean;
  offerNewChat: boolean;
}

/** FNV-1a over role, length and the ends of each message. Cheap and stable. */
export function fingerprint(messages: readonly ChatMessage[]): string {
  let hash = 0x811c9dc5;
  const feed = (text: string) => {
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
  };
  for (const message of messages) {
    const {text} = messageText(message);
    feed(message.role);
    feed(String(text.length));
    feed(text.slice(0, 48));
    feed(text.slice(-24));
  }
  return (hash >>> 0).toString(16);
}

/** The summary section appended to the system message, or ''. */
export function renderSummaryBlock(state: ContextState): string {
  const sections: string[] = [];
  if (state.carried) {
    const carried = renderSummaryText(
      state.carried.facts,
      state.carried.summary,
    );
    if (carried) {
      sections.push(
        `${CARRIED_BLOCK_HEADER}\n${CARRIED_BLOCK_LEAD}\n${carried}`,
      );
    }
  }
  const own = renderSummaryText(state.facts, state.summary);
  if (own) {
    sections.push(`${SUMMARY_BLOCK_HEADER}\n${SUMMARY_BLOCK_LEAD}\n${own}`);
  }
  return sections.join('\n\n');
}

function compose(
  system: ChatMessage | null,
  history: ChatMessage[],
  state: ContextState,
): ChatMessage[] {
  const block = renderSummaryBlock(state);
  const systemText = system ? messageText(system).text : '';
  const text = [systemText, block].filter(Boolean).join('\n\n');
  return [
    ...(text ? [{role: 'system', content: text}] : []),
    ...history.slice(state.cutCount),
  ];
}

const turnStarts = (history: readonly ChatMessage[]): number[] => {
  const starts: number[] = [];
  history.forEach((message, index) => {
    if (message.role === 'user') {
      starts.push(index);
    }
  });
  return starts;
};

/** Is the stored state still about this history? */
function validState(
  state: ContextState | null | undefined,
  history: readonly ChatMessage[],
  starts: number[],
): ContextState {
  if (!state) {
    return emptyContextState();
  }
  const lastStart = starts.length ? starts[starts.length - 1] : 0;
  const ok =
    state.cutCount === 0 ||
    (state.cutCount <= lastStart &&
      starts.includes(state.cutCount) &&
      state.fingerprint === fingerprint(history.slice(0, state.cutCount)));
  if (ok) {
    return state;
  }
  // The earlier history was edited or regenerated: the summary no longer
  // describes it. A carried summary belongs to another chat and stays.
  return {...emptyContextState(), carried: state.carried};
}

export async function fitContext(input: FitInput): Promise<FitResult> {
  const {budget, counter, tools} = input;
  const hasSystem = input.messages[0]?.role === 'system';
  const system = hasSystem ? input.messages[0] : null;
  const history = hasSystem ? input.messages.slice(1) : [...input.messages];
  const starts = turnStarts(history);
  const lastStart = starts.length ? starts[starts.length - 1] : 0;

  let state = validState(input.state, history, starts);
  let messages = compose(system, history, state);
  let promptTokens = await counter.countPrompt(messages, tools);
  const trigger = Math.min(
    input.trigger ?? budget.triggerTokens,
    budget.promptLimit,
  );

  const result = (flags: {
    compacted: boolean;
    summarized: boolean;
    shrunkNewest: boolean;
  }): FitResult => ({
    messages,
    state,
    promptTokens,
    ...flags,
    offerNewChat: state.compactions >= OFFER_NEW_CHAT_AFTER,
  });

  if (promptTokens <= trigger) {
    return result({compacted: false, summarized: false, shrunkNewest: false});
  }

  // --- Choose the new cut -------------------------------------------------
  const costs: number[] = [];
  for (let i = state.cutCount; i < history.length; i++) {
    const {text, images} = messageText(history[i]);
    costs.push(
      (await counter.countText(text)) + MESSAGE_OVERHEAD_TOKENS + images * 512,
    );
  }
  const historyTokens = costs.reduce((sum, cost) => sum + cost, 0);
  const summaryReserve =
    input.summarize || state.summary || state.facts.length
      ? budget.summaryTokens
      : 0;
  const currentSummaryTokens = await counter.countText(
    renderSummaryText(state.facts, state.summary),
  );
  // Everything that is not history: system text, tools, template overhead.
  const fixedTokens = Math.max(
    0,
    promptTokens - historyTokens - currentSummaryTokens,
  );
  const historyTarget = Math.max(
    0,
    Math.min(budget.targetTokens, trigger) - fixedTokens - summaryReserve,
  );

  let newCut = lastStart;
  let kept = 0;
  for (let i = history.length - 1; i >= state.cutCount; i--) {
    kept += costs[i - state.cutCount];
    if (starts.includes(i)) {
      if (kept <= historyTarget || i === lastStart) {
        newCut = i;
      }
      if (kept > historyTarget) {
        break;
      }
    }
  }
  newCut = Math.max(newCut, state.cutCount);

  // --- Summarise what is being removed -------------------------------------
  let summarized = false;
  let next: ContextState = {...state};
  if (newCut > state.cutCount) {
    if (input.summarize) {
      const summary = await input.summarize({
        messages: history.slice(state.summarizedCount, newCut),
        previousFacts: state.facts,
        previousSummary: state.summary,
        maxTokens: budget.summaryTokens,
      });
      if (summary) {
        next.facts = summary.facts;
        next.summary = summary.summary;
        next.summarizedCount = newCut;
        summarized = true;
      }
    }
    next.cutCount = newCut;
    next.fingerprint = fingerprint(history.slice(0, newCut));
    next.compactions = state.compactions + 1;
    next.updatedAt = input.now ?? Date.now();
  }
  const compacted = next.cutCount > state.cutCount;
  state = next;
  messages = compose(system, history, state);
  promptTokens = await counter.countPrompt(messages, tools);

  // --- Guarantee the limit --------------------------------------------------
  // 1. Drop further whole turns while more than the newest one is left.
  while (promptTokens > budget.promptLimit && state.cutCount < lastStart) {
    const following = starts.find(start => start > state.cutCount) ?? lastStart;
    state = {
      ...state,
      cutCount: following,
      fingerprint: fingerprint(history.slice(0, following)),
    };
    messages = compose(system, history, state);
    promptTokens = await counter.countPrompt(messages, tools);
  }

  // 2. Shorten the summary, then drop it.
  if (promptTokens > budget.promptLimit && state.summary) {
    const over = promptTokens - budget.promptLimit;
    const summaryTokens = await counter.countText(state.summary);
    state = {
      ...state,
      summary:
        summaryTokens > over + 24
          ? await truncateHead(state.summary, summaryTokens - over - 8, counter)
          : '',
    };
    messages = compose(system, history, state);
    promptTokens = await counter.countPrompt(messages, tools);
  }

  // 3. Shorten the largest message of the newest turn until it fits.
  let shrunkNewest = false;
  for (
    let attempt = 0;
    attempt < 8 && promptTokens > budget.promptLimit;
    attempt++
  ) {
    const offset = messages.length - (history.length - state.cutCount);
    let largest = -1;
    let largestTokens = 0;
    for (let i = Math.max(offset, 0); i < messages.length; i++) {
      const tokens = await counter.countText(messageText(messages[i]).text);
      if (tokens > largestTokens) {
        largest = i;
        largestTokens = tokens;
      }
    }
    if (largest === -1 || largestTokens < 16) {
      break;
    }
    const over = promptTokens - budget.promptLimit;
    const allowance = Math.max(
      8,
      Math.floor((largestTokens - over) * (attempt === 0 ? 0.97 : 0.8)),
    );
    const shrunk = await shrinkMessage(messages[largest], allowance, counter);
    messages = [...messages];
    messages[largest] = shrunk;
    shrunkNewest = true;
    promptTokens = await counter.countPrompt(messages, tools);
  }

  return result({compacted, summarized, shrunkNewest});
}
