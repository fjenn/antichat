/**
 * Is the thread being flung? Rows that enter during a fling mount in a light
 * form (see `AssistantMessage`), so mounting never competes with the scroll.
 * One pace per screen: there is one thread on screen at a time.
 */
import {useSyncExternalStore} from 'react';

export type ScrollPace = 'normal' | 'fast';

/** px per ms. A hard fling is 4 and more; reading speed is far under 1. */
const ENTER = 2.5;
const EXIT = 0.8;
const CALM_MS = 140;

let pace: ScrollPace = 'normal';
let lastOffset = 0;
let lastAt = 0;
let calm: ReturnType<typeof setTimeout> | undefined;
const listeners = new Set<() => void>();

function set(next: ScrollPace): void {
  if (pace !== next) {
    pace = next;
    listeners.forEach(listener => listener());
  }
}

/** Call from the list's scroll handler. */
export function noteScroll(offset: number, now: number = Date.now()): void {
  const elapsed = now - lastAt;
  const velocity =
    elapsed > 0 && elapsed < 120 ? Math.abs(offset - lastOffset) / elapsed : 0;
  lastOffset = offset;
  lastAt = now;
  if (velocity >= ENTER) {
    set('fast');
  }
  if (pace === 'fast') {
    // Back to normal once the scroll has slowed down, or stopped reporting.
    clearTimeout(calm);
    calm = setTimeout(() => set('normal'), velocity < EXIT ? 0 : CALM_MS);
  }
}

export function resetScrollPace(): void {
  clearTimeout(calm);
  lastAt = 0;
  set('normal');
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
const read = () => pace;

export const useScrollPace = (): ScrollPace =>
  useSyncExternalStore(subscribe, read, read);

const waiting: Array<() => void> = [];
let draining = false;

function drain(): void {
  const next = waiting.shift();
  if (!next) {
    draining = false;
    return;
  }
  next();
  // One row per frame, with a frame of air in between.
  requestAnimationFrame(() => requestAnimationFrame(drain));
}

/**
 * Runs `work` soon, one piece of work per frame: after a fling several rows
 * want their full form at the same moment, and together they would hitch.
 * Returns the function that takes it back.
 */
export function typesetSoon(work: () => void): () => void {
  waiting.push(work);
  if (!draining) {
    draining = true;
    requestAnimationFrame(drain);
  }
  return () => {
    const at = waiting.indexOf(work);
    if (at >= 0) {
      waiting.splice(at, 1);
    }
  };
}
