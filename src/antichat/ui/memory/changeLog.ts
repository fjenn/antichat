import type {MemoryChange} from './types';

const EMPTY: readonly MemoryChange[] = [];
const MAX_PER_CHAT = 20;

/** In-memory record of what memory did per chat, for "Memory updated". */
export class ChangeLog {
  private readonly byChat = new Map<string, MemoryChange[]>();
  private nextKey = 1;

  add(change: Omit<MemoryChange, 'key'>): void {
    const list = this.byChat.get(change.conversationId) ?? [];
    // One line per memory: a later update replaces the earlier entry.
    const rest = list.filter(item => item.memoryId !== change.memoryId);
    const first = list.find(item => item.memoryId === change.memoryId);
    const merged: MemoryChange = {
      ...change,
      key: this.nextKey++,
      // Saved and then refined in the same chat is still "saved".
      kind: first?.kind === 'saved' ? 'saved' : change.kind,
      previousText: first?.previousText ?? change.previousText,
    };
    this.byChat.set(
      change.conversationId,
      [...rest, merged].slice(-MAX_PER_CHAT),
    );
  }

  for(conversationId: string): readonly MemoryChange[] {
    return this.byChat.get(conversationId) ?? EMPTY;
  }

  forget(memoryIds: string[]): void {
    const gone = new Set(memoryIds);
    for (const [chat, list] of this.byChat) {
      const kept = list.filter(item => !gone.has(item.memoryId));
      if (kept.length === 0) {
        this.byChat.delete(chat);
      } else if (kept.length !== list.length) {
        this.byChat.set(chat, kept);
      }
    }
  }

  dismiss(conversationId: string): void {
    this.byChat.delete(conversationId);
  }

  clear(): void {
    this.byChat.clear();
  }
}
