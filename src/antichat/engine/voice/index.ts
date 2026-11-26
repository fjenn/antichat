/**
 * Voice engine (M11): dictation, read-aloud and hands-free voice mode.
 *
 * The UI reads `VoicePort` (port.ts). Everything else exported here is for
 * the adapter that builds the port and for diagnostics screens. The native
 * bindings are in `./native` so that this entry stays free of native
 * modules (tests, fakes and the UI's storybook can import it).
 */
export * from './port';
export * from './types';
export {VoiceEngine, type VoiceEngineDeps} from './VoiceEngine';

export type {
  SttAdapter,
  SttEvent,
  SttOptions,
  SttResult,
  SttSession,
} from './stt/types';
export {WhisperSttAdapter, type WhisperBackend} from './stt/whisperAdapter';
export {
  SystemSttAdapter,
  type SystemRecognizerBackend,
} from './stt/systemAdapter';
export {
  selectStt,
  whisperTierFor,
  type SttChoice,
  type SttFacts,
} from './stt/select';
export {listeningLocale, matchLocale, whisperLanguage} from './stt/language';
export {
  transcribeAudioFile,
  transcribePcm,
  type AudioFileDecoder,
  type FileTranscript,
} from './stt/fileTranscriber';

export {
  SentenceSplitter,
  splitSentences,
  type SpeechUnit,
} from './tts/sentenceSplitter';
export {normalizeForSpeech} from './tts/normalize';
export {
  PronunciationLexicon,
  BUILTIN_PRONUNCIATIONS,
  type PronunciationEntry,
} from './tts/pronunciation';
export {StreamingSpeaker} from './tts/streamingSpeaker';
export {
  ReadAloudPlayer,
  READ_ALOUD_RATES,
  type PlaybackKeeper,
} from './tts/readAloud';
export type {TtsBackend, TtsStream} from './tts/types';
export * from './tts/voices';

export {
  VoiceModeController,
  DEFAULT_VOICE_MODE_CONFIG,
  type VoiceModeConfig,
  type VoiceModeEvent,
} from './mode/controller';
export type {
  SpeculativeReply,
  VoiceChatPort,
  VoiceReplyCallbacks,
  VoiceReplyResult,
  VoiceSendOptions,
} from './mode/chatPort';
export {transition, type VoicePhase} from './mode/machine';
export {EchoGuard} from './mode/echo';
export {planVoiceMemory, type VoiceMemoryPlan} from './mode/memoryPolicy';
export {
  LatencyTracker,
  type LatencySummary,
  type TurnLatency,
} from './latency/tracker';
export type * from './session/ports';
