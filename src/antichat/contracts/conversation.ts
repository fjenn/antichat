/**
 * ConversationPort: the chat list. M3 implements it (`antichat.db` beside
 * WatermelonDB); M4 builds the drawer contents against it.
 */
import type {Observable} from './common';

export interface ConversationView {
  id: string;
  title: string;
  /** Time of the last message. */
  updatedAt: number;
  createdAt: number;
  pinned: boolean;
  archived: boolean;
  /** Not saved, not in memory, gone when closed. */
  temporary: boolean;
  /** Needs device unlock before its title and messages are shown. */
  locked: boolean;
  projectId?: string;
  /** The chat this one was branched from. */
  branchedFrom?: {conversationId: string; messageId: string};
}

export type DateBucket =
  | 'today'
  | 'yesterday'
  | 'previous7Days'
  | 'previous30Days'
  | 'older';

export interface ConversationSection {
  /** `pinned`, or a date bucket the UI words from the locale file. */
  key: 'pinned' | DateBucket;
  conversations: ConversationView[];
}

export interface SearchHit {
  conversation: ConversationView;
  /** Message the snippet comes from; absent for a title match. */
  messageId?: string;
  /** Text around the match. */
  snippet?: string;
  /** Ranges of `snippet` (or the title) to highlight: [start, end). */
  matches: Array<[number, number]>;
  /**
   * Ranges of the title to highlight when the hit also carries a message
   * snippet (M4). Absent: `matches` belongs to the title if there is no
   * snippet.
   */
  titleMatches?: Array<[number, number]>;
}

export interface SearchOptions {
  filter?: 'all' | 'chats' | 'images' | 'documents';
  limit?: number;
}

export interface ConversationPort extends Observable {
  /** Saved chats, newest first; no archived or temporary ones. */
  readonly conversations: readonly ConversationView[];
  /** The same chats grouped for the drawer: pinned first, then by date. */
  sections(now?: number): ConversationSection[];
  get(id: string): ConversationView | undefined;
  archived(): readonly ConversationView[];

  create(options?: {
    temporary?: boolean;
    projectId?: string;
  }): Promise<ConversationView>;
  rename(id: string, title: string): Promise<void>;
  setPinned(id: string, pinned: boolean): Promise<void>;
  setArchived(id: string, archived: boolean): Promise<void>;
  setLocked(id: string, locked: boolean): Promise<void>;
  /** Keep a temporary chat. */
  saveTemporary(id: string): Promise<void>;
  remove(id: string): Promise<void>;
  removeAll(): Promise<void>;
  /** New chat holding the thread up to and including `messageId`. */
  branch(id: string, messageId: string): Promise<ConversationView>;

  search(query: string, options?: SearchOptions): Promise<SearchHit[]>;
}
