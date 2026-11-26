/**
 * Debug builds: measures frame times of both threads while the drawer's
 * list is scrolled by hand (or by Maestro). Arm it in the history lab; the
 * recording starts with the first scroll of the drawer list and runs for
 * `RECORD_MS`. The result is shown in the lab and written to the Metro log
 * as `[antichat-perf] {...}`.
 */
import {useEffect} from 'react';

import {
  JsFrameRecorder,
  useUiFrameRecorder,
  type FrameStats,
} from '../../../spike-ui/perf';

export const RECORD_MS = 12_000;

export interface ProbeResult {
  rows: number;
  ui: FrameStats;
  js: FrameStats;
}

type Phase = 'idle' | 'armed' | 'recording';

let phase: Phase = 'idle';
let rows = 0;
let last: ProbeResult | null = null;
let controls: {start: () => void; stop: () => FrameStats} | null = null;
const js = new JsFrameRecorder();
const listeners = new Set<() => void>();

function publish(): void {
  listeners.forEach(listener => listener());
}

export const perfProbe = {
  phase: (): Phase => phase,
  last: (): ProbeResult | null => last,
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  arm(): void {
    last = null;
    phase = 'armed';
    publish();
  },
  /** Called by the drawer list when a scroll starts. */
  onScroll(rowCount: number): void {
    if (phase !== 'armed' || !controls) {
      return;
    }
    phase = 'recording';
    rows = rowCount;
    controls.start();
    js.start();
    publish();
    setTimeout(() => {
      if (!controls) {
        return;
      }
      last = {rows, ui: controls.stop(), js: js.stop()};
      phase = 'idle';
      console.log(`[antichat-perf] ${JSON.stringify(last)}`);
      publish();
    }, RECORD_MS);
  },
};

/** Mount once in a debug build; it only holds the UI-thread recorder. */
export function PerfProbeHost() {
  const recorder = useUiFrameRecorder();
  useEffect(() => {
    controls = recorder;
    return () => {
      controls = null;
    };
  }, [recorder]);
  return null;
}
