/**
 * History adapter (M4): the chat list of the conversation store as the
 * synchronous, observable `ConversationPort` the UI reads.
 *
 * M3's port (`engine/store/port.ts`) is asynchronous: every read is a query
 * on antichat.db. The drawer wants a list it can read during render, so this
 * file keeps a snapshot of the listing in memory, refreshes it whenever the
 * store says something changed, and applies the user's own actions to the
 * snapshot at once (the row moves before the database answers).
 *
 * The thread of a chat is not this file's business (M2: `adapters/chat.ts`);
 * `thread()` exists for export, branch and the search-hit stand-in only.
 */
import {Emitter} from '../contracts/common';
import type {
  ConversationPort,
  ConversationSection,
  ConversationView,
  SearchHit,
  SearchOptions,
} from '../contracts/conversation';
import {buildSections} from '../contracts/dateBuckets';
import type {ConversationPort as StorePort} from '../engine/store/port';
import type {
  HistoryItem,
  SearchHit as StoreSearchHit,
  SessionMeta,
  TextSegment,
} from '../engine/store/types';

/** One message of a chat's visible thread, as far as history needs it. */
export interface HistoryMessage {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  createdAt: number;
}

export type ExportFormat = 'markdown' | 'text' | 'chatgpt';

export interface ExportedChat {
  format: ExportFormat;
  /** File name without a path, safe on both platforms. */
  fileName: string;
  mimeType: string;
  content: string;
}

/** What M4's screens use beyond the shared contract. */
export interface HistoryPort extends ConversationPort {
  /** False until the first listing has been read from the database. */
  readonly loaded: boolean;
  /** Resolves when `loaded` turns true. */
  ready(): Promise<void>;
  /**
   * The next chat that gets created is temporary (or not, after all). The
   * real store creates a chat with its first message, so the switch is set
   * before there is an id.
   */
  armTemporary(on: boolean): void;
  /** Throws away a temporary chat (leaving it). */
  discardTemporary(id: string): Promise<void>;
  /** The visible thread, oldest first. */
  thread(id: string): Promise<HistoryMessage[]>;
  exportChat(
    id: string,
    format: ExportFormat,
    labels?: {user: string; assistant: string},
  ): Promise<ExportedChat>;
}

/** A plain run of text and the [start, end) ranges to highlight in it. */
export function flattenSegments(segments: readonly TextSegment[]): {
  text: string;
  matches: Array<[number, number]>;
} {
  let text = '';
  const matches: Array<[number, number]> = [];
  for (const segment of segments) {
    if (segment.match && segment.text.length > 0) {
      matches.push([text.length, text.length + segment.text.length]);
    }
    text += segment.text;
  }
  return {text, matches};
}

function viewFromItem(item: HistoryItem): ConversationView {
  return {
    id: item.sessionId,
    title: item.title,
    updatedAt: item.updatedAt,
    createdAt: item.createdAt,
    pinned: item.pinned,
    archived: item.archived,
    temporary: false,
    locked: item.locked,
    ...(item.projectId ? {projectId: item.projectId} : null),
    ...(item.originKind === 'branch' && item.originSessionId
      ? {branchedFrom: {conversationId: item.originSessionId, messageId: ''}}
      : null),
  };
}

function viewFromMeta(meta: SessionMeta): ConversationView {
  return {
    id: meta.sessionId,
    title: meta.title,
    updatedAt: meta.updatedAt,
    createdAt: meta.createdAt,
    pinned: meta.pinnedAt !== null,
    archived: meta.archivedAt !== null,
    temporary: meta.temporary,
    locked: meta.locked,
    ...(meta.projectId ? {projectId: meta.projectId} : null),
    ...(meta.originKind === 'branch' && meta.originSessionId
      ? {
          branchedFrom: {
            conversationId: meta.originSessionId,
            messageId: meta.originNodeId ?? '',
          },
        }
      : null),
  };
}

/** A file name from a chat title: letters, digits, dashes; never empty. */
export function exportFileName(title: string, extension: string): string {
  const base = title
    .normalize('NFKD')
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return `${base || 'chat'}.${extension}`;
}

/** The thread as text a person would paste into a note. */
export function threadAsPlainText(
  title: string,
  messages: readonly HistoryMessage[],
  labels: {user: string; assistant: string},
): string {
  const lines: string[] = [];
  if (title.trim()) {
    lines.push(title.trim(), '');
  }
  for (const message of messages) {
    const text = message.text.trim();
    if (!text) {
      continue;
    }
    lines.push(
      `${message.role === 'user' ? labels.user : labels.assistant}:`,
      text,
      '',
    );
  }
  return lines.join('\n').trimEnd() + '\n';
}

export class StoreHistory extends Emitter implements HistoryPort {
  conversations: readonly ConversationView[] = [];
  loaded = false;

  private archivedList: readonly ConversationView[] = [];
  private byId = new Map<string, ConversationView>();
  /** Chats the listing leaves out (temporary ones), read on demand. */
  private offList = new Map<string, ConversationView | null>();
  private refreshing: Promise<void> | null = null;
  private dirty = false;
  private readonly firstLoad: Promise<void>;
  private resolveFirstLoad: () => void = () => {};
  private readonly unsubscribe: () => void;

  constructor(
    private readonly store: StorePort,
    private readonly now: () => number = Date.now,
  ) {
    super();
    this.firstLoad = new Promise(resolve => {
      this.resolveFirstLoad = resolve;
    });
    this.unsubscribe = store.subscribe(() => {
      this.refresh();
    });
    this.refresh();
  }

  dispose(): void {
    this.unsubscribe();
  }

  ready(): Promise<void> {
    return this.firstLoad;
  }

  /** Reads the listing again; calls that arrive meanwhile share one read. */
  refresh(): Promise<void> {
    if (this.refreshing) {
      this.dirty = true;
      return this.refreshing;
    }
    const run = async () => {
      do {
        this.dirty = false;
        try {
          const listing = await this.store.listHistory({scope: 'all'});
          const items = [
            ...listing.pinned,
            ...listing.groups.flatMap(group => group.items),
          ];
          this.replace(items.map(viewFromItem));
        } catch (error) {
          console.warn('[antichat] history: listing failed', error);
        }
      } while (this.dirty);
      this.refreshing = null;
      if (!this.loaded) {
        this.loaded = true;
        this.resolveFirstLoad();
      }
      this.emit();
    };
    this.refreshing = run();
    return this.refreshing;
  }

  private replace(all: ConversationView[]): void {
    const sorted = [...all].sort((a, b) => b.updatedAt - a.updatedAt);
    this.byId = new Map(sorted.map(view => [view.id, view]));
    this.conversations = sorted.filter(view => !view.archived);
    this.archivedList = sorted.filter(view => view.archived);
    // A chat that is listed now is no longer an off-list (temporary) one.
    for (const id of [...this.offList.keys()]) {
      if (this.byId.has(id)) {
        this.offList.delete(id);
      }
    }
  }

  /** The user's action shows at once; the store's answer follows. */
  private patch(id: string, fields: Partial<ConversationView>): void {
    const current = this.byId.get(id);
    if (!current) {
      return;
    }
    this.replace(
      [...this.byId.values()].map(view =>
        view.id === id ? {...view, ...fields} : view,
      ),
    );
    this.emit();
  }

  private drop(ids: readonly string[]): void {
    const gone = new Set(ids);
    this.replace([...this.byId.values()].filter(view => !gone.has(view.id)));
    ids.forEach(id => this.offList.delete(id));
    this.emit();
  }

  /** Runs a store write; a failure puts the list back as the store has it. */
  private async write(work: () => Promise<void>): Promise<void> {
    try {
      await work();
    } catch (error) {
      await this.refresh();
      throw error;
    }
  }

  sections(now: number = this.now()): ConversationSection[] {
    return buildSections(this.conversations, now);
  }

  get(id: string): ConversationView | undefined {
    const listed = this.byId.get(id);
    if (listed) {
      return listed;
    }
    if (!this.offList.has(id)) {
      this.offList.set(id, null);
      this.store
        .getMeta(id)
        .then(meta => {
          if (meta && !this.byId.has(id)) {
            this.offList.set(id, viewFromMeta(meta));
            this.emit();
          } else if (!meta) {
            // Not written yet (a chat that was just created): ask again later.
            this.offList.delete(id);
          }
        })
        .catch(() => this.offList.delete(id));
    }
    return this.offList.get(id) ?? undefined;
  }

  archived(): readonly ConversationView[] {
    return this.archivedList;
  }

  /**
   * The real store has no empty chats: upstream creates one with its first
   * message. This only records whether that chat will be temporary and
   * returns a view without an id; the chat adapter's `send(null, …)` makes
   * the chat.
   */
  async create(
    options: {temporary?: boolean; projectId?: string} = {},
  ): Promise<ConversationView> {
    this.armTemporary(options.temporary === true);
    const now = this.now();
    return {
      id: '',
      title: '',
      updatedAt: now,
      createdAt: now,
      pinned: false,
      archived: false,
      temporary: options.temporary === true,
      locked: false,
      ...(options.projectId ? {projectId: options.projectId} : null),
    };
  }

  armTemporary(on: boolean): void {
    if (on) {
      this.store.startTemporaryChat();
    } else {
      this.store.cancelTemporaryChat();
    }
  }

  async rename(id: string, title: string): Promise<void> {
    const clean = title.replace(/\s+/g, ' ').trim();
    if (!clean) {
      return;
    }
    this.patch(id, {title: clean});
    await this.write(() => this.store.rename(id, clean));
  }

  async setPinned(id: string, pinned: boolean): Promise<void> {
    this.patch(id, {pinned});
    await this.write(() => this.store.setPinned(id, pinned));
  }

  async setArchived(id: string, archived: boolean): Promise<void> {
    const wasPinned = this.byId.get(id)?.pinned === true;
    this.patch(id, {archived, ...(archived ? {pinned: false} : null)});
    await this.write(async () => {
      if (archived && wasPinned) {
        await this.store.setPinned(id, false);
      }
      await this.store.setArchived(id, archived);
    });
  }

  async setLocked(id: string, locked: boolean): Promise<void> {
    this.patch(id, {locked});
    await this.write(() => this.store.setLocked(id, locked));
  }

  async saveTemporary(id: string): Promise<void> {
    this.offList.delete(id);
    await this.write(() => this.store.keepTemporaryChat(id));
    await this.refresh();
  }

  async discardTemporary(id: string): Promise<void> {
    this.offList.delete(id);
    await this.store.discardTemporaryChat(id);
  }

  async remove(id: string): Promise<void> {
    this.drop([id]);
    await this.write(() => this.store.deleteSessions([id]));
  }

  async removeAll(): Promise<void> {
    const ids = [...this.byId.keys()];
    this.drop(ids);
    await this.write(() => this.store.deleteSessions(ids));
  }

  async branch(id: string, messageId: string): Promise<ConversationView> {
    const newId = await this.store.branch(id, messageId);
    await this.refresh();
    const view = this.byId.get(newId);
    if (view) {
      return view;
    }
    const meta = await this.store.getMeta(newId);
    if (!meta) {
      throw new Error(`Branch ${newId} was not created`);
    }
    return viewFromMeta(meta);
  }

  async search(
    query: string,
    options: SearchOptions = {},
  ): Promise<SearchHit[]> {
    const hits = await this.store.search(query, {limit: options.limit ?? 40});
    return hits.map(hit => this.toHit(hit));
  }

  private toHit(hit: StoreSearchHit): SearchHit {
    const conversation = this.byId.get(hit.sessionId) ?? {
      id: hit.sessionId,
      title: hit.title,
      updatedAt: hit.updatedAt,
      createdAt: hit.updatedAt,
      pinned: false,
      archived: hit.archived,
      temporary: false,
      locked: hit.locked,
    };
    const title = flattenSegments(hit.titleSegments);
    if (!hit.snippet || hit.snippet.segments.length === 0) {
      return {conversation, matches: title.matches};
    }
    const snippet = flattenSegments(hit.snippet.segments);
    return {
      conversation,
      messageId: hit.snippet.messageId ?? undefined,
      snippet: snippet.text,
      matches: snippet.matches,
      titleMatches: title.matches,
    };
  }

  async thread(id: string): Promise<HistoryMessage[]> {
    const messages = await this.store.getThread(id);
    return messages
      .filter(
        message => message.role === 'user' || message.role === 'assistant',
      )
      .map(message => ({
        id: message.messageId,
        role: message.role as 'user' | 'assistant',
        text: message.text,
        createdAt: message.createdAt,
      }));
  }

  async exportChat(
    id: string,
    format: ExportFormat,
    labels: {user: string; assistant: string} = {
      user: 'You',
      assistant: 'AntiChat',
    },
  ): Promise<ExportedChat> {
    const title = this.byId.get(id)?.title ?? '';
    if (format === 'markdown') {
      return {
        format,
        fileName: exportFileName(title, 'md'),
        mimeType: 'text/markdown',
        content: await this.store.exportMarkdown(id, {
          userLabel: labels.user,
          assistantLabel: labels.assistant,
        }),
      };
    }
    if (format === 'chatgpt') {
      return {
        format,
        fileName: exportFileName(title, 'json'),
        mimeType: 'application/json',
        content: JSON.stringify(
          await this.store.exportConversations([id]),
          null,
          2,
        ),
      };
    }
    return {
      format,
      fileName: exportFileName(title, 'txt'),
      mimeType: 'text/plain',
      content: threadAsPlainText(title, await this.thread(id), labels),
    };
  }
}

export function isHistoryPort(port: ConversationPort): port is HistoryPort {
  return typeof (port as Partial<HistoryPort>).exportChat === 'function';
}

let shared: StoreHistory | null = null;

/** The app's chat list on the real store. antichat.db opens on first use. */
export function historyPort(): StoreHistory {
  if (!shared) {
    const {conversationAdapter} = require('./conversation');
    shared = new StoreHistory(conversationAdapter());
  }
  return shared;
}
