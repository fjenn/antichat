/**
 * Request provider for context management. It runs last (order 900): every
 * other provider has added its blocks by then, so what is measured is what is
 * sent.
 */
import {cleanForContext} from '../prompt/hygiene';
import type {
  ChatMessage,
  RequestContext,
  RequestDraft,
  RequestProvider,
} from '../prompt/types';
import {budgetFor} from './budget';
import {emitContextEvent} from './events';
import {fitContext, type Summarizer} from './fit';
import {summarizeMessages} from './summary';
import {
  createMemoryContextStateStore,
  getContextStateStore,
} from './summaryStore';
import {withTokenCache, type TokenCounter} from './tokenCounter';
import {applyInsertionLimits} from './truncation';

export const CONTEXT_PROVIDER_ID = 'antichat.context';

export interface ContextProviderOptions {
  /** Write summaries with the model (default true). False = sliding window. */
  summarize?: boolean;
  summaryTimeoutMs?: number;
}

/** Strip leaked thinking and template tokens from earlier assistant turns. */
export function cleanHistory(messages: ChatMessage[]): ChatMessage[] {
  return messages.map(message => {
    if (message.role !== 'assistant' || typeof message.content !== 'string') {
      return message;
    }
    const cleaned = cleanForContext(message.content);
    return cleaned === message.content
      ? message
      : {...message, content: cleaned};
  });
}

const temporaryStore = createMemoryContextStateStore();

// One token cache per underlying counter (i.e. per loaded model).
const caches = new WeakMap<TokenCounter, TokenCounter>();
const cached = (counter: TokenCounter): TokenCounter => {
  let hit = caches.get(counter);
  if (!hit) {
    hit = withTokenCache(counter);
    caches.set(counter, hit);
  }
  return hit;
};

export function makeSummarizer(
  context: Pick<RequestContext, 'runtime'>,
  counter: TokenCounter,
  timeoutMs?: number,
): Summarizer | undefined {
  const {engine, family, nCtx, signal} = context.runtime;
  if (!engine) {
    return undefined;
  }
  return request =>
    summarizeMessages({
      engine,
      family,
      nCtx,
      counter,
      signal,
      timeoutMs,
      ...request,
    });
}

export function createContextProvider(
  options: ContextProviderOptions = {},
): RequestProvider {
  return {
    id: CONTEXT_PROVIDER_ID,
    order: 900,
    transform: async (
      draft: RequestDraft,
      context: RequestContext,
    ): Promise<RequestDraft> => {
      const {runtime, session} = context;
      const budget = budgetFor(runtime.nCtx);
      const counter = cached(runtime.tokenCounter);
      // Temporary chats keep their summary in memory for this run only.
      const store = session.temporary ? temporaryStore : getContextStateStore();
      const sessionId = session.id;

      const prepared = await applyInsertionLimits(
        cleanHistory(draft.messages),
        budget,
        counter,
      );
      const state = sessionId ? await store.get(sessionId) : null;
      const summarize =
        options.summarize === false
          ? undefined
          : makeSummarizer(context, counter, options.summaryTimeoutMs);

      let announced = false;
      const fit = await fitContext({
        messages: prepared,
        tools: draft.tools,
        budget,
        counter,
        state,
        summarize: summarize
          ? request => {
              announced = true;
              emitContextEvent({type: 'compacting', sessionId, active: true});
              return summarize(request);
            }
          : undefined,
        now: runtime.now.getTime(),
      });
      if (announced) {
        emitContextEvent({type: 'compacting', sessionId, active: false});
      }
      if (sessionId && fit.state !== state) {
        await store.set(sessionId, fit.state);
      }

      const usage = {
        sessionId,
        promptTokens: fit.promptTokens,
        nCtx: budget.nCtx,
        compacted: fit.compacted,
        summarized: fit.summarized,
        offerNewChat: fit.offerNewChat,
        exact: counter.exact,
      };
      emitContextEvent({type: 'usage', usage});
      return {
        ...draft,
        messages: fit.messages,
        // `contextInput` is the request before fitting; the after-reply
        // compaction continues from it.
        meta: {...draft.meta, context: usage, contextInput: prepared},
      };
    },
  };
}
