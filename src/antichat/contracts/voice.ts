/**
 * VoicePort: dictation, read-aloud and hands-free voice mode. M11 implements
 * it; the composer and the voice orb read it.
 */
import type {Observable, PortError} from './common';

export type DictationState =
  | {status: 'idle'}
  | {
      status: 'listening';
      /** Words so far; they change until the phrase settles. */
      partial: string;
      /** 0..1 input level for the waveform. */
      level: number;
      startedAt: number;
    }
  | {status: 'transcribing'}
  | {status: 'failed'; error: PortError};

export type SpeechState =
  | {status: 'idle'}
  | {status: 'preparing'; messageId: string}
  | {status: 'speaking'; messageId: string; /** 0..1 */ progress: number}
  | {status: 'paused'; messageId: string; progress: number};

export type VoiceModeState =
  | {status: 'off'}
  | {status: 'listening'; level: number}
  | {status: 'thinking'}
  | {status: 'speaking'; level: number}
  | {status: 'muted'};

export interface VoiceOption {
  id: string;
  displayName: string;
  languageTag: string;
}

export interface VoicePort extends Observable {
  readonly dictation: DictationState;
  readonly speech: SpeechState;
  readonly voiceMode: VoiceModeState;
  readonly voices: readonly VoiceOption[];
  readonly voiceId: string | null;

  startDictation(): Promise<void>;
  /** Stop listening and resolve with the final text. */
  finishDictation(): Promise<string>;
  cancelDictation(): void;

  speak(messageId: string, text: string): Promise<void>;
  pauseSpeech(): void;
  resumeSpeech(): void;
  stopSpeech(): void;

  startVoiceMode(conversationId: string | null): Promise<void>;
  setMuted(muted: boolean): void;
  /** Cut the spoken answer short and listen again. */
  interrupt(): void;
  stopVoiceMode(): void;

  setVoice(voiceId: string): Promise<void>;
}
