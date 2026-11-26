/**
 * Frame-time recorders for the two threads that matter: the JS thread
 * (requestAnimationFrame cadence) and the UI thread (Reanimated frame
 * callback, driven by the display link / Choreographer).
 *
 * A frame counts as dropped when it took longer than 1.5 frame periods; a
 * hitch is a frame of 3 periods or more (what a user sees as a stutter).
 */
import {useCallback} from 'react';
import {
  useFrameCallback,
  useSharedValue,
  type SharedValue,
} from 'react-native-reanimated';

export type FrameStats = {
  frames: number;
  seconds: number;
  fps: number;
  periodMs: number;
  dropped: number;
  droppedPct: number;
  hitches: number;
  maxMs: number;
  p95Ms: number;
  p99Ms: number;
};

export function summarize(deltas: number[]): FrameStats {
  const n = deltas.length;
  if (n === 0) {
    return {
      frames: 0,
      seconds: 0,
      fps: 0,
      periodMs: 0,
      dropped: 0,
      droppedPct: 0,
      hitches: 0,
      maxMs: 0,
      p95Ms: 0,
      p99Ms: 0,
    };
  }
  const sorted = [...deltas].sort((a, b) => a - b);
  const total = deltas.reduce((a, b) => a + b, 0);
  // The display period is the typical frame, not the mean (which hitches skew).
  const median = sorted[Math.floor(n / 2)];
  const periodMs =
    median < 10 ? 1000 / 120 : median < 13 ? 1000 / 90 : 1000 / 60;
  const dropped = deltas.filter(d => d > periodMs * 1.5).length;
  const r = (v: number) => Math.round(v * 10) / 10;
  return {
    frames: n,
    seconds: r(total / 1000),
    fps: r((n * 1000) / total),
    periodMs: r(periodMs),
    dropped,
    droppedPct: r((dropped * 100) / n),
    hitches: deltas.filter(d => d >= periodMs * 3).length,
    maxMs: r(sorted[n - 1]),
    p95Ms: r(sorted[Math.floor(n * 0.95)]),
    p99Ms: r(sorted[Math.floor(n * 0.99)]),
  };
}

/** JS-thread recorder. */
export class JsFrameRecorder {
  private deltas: number[] = [];
  private last = 0;
  private handle: number | undefined;

  start(): void {
    this.deltas = [];
    this.last = 0;
    const loop = (t: number) => {
      if (this.last > 0) {
        this.deltas.push(t - this.last);
      }
      this.last = t;
      this.handle = requestAnimationFrame(loop);
    };
    this.handle = requestAnimationFrame(loop);
  }

  stop(): FrameStats {
    if (this.handle !== undefined) {
      cancelAnimationFrame(this.handle);
      this.handle = undefined;
    }
    return summarize(this.deltas);
  }
}

/** UI-thread recorder: start()/stop() from JS, frames counted in a worklet. */
export function useUiFrameRecorder(): {
  start: () => void;
  stop: () => FrameStats;
  live: SharedValue<number>;
} {
  const deltas = useSharedValue<number[]>([]);
  const recording = useSharedValue(false);
  const live = useSharedValue(0);

  useFrameCallback(frame => {
    'worklet';
    const d = frame.timeSincePreviousFrame;
    if (d == null) {
      return;
    }
    live.value = d;
    if (recording.value) {
      deltas.modify(list => {
        'worklet';
        list.push(d);
        return list;
      });
    }
  }, true);

  const start = useCallback(() => {
    deltas.value = [];
    recording.value = true;
  }, [deltas, recording]);
  const stop = useCallback(() => {
    recording.value = false;
    return summarize(deltas.value);
  }, [deltas, recording]);
  return {start, stop, live};
}
