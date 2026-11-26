/**
 * What the voice engine needs from the phone, as narrow ports. The bindings
 * to react-native-audio-api and PocketPal's native modules are in
 * `bindings/`; tests and the fixture harness provide fakes.
 */
import type {Unsubscribe} from '../types';

export type AudioRoute =
  | 'speaker'
  | 'earpiece'
  | 'wired'
  | 'bluetooth'
  | 'car'
  | 'unknown';

/**
 * - `dictation`: record only, other audio ducked.
 * - `playback`: read-aloud; keeps playing with the screen locked.
 * - `conversation`: play and record with the platform's echo cancellation.
 */
export type SessionProfile = 'dictation' | 'playback' | 'conversation';

export type SessionEvent =
  /** A call, Siri or another app took the audio. */
  | {type: 'interruption_began'}
  | {type: 'interruption_ended'; shouldResume: boolean}
  | {
      type: 'route_changed';
      route: AudioRoute;
      reason: 'new_device' | 'device_removed' | 'other';
    };

export interface SessionInfo {
  route: AudioRoute;
  /** The platform cancels our own playback out of the microphone signal. */
  echoCancellation: boolean;
}

export interface AudioSessionPort {
  activate(profile: SessionProfile): Promise<SessionInfo>;
  deactivate(): Promise<void>;
  /** 'auto' lets the system pick (a connected headset wins). */
  setOutput(output: 'speaker' | 'earpiece' | 'auto'): Promise<SessionInfo>;
  on(listener: (event: SessionEvent) => void): Unsubscribe;
}

export interface MicSource {
  /** Starts capture; chunks are 16 kHz mono Int16, 20–100 ms each. */
  start(
    onChunk: (pcm: Int16Array) => void,
    options: {echoCancellation: boolean},
  ): Promise<void>;
  stop(): Promise<void>;
}

export interface MicPermission {
  ensure(): Promise<'granted' | 'denied' | 'blocked'>;
}

export interface KeepAwake {
  /** Keeps the screen on until the returned release is called. */
  acquire(): () => void;
}
