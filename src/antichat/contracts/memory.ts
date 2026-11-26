/**
 * MemoryPort: what the app remembers about the user across chats. M9
 * implements it; the memory screen and the "memory used" chip read it.
 */
import type {Observable} from './common';

export interface MemoryView {
  id: string;
  text: string;
  createdAt: number;
  updatedAt: number;
  /** `saved`: the user asked for it. `learned`: picked up from a chat. */
  origin: 'saved' | 'learned';
  /** Chat the memory came from. */
  conversationId?: string;
}

export interface MemoryPort extends Observable {
  /** Master switch: off means nothing is saved and nothing is used. */
  readonly enabled: boolean;
  readonly memories: readonly MemoryView[];
  setEnabled(enabled: boolean): Promise<void>;
  add(text: string): Promise<MemoryView>;
  update(id: string, text: string): Promise<void>;
  remove(id: string): Promise<void>;
  removeAll(): Promise<void>;
  /** Memories that were put into the prompt of an answer. */
  usedBy(messageId: string): readonly MemoryView[];
}
