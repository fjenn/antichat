/**
 * Binds the memory and projects engine to the app, without touching an
 * upstream file:
 *  - registers the request providers behind M7's seam and the tools with
 *    upstream's talent registry;
 *  - watches `isGenerating` to record which memories an answer used and to
 *    catch a "remember that …" the model did not act on;
 *  - watches the active chat to run the idle pass when the user leaves a
 *    chat, and after a minute without activity.
 *
 * Call `registerMemorySchemas()` before the conversation store is
 * initialised, then `installMemoryEngine()` once antichat.db is open.
 */
import {reaction} from 'mobx';

import {talentRegistry} from '../../../services/talents/TalentRegistry';
import {chatSessionStore, modelStore} from '../../../store';
import {derivedText} from '../../../utils/chat';
import {messageText} from '../context/tokenCounter';
import {registerProjectMigrations} from '../projects/schema';
import {afterReplyQueue} from '../prompt/afterReply';
import {newestMessage, watchReplies} from '../prompt/postTurn';
import {registerRequestProvider} from '../prompt/registry';
import {getLastSentRequest, resolveSeamRuntime} from '../prompt/seam';
import type {DeviceClass} from '../prompt/types';
import {
  createMemoryEngine,
  type MemoryEngine,
  type MemoryEngineOptions,
} from './engine';
import {hasRememberCue} from './extraction';
import {registerMemoryMigrations} from './schema';
import type {ModelLease} from './scheduler';
import {SAVE_MEMORY} from './tools';

/** Adds the memory and projects migration steps to antichat.db's history. */
export function registerMemorySchemas(): void {
  registerMemoryMigrations();
  registerProjectMigrations();
}

export interface InstallOptions
  extends Pick<MemoryEngineOptions, 'db' | 'chats' | 'embedding'> {
  deviceClass?: () => DeviceClass | undefined;
  /** Wait after a reply before the post-reply work (ms). */
  afterReplyDelayMs?: number;
  /** Inactivity before the idle pass (ms). */
  idleMs?: number;
}

const YIELD_POLL_MS = 120;

/** The generation lease as a `ModelLease` that gives way to the user. */
function acquireModel(): ModelLease | null {
  const lease = modelStore.tryAcquireGeneration();
  if (!lease) {
    return null;
  }
  // A new send queues behind this lease and flags `isStopping`: step aside
  // at once, the user's message always beats a background job.
  const yieldToUser = setInterval(() => {
    if (chatSessionStore.isStopping) {
      lease.abort();
    }
  }, YIELD_POLL_MS);
  return {
    engine: lease.engine,
    family: resolveSeamRuntime().family,
    signal: lease.signal,
    end: () => {
      clearInterval(yieldToUser);
      lease.end();
    },
  };
}

/**
 * What happens once a reply is on screen: the use record of that answer is
 * tied to the message and marked with the memories it drew on, and a
 * "remember that …" the model did not act on is captured. Resolves true
 * when the capture could not run because the model was busy.
 */
export async function handleReply(
  engine: MemoryEngine,
  attempt: number = 0,
): Promise<boolean> {
  const sent = getLastSentRequest();
  const sessionId = chatSessionStore.activeSessionId ?? undefined;
  if (!sent || !sessionId || sent.sessionId !== sessionId) {
    return false;
  }
  const session = chatSessionStore.sessions.find(s => s.id === sessionId);
  const last = newestMessage(session?.messages);
  if (!last || last.type !== 'assistant_turn') {
    return false;
  }
  const users = sent.messages.filter(message => message.role === 'user');
  const userText = users.length
    ? messageText(users[users.length - 1]).text
    : '';
  const steps = (last as {steps?: Array<{toolCalls?: any[]}>}).steps ?? [];
  const toolsCalled = steps.flatMap(step =>
    (step.toolCalls ?? []).map(call => String(call?.function?.name ?? '')),
  );
  const outcome = await engine.afterReply({
    sessionId,
    messageId: last.id,
    userText,
    reply: derivedText(last),
    // The use record is confirmed once; retries only repeat the capture.
    meta: attempt === 0 ? sent.prepared.meta : undefined,
    toolsCalled,
  });
  return (
    outcome.captured === null &&
    hasRememberCue(userText) &&
    !toolsCalled.includes(SAVE_MEMORY) &&
    engine.store.canWrite
  );
}

let installed: {engine: MemoryEngine; remove: () => void} | null = null;

/** The installed engine, for UI code (manage screen, chip, projects). */
export function getMemoryEngine(): MemoryEngine | null {
  return installed?.engine ?? null;
}

export async function installMemoryEngine(
  options: InstallOptions,
): Promise<MemoryEngine> {
  if (installed) {
    return installed.engine;
  }
  registerMemorySchemas();
  const engine = createMemoryEngine({
    db: options.db,
    chats: options.chats,
    embedding: options.embedding,
    deviceClass: options.deviceClass,
    acquireModel,
    currentSessionId: () => chatSessionStore.activeSessionId,
    currentUserText: () => {
      const sent = getLastSentRequest();
      const users = (sent?.messages ?? []).filter(m => m.role === 'user');
      return users.length
        ? messageText(users[users.length - 1]).text
        : undefined;
    },
    nCtx: () => resolveSeamRuntime().nCtx,
  });
  await engine.init();
  engine.tools.forEach(tool => talentRegistry.register(tool));
  const removers = engine.providers.map(provider =>
    registerRequestProvider(provider),
  );

  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  const background = (work: Promise<unknown>) =>
    work.catch(error => console.warn('[antichat] memory job failed', error));

  const armIdle = () => {
    if (idleTimer) {
      clearTimeout(idleTimer);
    }
    idleTimer = setTimeout(() => {
      if (!chatSessionStore.isGenerating) {
        background(engine.idle());
      }
    }, options.idleMs ?? 60_000);
  };

  // After the title and follow-ups (order 10) in the shared queue, so the
  // capture finds the generation lease free instead of retrying on a timer.
  const removeJob = afterReplyQueue.register({
    id: 'memory.after-reply',
    order: 50,
    run: async () => {
      await handleReply(engine);
    },
  });
  const stopWatching = watchReplies(options.afterReplyDelayMs);
  const disposeReply = reaction(
    () => chatSessionStore.isGenerating,
    (generating, wasGenerating) => {
      if (!generating && wasGenerating) {
        armIdle();
      }
    },
  );
  const disposeLeave = reaction(
    () => chatSessionStore.activeSessionId,
    (_current, previous) => {
      if (previous) {
        background(engine.leaveChat(previous));
      }
      armIdle();
    },
  );
  armIdle();

  const remove = () => {
    disposeReply();
    disposeLeave();
    removeJob();
    stopWatching();
    removers.forEach(fn => fn());
    // The tools stay in upstream's registry (it has no remove); without
    // the provider they are never offered, so they cannot be called.
    if (idleTimer) {
      clearTimeout(idleTimer);
    }
    installed = null;
  };
  installed = {engine, remove};
  return engine;
}

/** Removes providers and watchers again (tests, hot reload). */
export function uninstallMemoryEngine(): void {
  installed?.remove();
}
