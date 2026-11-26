/**
 * Every haptic in the app goes through here, so the one switch in Settings
 * silences all of them. Calls never throw: on a simulator or a tablet without
 * a haptic engine they do nothing.
 */
import {Presets, Settings} from 'react-native-pulsar';

let enabled = true;

export function setHapticsEnabled(next: boolean): void {
  enabled = next;
  try {
    Settings.enableHaptics(next);
  } catch {
    // No haptic engine.
  }
}

export function hapticsEnabled(): boolean {
  return enabled;
}

function play(effect: () => void): void {
  if (!enabled) {
    return;
  }
  try {
    effect();
  } catch {
    // No haptic engine: haptics are cosmetic.
  }
}

/** Smallest gap between streaming ticks: about twelve soft taps a second. */
export const STREAM_TICK_MIN_INTERVAL_MS = 80;

let lastTick = 0;

export const haptics = {
  /** A control was pressed: buttons, rows, send. */
  tap: () => play(Presets.System.impactLight),
  /** A value changed: toggle, picker, drawer snapping open. */
  selection: () => play(Presets.System.selection),
  /** Something heavier happened: long-press menu, stop. */
  press: () => play(Presets.System.impactMedium),
  success: () => play(Presets.System.notificationSuccess),
  warning: () => play(Presets.System.notificationWarning),
  error: () => play(Presets.System.notificationError),
  /**
   * The streaming tick. Call once per rendered batch of text; it limits
   * itself so a fast model feels like a steady purr rather than a buzz.
   */
  streamTick: (now: number = Date.now()) => {
    if (now - lastTick < STREAM_TICK_MIN_INTERVAL_MS) {
      return false;
    }
    lastTick = now;
    play(Presets.System.impactSoft);
    return enabled;
  },
};
