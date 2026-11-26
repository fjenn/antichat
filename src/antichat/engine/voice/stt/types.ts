/**
 * Speech-to-text seam. One shape for every recogniser: 16 kHz mono PCM in,
 * `partial` and `final` segments out.
 */
import type {VoiceError} from '../types';

export type SttAdapterId = 'system' | 'whisper';

export type SttEvent =
  /**
   * The open segment's text so far. `stable` is the leading part that two
   * decodes in a row agreed on; the rest may still change.
   */
  | {type: 'partial'; segmentId: number; text: string; stable: string}
  | {type: 'final'; segmentId: number; text: string; language?: string}
  | {type: 'error'; error: VoiceError};

export interface SttOptions {
  /** BCP-47 tag, or 'auto' to detect (recognisers that cannot detect use the device language). */
  language: string;
  /** `dictation` cuts segments at pauses itself; `conversation` leaves the turn end to the caller. */
  mode: 'dictation' | 'conversation';
  /** Punctuation and capitals in the result. */
  punctuate?: boolean;
  /** Earlier text, as context for the first segment. */
  context?: string;
}

export interface SttResult {
  text: string;
  /** Language the speech was recognised in ('' when unknown). */
  language: string;
  segments: {id: number; text: string}[];
}

export interface SttSession {
  /** Everything recognised so far: final segments plus the open partial. */
  readonly text: string;
  push(pcm: Int16Array): void;
  /**
   * Best transcript of what was said so far, without ending the session.
   * Voice mode asks for it at the first short pause.
   */
  snapshot(): Promise<string>;
  /** No more audio: resolves with the final text. */
  finish(): Promise<SttResult>;
  cancel(): void;
}

export interface SttAdapter {
  readonly id: SttAdapterId;
  /** Partials are word-by-word from the recogniser itself (not re-decodes). */
  readonly trueStreaming: boolean;
  /** Loads models so the first `start` is quick. */
  prepare(language: string): Promise<void>;
  release(): Promise<void>;
  start(options: SttOptions, onEvent: (event: SttEvent) => void): SttSession;
  /** One-shot recognition of a finished buffer (file pieces, tests). */
  transcribe(
    pcm: Int16Array,
    options: Pick<SttOptions, 'language' | 'punctuate' | 'context'>,
  ): Promise<{text: string; language: string}>;
}
