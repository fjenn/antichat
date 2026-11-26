/**
 * Per-chat context state: the rolling summary and how much of the history it
 * replaces. The transcript itself is never rewritten; this is a side record.
 *
 * The default store keeps state in memory and writes through to AsyncStorage.
 * M3 can swap in a store backed by `antichat.db` with `setContextStateStore`.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';

export interface ContextState {
  /** Lasting facts about the user and task; append-only, kept by code. */
  facts: string[];
  /** Narrative summary of the removed messages; rewritten at each compaction. */
  summary: string;
  /** Leading history messages (system excluded) no longer sent. */
  cutCount: number;
  /** Leading history messages already folded into `facts`/`summary`. */
  summarizedCount: number;
  /** Fingerprint of the removed messages; a mismatch means history was edited. */
  fingerprint: string;
  /** How many times this chat was compacted. */
  compactions: number;
  /** Summary carried over from the chat this one continues, if any. */
  carried?: {facts: string[]; summary: string; fromSessionId?: string};
  updatedAt: number;
}

export interface ContextStateStore {
  get(sessionId: string): Promise<ContextState | null>;
  set(sessionId: string, state: ContextState): Promise<void>;
  delete(sessionId: string): Promise<void>;
}

export const emptyContextState = (): ContextState => ({
  facts: [],
  summary: '',
  cutCount: 0,
  summarizedCount: 0,
  fingerprint: '',
  compactions: 0,
  updatedAt: 0,
});

export function createMemoryContextStateStore(): ContextStateStore {
  const states = new Map<string, ContextState>();
  return {
    get: async id => states.get(id) ?? null,
    set: async (id, state) => {
      states.set(id, state);
    },
    delete: async id => {
      states.delete(id);
    },
  };
}

const KEY_PREFIX = 'antichat.context.v1.';

/** Memory cache in front of AsyncStorage. */
export function createPersistentContextStateStore(): ContextStateStore {
  const cache = new Map<string, ContextState | null>();
  return {
    get: async id => {
      if (cache.has(id)) {
        return cache.get(id) ?? null;
      }
      let state: ContextState | null = null;
      try {
        const raw = await AsyncStorage.getItem(KEY_PREFIX + id);
        state = raw ? {...emptyContextState(), ...JSON.parse(raw)} : null;
      } catch {
        state = null;
      }
      cache.set(id, state);
      return state;
    },
    set: async (id, state) => {
      cache.set(id, state);
      try {
        await AsyncStorage.setItem(KEY_PREFIX + id, JSON.stringify(state));
      } catch {
        // The in-memory copy still serves this run.
      }
    },
    delete: async id => {
      cache.delete(id);
      try {
        await AsyncStorage.removeItem(KEY_PREFIX + id);
      } catch {
        // Nothing to clean up.
      }
    },
  };
}

let activeStore: ContextStateStore = createMemoryContextStateStore();

export function getContextStateStore(): ContextStateStore {
  return activeStore;
}

export function setContextStateStore(store: ContextStateStore): void {
  activeStore = store;
}
