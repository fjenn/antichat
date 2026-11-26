/**
 * What the memory screens and chat components ask for. Two implementations:
 * `engineMemoryUi` over M9's engine port and `fakeMemoryUi` over the
 * contract fake (`getPorts().memory`), which the tests and an app without
 * the engine installed use.
 */
export interface MemoryRow {
  id: string;
  text: string;
  /** `saved`: the user asked for it. `learned`: picked up from a chat. */
  origin: 'saved' | 'learned';
  pinned: boolean;
  projectId: string | null;
  conversationId: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface MemoryState {
  /** Master switch: off means nothing is saved and nothing is used. */
  enabled: boolean;
  /** Memories are still used, nothing new is saved. */
  paused: boolean;
  /** Recent chats are referenced as well. */
  referenceChats: boolean;
}

/** Something memory did during a chat; what "Memory updated" shows. */
export interface MemoryChange {
  key: number;
  kind: 'saved' | 'updated';
  memoryId: string;
  text: string;
  previousText?: string;
  conversationId: string;
  at: number;
}

/** A memory that was in an answer's prompt. */
export interface UsedMemory {
  memoryId: string;
  text: string;
  /** The answer drew on it (shares words with it). */
  cited: boolean;
}

export type AddOutcome = 'added' | 'updated' | 'duplicate' | 'rejected';

export interface MemoryUi {
  subscribe(listener: () => void): () => void;
  state(): MemoryState;
  list(): Promise<MemoryRow[]>;
  add(text: string): Promise<AddOutcome>;
  edit(id: string, text: string): Promise<void>;
  remove(id: string): Promise<void>;
  removeAll(): Promise<void>;
  setEnabled(enabled: boolean): Promise<void>;
  setPaused(paused: boolean): Promise<void>;
  setReferenceChats(on: boolean): Promise<void>;
  /** Memories in the prompt of an answer; empty when none were. */
  usedBy(messageId: string): Promise<UsedMemory[]>;
  /** Changes made while this chat was open, oldest first. */
  changes(conversationId: string): readonly MemoryChange[];
  /** Takes a change back: deletes a saved memory, restores an updated one. */
  undoChange(change: MemoryChange): Promise<void>;
  dismissChanges(conversationId: string): void;
}

export const MAX_MEMORY_TEXT = 240;
