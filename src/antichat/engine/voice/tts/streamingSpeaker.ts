/**
 * Speaks an answer while it is being written: text deltas in, sentences out
 * to the voice as soon as each one is complete.
 *
 * delta → SentenceSplitter → normalizeForSpeech → pronunciation fixes →
 * TtsStream. Units that have nothing to say (a table rule, an emoji) are
 * skipped. The speaker remembers which units were heard, so an interrupted
 * answer knows where the listener stopped.
 */
import {
  Hub,
  systemClock,
  voiceError,
  type Clock,
  type VoiceError,
} from '../types';
import {normalizeForSpeech} from './normalize';
import {PronunciationLexicon} from './pronunciation';
import {SentenceSplitter, type SpeechUnit} from './sentenceSplitter';
import type {TtsBackend, TtsStream} from './types';
import type {CatalogVoice} from './voices';

export interface SpokenUnit extends SpeechUnit {
  /** The words handed to the voice. */
  spoken: string;
}

export type SpeakerEvent =
  /** The first complete unit left the splitter (the "first sentence" mark). */
  | {type: 'first_unit'; atMs: number; unit: SpokenUnit}
  | {type: 'unit_start'; atMs: number; unit: SpokenUnit; first: boolean}
  | {type: 'unit_end'; atMs: number; unit: SpokenUnit}
  | {type: 'error'; error: VoiceError};

export interface SpeakerOptions {
  voice: CatalogVoice;
  rate?: number;
  language?: string;
  /** Start speaking at the first clause of a long opening sentence. */
  firstClause?: boolean;
  codePlaceholder?: string;
}

export type SpeakerOutcome = 'finished' | 'stopped' | 'failed';

export class StreamingSpeaker {
  readonly events = new Hub<SpeakerEvent>();
  readonly units: SpokenUnit[] = [];
  private readonly splitter: SentenceSplitter;
  private readonly stream: TtsStream;
  private readonly clock: Clock;
  private readonly lexicon: PronunciationLexicon;
  private startedIds = new Set<number>();
  private endedIds = new Set<number>();
  private outcome: SpeakerOutcome | null = null;
  private done: Promise<SpeakerOutcome> | null = null;
  private firstUnitSent = false;

  constructor(
    backend: TtsBackend,
    private readonly options: SpeakerOptions,
    deps: {clock?: Clock; lexicon?: PronunciationLexicon} = {},
  ) {
    this.clock = deps.clock ?? systemClock;
    this.lexicon = deps.lexicon ?? new PronunciationLexicon();
    this.splitter = new SentenceSplitter({
      language: options.language,
      firstClause: options.firstClause ?? true,
    });
    this.stream = backend.open(
      {
        voice: options.voice,
        rate: options.rate ?? 1,
        language: options.language,
      },
      {
        onUnitStart: id => {
          const unit = this.units[id];
          if (unit && !this.outcome) {
            const first = this.startedIds.size === 0;
            this.startedIds.add(id);
            this.events.emit({
              type: 'unit_start',
              atMs: this.clock.now(),
              unit,
              first,
            });
          }
        },
        onUnitEnd: id => {
          const unit = this.units[id];
          if (unit && !this.outcome) {
            this.endedIds.add(id);
            this.events.emit({type: 'unit_end', atMs: this.clock.now(), unit});
          }
        },
        onError: error => {
          if (!this.outcome) {
            this.outcome = 'failed';
            this.events.emit({type: 'error', error});
          }
        },
      },
    );
  }

  /** True once audio has started. */
  get speaking(): boolean {
    return this.startedIds.size > 0 && !this.outcome;
  }

  /** Words the listener has heard in full: the units that ended. */
  get heardText(): string {
    return this.units
      .filter(unit => this.endedIds.has(unit.index))
      .map(unit => unit.spoken)
      .join(' ');
  }

  /** Everything handed to the voice so far (the echo guard compares against it). */
  get spokenText(): string {
    return this.units.map(unit => unit.spoken).join(' ');
  }

  push(delta: string): void {
    if (this.outcome || this.done) {
      return;
    }
    this.queue(this.splitter.push(delta));
  }

  /** The answer is complete; resolves when the last unit was spoken. */
  finish(): Promise<SpeakerOutcome> {
    if (!this.done) {
      if (!this.outcome) {
        this.queue(this.splitter.flush());
      }
      this.done = this.stream
        .end()
        .then(() => (this.outcome ??= 'finished'))
        .catch(err => {
          this.events.emit({type: 'error', error: voiceError('failed', err)});
          return (this.outcome ??= 'failed');
        });
    }
    return this.done;
  }

  /** Cuts the speech off; resolves once the speaker is silent. */
  async stop(): Promise<void> {
    if (this.outcome) {
      return;
    }
    this.outcome = 'stopped';
    await this.stream.stop().catch(() => {});
  }

  private queue(units: SpeechUnit[]): void {
    for (const unit of units) {
      const spoken = this.lexicon.apply(
        normalizeForSpeech(unit.raw, {
          language: this.options.language,
          kind: unit.kind,
          codePlaceholder: this.options.codePlaceholder,
        }),
        this.options.language,
      );
      if (!spoken) {
        continue;
      }
      const item: SpokenUnit = {...unit, index: this.units.length, spoken};
      this.units.push(item);
      if (!this.firstUnitSent) {
        this.firstUnitSent = true;
        this.events.emit({
          type: 'first_unit',
          atMs: this.clock.now(),
          unit: item,
        });
      }
      this.stream.enqueue(item.index, spoken);
    }
  }
}
