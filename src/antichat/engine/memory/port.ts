/**
 * What the UI half of M9 builds on: the memory manage screen, the "Memory
 * updated" notice and the "memory used" chip. Local definition; when M1
 * publishes `MemoryPort` in `src/antichat/contracts/`, this is reconciled
 * with it.
 */
import type {MemoryStore, ListOptions, MemoryPatch} from './MemoryStore';
import type {
  MemoryEvent,
  MemoryItem,
  MemoryKind,
  MemorySettings,
  MemoryUse,
} from './types';
import type {MemoryWriter, SaveResult} from './writer';

export interface MemoryPort {
  /** Resolves once the schema is in place and settings are loaded. */
  ready(): Promise<void>;
  /** Saved, updated, deleted, cleared, settings changed. */
  subscribe(listener: (event: MemoryEvent) => void): () => void;

  // Manage screen
  list(options?: ListOptions): Promise<MemoryItem[]>;
  count(): Promise<number>;
  /** "Add a memory" typed by the user; duplicates are folded. */
  add(
    text: string,
    options?: {kind?: MemoryKind; projectId?: string | null},
  ): Promise<SaveResult>;
  edit(id: string, patch: MemoryPatch): Promise<MemoryItem | null>;
  setPinned(id: string, pinned: boolean): Promise<MemoryItem | null>;
  /** Puts back the text from before the last automatic update. */
  undoUpdate(id: string): Promise<MemoryItem | null>;
  delete(ids: string[]): Promise<number>;
  deleteAll(options?: {projectId?: string}): Promise<number>;

  // Controls
  getSettings(): MemorySettings;
  updateSettings(patch: Partial<MemorySettings>): Promise<MemorySettings>;
  setPaused(paused: boolean): Promise<MemorySettings>;

  // "Memory used" chip
  useForMessage(messageId: string): Promise<MemoryUse | null>;
  usesForSession(sessionId: string): Promise<MemoryUse[]>;
}

export function createMemoryPort(
  store: MemoryStore,
  writer: MemoryWriter,
  ready: () => Promise<void>,
): MemoryPort {
  return {
    ready,
    subscribe: listener => store.subscribe(listener),
    list: options => store.list(options),
    count: () => store.count(),
    add: (text, options = {}) =>
      writer.save({
        text,
        kind: options.kind,
        origin: 'user',
        explicit: true,
        scope: options.projectId
          ? {projectId: options.projectId, projectOnly: true}
          : {},
      }),
    edit: (id, patch) => store.update(id, patch),
    setPinned: (id, pinned) => store.setPinned(id, pinned),
    undoUpdate: id => store.undoUpdate(id),
    delete: ids => store.delete(ids, 'user'),
    deleteAll: options => store.deleteAll(options),
    getSettings: () => store.getSettings(),
    updateSettings: patch => store.updateSettings(patch),
    setPaused: paused => store.setPaused(paused),
    useForMessage: messageId => store.useForMessage(messageId),
    usesForSession: sessionId => store.usesForSession(sessionId),
  };
}
