/**
 * Read-aloud player for a finished message: play, pause, jump by sentence,
 * change speed. It keeps playing with the screen locked (the audio session is
 * a playback session and the platform keeper holds the process), and pauses
 * for a phone call.
 */
import {Hub, voiceError, type VoiceError} from '../types';
import {normalizeForSpeech} from './normalize';
import {PronunciationLexicon} from './pronunciation';
import {splitSentences} from './sentenceSplitter';
import type {SpokenUnit} from './streamingSpeaker';
import type {TtsBackend, TtsStream} from './types';
import type {CatalogVoice} from './voices';

export const READ_ALOUD_RATES = [0.75, 1, 1.25, 1.5, 2] as const;

export type ReadAloudState =
  | {status: 'idle'}
  | {status: 'preparing'; messageId: string}
  | {
      status: 'speaking' | 'paused';
      messageId: string;
      /** Sentence being read, and how many there are. */
      index: number;
      count: number;
      /** 0..1 over the whole message. */
      progress: number;
      rate: number;
    };

/** Keeps playback alive in the background (iOS audio session, Android foreground service). */
export interface PlaybackKeeper {
  hold(info: {title: string}): Promise<void>;
  release(): void;
}

export interface ReadAloudDeps {
  backend: TtsBackend;
  keeper?: PlaybackKeeper;
  lexicon?: PronunciationLexicon;
  voice: () => CatalogVoice;
}

export class ReadAloudPlayer {
  readonly changes = new Hub<ReadAloudState>();
  readonly errors = new Hub<VoiceError>();
  private current: ReadAloudState = {status: 'idle'};
  private units: SpokenUnit[] = [];
  private stream: TtsStream | null = null;
  private generation = 0;
  private rateValue = 1;
  private language: string | undefined;
  private pausedBySystem = false;

  constructor(private readonly deps: ReadAloudDeps) {}

  get state(): ReadAloudState {
    return this.current;
  }

  get rate(): number {
    return this.rateValue;
  }

  /** The sentences of the loaded message, for highlighting. */
  get sentences(): readonly SpokenUnit[] {
    return this.units;
  }

  async play(
    messageId: string,
    text: string,
    options: {language?: string; title?: string; startIndex?: number} = {},
  ): Promise<void> {
    await this.halt();
    const generation = this.generation;
    this.language = options.language;
    const lexicon = this.deps.lexicon ?? new PronunciationLexicon();
    this.units = splitSentences(text, {language: options.language})
      .map(unit => ({
        ...unit,
        spoken: lexicon.apply(
          normalizeForSpeech(unit.raw, {
            language: options.language,
            kind: unit.kind,
          }),
          options.language,
        ),
      }))
      .filter(unit => unit.spoken)
      .map((unit, index) => ({...unit, index}));
    if (this.units.length === 0) {
      return;
    }
    this.set({status: 'preparing', messageId});
    try {
      await this.deps.keeper?.hold({title: options.title ?? ''});
      await this.deps.backend.prepare(this.deps.voice());
    } catch (err) {
      if (generation === this.generation) {
        this.fail(voiceError('failed', err));
      }
      return;
    }
    if (generation !== this.generation) {
      return;
    }
    this.startAt(
      messageId,
      Math.min(options.startIndex ?? 0, this.units.length - 1),
    );
  }

  pause(): void {
    const state = this.current;
    if (state.status !== 'speaking') {
      return;
    }
    this.set({...state, status: 'paused'});
    this.stream?.pause().catch(() => {});
  }

  resume(): void {
    const state = this.current;
    if (state.status !== 'paused') {
      return;
    }
    this.pausedBySystem = false;
    if (this.stream) {
      this.set({...state, status: 'speaking'});
      this.stream.resume().catch(() => {});
    } else {
      // A seek or a speed change while paused left no stream: start there.
      this.startAt(state.messageId, state.index);
    }
  }

  /** Jumps to a sentence; keeps playing or stays paused. */
  seekTo(index: number): void {
    const state = this.current;
    if (state.status !== 'speaking' && state.status !== 'paused') {
      return;
    }
    const target = Math.max(0, Math.min(this.units.length - 1, index));
    this.dropStream();
    if (state.status === 'paused') {
      this.set({...state, index: target, progress: target / this.units.length});
    } else {
      this.startAt(state.messageId, target);
    }
  }

  next(): void {
    if ('index' in this.current) {
      this.seekTo(this.current.index + 1);
    }
  }

  /** Back to the start of this sentence's predecessor. */
  previous(): void {
    if ('index' in this.current) {
      this.seekTo(this.current.index - 1);
    }
  }

  /** Changes speed; the current sentence restarts at the new speed. */
  setRate(rate: number): void {
    this.rateValue = Math.max(0.5, Math.min(2, rate));
    const state = this.current;
    if (state.status === 'speaking') {
      this.dropStream();
      this.startAt(state.messageId, state.index);
    } else if (state.status === 'paused') {
      this.dropStream();
      this.set({...state, rate: this.rateValue});
    }
  }

  async stop(): Promise<void> {
    await this.halt();
    this.set({status: 'idle'});
  }

  /** A call or another app took the audio: pause, and resume after it if allowed. */
  handleInterruption(
    event: {type: 'began'} | {type: 'ended'; shouldResume: boolean},
  ): void {
    if (event.type === 'began') {
      if (this.current.status === 'speaking') {
        this.pause();
        this.pausedBySystem = true;
      }
    } else if (this.pausedBySystem && event.shouldResume) {
      this.resume();
    }
  }

  private startAt(messageId: string, index: number): void {
    const generation = ++this.generation;
    const count = this.units.length;
    this.set({
      status: 'speaking',
      messageId,
      index,
      count,
      progress: index / count,
      rate: this.rateValue,
    });
    const stream = this.deps.backend.open(
      {voice: this.deps.voice(), rate: this.rateValue, language: this.language},
      {
        onUnitStart: id => {
          const state = this.current;
          if (generation === this.generation && 'index' in state) {
            this.set({...state, index: id, progress: id / count});
          }
        },
        onUnitEnd: id => {
          const state = this.current;
          if (generation === this.generation && 'index' in state) {
            this.set({...state, progress: (id + 1) / count});
          }
        },
        onError: error => {
          if (generation === this.generation) {
            this.fail(error);
          }
        },
      },
    );
    this.stream = stream;
    for (const unit of this.units.slice(index)) {
      stream.enqueue(unit.index, unit.spoken);
    }
    stream
      .end()
      .then(() => {
        if (
          generation === this.generation &&
          this.current.status === 'speaking'
        ) {
          this.stream = null;
          this.deps.keeper?.release();
          this.set({status: 'idle'});
        }
      })
      .catch(err => {
        if (generation === this.generation) {
          this.fail(voiceError('failed', err));
        }
      });
  }

  private dropStream(): void {
    this.generation++;
    const stream = this.stream;
    this.stream = null;
    stream?.stop().catch(() => {});
  }

  private async halt(): Promise<void> {
    this.generation++;
    this.pausedBySystem = false;
    const stream = this.stream;
    this.stream = null;
    if (stream) {
      await stream.stop().catch(() => {});
    }
    if (this.current.status !== 'idle') {
      this.deps.keeper?.release();
    }
  }

  private fail(error: VoiceError): void {
    this.dropStream();
    this.deps.keeper?.release();
    this.set({status: 'idle'});
    this.errors.emit(error);
  }

  private set(state: ReadAloudState): void {
    this.current = state;
    this.changes.emit(state);
  }
}
