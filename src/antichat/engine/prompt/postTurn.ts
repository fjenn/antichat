/**
 * Jobs that run after a reply, while the phone is idle: the chat title (first
 * reply only), follow-up suggestions (class C and D), and an early summary so
 * the next send does not have to wait for one.
 *
 * `runPostTurn` is pure (everything injected) and is what the tests drive.
 * `installPostTurnHooks` binds it to the app's stores without touching an
 * upstream file: it watches `isGenerating` and takes the generation lease
 * only if it is free, so a user who is already sending again is never held up.
 */
import {reaction} from 'mobx';

import {chatSessionStore, modelStore} from '../../../store';
import {derivedText} from '../../../utils/chat';
import type {CompletionEngine} from '../../../utils/completionTypes';
import {budgetFor} from '../context/budget';
import {emitContextEvent} from '../context/events';
import {fitContext} from '../context/fit';
import {makeSummarizer} from '../context/provider';
import {getContextStateStore} from '../context/summaryStore';
import {messageText} from '../context/tokenCounter';
import {followUpsAllowed, generateFollowUps} from './followups';
import {cleanForContext} from './hygiene';
import {familyProfile} from './modelFamily';
import {afterReplyQueue} from './afterReply';
import {getLastSentRequest, resolveSeamRuntime} from './seam';
import {generateTitle} from './title';
import type {ChatMessage, RuntimeInfo} from './types';

export interface PostTurnInput {
  engine: CompletionEngine;
  runtime: Omit<RuntimeInfo, 'engine'>;
  sessionId?: string;
  /** The request as sent (system + history ending in the user message). */
  messages: ChatMessage[];
  /**
   * The request before context fitting (`meta.contextInput`). Needed for the
   * early compaction once a chat has been cut; defaults to `messages`.
   */
  fullMessages?: ChatMessage[];
  /** The assistant's finished reply. */
  reply: string;
  signal?: AbortSignal;
  title?: boolean;
  followUps?: boolean;
  compact?: boolean;
}

export interface PostTurnResult {
  title?: string;
  titleGenerated?: boolean;
  followUps: string[];
  compacted: boolean;
}

type FollowUpListener = (
  sessionId: string | undefined,
  items: string[],
) => void;
const followUpListeners = new Set<FollowUpListener>();

/** The UI subscribes here to show follow-up chips under the last reply. */
export function subscribeFollowUps(listener: FollowUpListener): () => void {
  followUpListeners.add(listener);
  return () => followUpListeners.delete(listener);
}

export async function runPostTurn(
  input: PostTurnInput,
): Promise<PostTurnResult> {
  const {engine, runtime, messages, signal} = input;
  const reply = cleanForContext(input.reply).trim();
  const result: PostTurnResult = {followUps: [], compacted: false};
  const users = messages.filter(message => message.role === 'user');
  const lastUser = users.length
    ? messageText(users[users.length - 1]).text
    : '';
  if (!reply || !lastUser) {
    return result;
  }

  // 1. Title, after the first exchange only. Where the family allows it, it
  //    is asked as one more turn of the same conversation, so the chat's
  //    cached prefix is reused and survives.
  if (input.title !== false && users.length === 1) {
    const title = await generateTitle({
      engine,
      family: runtime.family,
      userMessage: lastUser,
      assistantReply: reply,
      chatMessages:
        familyProfile(runtime.family).titleMode === 'inline'
          ? messages
          : undefined,
      signal,
    });
    result.title = title.title;
    result.titleGenerated = title.generated;
  }
  if (signal?.aborted) {
    return result;
  }

  // 2. Follow-ups.
  if (input.followUps !== false && followUpsAllowed(runtime.deviceClass)) {
    result.followUps = await generateFollowUps({
      engine,
      family: runtime.family,
      userMessage: lastUser,
      assistantReply: reply,
      signal,
    });
  }
  if (signal?.aborted) {
    return result;
  }

  // 3. Early compaction at the soft trigger.
  if (input.compact !== false && input.sessionId) {
    const budget = budgetFor(runtime.nCtx);
    const store = getContextStateStore();
    const state = await store.get(input.sessionId);
    {
      const withReply = [
        ...(input.fullMessages ?? messages),
        {role: 'assistant', content: reply},
      ];
      let announced = false;
      const summarize = makeSummarizer(
        {runtime: {...runtime, engine, signal}},
        runtime.tokenCounter,
      );
      const fit = await fitContext({
        messages: withReply,
        budget,
        counter: runtime.tokenCounter,
        state,
        trigger: budget.softTriggerTokens,
        summarize: summarize
          ? request => {
              announced = true;
              emitContextEvent({
                type: 'compacting',
                sessionId: input.sessionId,
                active: true,
              });
              return summarize(request);
            }
          : undefined,
      });
      if (announced) {
        emitContextEvent({
          type: 'compacting',
          sessionId: input.sessionId,
          active: false,
        });
      }
      if (fit.compacted && !signal?.aborted) {
        await store.set(input.sessionId, fit.state);
        result.compacted = true;
      }
    }
  }
  return result;
}

export interface PostTurnHookOptions {
  title?: boolean;
  followUps?: boolean;
  compact?: boolean;
  /** Wait this long after the reply before starting (ms). */
  idleDelayMs?: number;
}

/**
 * Start watching for finished replies. Returns the function that stops it.
 * Nothing runs unless a request went through the seam for the active chat.
 */
export function installPostTurnHooks(
  options: PostTurnHookOptions = {},
): () => void {
  const removeJob = afterReplyQueue.register({
    id: 'prompt.post-turn',
    order: 10,
    run: () => runAfterReply(options),
  });
  const stopWatching = watchReplies(options.idleDelayMs);
  return () => {
    removeJob();
    stopWatching();
  };
}

let watchers = 0;
let stopReaction: (() => void) | null = null;

/**
 * Drives the after-reply queue from `isGenerating`. Shared by every engine
 * that registers a job (prompt, memory); the first caller's delay applies.
 */
export function watchReplies(delayMs: number = 400): () => void {
  if (watchers++ === 0) {
    stopReaction = reaction(
      () => chatSessionStore.isGenerating,
      (generating, wasGenerating) => {
        if (generating) {
          // The user sent again: jobs that have not started are dropped.
          afterReplyQueue.cancel();
        } else if (wasGenerating) {
          afterReplyQueue.schedule(delayMs);
        }
      },
    );
  }
  let stopped = false;
  return () => {
    if (stopped) {
      return;
    }
    stopped = true;
    if (--watchers === 0) {
      stopReaction?.();
      stopReaction = null;
      afterReplyQueue.cancel();
    }
  };
}

const UPSTREAM_PLACEHOLDER_TITLE = 'New Session';
const YIELD_POLL_MS = 120;

const firstUserText = (messages: ChatMessage[]): string => {
  const first = messages.find(message => message.role === 'user');
  return first ? messageText(first).text : '';
};

/**
 * Is this still the title upstream set by itself (the placeholder, or the
 * first 40 characters of the first message)? Anything else was typed by the
 * user and is left alone.
 */
export function isAutomaticTitle(
  title: string | undefined,
  firstMessage: string,
): boolean {
  if (!title || title === UPSTREAM_PLACEHOLDER_TITLE) {
    return true;
  }
  const stem = title.replace(/\.\.\.$/, '');
  return stem.length > 0 && firstMessage.startsWith(stem);
}

/**
 * The newest message of a chat. Upstream keeps a session's messages newest
 * first (index 0); stores built in tests keep them oldest first. The
 * creation time decides, so both orders work.
 */
export function newestMessage<T extends {createdAt?: number}>(
  messages: readonly T[] | undefined,
): T | undefined {
  if (!messages || messages.length === 0) {
    return undefined;
  }
  const first = messages[0];
  const last = messages[messages.length - 1];
  return (first.createdAt ?? 0) > (last.createdAt ?? 0) ? first : last;
}

/** One pass after a finished reply; exported for tests. */
export async function runAfterReply(
  options: PostTurnHookOptions = {},
): Promise<void> {
  const sent = getLastSentRequest();
  const sessionId = chatSessionStore.activeSessionId ?? undefined;
  if (!sent || sent.sessionId !== sessionId || !sessionId) {
    return;
  }
  const session = chatSessionStore.sessions.find(s => s.id === sessionId);
  const last = newestMessage(session?.messages);
  if (!session || !last || last.type !== 'assistant_turn') {
    return;
  }
  const reply = derivedText(last);
  if (!reply.trim()) {
    return;
  }
  const lease = modelStore.tryAcquireGeneration();
  if (!lease) {
    return;
  }
  // A new send queues behind this lease and flags `isStopping`. Give way at
  // once: the user's message always beats a background job.
  const yieldToUser = setInterval(() => {
    if (chatSessionStore.isStopping) {
      lease.abort();
    }
  }, YIELD_POLL_MS);
  try {
    const runtime = resolveSeamRuntime({signal: lease.signal});
    const result = await runPostTurn({
      engine: lease.engine,
      runtime,
      sessionId,
      messages: sent.messages,
      fullMessages: sent.prepared.meta.contextInput as
        | ChatMessage[]
        | undefined,
      reply,
      signal: lease.signal,
      ...options,
    });
    // Write the title (generated, or the clean fallback) unless the user
    // has renamed the chat in the meantime.
    const current = chatSessionStore.sessions.find(s => s.id === sessionId);
    if (
      result.title &&
      !lease.signal.aborted &&
      isAutomaticTitle(current?.title, firstUserText(sent.messages))
    ) {
      await chatSessionStore.updateSessionTitleBySessionId(
        sessionId,
        result.title,
      );
    }
    if (result.followUps.length) {
      followUpListeners.forEach(listener =>
        listener(sessionId, result.followUps),
      );
    }
  } finally {
    clearInterval(yieldToUser);
    lease.end();
  }
}
