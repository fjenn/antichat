/**
 * The last few things the user searched for and opened a result of. Kept on
 * the phone (AsyncStorage); shown under the empty search field.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';

const KEY = 'antichat.search.recent.v1';
export const MAX_RECENT_SEARCHES = 8;

let recent: readonly string[] = [];
let loaded = false;
const listeners = new Set<() => void>();

function publish(next: readonly string[]): void {
  recent = next;
  listeners.forEach(listener => listener());
  AsyncStorage.setItem(KEY, JSON.stringify(next)).catch(() => {
    // Not saved: the list still holds for this run.
  });
}

/** Newest first, no duplicates (case and spacing aside), capped. */
export function withRecent(
  list: readonly string[],
  query: string,
): readonly string[] {
  const clean = query.replace(/\s+/g, ' ').trim();
  if (!clean) {
    return list;
  }
  const key = clean.toLowerCase();
  return [clean, ...list.filter(item => item.toLowerCase() !== key)].slice(
    0,
    MAX_RECENT_SEARCHES,
  );
}

export const recentSearches = {
  async load(): Promise<void> {
    if (loaded) {
      return;
    }
    loaded = true;
    try {
      const raw = await AsyncStorage.getItem(KEY);
      const parsed: unknown = raw ? JSON.parse(raw) : [];
      if (Array.isArray(parsed)) {
        recent = parsed
          .filter((item): item is string => typeof item === 'string')
          .slice(0, MAX_RECENT_SEARCHES);
        listeners.forEach(listener => listener());
      }
    } catch {
      // Unreadable: start empty.
    }
  },
  list(): readonly string[] {
    return recent;
  },
  add(query: string): void {
    const next = withRecent(recent, query);
    if (next !== recent) {
      publish(next);
    }
  },
  remove(query: string): void {
    publish(recent.filter(item => item !== query));
  },
  clear(): void {
    publish([]);
  },
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  /** Tests only. */
  reset(): void {
    recent = [];
    loaded = false;
  },
};
