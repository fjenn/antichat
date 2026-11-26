import {useCallback, useSyncExternalStore} from 'react';

import type {Observable} from '../../contracts';

/**
 * Reads one value from a port and re-renders only when that value changes.
 * `select` must return a primitive (or an object the port keeps stable):
 * unlike `usePort`, a port that announces every token costs nothing here.
 */
export function usePortValue<P extends Observable, T>(
  port: P,
  select: (port: P) => T,
): T {
  const read = useCallback(() => select(port), [port, select]);
  return useSyncExternalStore(port.subscribe, read, read);
}
