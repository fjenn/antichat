import type {MemoryPort} from '../../contracts';
import {ChangeLog} from './changeLog';
import type {AddOutcome, MemoryRow, MemoryUi} from './types';

export interface FakeMemoryUi extends MemoryUi {
  /** Test and demo control: memory saved something during a chat. */
  noteSaved(conversationId: string, text: string): Promise<void>;
}

/**
 * The memory screens on the contract port (`getPorts().memory`, normally
 * `FakeMemory`). Pause and "reference chats" live here; the contract only
 * has the master switch.
 */
export function createFakeMemoryUi(port: MemoryPort): FakeMemoryUi {
  const listeners = new Set<() => void>();
  const log = new ChangeLog();
  let paused = false;
  let referenceChats = true;
  const emit = () => listeners.forEach(listener => listener());
  port.subscribe(emit);

  const rows = (): MemoryRow[] =>
    port.memories.map(memory => ({
      id: memory.id,
      text: memory.text,
      origin: memory.origin,
      pinned: false,
      projectId: null,
      conversationId: memory.conversationId ?? null,
      createdAt: memory.createdAt,
      updatedAt: memory.updatedAt,
    }));

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    state: () => ({enabled: port.enabled, paused, referenceChats}),
    list: async () => rows(),
    async add(text): Promise<AddOutcome> {
      const clean = text.trim();
      if (!clean) {
        return 'rejected';
      }
      const known = port.memories.some(
        memory => memory.text.toLowerCase() === clean.toLowerCase(),
      );
      if (known) {
        return 'duplicate';
      }
      await port.add(clean);
      return 'added';
    },
    edit: (id, text) => port.update(id, text),
    async remove(id) {
      log.forget([id]);
      await port.remove(id);
    },
    async removeAll() {
      log.clear();
      await port.removeAll();
    },
    setEnabled: enabled => port.setEnabled(enabled),
    async setPaused(next) {
      paused = next;
      emit();
    },
    async setReferenceChats(next) {
      referenceChats = next;
      emit();
    },
    usedBy: async messageId =>
      port.usedBy(messageId).map(memory => ({
        memoryId: memory.id,
        text: memory.text,
        cited: true,
      })),
    changes: conversationId => log.for(conversationId),
    async undoChange(change) {
      log.forget([change.memoryId]);
      if (change.kind === 'saved') {
        await port.remove(change.memoryId);
      } else if (change.previousText) {
        await port.update(change.memoryId, change.previousText);
      }
      emit();
    },
    dismissChanges(conversationId) {
      log.dismiss(conversationId);
      emit();
    },
    async noteSaved(conversationId, text) {
      const memory = await port.add(text);
      log.add({
        kind: 'saved',
        memoryId: memory.id,
        text: memory.text,
        conversationId,
        at: memory.updatedAt,
      });
      emit();
    },
  };
}
