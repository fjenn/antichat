/**
 * The chat list as the UI wants it (`contracts/conversation.ts`: a
 * synchronous, observable list) on top of the conversation store's adapter
 * (`./conversation.ts`: everything asynchronous, read from antichat.db).
 *
 * This file only caches and maps. It re-reads the history after every store
 * change and tells its listeners when the mapped list is really different.
 */
import type {
  ConversationPort,
  ConversationSection,
  ConversationView,
  SearchHit,
  SearchOptions,
} from '../contracts/conversation';
import {Emitter} from '../contracts/common';
import {buildSections} from '../contracts/dateBuckets';
import type {ConversationPort as StorePort} from '../engine/store/port';
import type {
  HistoryItem,
  SearchHit as StoreSearchHit,
  TextSegment,
} from '../engine/store/types';

/** Upstream's title for a chat nobody has named yet. */
export const UPSTREAM_PLACEHOLDER_TITLE = 'New Session';

/** A chat as upstream's session list knows it (no archive or lock flags). */
export interface UpstreamChat {
  id: string;
  title: string;
  createdAt: number;
  pinned: boolean;
}

/** The little this wrapper needs from upstream's ChatSessionStore. */
export interface SessionGateway {
  /** Creates an empty chat, makes it the open one and returns its id. */
  createSession(): Promise<string | null>;
  /**
   * A chat upstream already has but the store has not folded in yet (the
   * store follows upstream with a short delay).
   */
  find(sessionId: string): UpstreamChat | undefined;
}

export interface ConversationPortOptions {
  store: StorePort;
  sessions: SessionGateway;
  now?: () => number;
}

const cleanTitle = (title: string | null | undefined): string =>
  !title || title === UPSTREAM_PLACEHOLDER_TITLE ? '' : title;

function viewOf(item: HistoryItem): ConversationView {
  const view: ConversationView = {
    id: item.sessionId,
    title: cleanTitle(item.title),
    updatedAt: item.updatedAt,
    createdAt: item.createdAt,
    pinned: item.pinned,
    archived: item.archived,
    temporary: false,
    locked: item.locked,
  };
  if (item.projectId) {
    view.projectId = item.projectId;
  }
  if (item.originKind === 'branch' && item.originSessionId) {
    // The history listing does not carry the message the branch left from.
    view.branchedFrom = {conversationId: item.originSessionId, messageId: ''};
  }
  return view;
}

function sameView(a: ConversationView, b: ConversationView): boolean {
  return (
    a.id === b.id &&
    a.title === b.title &&
    a.updatedAt === b.updatedAt &&
    a.createdAt === b.createdAt &&
    a.pinned === b.pinned &&
    a.archived === b.archived &&
    a.temporary === b.temporary &&
    a.locked === b.locked &&
    a.projectId === b.projectId &&
    a.branchedFrom?.conversationId === b.branchedFrom?.conversationId
  );
}

/** Joined text of highlighted runs plus the [start, end) of each match. */
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

export class StoreConversations extends Emitter implements ConversationPort {
  conversations: readonly ConversationView[] = EMPTY;
  private all: readonly ConversationView[] = EMPTY;
  private byId = new Map<string, ConversationView>();
  /** Temporary chats never reach the history listing; remembered here. */
  private readonly temporary = new Map<string, ConversationView>();
  private readonly store: StorePort;
  private readonly sessions: SessionGateway;
  private readonly now: () => number;
  private refreshing: Promise<void> | null = null;
  private stale = false;
  private unsubscribe: (() => void) | null = null;

  constructor(options: ConversationPortOptions) {
    super();
    this.store = options.store;
    this.sessions = options.sessions;
    this.now = options.now ?? Date.now;
    this.unsubscribe = this.store.subscribe(() => {
      this.refresh().catch(() => {});
    });
    this.refresh().catch(() => {});
  }

  dispose(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  /**
   * Re-reads the history. Calls that arrive while one read is running are
   * folded into a single follow-up read.
   */
  refresh(): Promise<void> {
    if (this.refreshing) {
      this.stale = true;
      return this.refreshing;
    }
    this.refreshing = (async () => {
      try {
        do {
          this.stale = false;
          const listing = await this.store.listHistory({
            scope: 'all',
            now: this.now(),
          });
          const items = [
            ...listing.pinned,
            ...listing.groups.flatMap(group => group.items),
          ];
          this.apply(items.map(viewOf));
        } while (this.stale);
      } catch (error) {
        console.warn('[antichat] chat list could not be read', error);
      } finally {
        this.refreshing = null;
      }
    })();
    return this.refreshing;
  }

  private apply(next: ConversationView[]): void {
    next.sort((a, b) => b.updatedAt - a.updatedAt);
    // Keep the old object for a chat that did not change, so rows that
    // compare by identity do not re-render.
    let changed = next.length !== this.all.length;
    const merged = next.map((view, index) => {
      const previous = this.byId.get(view.id);
      if (previous && sameView(previous, view)) {
        if (this.all[index] !== previous) {
          changed = true;
        }
        return previous;
      }
      changed = true;
      return view;
    });
    if (!changed) {
      return;
    }
    this.all = merged;
    this.byId = new Map(merged.map(view => [view.id, view]));
    this.conversations = merged.filter(view => !view.archived);
    for (const id of this.temporary.keys()) {
      // Saved in the meantime: the listing is the truth from here on.
      if (this.byId.has(id)) {
        this.temporary.delete(id);
      }
    }
    this.emit();
  }

  sections(now: number = this.now()): ConversationSection[] {
    return buildSections(this.conversations, now);
  }

  get(id: string): ConversationView | undefined {
    const known = this.byId.get(id) ?? this.temporary.get(id);
    if (known) {
      return known;
    }
    const upstream = this.sessions.find(id);
    if (!upstream) {
      return undefined;
    }
    const cached = this.pending.get(id);
    const title = cleanTitle(upstream.title);
    if (cached && cached.title === title && cached.pinned === upstream.pinned) {
      return cached;
    }
    const view: ConversationView = {
      id,
      title,
      updatedAt: upstream.createdAt,
      createdAt: upstream.createdAt,
      pinned: upstream.pinned,
      archived: false,
      temporary: false,
      locked: false,
    };
    this.pending.set(id, view);
    return view;
  }

  /** Views built from upstream for chats the store has not listed yet. */
  private readonly pending = new Map<string, ConversationView>();

  archived(): readonly ConversationView[] {
    return this.all.filter(view => view.archived);
  }

  async create(
    options: {temporary?: boolean; projectId?: string} = {},
  ): Promise<ConversationView> {
    if (options.temporary) {
      // The store marks the next chat upstream opens as temporary.
      this.store.startTemporaryChat();
    }
    let id: string | null = null;
    try {
      id = await this.sessions.createSession();
    } finally {
      if (!id && options.temporary) {
        this.store.cancelTemporaryChat();
      }
    }
    if (!id) {
      throw new Error('The chat could not be created');
    }
    const now = this.now();
    const view: ConversationView = {
      id,
      title: '',
      updatedAt: now,
      createdAt: now,
      pinned: false,
      archived: false,
      temporary: options.temporary === true,
      locked: false,
    };
    if (options.projectId) {
      view.projectId = options.projectId;
      await this.store.setProject(id, options.projectId).catch(() => {});
    }
    if (view.temporary) {
      this.temporary.set(id, view);
      this.emit();
    } else {
      await this.refresh();
    }
    return this.byId.get(id) ?? view;
  }

  async rename(id: string, title: string): Promise<void> {
    await this.store.rename(id, title.trim());
    await this.refresh();
  }

  async setPinned(id: string, pinned: boolean): Promise<void> {
    await this.store.setPinned(id, pinned);
    await this.refresh();
  }

  async setArchived(id: string, archived: boolean): Promise<void> {
    await this.store.setArchived(id, archived);
    await this.refresh();
  }

  async setLocked(id: string, locked: boolean): Promise<void> {
    await this.store.setLocked(id, locked);
    await this.refresh();
  }

  async saveTemporary(id: string): Promise<void> {
    await this.store.keepTemporaryChat(id);
    this.temporary.delete(id);
    await this.refresh();
    this.emit();
  }

  async remove(id: string): Promise<void> {
    if (this.temporary.has(id)) {
      this.temporary.delete(id);
      await this.store.discardTemporaryChat(id);
      this.emit();
      return;
    }
    await this.store.deleteSessions([id]);
    this.pending.delete(id);
    await this.refresh();
  }

  async removeAll(): Promise<void> {
    const ids = this.all.map(view => view.id);
    if (ids.length > 0) {
      await this.store.deleteSessions(ids);
    }
    this.pending.clear();
    await this.refresh();
  }

  async branch(id: string, messageId: string): Promise<ConversationView> {
    const newId = await this.store.branch(id, messageId);
    await this.refresh();
    const listed = this.byId.get(newId);
    if (listed) {
      return listed.branchedFrom
        ? {...listed, branchedFrom: {conversationId: id, messageId}}
        : listed;
    }
    const now = this.now();
    return {
      id: newId,
      title: cleanTitle(this.sessions.find(newId)?.title),
      updatedAt: now,
      createdAt: now,
      pinned: false,
      archived: false,
      temporary: false,
      locked: false,
      branchedFrom: {conversationId: id, messageId},
    };
  }

  async search(
    query: string,
    options: SearchOptions = {},
  ): Promise<SearchHit[]> {
    const filter = options.filter ?? 'all';
    // Only message text and titles are indexed so far.
    if (!query.trim() || filter === 'images' || filter === 'documents') {
      return [];
    }
    const hits = await this.store.search(query, {limit: options.limit});
    return hits.map(hit => this.hitOf(hit));
  }

  private hitOf(hit: StoreSearchHit): SearchHit {
    const conversation: ConversationView = this.byId.get(hit.sessionId) ?? {
      id: hit.sessionId,
      title: cleanTitle(hit.title),
      updatedAt: hit.updatedAt,
      createdAt: hit.updatedAt,
      pinned: false,
      archived: hit.archived,
      temporary: false,
      locked: hit.locked,
    };
    if (hit.snippet) {
      const {text, matches} = flattenSegments(hit.snippet.segments);
      const result: SearchHit = {conversation, snippet: text, matches};
      if (hit.snippet.messageId) {
        result.messageId = hit.snippet.messageId;
      }
      return result;
    }
    return {
      conversation,
      matches: hit.titleMatched
        ? flattenSegments(hit.titleSegments).matches
        : [],
    };
  }
}

const EMPTY: readonly ConversationView[] = Object.freeze([]);

let shared: StoreConversations | null = null;

/** The app's chat list, over the conversation store and upstream's sessions. */
export function conversationPort(): StoreConversations {
  if (!shared) {
    // Required here so a build on the fakes never opens antichat.db.
    const {conversationAdapter} =
      require('./conversation') as typeof import('./conversation');
    const {chatSessionStore, NEW_SESSION_TITLE} =
      require('../../store/ChatSessionStore') as typeof import('../../store/ChatSessionStore');
    shared = new StoreConversations({
      store: conversationAdapter(),
      sessions: {
        async createSession() {
          chatSessionStore.resetActiveSession();
          await chatSessionStore.createNewSession(NEW_SESSION_TITLE);
          return chatSessionStore.activeSessionId;
        },
        find(sessionId) {
          const session = chatSessionStore.sessions.find(
            item => item.id === sessionId,
          );
          if (!session) {
            return undefined;
          }
          const createdAt = Date.parse(session.date);
          return {
            id: session.id,
            title: session.title,
            createdAt: Number.isFinite(createdAt) ? createdAt : 0,
            pinned: session.pinned === true,
          };
        },
      },
    });
  }
  return shared;
}
