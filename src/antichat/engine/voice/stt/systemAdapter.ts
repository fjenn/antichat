/**
 * The phone's own on-device recogniser as an `SttAdapter`.
 *
 * iOS 26+: SpeechAnalyzer / SpeechTranscriber (streams our PCM, no time
 * limit, system-managed model, no app memory). Older iOS: SFSpeechRecognizer
 * with `requiresOnDeviceRecognition`, whose tasks end after about a minute,
 * so the session rolls over to a new task at a pause before the limit and a
 * long dictation never stops. Android: the on-device SpeechRecognizer where a
 * vendor ships one.
 *
 * The native side is behind `SystemRecognizerBackend`; this file is the
 * session logic that is the same for all of them.
 */
import {durationMs} from '../audio/pcm';
import {voiceError} from '../types';
import {EnergyVad} from '../vad/energyVad';
import {TurnDetector} from '../vad/turnDetector';
import {joinSegments, stablePrefix, tidySegment} from './text';
import type {
  SttAdapter,
  SttEvent,
  SttOptions,
  SttResult,
  SttSession,
} from './types';

export interface SystemRecognizerSupport {
  /** Recognition for this locale works without a network. */
  onDevice: boolean;
  /** The locale the recogniser will actually use. */
  locale: string;
  /** Longest single task; undefined when there is no limit. */
  maxTaskMs?: number;
  /** The recogniser adds punctuation itself. */
  punctuation: boolean;
}

export type SystemRecognizerEvent =
  /** Unsettled text of the running task: everything after its last `final`. */
  | {type: 'partial'; text: string}
  /** That stretch is settled; later partials start after it. */
  | {type: 'final'; text: string}
  | {type: 'error'; message: string};

export interface SystemRecognizerTask {
  feed(pcm: Int16Array): void;
  /** No more audio; resolves once the last `final` was delivered. */
  end(): Promise<void>;
  abort(): void;
}

export interface SystemRecognizerBackend {
  /** Locales with on-device recognition available now (assets installed). */
  supportedLocales(): Promise<string[]>;
  support(locale: string): Promise<SystemRecognizerSupport | null>;
  /** Downloads or warms the locale's system assets, where the OS allows. */
  prepare?(locale: string): Promise<void>;
  start(
    options: {locale: string; punctuation: boolean; context?: string},
    onEvent: (event: SystemRecognizerEvent) => void,
  ): SystemRecognizerTask;
}

/** Roll a time-limited task over this long before its limit, at a pause. */
const ROLLOVER_MARGIN_MS = 12_000;
const ROLLOVER_PAUSE_MS = 350;

export class SystemSttAdapter implements SttAdapter {
  readonly id = 'system' as const;
  readonly trueStreaming = true;

  constructor(
    private readonly backend: SystemRecognizerBackend,
    /** Maps the 'auto' / BCP-47 setting to a locale the recogniser has. */
    private readonly resolveLocale: (language: string) => Promise<string>,
  ) {}

  async prepare(language: string): Promise<void> {
    await this.backend.prepare?.(await this.resolveLocale(language));
  }

  async release(): Promise<void> {}

  start(options: SttOptions, onEvent: (event: SttEvent) => void): SttSession {
    return new SystemSession(
      this.backend,
      this.resolveLocale,
      options,
      onEvent,
    );
  }

  async transcribe(
    pcm: Int16Array,
    options: Pick<SttOptions, 'language' | 'punctuate' | 'context'>,
  ): Promise<{text: string; language: string}> {
    const session = this.start({...options, mode: 'dictation'}, () => {});
    session.push(pcm);
    const result = await session.finish();
    return {text: result.text, language: result.language};
  }
}

class SystemSession implements SttSession {
  private readonly finals: {id: number; text: string}[] = [];
  private segmentId = 0;
  private partial = '';
  private previousPartial = '';
  private task: SystemRecognizerTask | null = null;
  private taskToken = 0;
  private taskAudioMs = 0;
  private maxTaskMs: number | undefined;
  private locale = '';
  private backlog: Int16Array[] = [];
  private ready: Promise<void>;
  private ended = false;
  private cancelled = false;
  private failed: string | null = null;
  private rollover: Promise<void> = Promise.resolve();
  /** Only watches for pauses, to pick the moment of a task rollover. */
  private readonly pauses = new TurnDetector({
    vad: new EnergyVad(),
    hangMs: ROLLOVER_PAUSE_MS,
    keepAudio: false,
  });

  constructor(
    private readonly backend: SystemRecognizerBackend,
    resolveLocale: (language: string) => Promise<string>,
    private readonly options: SttOptions,
    private readonly onEvent: (event: SttEvent) => void,
  ) {
    this.ready = (async () => {
      this.locale = await resolveLocale(options.language);
      const support = await backend.support(this.locale);
      if (!support?.onDevice) {
        throw new Error(`no on-device recognition for ${this.locale}`);
      }
      this.locale = support.locale;
      this.maxTaskMs = support.maxTaskMs;
      if (!this.cancelled) {
        this.openTask();
        for (const chunk of this.backlog) {
          this.task?.feed(chunk);
        }
      }
      this.backlog = [];
    })();
    this.ready.catch(err => {
      this.failed = String(err instanceof Error ? err.message : err);
      this.onEvent({
        type: 'error',
        error: voiceError('unsupported', err, false),
      });
    });
  }

  get text(): string {
    return joinSegments([...this.finals.map(f => f.text), this.partial]);
  }

  push(pcm: Int16Array): void {
    if (this.ended || this.cancelled) {
      return;
    }
    if (!this.task) {
      this.backlog.push(pcm);
      return;
    }
    this.task.feed(pcm);
    this.taskAudioMs += durationMs(pcm.length);
    const paused = this.pauses.push(pcm).some(e => e.type === 'endpoint');
    if (this.maxTaskMs === undefined) {
      return;
    }
    const nearLimit = this.taskAudioMs >= this.maxTaskMs - ROLLOVER_MARGIN_MS;
    const atLimit = this.taskAudioMs >= this.maxTaskMs - 1500;
    if ((nearLimit && paused) || atLimit) {
      this.rollTask();
    }
  }

  async snapshot(): Promise<string> {
    await this.ready.catch(() => {});
    return this.text;
  }

  async finish(): Promise<SttResult> {
    this.ended = true;
    await this.ready.catch(() => {});
    await this.rollover;
    const task = this.task;
    this.task = null;
    if (task) {
      await task.end().catch(() => {});
      this.settle();
    }
    if (this.failed && this.finals.length === 0) {
      throw new Error(this.failed);
    }
    return {
      text: joinSegments(this.finals.map(f => f.text)),
      language: this.locale,
      segments: [...this.finals],
    };
  }

  cancel(): void {
    this.cancelled = true;
    this.ended = true;
    this.task?.abort();
    this.task = null;
  }

  private openTask(): void {
    this.taskAudioMs = 0;
    const token = ++this.taskToken;
    this.task = this.backend.start(
      {
        locale: this.locale,
        punctuation: this.options.punctuate ?? true,
        context:
          joinSegments([
            this.options.context ?? '',
            ...this.finals.map(f => f.text),
          ]).slice(-200) || undefined,
      },
      event => {
        if (this.cancelled || token !== this.taskToken) {
          return;
        }
        const id = this.segmentId;
        if (event.type === 'error') {
          this.failed = event.message;
          this.onEvent({
            type: 'error',
            error: voiceError('failed', event.message),
          });
          return;
        }
        const text = tidySegment(event.text, this.options.punctuate ?? true);
        if (event.type === 'final') {
          this.partial = text;
          this.settle();
          return;
        }
        const stable = stablePrefix(this.previousPartial, text);
        this.previousPartial = text;
        this.partial = text;
        this.onEvent({type: 'partial', segmentId: id, text, stable});
      },
    );
  }

  /** The open partial becomes a final segment. */
  private settle(): void {
    const text = this.partial;
    const id = this.segmentId++;
    this.partial = '';
    this.previousPartial = '';
    if (text) {
      this.finals.push({id, text});
      this.onEvent({type: 'final', segmentId: id, text, language: this.locale});
    }
  }

  /** Ends the running task and starts the next; audio keeps flowing. */
  private rollTask(): void {
    const old = this.task;
    if (!old) {
      return;
    }
    this.task = null;
    this.rollover = this.rollover.then(async () => {
      await old.end().catch(() => {});
      if (this.cancelled) {
        return;
      }
      this.settle();
      if (!this.ended) {
        this.openTask();
        for (const chunk of this.backlog) {
          this.task?.feed(chunk);
        }
        this.backlog = [];
      }
    });
  }
}
