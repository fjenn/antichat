/**
 * The streaming haptic tick: a soft tap as text arrives, rate-limited so a
 * fast model feels like a steady purr rather than a buzz. Driven from the
 * token batcher's flush, so it never runs more often than the screen updates.
 */
import {Presets} from 'react-native-pulsar';

/** ChatGPT's tick is light and continuous; ~12 taps a second reads as that. */
export const TICK_MIN_INTERVAL_MS = 80;

export class StreamingHaptics {
  enabled = true;
  ticks = 0;
  private last = 0;

  constructor(
    private readonly play: () => void = () => Presets.System.impactSoft(),
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** Call once per rendered batch of tokens. */
  tick(): void {
    if (!this.enabled) {
      return;
    }
    const t = this.now();
    if (t - this.last < TICK_MIN_INTERVAL_MS) {
      return;
    }
    this.last = t;
    this.ticks += 1;
    try {
      this.play();
    } catch {
      // No haptic engine (simulator, tablet): the tick is cosmetic.
    }
  }
}

export const sendHaptic = (): void => {
  try {
    Presets.System.impactLight();
  } catch {}
};
