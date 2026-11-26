/**
 * VoicePort: dictation, read-aloud and hands-free voice mode, as the UI sees
 * them. The composer, the action row's read-aloud button, the voice orb and
 * Settings > Voice read this port and nothing else of the voice engine.
 *
 * It is the M1 contracts draft (`contracts/voice.ts`) plus what the engine
 * turned out to need: sentence-level read-aloud controls, a "starting" and a
 * "paused" voice-mode state, typed events (live transcript, barge-in,
 * latency) and audio-file transcription. Everything in the draft is here
 * unchanged in name and meaning, so the draft can be replaced by this file.
 *
 * Observable like every port: read the fields, `subscribe` to be told that
 * one of them changed (works with `useSyncExternalStore`).
 */
import type {TurnLatency, LatencySummary} from './latency/tracker';
import type {AudioRoute} from './session/ports';
import type {FileTranscript} from './stt/fileTranscriber';
import type {PronunciationEntry} from './tts/pronunciation';
import type {Unsubscribe, VoiceError} from './types';

export type {Unsubscribe, VoiceError} from './types';

export type DictationState =
  | {status: 'idle'}
  /** Permission, audio session and recogniser are being set up. */
  | {status: 'starting'}
  | {
      status: 'listening';
      /** Words so far; the part after `stableLength` may still change. */
      partial: string;
      stableLength: number;
      /** 0..1 input level for the waveform. */
      level: number;
      startedAt: number;
    }
  | {status: 'transcribing'}
  | {status: 'failed'; error: VoiceError};

export type SpeechState =
  | {status: 'idle'}
  | {status: 'preparing'; messageId: string}
  | {
      status: 'speaking' | 'paused';
      messageId: string;
      /** 0..1 */
      progress: number;
      /** Sentence being read and the number of sentences. */
      sentence: number;
      sentenceCount: number;
      /** Offsets of that sentence in the message text, for highlighting. */
      range: {start: number; end: number} | null;
      rate: number;
    };

export type VoiceModeState =
  | {status: 'off'}
  | {status: 'starting'}
  | {
      status: 'listening';
      level: number;
      /** Live transcript of the turn. */ partial: string;
    }
  | {status: 'thinking'}
  | {status: 'speaking'; level: number}
  | {status: 'muted'}
  /** A call or another app holds the audio; `resumeVoiceMode` continues. */
  | {status: 'paused'};

export interface VoiceOption {
  id: string;
  displayName: string;
  /** BCP-47, or 'multi' for a voice that follows the text's language. */
  languageTag: string;
  gender?: 'f' | 'm';
  /** Files are on the phone; false means one tap downloads `downloadBytes`. */
  installed: boolean;
  downloadBytes: number;
  /** The default for this phone and language. */
  recommended: boolean;
}

export type VoicePortEvent =
  /** Voice mode: what the user said, committed to the thread. */
  | {type: 'user_turn'; conversationId: string | null; text: string}
  /** Voice mode: the spoken answer ended; `heardText` is what was heard. */
  | {
      type: 'assistant_turn';
      status: 'complete' | 'stopped' | 'error' | 'interrupted';
      heardText: string;
    }
  /** Voice mode created or switched the chat it writes to. */
  | {type: 'conversation'; conversationId: string}
  | {type: 'barge_in'; by: 'voice' | 'button'; stopMs: number}
  | {type: 'latency'; turn: TurnLatency}
  | {
      type: 'route';
      route: AudioRoute;
      /** Only the button interrupts. */ halfDuplex: boolean;
    }
  | {type: 'voice_mode_stopped'; reason: string}
  | {type: 'voice_download'; voiceId: string; progress: number}
  | {
      type: 'error';
      scope: 'dictation' | 'speech' | 'voice_mode';
      error: VoiceError;
      fatal: boolean;
    };

export interface VoiceSettings {
  /** 'auto', or a BCP-47 tag the user fixed in Settings > Voice. */
  language: string;
  /** Punctuation and capitals in dictated text. */
  punctuation: boolean;
  /** Start replies early on a pause (speculative generation). */
  fastReplies: boolean;
  /** Speaking over the assistant stops it. */
  bargeIn: boolean;
  pronunciations: PronunciationEntry[];
}

export interface VoicePort {
  subscribe(listener: () => void): Unsubscribe;
  /** Typed one-off events that are not state. */
  onEvent(listener: (event: VoicePortEvent) => void): Unsubscribe;

  readonly dictation: DictationState;
  readonly speech: SpeechState;
  readonly voiceMode: VoiceModeState;
  readonly voices: readonly VoiceOption[];
  readonly voiceId: string | null;
  /** The voice in use: the choice, or this phone's default while none is made. */
  readonly activeVoiceId?: string;
  readonly settings: VoiceSettings;
  /** Hands-free mode can run on this phone (device class, memory). */
  readonly voiceModeAvailable: boolean;
  /** p50/p90 of the session's turns, for the diagnostics screen. */
  readonly latency: LatencySummary | null;

  // Dictation into the composer. No time limit.
  startDictation(): Promise<void>;
  /** Stop listening and resolve with the final text. */
  finishDictation(): Promise<string>;
  cancelDictation(): void;

  // Read aloud.
  speak(messageId: string, text: string): Promise<void>;
  pauseSpeech(): void;
  resumeSpeech(): void;
  stopSpeech(): void;
  /** Jump to a sentence (0-based), or one back / forward. */
  seekSpeech(sentence: number): void;
  skipSpeech(direction: -1 | 1): void;
  /** 0.5–2; applies to read-aloud and voice mode. */
  setSpeechRate(rate: number): void;
  /** "Tap to hear": says a selection once, with the current voice. */
  pronounce(text: string, languageTag?: string): Promise<void>;

  // Hands-free voice mode.
  startVoiceMode(conversationId: string | null): Promise<void>;
  setMuted(muted: boolean): void;
  /** Cut the spoken answer short and listen again. */
  interrupt(): void;
  resumeVoiceMode(): Promise<void>;
  stopVoiceMode(): void;
  setAudioOutput(output: 'speaker' | 'earpiece' | 'auto'): Promise<void>;

  // Settings > Voice.
  setVoice(voiceId: string): Promise<void>;
  updateSettings(patch: Partial<VoiceSettings>): void;

  /** Audio attachment → text (30-minute cap). */
  transcribeFile(
    uri: string,
    onProgress?: (fraction: number, textSoFar: string) => void,
  ): Promise<FileTranscript>;
}
