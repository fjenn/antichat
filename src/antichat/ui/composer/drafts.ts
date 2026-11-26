/**
 * What was typed and not sent, per chat. Survives switching chats and
 * restarting the app; a sent message clears its draft.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';

const STORAGE_KEY = 'antichat.composer.drafts.v1';
const NEW_CHAT = '\u0000new';
const SAVE_DELAY_MS = 400;
/** Drafts kept on disk; the oldest go first. */
const MAX_STORED = 50;

const keyOf = (conversationId: string | null) => conversationId ?? NEW_CHAT;

export class DraftStore {
  /**
   * Off for the in-memory backend: its chat ids start over at every launch,
   * so a stored draft would turn up in some other chat.
   */
  persistent = true;
  private readonly drafts = new Map<string, string>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private loading: Promise<void> | null = null;

  /** Reads the stored drafts once. Typing never waits for it. */
  load(): Promise<void> {
    if (!this.persistent) {
      return Promise.resolve();
    }
    this.loading ??= AsyncStorage.getItem(STORAGE_KEY)
      .then(raw => {
        const stored: unknown = raw ? JSON.parse(raw) : null;
        if (Array.isArray(stored)) {
          for (const entry of stored) {
            if (
              Array.isArray(entry) &&
              typeof entry[0] === 'string' &&
              typeof entry[1] === 'string' &&
              !this.drafts.has(entry[0])
            ) {
              this.drafts.set(entry[0], entry[1]);
            }
          }
        }
      })
      .catch(() => {
        // Unreadable drafts are dropped.
      });
    return this.loading;
  }

  get(conversationId: string | null): string {
    return this.drafts.get(keyOf(conversationId)) ?? '';
  }

  set(conversationId: string | null, text: string): void {
    const key = keyOf(conversationId);
    if (text.length === 0) {
      if (!this.drafts.delete(key)) {
        return;
      }
    } else {
      if (this.drafts.get(key) === text) {
        return;
      }
      // Re-insert, so the map stays ordered oldest-first.
      this.drafts.delete(key);
      this.drafts.set(key, text);
    }
    this.scheduleSave();
  }

  clear(conversationId: string | null): void {
    this.set(conversationId, '');
  }

  /** A chat got its id on first send: its draft belonged to the new chat. */
  move(from: string | null, to: string | null): void {
    const text = this.get(from);
    if (text) {
      this.set(to, text);
      this.clear(from);
    }
  }

  private scheduleSave(): void {
    if (!this.persistent) {
      return;
    }
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      const entries = [...this.drafts.entries()].slice(-MAX_STORED);
      AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(entries)).catch(() => {
        // Not saved: the draft still holds for this run.
      });
    }, SAVE_DELAY_MS);
  }
}

export const drafts = new DraftStore();
