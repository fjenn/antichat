/**
 * The one seam upstream's ChatSessionStore calls into (see
 * docs/UPSTREAM-PATCHES.md). No imports on purpose: upstream code and its
 * Jest suite load this file, and must not pull in op-sqlite through it.
 *
 * `src/antichat/adapters/conversation.ts` installs the real handler once
 * the conversation store is open; until then the hook does nothing and
 * upstream behaves as it always did.
 */
export interface StoreHooks {
  /**
   * Upstream is about to delete the messages of `sessionId` from
   * `messageId` onward (edit or regenerate). Resolves when the tail is
   * parked in antichat.db.
   */
  beforeTruncate(
    sessionId: string,
    messageId: string,
    includeMessage: boolean,
  ): Promise<void>;
}

const idle: StoreHooks = {
  beforeTruncate: async () => {},
};

let current: StoreHooks = idle;

export const antichatStoreHooks: StoreHooks = {
  async beforeTruncate(sessionId, messageId, includeMessage) {
    try {
      await current.beforeTruncate(sessionId, messageId, includeMessage);
    } catch (error) {
      // Parking failed: let upstream carry on rather than block the chat.
      console.warn('[antichat] beforeTruncate hook failed', error);
    }
  },
};

export function installStoreHooks(hooks: StoreHooks): () => void {
  current = hooks;
  return () => {
    if (current === hooks) {
      current = idle;
    }
  };
}
