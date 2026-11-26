/**
 * Whisper as a live recogniser.
 *
 * Whisper decodes whole buffers, so "words while you speak" are re-decodes of
 * the open segment every `partialIntervalMs` of new audio; the words two
 * decodes in a row agree on are reported as stable. A segment closes at a
 * pause (or at `maxSegmentMs`, cut at the quietest point so no word is
 * split), its audio is dropped and only its text is kept, with the tail of
 * the text carried into the next decode as context. Memory therefore does not
 * grow with the length of the dictation, and there is no time limit.
 */
import {concatPcm, durationMs, quietestPoint, samplesFor} from '../audio/pcm';
import {voiceError} from '../types';
import {EnergyVad} from '../vad/energyVad';
import {TurnDetector} from '../vad/turnDetector';
import {whisperLanguage} from './language';
import {isPhantom, joinSegments, stablePrefix, tidySegment} from './text';
import type {
  SttAdapter,
  SttEvent,
  SttOptions,
  SttResult,
  SttSession,
} from './types';

/** The decoder: whisper.rn on the phone, whisper.cpp in the host harness. */
export interface WhisperBackend {
  transcribe(
    pcm: Int16Array,
    options: {language?: string; prompt?: string},
  ): Promise<{text: string; language: string}>;
  /** Stops a running decode, which then resolves with empty text. */
  cancel(): Promise<void>;
  preload?(): Promise<void>;
  release?(): Promise<void>;
}

export interface WhisperAdapterConfig {
  /** New audio between two partial decodes. */
  partialIntervalMs?: number;
  /** Speech heard before the first partial decode. */
  firstPartialMs?: number;
  /** Pause that closes a dictation segment. */
  segmentPauseMs?: number;
  maxSegmentMs?: number;
  /** Characters of earlier text passed as context. */
  promptChars?: number;
}

const DEFAULTS = {
  partialIntervalMs: 900,
  firstPartialMs: 400,
  segmentPauseMs: 700,
  maxSegmentMs: 25_000,
  promptChars: 200,
};

export class WhisperSttAdapter implements SttAdapter {
  readonly id = 'whisper' as const;
  readonly trueStreaming = false;
  private readonly config: Required<WhisperAdapterConfig>;

  constructor(
    private readonly backend: WhisperBackend,
    config: WhisperAdapterConfig = {},
  ) {
    this.config = {...DEFAULTS, ...config};
  }

  async prepare(): Promise<void> {
    await this.backend.preload?.();
  }

  async release(): Promise<void> {
    await this.backend.release?.();
  }

  start(options: SttOptions, onEvent: (event: SttEvent) => void): SttSession {
    return new WhisperSession(this.backend, this.config, options, onEvent);
  }

  async transcribe(
    pcm: Int16Array,
    options: Pick<SttOptions, 'language' | 'punctuate' | 'context'>,
  ): Promise<{text: string; language: string}> {
    const result = await this.backend.transcribe(pcm, {
      language: whisperLanguage(options.language),
      prompt: options.context?.slice(-this.config.promptChars) || undefined,
    });
    return {
      text: tidySegment(result.text, options.punctuate ?? true),
      language: result.language,
    };
  }
}

class WhisperSession implements SttSession {
  private readonly detector: TurnDetector;
  private readonly finals: {id: number; text: string}[] = [];
  private segmentId = 0;
  private partial = '';
  private previousPartial = '';
  /** Audio cut off a full-length segment, to start the next one. */
  private carry: Int16Array = new Int16Array(0);
  private openVoicedMs = 0;
  private sincePartialMs = 0;
  private partialVoicedMs = 0;
  private queue: Promise<void> = Promise.resolve();
  private pending = 0;
  private ended = false;
  private cancelled = false;
  private language: string | undefined;
  private detected = '';
  private snapshotCache: {id: number; voicedMs: number; text: string} | null =
    null;
  private failed: unknown = null;

  constructor(
    private readonly backend: WhisperBackend,
    private readonly config: Required<WhisperAdapterConfig>,
    private readonly options: SttOptions,
    private readonly onEvent: (event: SttEvent) => void,
  ) {
    this.language = whisperLanguage(options.language);
    this.detector = new TurnDetector({
      vad: new EnergyVad(),
      // In a conversation the caller ends the turn; only the length cap cuts.
      hangMs: options.mode === 'dictation' ? config.segmentPauseMs : 3_600_000,
      maxTurnMs: config.maxSegmentMs,
      preRollMs: 300,
    });
  }

  get text(): string {
    return joinSegments([...this.finals.map(f => f.text), this.partial]);
  }

  push(pcm: Int16Array): void {
    if (this.ended || this.cancelled) {
      return;
    }
    const wasSpeech = this.detector.inSpeech;
    const events = this.detector.push(pcm);
    for (const event of events) {
      if (event.type === 'endpoint') {
        this.openVoicedMs = event.voicedMs;
        this.closeSegment(event.reason === 'max');
      }
    }
    if (this.detector.inSpeech) {
      this.openVoicedMs = this.detector.speechMs;
      if (wasSpeech) {
        this.sincePartialMs += durationMs(pcm.length);
      } else {
        // The first words should show quickly; later updates keep the pace.
        this.sincePartialMs = Math.max(
          0,
          this.config.partialIntervalMs - this.config.firstPartialMs,
        );
      }
      // Only new speech is worth a decode: a pause changes nothing.
      if (
        this.sincePartialMs >= this.config.partialIntervalMs &&
        this.openVoicedMs - this.partialVoicedMs >= 200 &&
        this.pending === 0
      ) {
        this.sincePartialMs = 0;
        this.partialVoicedMs = this.openVoicedMs;
        this.decodePartial();
      }
    }
  }

  snapshot(): Promise<string> {
    const voicedMs = this.openVoicedMs;
    const audio = this.openAudio();
    const id = this.segmentId;
    this.partialVoicedMs = voicedMs;
    this.sincePartialMs = 0;
    return this.run(async () => {
      if (voicedMs === 0 || this.cancelled) {
        return;
      }
      const text = await this.decode(audio, voicedMs);
      if (this.cancelled) {
        return;
      }
      // Kept even if the segment closed meanwhile: its final decode is queued
      // behind this one and takes the text when no more speech came.
      this.snapshotCache = {id, voicedMs, text};
      if (id === this.segmentId) {
        this.setPartial(id, text);
      }
    }).then(() => this.text);
  }

  async finish(): Promise<SttResult> {
    if (!this.ended) {
      this.ended = true;
      const pending = this.detector.pendingVoicedMs;
      if (pending >= 100 && pending > this.openVoicedMs) {
        this.openVoicedMs = pending;
      }
      this.closeSegment(false);
    }
    await this.queue;
    if (this.failed && this.finals.length === 0) {
      throw this.failed;
    }
    return {
      text: joinSegments(this.finals.map(f => f.text)),
      language: this.detected || this.language || '',
      segments: [...this.finals],
    };
  }

  cancel(): void {
    if (this.cancelled) {
      return;
    }
    this.cancelled = true;
    this.ended = true;
    this.backend.cancel().catch(() => {});
  }

  private openAudio(): Int16Array {
    const live = this.detector.peek();
    return this.carry.length ? concatPcm([this.carry, live]) : live;
  }

  private run(work: () => Promise<void>): Promise<void> {
    this.pending++;
    this.queue = this.queue
      .then(work)
      .catch(err => {
        if (!this.cancelled) {
          this.failed = err;
          this.onEvent({type: 'error', error: voiceError('failed', err)});
        }
      })
      .finally(() => {
        this.pending--;
      });
    return this.queue;
  }

  private async decode(pcm: Int16Array, voicedMs: number): Promise<string> {
    const prompt = joinSegments([
      this.options.context ?? '',
      ...this.finals.map(f => f.text),
    ]).slice(-this.config.promptChars);
    const result = await this.backend.transcribe(pcm, {
      language: this.language,
      prompt: prompt || undefined,
    });
    const text = tidySegment(result.text, this.options.punctuate ?? true);
    if (isPhantom(text, voicedMs)) {
      return '';
    }
    // Detection is trusted only on a real stretch of speech, then kept, so a
    // short "okay" cannot flip the language mid-dictation.
    if (!this.language && result.language && voicedMs >= 1000) {
      this.language = result.language;
    }
    this.detected = this.language ?? result.language ?? this.detected;
    return text;
  }

  private setPartial(id: number, text: string): void {
    const stable = stablePrefix(this.previousPartial, text);
    this.previousPartial = text;
    this.partial = text;
    this.onEvent({type: 'partial', segmentId: id, text, stable});
  }

  private decodePartial(): void {
    const id = this.segmentId;
    const audio = this.openAudio();
    const voicedMs = this.openVoicedMs;
    this.run(async () => {
      if (id !== this.segmentId || this.cancelled) {
        return;
      }
      const text = await this.decode(audio, voicedMs);
      if (id === this.segmentId && !this.cancelled && text) {
        this.setPartial(id, text);
      }
    });
  }

  private closeSegment(atMax: boolean): void {
    const id = this.segmentId;
    const voicedMs = this.openVoicedMs;
    let audio = this.detector.take();
    if (this.carry.length) {
      audio = concatPcm([this.carry, audio]);
      this.carry = new Int16Array(0);
    }
    if (atMax) {
      const cut = quietestPoint(
        audio,
        Math.max(0, audio.length - samplesFor(3000)),
        audio.length,
      );
      this.carry = audio.slice(cut);
      audio = audio.subarray(0, cut);
    }
    this.segmentId++;
    this.openVoicedMs = 0;
    this.sincePartialMs = 0;
    this.partialVoicedMs = 0;
    this.partial = '';
    this.previousPartial = '';
    if (voicedMs === 0) {
      return;
    }
    this.run(async () => {
      if (this.cancelled) {
        return;
      }
      // Nothing was said after the snapshot: its text is the final text.
      const cached = this.snapshotCache;
      this.snapshotCache = null;
      const text =
        cached && cached.id === id && cached.voicedMs === voicedMs
          ? cached.text
          : await this.decode(audio, voicedMs);
      if (this.cancelled || !text) {
        return;
      }
      this.finals.push({id, text});
      this.onEvent({
        type: 'final',
        segmentId: id,
        text,
        language: this.detected || undefined,
      });
    });
  }
}
