/**
 * Which chat list the app talks to: the real conversation store or the
 * in-memory fake. Release builds always use the real one. A debug build can
 * switch (Settings → History lab) so UI tests run against known fake data;
 * the choice survives reloads. Jest uses the fake unless a test says
 * otherwise.
 */
import {currentBackend, loadBackend, setBackend} from './backend';

export type HistoryBackend = 'real' | 'fake';

// One switch for the whole app since the merge with M2: `./backend`.
export function historyBackend(): HistoryBackend {
  return currentBackend();
}

/** Reads the stored choice. Call before the first `getPorts()`. */
export async function loadHistoryBackend(): Promise<HistoryBackend> {
  await loadBackend().catch(() => undefined);
  return currentBackend();
}

/** Debug builds: store the choice and reload the app into it. */
export async function switchHistoryBackend(
  next: HistoryBackend,
): Promise<void> {
  if (next !== currentBackend()) {
    await setBackend(next);
  }
}

/** Tests only. */
export function setHistoryBackendForTests(_next: HistoryBackend): void {}
