import type {Catalog} from '../catalog/types';

import {stepDown} from './select';

/**
 * Post-load calibration: measure real generation speed for a few seconds. If
 * the phone is slower than the floor, the smaller model is offered once.
 */

const MIN_TOKENS = 16;
const MIN_SECONDS = 1;

export interface SpeedSample {
  tokens: number;
  seconds: number;
  tokensPerSecond: number;
}

/** A silence this long between tokens is a pause, not slow generation. */
const MAX_TOKEN_GAP_MS = 5000;

/**
 * Counts generated tokens over a window of GENERATION time. Only time spent
 * streaming counts: the clock starts at the first token of each answer (so
 * prompt processing is not held against the speed) and stops between answers
 * (so the user reading for a minute does not look like a slow phone).
 */
export class SpeedMeter {
  /** Start of the answer being streamed; null between answers. */
  private segmentStart: number | null = null;
  private lastAt = 0;
  /** Generation time of finished answers. */
  private bankedMs = 0;
  private tokens = 0;

  constructor(
    private readonly windowSeconds: number,
    private readonly now: () => number = Date.now,
  ) {}

  /** Record tokens as they stream. Ignored once the window is full. */
  onTokens(count = 1): void {
    if (this.done) {
      return;
    }
    const at = this.now();
    if (this.segmentStart !== null && at - this.lastAt > MAX_TOKEN_GAP_MS) {
      // The caller did not report the end of the answer; the gap does.
      this.endSegment();
    }
    if (this.segmentStart === null) {
      // The first token marks the start; it is not counted as throughput.
      this.segmentStart = at;
      this.lastAt = at;
      return;
    }
    this.tokens += count;
    this.lastAt = at;
  }

  /** The answer finished: stop the clock until the next one starts. */
  endSegment(): void {
    if (this.segmentStart !== null) {
      this.bankedMs += this.lastAt - this.segmentStart;
      this.segmentStart = null;
    }
  }

  private get activeMs(): number {
    return (
      this.bankedMs +
      (this.segmentStart === null ? 0 : this.lastAt - this.segmentStart)
    );
  }

  get done(): boolean {
    return this.activeMs >= this.windowSeconds * 1000;
  }

  /** Null until enough was generated to judge. */
  sample(): SpeedSample | null {
    const seconds = this.activeMs / 1000;
    // A full window with only a handful of tokens is not "too little data":
    // it is a very slow phone (under about 3 tokens per second), the case this
    // measurement exists for. The token minimum only guards short answers.
    const fullWindow = seconds >= this.windowSeconds;
    if (
      this.tokens === 0 ||
      seconds < MIN_SECONDS ||
      (this.tokens < MIN_TOKENS && !fullWindow)
    ) {
      return null;
    }
    return {
      tokens: this.tokens,
      seconds,
      tokensPerSecond: this.tokens / seconds,
    };
  }
}

export interface CalibrationRecord {
  tokensPerSecond: number;
  /** The smaller model was already offered for this model. */
  slowOfferShown?: boolean;
}

export type CalibrationVerdict =
  | {verdict: 'inconclusive'}
  | {verdict: 'ok'; tokensPerSecond: number}
  | {
      verdict: 'too_slow';
      tokensPerSecond: number;
      floor: number;
      /** The smaller model to offer; null when already offered or none exists. */
      offerModelId: string | null;
    };

export function judgeCalibration(
  sample: SpeedSample | null,
  modelId: string,
  catalog: Catalog,
  previous?: CalibrationRecord,
): CalibrationVerdict {
  if (sample === null) {
    return {verdict: 'inconclusive'};
  }
  const floor = catalog.policy.speedFloorTokPerSec;
  if (sample.tokensPerSecond >= floor) {
    return {verdict: 'ok', tokensPerSecond: sample.tokensPerSecond};
  }
  return {
    verdict: 'too_slow',
    tokensPerSecond: sample.tokensPerSecond,
    floor,
    offerModelId: previous?.slowOfferShown ? null : stepDown(catalog, modelId),
  };
}
