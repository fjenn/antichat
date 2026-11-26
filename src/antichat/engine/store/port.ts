import type {MarkdownOptions} from './markdown';
import type {
  HistoryListing,
  HistoryOptions,
  ImportOptions,
  ImportResult,
  SearchHit,
  SearchOptions,
  SessionMeta,
  ThreadMessage,
} from './types';

/**
 * What the rest of AntiChat may ask of the conversation store. Local
 * definition: M1 publishes the shared `ConversationPort` in
 * `src/antichat/contracts/`; when it lands, this interface is reconciled
 * with it (alias or thin wrapper) and UI code imports the contract.
 *
 * All ids are upstream ids: `sessionId` is the chat's id in upstream's
 * `chat_sessions`, `messageId` the id of a message in the visible thread.
 */
export interface ConversationPort {
  /** Resolves once antichat.db is open, migrated and in step with upstream. */
  ready(): Promise<void>;
  /** Fires after anything changed (history, flags, thread). */
  subscribe(listener: () => void): () => void;

  // History and search
  listHistory(options?: HistoryOptions): Promise<HistoryListing>;
  search(query: string, options?: SearchOptions): Promise<SearchHit[]>;
  getMeta(sessionId: string): Promise<SessionMeta | null>;

  // Thread and answer versions
  getThread(sessionId: string): Promise<ThreadMessage[]>;
  switchVersion(
    sessionId: string,
    messageId: string,
    target: number | 'previous' | 'next',
  ): Promise<ThreadMessage[]>;
  /** Brings a parked node (a search hit) into the visible thread. */
  showNode(sessionId: string, nodeId: string): Promise<ThreadMessage[]>;
  /** Copies the thread up to `messageId` into a new chat; returns its id. */
  branch(sessionId: string, messageId: string): Promise<string>;

  // Chat-level actions
  rename(sessionId: string, title: string): Promise<void>;
  setPinned(sessionId: string, pinned: boolean): Promise<void>;
  setArchived(sessionId: string, archived: boolean): Promise<void>;
  setLocked(sessionId: string, locked: boolean): Promise<void>;
  setProject(sessionId: string, projectId: string | null): Promise<void>;
  deleteSessions(sessionIds: string[]): Promise<void>;

  // Temporary chat
  /** The next chat that gets created is temporary. */
  startTemporaryChat(): void;
  cancelTemporaryChat(): void;
  isTemporaryPending(): boolean;
  /** "Save": turns the temporary chat into a normal one. */
  keepTemporaryChat(sessionId: string): Promise<void>;
  /** Deletes the temporary chat (leaving it, or closing the app). */
  discardTemporaryChat(sessionId: string): Promise<void>;

  // Export and import
  exportConversations(sessionIds?: string[]): Promise<Record<string, any>[]>;
  exportArchive(sessionIds?: string[]): Promise<Uint8Array>;
  exportMarkdown(sessionId: string, options?: MarkdownOptions): Promise<string>;
  importConversations(
    conversations: unknown[],
    options?: ImportOptions,
  ): Promise<ImportResult>;
  importArchive(
    bytes: Uint8Array,
    options?: ImportOptions,
  ): Promise<ImportResult>;
}
