/**
 * The connectivity flag, behind the smallest possible interface. M5 owns the
 * real source (NetInfo); the tool layer only ever asks "online right now?".
 * Until a source is injected the device counts as online, so a build without
 * M5 behaves as upstream.
 */
export interface Connectivity {
  isOnline(): boolean;
  /** Optional change feed, for the UI's greyed chips. */
  subscribe?(listener: (online: boolean) => void): () => void;
}

const ALWAYS_ONLINE: Connectivity = {isOnline: () => true};

let current: Connectivity = ALWAYS_ONLINE;

export function setConnectivity(source: Connectivity | null): void {
  current = source ?? ALWAYS_ONLINE;
}

export function getConnectivity(): Connectivity {
  return current;
}

export function isOnline(): boolean {
  try {
    return current.isOnline();
  } catch {
    return true;
  }
}

/** A settable flag for tests and for hosts that push state. */
export function createConnectivityFlag(initial = true): Connectivity & {
  set(online: boolean): void;
} {
  let online = initial;
  const listeners = new Set<(online: boolean) => void>();
  return {
    isOnline: () => online,
    set(next: boolean) {
      if (next !== online) {
        online = next;
        listeners.forEach(listener => listener(online));
      }
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

export const OFFLINE_NOTE =
  'The device is offline: web search and other online tools are unavailable. If the answer needs current information, say in one sentence that you cannot look it up while offline, then answer from what you know.';
