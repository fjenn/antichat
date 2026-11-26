/** Text-to-speech seam: a stream of units to say, one after another. */
import type {VoiceError} from '../types';
import type {CatalogVoice} from './voices';

export interface TtsStreamCallbacks {
  /** Audio of unit `id` started coming out of the speaker. */
  onUnitStart(id: number): void;
  onUnitEnd(id: number): void;
  onError(error: VoiceError): void;
}

export interface TtsStreamOptions {
  voice: CatalogVoice;
  /** Speed multiplier, 0.5–2. */
  rate: number;
  /** BCP-47 language of the text (picks the system voice, the phonemizer). */
  language?: string;
}

export interface TtsStream {
  /** Queues a unit; synthesis may run ahead of playback. */
  enqueue(id: number, text: string): void;
  /** No more units. Resolves when everything queued was spoken, or on stop. */
  end(): Promise<void>;
  /** Silences the speaker now and drops the queue. */
  stop(): Promise<void>;
  pause(): Promise<void>;
  resume(): Promise<void>;
}

export interface TtsBackend {
  /** Loads the voice's engine so the first unit starts quickly. */
  prepare(voice: CatalogVoice): Promise<void>;
  open(options: TtsStreamOptions, callbacks: TtsStreamCallbacks): TtsStream;
  release(): Promise<void>;
}
