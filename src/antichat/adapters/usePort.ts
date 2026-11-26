import {useCallback, useRef, useSyncExternalStore} from 'react';

import type {Observable} from '../contracts';

/**
 * Reads a value from a port and re-renders when the port changes.
 *
 *   const sections = usePort(ports.conversations, c => c.sections());
 *
 * `select` runs on every render, so it may close over props and state and may
 * build a new object each time.
 */
export function usePort<P extends Observable, T>(
  port: P,
  select: (port: P) => T,
): T {
  const version = useRef(0);
  const subscribe = useCallback(
    (notify: () => void) =>
      port.subscribe(() => {
        version.current += 1;
        notify();
      }),
    [port],
  );
  const getVersion = () => version.current;
  useSyncExternalStore(subscribe, getVersion, getVersion);
  return select(port);
}
