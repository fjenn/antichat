/**
 * Finds one spoken turn in a live PCM stream: where speech starts, the short
 * pause that makes a provisional transcript worth requesting, and the longer
 * pause that ends the turn.
 *
 * Time is audio time (samples seen), so the detector behaves the same on a
 * microphone and on a file fed faster than real time.
 */
import {concatPcm, durationMs, samplesFor} from '../audio/pcm';
import {EnergyVad, type Vad} from './energyVad';

export interface TurnDetectorOptions {
  vad?: Vad;
  /** Silence after speech that ends the turn. */
  hangMs?: number;
  /** Voiced audio needed before a sound counts as speech. */
  minSpeechMs?: number;
  /** Silence after which unconfirmed sound is forgotten. */
  dropMs?: number;
  /** Audio kept from before the speech start, so the first word is whole. */
  preRollMs?: number;
  /** A turn this long is ended without a pause. */
  maxTurnMs?: number;
  /** Pause that fires `provisional`; 0 switches it off. */
  provisionalMs?: number;
  /** Keep the turn's audio for `take()`. Off for pure barge-in detection. */
  keepAudio?: boolean;
}

export type TurnEvent =
  | {type: 'speech_start'; atMs: number; onsetMs: number}
  /** A pause long enough to guess that the turn may be over. */
  | {type: 'provisional'; atMs: number; speechEndMs: number}
  /** Speech went on after a `provisional`. */
  | {type: 'speech_resumed'; atMs: number}
  | {
      type: 'endpoint';
      atMs: number;
      /** Audio time of the last voiced frame. */
      speechEndMs: number;
      /** Voiced audio in the turn. */
      voicedMs: number;
      reason: 'pause' | 'max';
    };

export const DEFAULT_HANG_MS = 700;
export const DEFAULT_MIN_SPEECH_MS = 240;
export const DEFAULT_PROVISIONAL_MS = 300;

export class TurnDetector {
  readonly vad: Vad;
  private readonly hangMs: number;
  private readonly minSpeechMs: number;
  private readonly dropMs: number;
  private readonly preRollSamples: number;
  private readonly maxTurnMs: number;
  private readonly provisionalMs: number;
  private readonly keepAudio: boolean;

  private rest: Int16Array = new Int16Array(0);
  private samplesSeen = 0;
  private chunks: Int16Array[] = [];
  private bufferedSamples = 0;
  private phase: 'idle' | 'candidate' | 'speech' = 'idle';
  private voicedMs = 0;
  private silentMs = 0;
  private onsetMs = 0;
  private lastVoicedEndMs = 0;
  private provisionalSent = false;
  private lastLevelDb = -100;

  constructor(options: TurnDetectorOptions = {}) {
    this.vad = options.vad ?? new EnergyVad();
    this.hangMs = options.hangMs ?? DEFAULT_HANG_MS;
    this.minSpeechMs = options.minSpeechMs ?? DEFAULT_MIN_SPEECH_MS;
    this.dropMs = options.dropMs ?? 400;
    this.preRollSamples = samplesFor(options.preRollMs ?? 300);
    this.maxTurnMs = options.maxTurnMs ?? 60_000;
    this.provisionalMs = options.provisionalMs ?? 0;
    this.keepAudio = options.keepAudio ?? true;
  }

  get inSpeech(): boolean {
    return this.phase === 'speech';
  }

  /** Audio time consumed so far. */
  get nowMs(): number {
    return durationMs(this.samplesSeen);
  }

  get levelDb(): number {
    return this.lastLevelDb;
  }

  /** Voiced audio in the current turn. */
  get speechMs(): number {
    return this.phase === 'speech' ? this.voicedMs : 0;
  }

  /** Voiced audio heard since the last turn, confirmed as speech or not. */
  get pendingVoicedMs(): number {
    return this.phase === 'idle' ? 0 : this.voicedMs;
  }

  push(chunk: Int16Array): TurnEvent[] {
    const events: TurnEvent[] = [];
    this.keep(chunk);
    const frame = this.vad.frameSamples;
    const all = this.rest.length ? concatPcm([this.rest, chunk]) : chunk;
    let at = 0;
    for (; at + frame <= all.length; at += frame) {
      this.samplesSeen += frame;
      this.step(all.subarray(at, at + frame), events);
    }
    this.rest = all.slice(at);
    return events;
  }

  /** The turn's audio (with pre-roll); the detector starts over. */
  take(): Int16Array {
    const pcm = concatPcm(this.chunks);
    this.resetTurn();
    return pcm;
  }

  /** The turn's audio so far, without ending the turn. */
  peek(): Int16Array {
    return concatPcm(this.chunks);
  }

  /** Forget the current turn; the noise floor is kept. */
  resetTurn(): void {
    this.chunks = [];
    this.bufferedSamples = 0;
    this.phase = 'idle';
    this.voicedMs = 0;
    this.silentMs = 0;
    this.provisionalSent = false;
  }

  reset(): void {
    this.resetTurn();
    this.rest = new Int16Array(0);
    this.vad.reset();
  }

  private keep(chunk: Int16Array): void {
    if (!this.keepAudio) {
      return;
    }
    this.chunks.push(chunk);
    this.bufferedSamples += chunk.length;
    if (this.phase === 'idle') {
      this.trimPreRoll();
    }
  }

  private trimPreRoll(): void {
    while (
      this.chunks.length > 1 &&
      this.bufferedSamples - this.chunks[0]!.length >= this.preRollSamples
    ) {
      this.bufferedSamples -= this.chunks.shift()!.length;
    }
  }

  private step(frame: Int16Array, events: TurnEvent[]): void {
    const frameMs = durationMs(frame.length);
    const now = this.nowMs;
    const {speech, levelDb} = this.vad.process(frame);
    this.lastLevelDb = levelDb;

    if (speech) {
      if (this.phase === 'idle') {
        this.phase = 'candidate';
        this.onsetMs = now - frameMs;
        this.voicedMs = 0;
      }
      this.voicedMs += frameMs;
      this.silentMs = 0;
      this.lastVoicedEndMs = now;
      if (this.phase === 'candidate' && this.voicedMs >= this.minSpeechMs) {
        this.phase = 'speech';
        events.push({type: 'speech_start', atMs: now, onsetMs: this.onsetMs});
      } else if (this.phase === 'speech' && this.provisionalSent) {
        this.provisionalSent = false;
        events.push({type: 'speech_resumed', atMs: now});
      }
    } else if (this.phase !== 'idle') {
      this.silentMs += frameMs;
      if (this.phase === 'candidate') {
        if (this.silentMs >= this.dropMs) {
          this.phase = 'idle';
          this.voicedMs = 0;
          this.trimPreRoll();
        }
        return;
      }
      if (
        this.provisionalMs > 0 &&
        !this.provisionalSent &&
        this.silentMs >= this.provisionalMs &&
        this.silentMs < this.hangMs
      ) {
        this.provisionalSent = true;
        events.push({
          type: 'provisional',
          atMs: now,
          speechEndMs: this.lastVoicedEndMs,
        });
      }
      if (this.silentMs >= this.hangMs) {
        events.push({
          type: 'endpoint',
          atMs: now,
          speechEndMs: this.lastVoicedEndMs,
          voicedMs: this.voicedMs,
          reason: 'pause',
        });
        this.phase = 'idle';
        return;
      }
    }
    if (this.phase === 'speech' && now - this.onsetMs >= this.maxTurnMs) {
      events.push({
        type: 'endpoint',
        atMs: now,
        speechEndMs: this.lastVoicedEndMs,
        voicedMs: this.voicedMs,
        reason: 'max',
      });
      this.phase = 'idle';
    }
  }
}
