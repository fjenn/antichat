/**
 * The idle pass (H2): when the user has left a chat, or the phone has sat
 * idle with the model loaded, read what is new in finished chats and
 * update memory and the chat digests.
 *
 * Rules:
 *  - Never from temporary chats. They have no rows in antichat.db, and the
 *    flag is checked again here.
 *  - Never while the user is generating: the pass takes the generation
 *    lease only if it is free and gives it up the moment the user sends.
 *  - Each chat is read once per new message: a watermark records how far
 *    the pass got, so nothing is extracted twice and a deleted memory is
 *    not brought back from an old chat.
 *  - A chat is read only when it has gone quiet (`quietMs`), so an ongoing
 *    conversation is extracted as a whole, corrections included.
 *
 * `MemoryScheduler` is pure (everything injected); `install.ts` binds it
 * to the app's stores.
 */
import type {DeviceClass} from '../prompt/types';
import type {Db} from '../store/driver';
import {getChatActivity, listChatActivity, userTurnsAfter} from '../store/read';
import {createChatResolver, type ChatResolver} from './chatScope';
import {DigestStore, ruleDigest, writeModelDigest} from './digest';
import {MAX_TURNS_PER_PASS, hasRememberCue} from './extraction';
import type {MemoryStore} from './MemoryStore';
import type {MemoryWriter, ModelAccess, SaveResult} from './writer';

/** A granted generation lease: the model, until `end` is called. */
export interface ModelLease extends ModelAccess {
  end(): void;
}

export interface SchedulerOptions {
  db: Db;
  store: MemoryStore;
  writer: MemoryWriter;
  digests?: DigestStore;
  resolveChat?: ChatResolver;
  /** Takes the model if nobody is using it; null when it is busy or absent. */
  acquireModel: () => ModelLease | null;
  deviceClass?: () => DeviceClass | undefined;
  now?: () => number;
  /** A chat must have been quiet this long before it is read (ms). */
  quietMs?: number;
  /**
   * The chat on screen is read only after it has been quiet this long
   * (ms, default 10 minutes): reading it costs its cached prompt prefix.
   */
  currentGraceMs?: number;
  /** Chats read per pass. */
  maxChatsPerPass?: number;
  /** Per-class switches; see `passPolicyFor`. */
  policy?: (deviceClass: DeviceClass) => PassPolicy;
}

export interface PassPolicy {
  /** Run the extraction prompt over finished chats. */
  extract: boolean;
  /** Let the model rewrite chat digests. */
  modelDigests: boolean;
}

/**
 * What the idle pass may do per device class.
 *
 * Extraction runs on every class, 4 GB phones included. The gap analysis
 * planned "tool only" for class A; the head-to-head says otherwise: with
 * LFM3 1.7B the background prompt plus the code screen reached precision
 * 0.97 / recall 1.00 (0.83 / 0.92 on unseen chats), the tool alone 0.90 /
 * 0.63 (0.75 / 0.54). See docs/antichat/m9-eval.md. The cost is one short
 * generation when a chat is left.
 *
 * Model-written digests are skipped on class A: a 4k context has no room
 * for the recent-chats block they feed.
 */
export function passPolicyFor(deviceClass: DeviceClass): PassPolicy {
  return {extract: true, modelDigests: deviceClass !== 'A'};
}

export interface PendingChat {
  sessionId: string;
  /** Highest `seq` on the chat's visible path. */
  throughSeq: number;
  updatedAt: number;
}

export interface PassResult {
  ran: boolean;
  /** Why nothing ran: 'off' | 'paused' | 'busy' | 'nothing'. */
  reason?: 'off' | 'busy' | 'nothing';
  chats: number;
  saved: SaveResult[];
  digests: number;
  reviewed: number;
  aborted: boolean;
}

export class MemoryScheduler {
  private readonly options: SchedulerOptions;
  private readonly now: () => number;
  private readonly resolveChat: ChatResolver;
  private running: Promise<PassResult> | null = null;

  constructor(options: SchedulerOptions) {
    this.options = options;
    this.now = options.now ?? Date.now;
    this.resolveChat = options.resolveChat ?? createChatResolver(options.db);
  }

  private policy(): PassPolicy {
    const deviceClass = this.options.deviceClass?.() ?? 'B';
    return (this.options.policy ?? passPolicyFor)(deviceClass);
  }

  /**
   * Chats with messages the pass has not read, quiet for `quietMs`, newest
   * first. Temporary chats are excluded by the query and have no nodes.
   */
  async pendingChats(currentSessionId?: string | null): Promise<PendingChat[]> {
    const now = this.now();
    const quiet = now - (this.options.quietMs ?? 60_000);
    const currentQuiet = now - (this.options.currentGraceMs ?? 600_000);
    const [chats, marks] = await Promise.all([
      listChatActivity(this.options.db, {quietSince: quiet}),
      this.options.db.all<{session_id: string; through_seq: number}>(
        'SELECT session_id, through_seq FROM memory_extraction',
      ),
    ]);
    const done = new Map(marks.map(row => [row.session_id, row.through_seq]));
    return chats
      .filter(
        chat =>
          chat.topSeq > (done.get(chat.sessionId) ?? 0) &&
          (chat.sessionId !== currentSessionId ||
            chat.lastWrite <= currentQuiet),
      )
      .map(chat => ({
        sessionId: chat.sessionId,
        throughSeq: chat.topSeq,
        updatedAt: chat.updatedAt,
      }));
  }

  /** The user's messages of a chat after `afterSeq`, oldest first. */
  private userTurns(sessionId: string, afterSeq: number): Promise<string[]> {
    return userTurnsAfter(this.options.db, sessionId, afterSeq);
  }

  /**
   * One pass. `leaving` is the chat the user just left: it is read even if
   * it was active a moment ago. `current` is the chat on screen: it is
   * skipped while the conversation is going, so its cached prompt prefix
   * is not thrown away mid-chat.
   */
  runPass(
    input: {leaving?: string | null; current?: string | null} = {},
  ): Promise<PassResult> {
    if (!this.running) {
      this.running = this.pass(input).finally(() => {
        this.running = null;
      });
    }
    return this.running;
  }

  private async pass(input: {
    leaving?: string | null;
    current?: string | null;
  }): Promise<PassResult> {
    const {store, writer, db} = this.options;
    const result: PassResult = {
      ran: false,
      chats: 0,
      saved: [],
      digests: 0,
      reviewed: 0,
      aborted: false,
    };
    const settings = store.getSettings();
    if (!settings.enabled) {
      return {...result, reason: 'off'};
    }
    await store.purge();
    const policy = this.policy();
    const pending = await this.pendingChats(input.current);
    if (input.leaving && !pending.some(c => c.sessionId === input.leaving)) {
      // The chat just left has not been quiet yet; read it anyway.
      const left = await getChatActivity(db, input.leaving);
      if (
        left?.topSeq &&
        !left.temporary &&
        left.topSeq > (await store.extractedThrough(input.leaving))
      ) {
        pending.unshift({
          sessionId: input.leaving,
          throughSeq: left.topSeq,
          updatedAt: left.updatedAt,
        });
      }
    }
    const chats = pending.slice(0, this.options.maxChatsPerPass ?? 4);
    const needsReview = (await store.needingReview()).length > 0;
    if (chats.length === 0 && !needsReview) {
      return {...result, reason: 'nothing'};
    }

    // Digests by rule cost nothing and need no model.
    const digests = this.options.digests;
    const turnsByChat = new Map<string, string[]>();
    for (const chat of chats) {
      const done = await store.extractedThrough(chat.sessionId);
      const turns = await this.userTurns(chat.sessionId, done);
      turnsByChat.set(chat.sessionId, turns);
      if (digests && settings.referenceChats) {
        const existing = await digests.get(chat.sessionId);
        if (!existing || existing.source === 'rule') {
          const all = await this.userTurns(chat.sessionId, 0);
          await digests.set(
            chat.sessionId,
            ruleDigest(all),
            chat.throughSeq,
            'rule',
          );
          result.digests++;
        }
      }
    }

    const wantsModel =
      needsReview ||
      (policy.extract && settings.autoExtract && store.canWrite) ||
      (policy.modelDigests && settings.referenceChats && !!digests);
    if (!wantsModel) {
      // Nothing for the model to do: mark the chats as read by rule.
      if (!policy.extract || !settings.autoExtract) {
        for (const chat of chats) {
          await store.markExtracted(chat.sessionId, chat.throughSeq);
        }
      }
      return {...result, ran: true, chats: chats.length};
    }
    const lease = this.options.acquireModel();
    if (!lease) {
      return {...result, ran: result.digests > 0, reason: 'busy'};
    }
    result.ran = true;
    try {
      if (needsReview) {
        result.reviewed = await writer.reviewPending(lease);
      }
      for (const chat of chats) {
        if (lease.signal?.aborted) {
          result.aborted = true;
          break;
        }
        const info = await this.resolveChat(chat.sessionId);
        if (info.temporary) {
          continue;
        }
        if (info.readOnly) {
          // Offline chat: nothing is mined or digested, now or later.
          await store.markExtracted(chat.sessionId, chat.throughSeq);
          continue;
        }
        const turns = turnsByChat.get(chat.sessionId) ?? [];
        if (policy.extract && settings.autoExtract && store.canWrite) {
          if (turns.length > 0) {
            const extracted = await writer.extractAndSave({
              turns: turns.slice(-MAX_TURNS_PER_PASS),
              scope: info.scope,
              sessionId: chat.sessionId,
              model: lease,
            });
            if (!extracted.ok) {
              // Aborted or failed: leave the watermark so it is retried.
              result.aborted = !!lease.signal?.aborted;
              if (result.aborted) {
                break;
              }
              continue;
            }
            result.saved.push(...extracted.results);
          }
        }
        // Paused or switched off: the chat still counts as read, so that
        // un-pausing later does not mine what was said while paused.
        await store.markExtracted(chat.sessionId, chat.throughSeq);
        result.chats++;

        if (
          digests &&
          policy.modelDigests &&
          settings.referenceChats &&
          turns.length > 0 &&
          !lease.signal?.aborted
        ) {
          const previous = await digests.get(chat.sessionId);
          if (previous?.source === 'suppressed') {
            continue;
          }
          const note = await writeModelDigest({
            engine: lease.engine,
            family: lease.family,
            previous: previous?.source === 'model' ? previous.digest : null,
            turns,
            signal: lease.signal,
          });
          if (note) {
            await digests.set(chat.sessionId, note, chat.throughSeq, 'model');
            result.digests++;
          }
        }
      }
      if (!lease.signal?.aborted) {
        await writer.indexMissing().catch(() => 0);
      }
    } finally {
      lease.end();
    }
    return result;
  }

  /**
   * The safety net for "remember that …" (the Mac app's per-turn capture):
   * the user asked, the reply is finished, and the model did not call
   * `save_memory`. One extraction call on that message alone, right away.
   * Returns null when the model is busy or nothing was asked.
   */
  async captureExplicit(input: {
    sessionId?: string | null;
    userText: string;
    /** `save_memory` was called during the reply. */
    toolSaved: boolean;
  }): Promise<SaveResult[] | null> {
    const {store, writer} = this.options;
    if (input.toolSaved || !store.canWrite) {
      return null;
    }
    if (!hasRememberCue(input.userText)) {
      return null;
    }
    const info = await this.resolveChat(input.sessionId);
    if (info.temporary || info.readOnly) {
      return null;
    }
    const lease = this.options.acquireModel();
    if (!lease) {
      return null;
    }
    try {
      const extracted = await writer.extractAndSave({
        turns: [input.userText],
        scope: info.scope,
        sessionId: input.sessionId,
        model: lease,
        fresh: true,
      });
      return extracted.results;
    } finally {
      lease.end();
    }
  }
}
