/**
 * Conversation adapter (M3): joins the conversation store
 * (`src/antichat/engine/store/`, antichat.db) to upstream's chat tables and
 * its ChatSessionStore, and exposes the result as a `ConversationPort`.
 *
 * Upstream keeps owning the visible thread. This file
 *  - reads and writes upstream's WatermelonDB rows for the store
 *    (`WatermelonGateway`),
 *  - watches ChatSessionStore and folds what upstream wrote into the tree,
 *  - installs the edit / regenerate hook (`antichatStoreHooks`),
 *  - keeps ChatSessionStore's in-memory lists in step after a tail swap,
 *    branch, import or delete.
 */
import {Q} from '@nozbe/watermelondb';
import {reaction, runInAction} from 'mobx';

import {database} from '../../database';
import {chatSessionRepository} from '../../repositories/ChatSessionRepository';
import {chatSessionStore} from '../../store/ChatSessionStore';
import type {SessionMetaData} from '../../store/ChatSessionStore';
import {assistantId, userId} from '../../utils/chat';
import {migrateCompletionSettings} from '../../utils/completionSettingsVersions';

import {ConversationStore} from '../engine/store/ConversationStore';
import {Db} from '../engine/store/driver';
import type {SqlDriver} from '../engine/store/driver';
import {listHistory} from '../engine/store/history';
import type {ConversationPort} from '../engine/store/port';
import {searchConversations} from '../engine/store/search';
import {
  exportArchive,
  exportConversations,
  exportSessionMarkdown,
  importArchive,
  importConversations,
} from '../engine/store/transfer';
import type {UpMessage, UpSession} from '../engine/store/types';
import type {UpstreamGateway} from '../engine/store/upstream';
import {installStoreHooks} from '../engine/store/upstreamHooks';

const SYNC_DEBOUNCE_MS = 300;

function parseMetadata(raw: unknown): Record<string, any> {
  if (typeof raw !== 'string' || raw.length === 0) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

function toUpSession(record: any): UpSession {
  const fromDate = Date.parse(record.date);
  return {
    id: record.id,
    title: record.title ?? '',
    createdAt: Number.isFinite(fromDate) ? fromDate : (record.createdAt ?? 0),
    pinned: record.pinned === true,
  };
}

function toUpMessage(record: any): UpMessage {
  const message: UpMessage = {
    id: record.id,
    author: record.author,
    type: record.type,
    createdAt: record.createdAt ?? 0,
    metadata: parseMetadata(record.metadata),
  };
  if (typeof record.text === 'string') {
    message.text = record.text;
  }
  return message;
}

/** Upstream's chat tables, reached the way upstream reaches them. */
export class WatermelonGateway implements UpstreamGateway {
  readonly authors = {user: userId, assistant: assistantId};

  private sessions() {
    return database.collections.get('chat_sessions');
  }

  private messages() {
    return database.collections.get('messages');
  }

  private messageRows(sessionId: string): Promise<any[]> {
    return this.messages()
      .query(Q.where('session_id', sessionId), Q.sortBy('position', Q.asc))
      .fetch();
  }

  private writeMessage(
    record: any,
    sessionId: string,
    message: UpMessage,
    position: number,
  ) {
    record._raw.id = message.id;
    record.sessionId = sessionId;
    record.author = message.author;
    if (typeof message.text === 'string') {
      record.text = message.text;
    }
    record.type = message.type;
    record.metadata = JSON.stringify(message.metadata ?? {});
    record.position = position;
    record.createdAt = message.createdAt;
  }

  async listSessions(): Promise<UpSession[]> {
    const records = await this.sessions().query().fetch();
    return records.map(toUpSession);
  }

  async getSession(sessionId: string): Promise<UpSession | null> {
    const record = await this.sessions()
      .find(sessionId)
      .catch(() => null);
    return record ? toUpSession(record) : null;
  }

  async getMessages(sessionId: string): Promise<UpMessage[]> {
    return (await this.messageRows(sessionId)).map(toUpMessage);
  }

  async createSession(input: {
    title: string;
    createdAt?: number;
    pinned?: boolean;
    messages: UpMessage[];
    likeSessionId?: string;
  }): Promise<string> {
    const like: any = input.likeSessionId
      ? await this.sessions()
          .find(input.likeSessionId)
          .catch(() => null)
      : null;
    let settings: string | null = null;
    if (like) {
      const rows: any[] = await database.collections
        .get('completion_settings')
        .query(Q.where('session_id', like.id))
        .fetch();
      settings = rows[0]?.settings ?? null;
    }
    if (!settings) {
      settings = JSON.stringify(
        migrateCompletionSettings(chatSessionStore.newChatCompletionSettings),
      );
    }
    const createdAt = input.createdAt ?? Date.now();

    let sessionId = '';
    await database.write(async () => {
      const session: any = await this.sessions().create((record: any) => {
        record.title = input.title;
        record.date = new Date(createdAt).toISOString();
        record.pinned = input.pinned === true;
        if (like?.activePalId) {
          record.activePalId = like.activePalId;
        }
        if (like?.settingsSource) {
          record.settingsSource = like.settingsSource;
        }
      });
      sessionId = session.id;
      await database.batch(
        database.collections
          .get('completion_settings')
          .prepareCreate((record: any) => {
            record.sessionId = sessionId;
            record.settings = settings;
          }),
        ...input.messages.map((message, index) =>
          this.messages().prepareCreate((record: any) =>
            this.writeMessage(record, sessionId, message, index + 1),
          ),
        ),
      );
    });

    // ChatSessionStore keeps its own list; add the chat without touching
    // the others (a full reload would drop the open chat's messages).
    const data =
      await chatSessionRepository.getSessionMetadataWithSettings(sessionId);
    if (data) {
      const meta: SessionMetaData = {
        id: sessionId,
        title: data.session.title,
        date: data.session.date,
        messages: [],
        completionSettings: data.completionSettings
          ? data.completionSettings.getSettings()
          : chatSessionStore.newChatCompletionSettings,
        activePalId: data.session.activePalId,
        settingsSource:
          (data.session.settingsSource as 'pal' | 'custom') || 'pal',
        pinned: data.session.pinned || false,
        messagesLoaded: false,
      };
      runInAction(() => {
        if (!chatSessionStore.sessions.some(item => item.id === sessionId)) {
          chatSessionStore.sessions.push(meta);
        }
      });
    }
    return sessionId;
  }

  async replaceTail(
    sessionId: string,
    keep: number,
    tail: UpMessage[],
  ): Promise<void> {
    const rows = await this.messageRows(sessionId);
    const basePosition = keep > 0 ? (rows[keep - 1]?.position ?? keep) : 0;
    await database.write(async () => {
      await database.batch(
        ...rows.slice(keep).map(row => row.prepareDestroyPermanently()),
        ...tail.map((message, index) =>
          this.messages().prepareCreate((record: any) =>
            this.writeMessage(
              record,
              sessionId,
              message,
              basePosition + index + 1,
            ),
          ),
        ),
      );
    });
    await this.reloadMessages(sessionId);
  }

  async renameSession(sessionId: string, title: string): Promise<void> {
    await chatSessionRepository.updateSessionTitle(sessionId, title);
    const session = chatSessionStore.sessions.find(
      item => item.id === sessionId,
    );
    if (session) {
      runInAction(() => {
        session.title = title;
      });
    }
  }

  async setPinned(sessionId: string, pinned: boolean): Promise<void> {
    await chatSessionRepository.setSessionPinned(sessionId, pinned);
    const session = chatSessionStore.sessions.find(
      item => item.id === sessionId,
    );
    if (session) {
      runInAction(() => {
        session.pinned = pinned;
      });
    }
  }

  async deleteSessions(sessionIds: string[]): Promise<void> {
    await chatSessionRepository.deleteSessions(sessionIds);
    const gone = new Set(sessionIds);
    if (
      chatSessionStore.activeSessionId &&
      gone.has(chatSessionStore.activeSessionId)
    ) {
      chatSessionStore.resetActiveSession();
    }
    runInAction(() => {
      chatSessionStore.sessions = chatSessionStore.sessions.filter(
        item => !gone.has(item.id),
      );
      for (const id of sessionIds) {
        chatSessionStore.sessionDrafts.delete(id);
      }
    });
  }

  /** After a tail swap: what removeMessagesFromId does to the open chat. */
  private async reloadMessages(sessionId: string): Promise<void> {
    const session = chatSessionStore.sessions.find(
      item => item.id === sessionId,
    );
    if (!session || !session.messagesLoaded) {
      return;
    }
    const data = await chatSessionRepository.getSessionById(sessionId);
    runInAction(() => {
      session.messages =
        data?.messages?.map(message => message.toMessageObject()) ?? [];
      if (chatSessionStore.activeSessionId === sessionId) {
        chatSessionStore.exitEditMode();
        chatSessionStore.lastCompletionResult = undefined;
        chatSessionStore.dismissedBannerVariants = new Set();
        chatSessionStore.consecutiveFullFailures = 0;
      }
    });
  }
}

export interface ConversationAdapter extends ConversationPort {
  /** The engine object, for other engine milestones (memory, files). */
  store(): Promise<ConversationStore>;
  /** Stops watching upstream and closes antichat.db. */
  dispose(): void;
}

export interface ConversationAdapterOptions {
  /** Opens antichat.db; defaults to op-sqlite. */
  openDriver?: () => SqlDriver;
  gateway?: UpstreamGateway;
}

export function createConversationAdapter(
  options: ConversationAdapterOptions = {},
): ConversationAdapter {
  let opening: Promise<ConversationStore> | null = null;
  let driver: SqlDriver | null = null;
  const disposers: Array<() => void> = [];
  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  const temporaryIds = new Set<string>();
  let temporaryPending = false;

  const open = (): Promise<ConversationStore> => {
    if (!opening) {
      opening = (async () => {
        driver = options.openDriver
          ? options.openDriver()
          : require('../engine/store/driver.opsqlite').openOpSqlite();
        const store = new ConversationStore({
          db: new Db(driver!),
          upstream: options.gateway ?? new WatermelonGateway(),
        });
        await store.init();
        watch(store);
        return store;
      })();
      opening.catch(() => {
        opening = null;
      });
    }
    return opening;
  };

  const report = (what: string) => (error: unknown) => {
    console.warn(`[antichat] conversation store: ${what} failed`, error);
  };

  const scheduleSync = (store: ConversationStore, sessionId: string) => {
    const existing = timers.get(sessionId);
    if (existing) {
      clearTimeout(existing);
    }
    timers.set(
      sessionId,
      setTimeout(() => {
        timers.delete(sessionId);
        store.syncSession(sessionId).catch(report('sync'));
      }, SYNC_DEBOUNCE_MS),
    );
  };

  /** Everything upstream does by itself reaches the tree from here. */
  const watch = (store: ConversationStore) => {
    disposers.push(
      installStoreHooks({
        beforeTruncate: (sessionId, messageId, includeMessage) =>
          store.beforeTruncate(sessionId, messageId, includeMessage),
      }),
    );

    // A chat was opened, created or left.
    disposers.push(
      reaction(
        () => chatSessionStore.activeSessionId,
        (sessionId, previous) => {
          if (sessionId && temporaryPending) {
            temporaryPending = false;
            temporaryIds.add(sessionId);
            store.markTemporary(sessionId).catch(report('markTemporary'));
          }
          if (previous && previous !== sessionId) {
            if (temporaryIds.has(previous)) {
              temporaryIds.delete(previous);
              store
                .discardTemporary(previous)
                .catch(report('discardTemporary'));
            } else {
              scheduleSync(store, previous);
            }
          }
          if (sessionId) {
            scheduleSync(store, sessionId);
          }
        },
      ),
    );

    // A message was added to or removed from the open chat.
    disposers.push(
      reaction(
        () => {
          const id = chatSessionStore.activeSessionId;
          const session = id
            ? chatSessionStore.sessions.find(item => item.id === id)
            : undefined;
          return session ? `${id}:${session.messages.length}` : '';
        },
        () => {
          const id = chatSessionStore.activeSessionId;
          if (id) {
            scheduleSync(store, id);
          }
        },
      ),
    );

    // An answer finished (or was stopped): capture its final text.
    disposers.push(
      reaction(
        () => chatSessionStore.isGenerating,
        generating => {
          const id = chatSessionStore.activeSessionId;
          if (!generating && id) {
            scheduleSync(store, id);
          }
        },
      ),
    );

    // Titles and pins upstream changes by itself; chats it deletes.
    let known = new Map<string, string>(
      chatSessionStore.sessions.map(item => [
        item.id,
        `${item.title}\u0000${item.pinned}`,
      ]),
    );
    disposers.push(
      reaction(
        () =>
          chatSessionStore.sessions.map(
            item => [item.id, `${item.title}\u0000${item.pinned}`] as const,
          ),
        entries => {
          const next = new Map(entries);
          let removed = false;
          for (const id of known.keys()) {
            if (!next.has(id)) {
              removed = true;
            }
          }
          for (const [id, signature] of next) {
            if (known.get(id) !== signature) {
              scheduleSync(store, id);
            }
          }
          known = next;
          if (removed) {
            store.syncAll().catch(report('syncAll'));
          }
        },
      ),
    );
  };

  const busy = () => {
    if (chatSessionStore.isGenerating) {
      throw new Error('An answer is being written; try again when it is done');
    }
  };

  return {
    store: open,
    async ready() {
      await open();
    },
    subscribe(listener) {
      let off: (() => void) | null = null;
      let cancelled = false;
      open()
        .then(store => {
          if (!cancelled) {
            off = store.onChange(listener);
          }
        })
        .catch(report('open'));
      return () => {
        cancelled = true;
        off?.();
      };
    },

    async listHistory(historyOptions) {
      return listHistory((await open()).db, historyOptions);
    },
    async search(query, searchOptions) {
      return searchConversations((await open()).db, query, searchOptions);
    },
    async getMeta(sessionId) {
      return (await open()).getMeta(sessionId);
    },

    async getThread(sessionId) {
      const store = await open();
      await store.syncSession(sessionId);
      return store.getThread(sessionId);
    },
    async switchVersion(sessionId, messageId, target) {
      busy();
      return (await open()).switchVersion(sessionId, messageId, target);
    },
    async showNode(sessionId, nodeId) {
      busy();
      return (await open()).showNode(sessionId, nodeId);
    },
    async branch(sessionId, messageId) {
      return (await open()).branch(sessionId, messageId);
    },

    async rename(sessionId, title) {
      return (await open()).rename(sessionId, title);
    },
    async setPinned(sessionId, pinned) {
      return (await open()).setPinned(sessionId, pinned);
    },
    async setArchived(sessionId, archived) {
      return (await open()).setArchived(sessionId, archived);
    },
    async setLocked(sessionId, locked) {
      return (await open()).setLocked(sessionId, locked);
    },
    async setProject(sessionId, projectId) {
      return (await open()).setProject(sessionId, projectId);
    },
    async deleteSessions(sessionIds) {
      return (await open()).deleteSessions(sessionIds);
    },

    startTemporaryChat() {
      temporaryPending = true;
    },
    cancelTemporaryChat() {
      temporaryPending = false;
    },
    isTemporaryPending() {
      return temporaryPending;
    },
    async keepTemporaryChat(sessionId) {
      temporaryIds.delete(sessionId);
      return (await open()).keepTemporary(sessionId);
    },
    async discardTemporaryChat(sessionId) {
      temporaryIds.delete(sessionId);
      return (await open()).discardTemporary(sessionId);
    },

    async exportConversations(sessionIds) {
      const store = await open();
      await store.syncAll();
      return exportConversations(store, sessionIds);
    },
    async exportArchive(sessionIds) {
      const store = await open();
      await store.syncAll();
      return exportArchive(store, sessionIds);
    },
    async exportMarkdown(sessionId, markdownOptions) {
      return exportSessionMarkdown(await open(), sessionId, markdownOptions);
    },
    async importConversations(conversations, importOptions) {
      return importConversations(await open(), conversations, importOptions);
    },
    async importArchive(bytes, importOptions) {
      return importArchive(await open(), bytes, importOptions);
    },

    dispose() {
      for (const off of disposers.splice(0)) {
        off();
      }
      for (const timer of timers.values()) {
        clearTimeout(timer);
      }
      timers.clear();
      driver?.close();
      driver = null;
      opening = null;
    },
  };
}

let shared: ConversationAdapter | null = null;

/** The app's conversation port. antichat.db opens on first use. */
export function conversationAdapter(): ConversationAdapter {
  if (!shared) {
    shared = createConversationAdapter();
  }
  return shared;
}
