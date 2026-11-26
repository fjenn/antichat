import type {UpMessage, UpSession} from './types';

/**
 * Everything the conversation store asks of upstream's chat tables
 * (WatermelonDB `chat_sessions` / `messages`). The real implementation lives
 * in `src/antichat/adapters/conversation.ts`; Jest uses an in-memory fake.
 *
 * Contract: after any store operation, `getMessages(sessionId)` is exactly
 * the visible thread of that chat, oldest first.
 */
export interface UpstreamGateway {
  /** Upstream's fixed author ids. */
  readonly authors: {user: string; assistant: string};

  listSessions(): Promise<UpSession[]>;
  getSession(sessionId: string): Promise<UpSession | null>;
  /** Oldest first. */
  getMessages(sessionId: string): Promise<UpMessage[]>;

  /**
   * Creates a chat holding `messages` (oldest first) and returns its id.
   * Message ids are kept. `likeSessionId` copies that chat's settings.
   */
  createSession(input: {
    title: string;
    createdAt?: number;
    pinned?: boolean;
    messages: UpMessage[];
    likeSessionId?: string;
  }): Promise<string>;

  /**
   * Keeps the first `keep` messages of the chat, deletes the rest and
   * appends `tail` (ids kept), in one atomic write.
   */
  replaceTail(
    sessionId: string,
    keep: number,
    tail: UpMessage[],
  ): Promise<void>;

  renameSession(sessionId: string, title: string): Promise<void>;
  setPinned(sessionId: string, pinned: boolean): Promise<void>;
  deleteSessions(sessionIds: string[]): Promise<void>;
}
