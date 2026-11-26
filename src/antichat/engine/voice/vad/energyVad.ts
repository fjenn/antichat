/**
 * Voice activity detection on frame energy with an adaptive noise floor.
 *
 * The floor starts at the level of the first frame and follows the quietest
 * recent frames (fast down, slow up). Sound that holds one level for a third
 * of a second is noise, whatever its loudness, and becomes the floor at once
 * (speech never holds still that long), so a fan that starts mid-session does
 * not count as speech and speech does not drag the floor up. A frame is
 * speech when it is `marginDb` above the floor and above an absolute minimum;
 * it stays speech until it falls back to `releaseDb` above the floor
 * (hysteresis keeps weak syllables together).
 *
 * `Vad` is the seam for a neural detector (Silero through whisper.rn):
 * anything that labels 20 ms frames fits.
 */
import {rms, toDb} from '../audio/pcm';
import {SAMPLE_RATE} from '../types';

export interface VadFrame {
  speech: boolean;
  levelDb: number;
}

export interface Vad {
  /** Samples per frame the detector wants. */
  readonly frameSamples: number;
  process(frame: Int16Array): VadFrame;
  reset(): void;
  /**
   * Extra bar a frame must clear, in dBFS (-100 = none). Voice mode raises it
   * while the assistant speaks, to the level its own voice reaches the mic.
   */
  setGateDb(db: number): void;
}

export interface EnergyVadOptions {
  frameMs?: number;
  /** dB above the noise floor that starts speech. */
  marginDb?: number;
  /** dB above the noise floor that keeps speech going. */
  releaseDb?: number;
  /** Nothing below this is speech, however quiet the room (dBFS). */
  minSpeechDb?: number;
  /** Where the floor starts, and its bounds (dBFS). */
  initialFloorDb?: number;
  maxFloorDb?: number;
  /** How fast the floor rises under steady sound (dB per second). */
  floorRiseDbPerSec?: number;
}

export const VAD_FRAME_MS = 20;
const STEADY_FRAMES = 16;
const STEADY_RANGE_DB = 5;

export class EnergyVad implements Vad {
  readonly frameSamples: number;
  private readonly marginDb: number;
  private readonly releaseDb: number;
  private readonly minSpeechDb: number;
  private readonly initialFloorDb: number;
  private readonly maxFloorDb: number;
  private readonly risePerFrame: number;
  private floorDb: number;
  private gateDb = -100;
  private active = false;
  private primed = false;
  private readonly recent: number[] = [];

  constructor(options: EnergyVadOptions = {}) {
    const frameMs = options.frameMs ?? VAD_FRAME_MS;
    this.frameSamples = (SAMPLE_RATE * frameMs) / 1000;
    this.marginDb = options.marginDb ?? 9;
    this.releaseDb = options.releaseDb ?? 5;
    this.minSpeechDb = options.minSpeechDb ?? -48;
    this.initialFloorDb = options.initialFloorDb ?? -60;
    this.maxFloorDb = options.maxFloorDb ?? -25;
    this.risePerFrame = ((options.floorRiseDbPerSec ?? 6) * frameMs) / 1000;
    this.floorDb = this.initialFloorDb;
  }

  get noiseFloorDb(): number {
    return this.floorDb;
  }

  setGateDb(db: number): void {
    this.gateDb = db;
  }

  process(frame: Int16Array): VadFrame {
    const levelDb = toDb(rms(frame));
    if (!this.primed) {
      this.primed = true;
      this.floorDb = Math.min(this.maxFloorDb, Math.max(-90, levelDb));
    }
    this.recent.push(levelDb);
    if (this.recent.length > STEADY_FRAMES) {
      this.recent.shift();
    }
    if (this.isSteady()) {
      this.floorDb = Math.min(this.maxFloorDb, Math.max(...this.recent));
    } else if (levelDb < this.floorDb) {
      this.floorDb = Math.max(-90, this.floorDb * 0.7 + levelDb * 0.3);
    } else if (!this.active) {
      // Rises only while no speech is detected, so a long sentence cannot
      // lift the floor over itself.
      this.floorDb = Math.min(
        this.maxFloorDb,
        levelDb,
        this.floorDb + this.risePerFrame,
      );
    }
    const bar = this.active ? this.releaseDb : this.marginDb;
    this.active =
      levelDb >= this.floorDb + bar &&
      levelDb >= this.minSpeechDb &&
      levelDb >= this.gateDb;
    return {speech: this.active, levelDb};
  }

  reset(): void {
    this.floorDb = this.initialFloorDb;
    this.active = false;
    this.primed = false;
    this.recent.length = 0;
  }

  /** The last third of a second stayed within a few dB: steady noise. */
  private isSteady(): boolean {
    if (this.recent.length < STEADY_FRAMES) {
      return false;
    }
    const top = Math.max(...this.recent);
    return top > -90 && top - Math.min(...this.recent) <= STEADY_RANGE_DB;
  }
}
