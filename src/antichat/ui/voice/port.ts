/**
 * The voice UI talks to the engine's `VoicePort` (engine/voice/port.ts). The
 * shell's port may still be the M1 contract shape (the fake, until
 * `adapters/voice.ts` is switched on); `asVoicePort` lifts that to the
 * engine shape with neutral defaults, so the components have one type.
 */
import {getPorts} from '../../adapters';
import type {VoicePort as ContractVoicePort} from '../../contracts';
import type {
  SpeechState,
  VoiceModeState,
  VoicePort,
  VoiceSettings,
} from '../../engine/voice/port';

const SETTINGS: VoiceSettings = {
  language: 'auto',
  punctuation: true,
  fastReplies: true,
  bargeIn: true,
  pronunciations: [],
};

const lifted = new WeakMap<object, VoicePort>();

export function asVoicePort(port: ContractVoicePort | VoicePort): VoicePort {
  if ('onEvent' in port) {
    return port;
  }
  const known = lifted.get(port);
  if (known) {
    return known;
  }
  let rate = 1;
  const wrapped: VoicePort = {
    subscribe: listener => port.subscribe(listener),
    onEvent: () => () => {},
    get dictation() {
      const state = port.dictation;
      return state.status === 'listening'
        ? {...state, stableLength: state.partial.length}
        : state.status === 'failed'
          ? {
              status: 'failed' as const,
              error: {code: 'failed' as const, retryable: true},
            }
          : state;
    },
    get speech(): SpeechState {
      const state = port.speech;
      return state.status === 'speaking' || state.status === 'paused'
        ? {...state, sentence: 0, sentenceCount: 1, range: null, rate}
        : state;
    },
    get voiceMode(): VoiceModeState {
      const state = port.voiceMode;
      return state.status === 'listening' ? {...state, partial: ''} : state;
    },
    get voices() {
      return port.voices.map((voice, index) => ({
        ...voice,
        installed: true,
        downloadBytes: 0,
        recommended: index === 0,
      }));
    },
    get voiceId() {
      return port.voiceId;
    },
    settings: SETTINGS,
    voiceModeAvailable: true,
    latency: null,
    startDictation: () => port.startDictation(),
    finishDictation: () => port.finishDictation(),
    cancelDictation: () => port.cancelDictation(),
    speak: (id, text) => port.speak(id, text),
    pauseSpeech: () => port.pauseSpeech(),
    resumeSpeech: () => port.resumeSpeech(),
    stopSpeech: () => port.stopSpeech(),
    seekSpeech: () => {},
    skipSpeech: () => {},
    setSpeechRate: next => {
      rate = next;
    },
    pronounce: (text: string) => port.speak('pronounce', text),
    startVoiceMode: id => port.startVoiceMode(id),
    setMuted: muted => port.setMuted(muted),
    interrupt: () => port.interrupt(),
    resumeVoiceMode: async () => {},
    stopVoiceMode: () => port.stopVoiceMode(),
    setAudioOutput: async () => {},
    setVoice: id => port.setVoice(id),
    updateSettings: () => {},
    transcribeFile: async () => {
      throw new Error('not available');
    },
  };
  lifted.set(port, wrapped);
  return wrapped;
}

/** The app's voice port, in the engine shape. */
export const getVoicePort = (): VoicePort =>
  asVoicePort(getPorts().voice as ContractVoicePort | VoicePort);
