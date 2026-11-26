/**
 * Which implementation the memory screens talk to. The fake over the
 * contract port until `registerMemoryUi` (register.ts) puts the
 * engine in; components re-render when that happens.
 */
import {useSyncExternalStore} from 'react';

import {getPorts} from '../../adapters';
import {createFakeMemoryUi} from './fakeMemoryUi';
import type {MemoryUi} from './types';

let current: MemoryUi | undefined;
const listeners = new Set<() => void>();

export function getMemoryUi(): MemoryUi {
  current ??= createFakeMemoryUi(getPorts().memory);
  return current;
}

/** Sets the implementation; no argument goes back to the fake. */
export function setMemoryUi(next?: MemoryUi): void {
  current = next;
  listeners.forEach(listener => listener());
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function useMemoryUi(): MemoryUi {
  return useSyncExternalStore(subscribe, getMemoryUi, getMemoryUi);
}
