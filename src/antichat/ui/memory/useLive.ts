import {useEffect, useRef, useState} from 'react';

interface Source {
  subscribe(listener: () => void): () => void;
}

/**
 * Loads a value from an async source and loads it again whenever the source
 * says something changed. `undefined` until the first load has finished.
 */
export function useLive<T>(
  source: Source,
  load: () => Promise<T>,
  deps: readonly unknown[] = [],
): T | undefined {
  const [value, setValue] = useState<T>();
  const loader = useRef(load);
  loader.current = load;

  useEffect(() => {
    let alive = true;
    let run = 0;
    const refresh = () => {
      const mine = ++run;
      loader
        .current()
        .then(next => {
          if (alive && mine === run) {
            setValue(next);
          }
        })
        .catch(() => {});
    };
    refresh();
    const off = source.subscribe(refresh);
    return () => {
      alive = false;
      off();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source, ...deps]);

  return value;
}

/** Re-renders when the source changes; for its synchronous fields. */
export function useChanges(source: Source): void {
  const [, bump] = useState(0);
  useEffect(() => source.subscribe(() => bump(n => n + 1)), [source]);
}
