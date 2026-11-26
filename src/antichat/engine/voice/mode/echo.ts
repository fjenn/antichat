/**
 * Keeps the assistant's own voice out of the recogniser.
 *
 * Layer 1 is the platform's echo cancellation (voice-processing I/O on iOS,
 * the voiceCommunication preset on Android). This guard is layers 2 and 3:
 *
 * 2. Level gate. While speech plays, the guard learns how loud our own voice
 *    arrives at the microphone: everything heard in the first moments of
 *    playback, every later burst that is too short to be a barge-in, and the
 *    peak remembered from earlier answers on the same route. A barge-in has
 *    to be clearly louder than that for long enough. Without hardware
 *    cancellation on the loudspeaker the echo is as loud as a talker, so
 *    voice barge-in is off there and only the button interrupts.
 * 3. Text check. A transcript that repeats what was just spoken is dropped.
 */
import type {AudioRoute} from '../session/ports';
import {wordsOf} from '../stt/text';

export interface EchoGuardOptions {
  hardwareAec: boolean;
  route: AudioRoute;
  /** How far above the echo a barge-in must be (dB). */
  marginDb?: number;
  /** The gate stays up this long after playback stops (room tail, buffers). */
  tailMs?: number;
}

/** Listening-only time at the start of playback: first answer, later answers. */
const FIRST_CALIBRATION_MS = 600;
const CALIBRATION_MS = 300;
/** A louder stretch that ends within this is echo, not a talker. */
const BURST_GAP_MS = 100;

export class EchoGuard {
  private hardwareAec: boolean;
  private route: AudioRoute;
  private readonly marginDb: number;
  private readonly tailMs: number;
  private playing = false;
  private calibrateUntil = 0;
  private stoppedAt = -Infinity;
  private echoDb = -100;
  /** Loudest echo of earlier answers on this route. */
  private learnedDb = -100;
  private burstMs = 0;
  private burstPeakDb = -100;
  private belowMs = 0;

  constructor(options: EchoGuardOptions) {
    this.hardwareAec = options.hardwareAec;
    this.route = options.route;
    this.marginDb = options.marginDb ?? 8;
    this.tailMs = options.tailMs ?? 300;
  }

  setRoute(route: AudioRoute, hardwareAec = this.hardwareAec): void {
    if (route !== this.route) {
      // Another speaker, another echo path: learn again.
      this.learnedDb = -100;
      this.echoDb = -100;
    }
    this.route = route;
    this.hardwareAec = hardwareAec;
  }

  /** The speaker's sound reaches the microphone through the air. */
  private get coupled(): boolean {
    return (
      this.route === 'speaker' ||
      this.route === 'unknown' ||
      this.route === 'car'
    );
  }

  /** Voice barge-in cannot be told from echo: only the button interrupts. */
  get halfDuplex(): boolean {
    return !this.hardwareAec && this.coupled;
  }

  /**
   * The loudest our own voice can plausibly be at the microphone. What is
   * left after the phone's canceller is faint; a talker who speaks during
   * calibration must not be learned as echo beyond this.
   */
  private get ceilingDb(): number {
    return this.hardwareAec ? -35 : -15;
  }

  /** Voiced audio a barge-in needs. */
  get minBargeInMs(): number {
    return 300;
  }

  playbackStarted(nowMs: number): void {
    this.playing = true;
    this.calibrateUntil =
      nowMs + (this.learnedDb > -100 ? CALIBRATION_MS : FIRST_CALIBRATION_MS);
    this.echoDb = this.learnedDb;
    this.burstMs = 0;
    this.belowMs = 0;
  }

  playbackStopped(nowMs: number): void {
    if (this.playing) {
      this.playing = false;
      this.stoppedAt = nowMs;
      this.learnedDb = Math.max(this.learnedDb - 3, this.echoDb);
    }
  }

  /** Is our own speech still in the air at `nowMs`? */
  active(nowMs: number): boolean {
    return this.playing || nowMs - this.stoppedAt < this.tailMs;
  }

  /** Feed the level of every microphone chunk while speech plays. */
  observe(levelDb: number, nowMs: number, frameMs: number): void {
    if (!this.playing || !this.coupled) {
      return;
    }
    if (nowMs < this.calibrateUntil) {
      this.echoDb = Math.min(this.ceilingDb, Math.max(this.echoDb, levelDb));
      return;
    }
    if (levelDb >= this.echoDb + this.marginDb) {
      // Louder than anything known: a talker if it lasts, echo if it does not.
      this.burstMs += frameMs;
      this.burstPeakDb = Math.max(this.burstPeakDb, levelDb);
      this.belowMs = 0;
      return;
    }
    if (this.burstMs > 0) {
      this.belowMs += frameMs;
      if (this.belowMs >= BURST_GAP_MS) {
        if (this.burstMs < this.minBargeInMs) {
          this.echoDb = Math.min(
            this.ceilingDb,
            Math.max(this.echoDb, this.burstPeakDb),
          );
        }
        this.burstMs = 0;
        this.burstPeakDb = -100;
      }
    }
    if (levelDb > this.echoDb) {
      // Creeps up at 20 dB/s, so a talker's first syllable cannot lift it far.
      this.echoDb = Math.min(
        levelDb,
        this.ceilingDb,
        this.echoDb + (20 * frameMs) / 1000,
      );
    }
  }

  /** The level a microphone frame must reach to count as the user (dBFS). */
  gateDb(nowMs: number): number {
    // Headphones and the earpiece do not feed the microphone: no gate.
    if (!this.active(nowMs) || !this.coupled) {
      return -100;
    }
    // While calibrating nothing passes: the level is still being learned.
    return this.playing && nowMs < this.calibrateUntil
      ? 0
      : this.echoDb + this.marginDb;
  }

  /**
   * True when `transcript` is (mostly) a run of words from `spoken`: the
   * recogniser heard the assistant, not the user.
   */
  static isEchoTranscript(transcript: string, spoken: string): boolean {
    const heard = wordsOf(transcript);
    const said = wordsOf(spoken);
    if (heard.length < 2 || said.length === 0) {
      return false;
    }
    // Longest run of consecutive words of `heard` found in `said`.
    let best = 0;
    for (let i = 0; i < heard.length; i++) {
      for (let j = 0; j < said.length; j++) {
        let n = 0;
        while (
          i + n < heard.length &&
          j + n < said.length &&
          heard[i + n] === said[j + n]
        ) {
          n++;
        }
        best = Math.max(best, n);
      }
    }
    return best >= 2 && best / heard.length >= 0.6;
  }
}
