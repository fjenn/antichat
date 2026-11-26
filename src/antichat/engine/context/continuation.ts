/**
 * "Continue in a new chat with a summary" (H9). ChatGPT offers this when a
 * thread is full. Here the offer appears once a chat has been compacted a few
 * times (`FitResult.offerNewChat`): a summary of a summary of a summary loses
 * detail, and a fresh chat that starts from one clean summary answers faster
 * and better.
 *
 * Flow for the UI: `buildContinuation` → create the new chat →
 * `seedContinuation(newId, continuation)`. The context provider then shows
 * the carried summary to the model in the new chat.
 */
import type {RuntimeInfo, ChatMessage} from '../prompt/types';
import {budgetFor} from './budget';
import {fingerprint} from './fit';
import {renderSummaryText, summarizeMessages} from './summary';
import {
  emptyContextState,
  getContextStateStore,
  type ContextState,
} from './summaryStore';

export interface Continuation {
  fromSessionId?: string;
  facts: string[];
  summary: string;
  /** Facts and summary as readable text, for a preview. */
  text: string;
}

export interface ContinuationRequest {
  sessionId?: string;
  /** Full history of the chat (a leading system message is ignored). */
  messages: ChatMessage[];
  runtime: Pick<
    RuntimeInfo,
    'engine' | 'family' | 'nCtx' | 'tokenCounter' | 'signal'
  >;
}

/**
 * Summarise the whole chat: the stored summary covers the removed part, and
 * the messages still in the window are folded in now.
 */
export async function buildContinuation(
  request: ContinuationRequest,
): Promise<Continuation | null> {
  const {runtime, sessionId} = request;
  const history = request.messages.filter(m => m.role !== 'system');
  const store = getContextStateStore();
  const stored = sessionId ? await store.get(sessionId) : null;
  const usable =
    stored &&
    stored.summarizedCount <= history.length &&
    (stored.cutCount === 0 ||
      stored.fingerprint === fingerprint(history.slice(0, stored.cutCount)));
  const state: ContextState = usable ? stored : emptyContextState();

  let facts = [...(state.carried?.facts ?? []), ...state.facts];
  let summary = [state.carried?.summary, state.summary]
    .filter(Boolean)
    .join(' ');
  const rest = history.slice(state.summarizedCount);
  if (rest.length && runtime.engine) {
    const result = await summarizeMessages({
      engine: runtime.engine,
      family: runtime.family,
      nCtx: runtime.nCtx,
      counter: runtime.tokenCounter,
      signal: runtime.signal,
      messages: rest,
      previousFacts: facts,
      previousSummary: summary,
      maxTokens: budgetFor(runtime.nCtx).summaryTokens,
    });
    if (result) {
      facts = result.facts;
      summary = result.summary;
    }
  }
  if (!facts.length && !summary) {
    return null;
  }
  return {
    fromSessionId: sessionId,
    facts,
    summary,
    text: renderSummaryText(facts, summary),
  };
}

/** Attach a continuation to a (new, empty) chat. */
export async function seedContinuation(
  newSessionId: string,
  continuation: Continuation,
): Promise<void> {
  await getContextStateStore().set(newSessionId, {
    ...emptyContextState(),
    carried: {
      facts: continuation.facts,
      summary: continuation.summary,
      fromSessionId: continuation.fromSessionId,
    },
    updatedAt: Date.now(),
  });
}
