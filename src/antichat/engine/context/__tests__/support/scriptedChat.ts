/**
 * The 200-turn scripted chat of the M7 acceptance row, run through the real
 * pipeline (`prepareRequest` with the system-prompt, skills and context
 * providers) against the fake engine.
 */
import type {ModelFamily} from '../../../prompt/modelFamily';
import {createSystemPromptProvider} from '../../../prompt/provider';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../../prompt/registry';
import type {ChatMessage, RequestProvider} from '../../../prompt/types';
import {createSkillsProvider} from '../../../skills/provider';
import {budgetFor} from '../../budget';
import {createContextProvider} from '../../provider';
import {
  createMemoryContextStateStore,
  getContextStateStore,
  setContextStateStore,
} from '../../summaryStore';
import {messageText, type TokenCounter} from '../../tokenCounter';
import {createFakeEngine, filler, type FakeEngine} from './fakeEngine';

export const FACT_TURN = 2; // the third turn
export const FACT_MESSAGE =
  'Before we go on, please remember this: my dog is called Biscuit. (20 words)';
export const RECALL_QUESTION = 'What is my dog called?';
export const SCRIPT_NOW = new Date(2026, 10, 24, 14, 5);

const TOPICS = [
  'basil',
  'stretching',
  'baking',
  'interest',
  'sleep',
  'kettles',
  'interviews',
  'running',
  'soup',
  'names',
  'budgets',
  'weather',
];

export function userMessage(turn: number, turns: number): string {
  if (turn === FACT_TURN) {
    return FACT_MESSAGE;
  }
  if (turn === turns - 1) {
    return RECALL_QUESTION;
  }
  const words = 80 + ((turn * 37) % 121);
  return `Question ${turn + 1} about ${TOPICS[turn % TOPICS.length]}: ${filler(turn + 9000, 10 + (turn % 9))}? (${words} words)`;
}

export interface ScriptedChatOptions {
  family: ModelFamily;
  nCtx: number;
  counter: TokenCounter;
  turns?: number;
  /** Replace the default providers (for the "before" baseline). */
  providers?: RequestProvider[];
  sessionId?: string;
}

export interface ScriptedChatResult {
  engine: FakeEngine;
  promptLimit: number;
  /** Prompt tokens of every chat request, by the given counter. */
  promptTokens: number[];
  maxPromptTokens: number;
  compactions: number;
  summarized: number;
  recallReply: string;
  /** Was the fact still inside the message window at the last turn? */
  factInWindow: boolean;
  /** Was it in the system message (i.e. in the summary)? */
  factInSummary: boolean;
  cacheHitRate: number;
  offeredNewChat: boolean;
  lastRequest: ChatMessage[];
}

export async function runScriptedChat(
  options: ScriptedChatOptions,
): Promise<ScriptedChatResult> {
  const turns = options.turns ?? 200;
  const sessionId =
    options.sessionId ?? `scripted-${options.family}-${options.nCtx}`;
  const engine = createFakeEngine();
  const budget = budgetFor(options.nCtx);
  clearRequestProviders();
  setContextStateStore(createMemoryContextStateStore());
  for (const provider of options.providers ?? [
    createSystemPromptProvider({personalization: () => null}),
    createSkillsProvider(),
    createContextProvider(),
  ]) {
    registerRequestProvider(provider);
  }

  const history: ChatMessage[] = [];
  const promptTokens: number[] = [];
  let summarized = 0;
  let offeredNewChat = false;
  let recallReply = '';
  let lastRequest: ChatMessage[] = [];
  try {
    for (let turn = 0; turn < turns; turn++) {
      history.push({role: 'user', content: userMessage(turn, turns)});
      const prepared = await prepareRequest({
        messages: [...history],
        session: {id: sessionId},
        runtime: {
          nCtx: options.nCtx,
          family: options.family,
          tokenCounter: options.counter,
          engine,
          now: SCRIPT_NOW,
        },
      });
      const usage = prepared.meta.context as
        | {summarized: boolean; offerNewChat: boolean}
        | undefined;
      summarized += usage?.summarized ? 1 : 0;
      offeredNewChat = offeredNewChat || !!usage?.offerNewChat;
      // Counted here, independently of what the provider reported.
      promptTokens.push(await options.counter.countPrompt(prepared.messages));
      const result = await engine.completion({
        ...prepared.params,
        messages: prepared.messages,
      } as never);
      history.push({role: 'assistant', content: result.content});
      recallReply = result.content;
      lastRequest = prepared.messages;
    }
    const state = await getContextStateStore().get(sessionId);
    const window = lastRequest
      .filter(message => message.role !== 'system')
      .map(message => messageText(message).text)
      .join('\n');
    const system =
      lastRequest[0]?.role === 'system' ? messageText(lastRequest[0]).text : '';
    return {
      engine,
      promptLimit: budget.promptLimit,
      promptTokens,
      maxPromptTokens: Math.max(...promptTokens),
      compactions: state?.compactions ?? 0,
      summarized,
      recallReply,
      factInWindow: window.includes('Biscuit'),
      factInSummary: system.includes('Biscuit'),
      cacheHitRate: engine.cacheHitRate('chat'),
      offeredNewChat,
      lastRequest,
    };
  } finally {
    clearRequestProviders();
  }
}

export const FAMILIES: ModelFamily[] = ['gemma4', 'lfm3', 'qwen35'];
export const WINDOWS = [4096, 8192, 16384, 32768];

export const fixturePath = (family: ModelFamily): string =>
  `${__dirname}/../../__fixtures__/tokens-${family}.json`;
