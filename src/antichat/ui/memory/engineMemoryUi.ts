import type {MemoryPort as EngineMemoryPort} from '../../engine/memory/port';
import type {MemoryItem} from '../../engine/memory/types';
import {ChangeLog} from './changeLog';
import type {AddOutcome, MemoryRow, MemoryUi} from './types';

export type EngineMemoryUi = MemoryUi & {dispose(): void};

function toRow(item: MemoryItem): MemoryRow {
  return {
    id: item.id,
    text: item.text,
    origin: item.origin === 'extraction' ? 'learned' : 'saved',
    pinned: item.pinned,
    projectId: item.projectId,
    conversationId: item.sourceSessionId,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  };
}

/** The memory screens on M9's engine (`engine.port`). */
export function createEngineMemoryUi(port: EngineMemoryPort): EngineMemoryUi {
  const listeners = new Set<() => void>();
  const log = new ChangeLog();
  const emit = () => listeners.forEach(listener => listener());

  const off = port.subscribe(event => {
    if (event.type === 'saved' && event.sessionId) {
      log.add({
        kind: 'saved',
        memoryId: event.memory.id,
        text: event.memory.text,
        conversationId: event.sessionId,
        at: event.memory.updatedAt,
      });
    } else if (event.type === 'updated' && event.sessionId) {
      log.add({
        kind: 'updated',
        memoryId: event.memory.id,
        text: event.memory.text,
        previousText: event.previousText,
        conversationId: event.sessionId,
        at: event.memory.updatedAt,
      });
    } else if (event.type === 'deleted') {
      log.forget(event.ids);
    } else if (event.type === 'cleared') {
      log.clear();
    }
    emit();
  });

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    state() {
      const settings = port.getSettings();
      return {
        enabled: settings.enabled,
        paused: settings.paused,
        referenceChats: settings.referenceChats,
      };
    },
    async list() {
      await port.ready();
      return (await port.list()).map(toRow);
    },
    async add(text): Promise<AddOutcome> {
      const result = await port.add(text);
      if (result.status === 'added' || result.status === 'updated') {
        return result.status;
      }
      return result.status === 'duplicate' ? 'duplicate' : 'rejected';
    },
    async edit(id, text) {
      await port.edit(id, {text});
    },
    async remove(id) {
      await port.delete([id]);
    },
    async removeAll() {
      await port.deleteAll();
    },
    async setEnabled(enabled) {
      await port.updateSettings({enabled});
    },
    async setPaused(paused) {
      await port.setPaused(paused);
    },
    async setReferenceChats(referenceChats) {
      await port.updateSettings({referenceChats});
    },
    async usedBy(messageId) {
      const use = await port.useForMessage(messageId);
      return (use?.items ?? []).map(item => ({
        memoryId: item.memoryId,
        text: item.text,
        cited: item.cited,
      }));
    },
    changes: conversationId => log.for(conversationId),
    async undoChange(change) {
      if (change.kind === 'saved') {
        await port.delete([change.memoryId]);
      } else {
        await port.undoUpdate(change.memoryId);
      }
      log.forget([change.memoryId]);
      emit();
    },
    dismissChanges(conversationId) {
      log.dismiss(conversationId);
      emit();
    },
    dispose() {
      off();
      listeners.clear();
    },
  };
}
