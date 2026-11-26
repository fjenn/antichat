/**
 * Builds the real `VoicePort` for the phone: picks the recogniser and the
 * voice for this device, plans memory, and wires the native bindings.
 *
 * The adapter in `src/antichat/adapters/` calls `createVoicePort` once, with
 * the chat port of the normal send path:
 *
 *   const voice = await createVoicePort({chat, deviceClass, deviceLocales});
 */
import {Platform} from 'react-native';

import type {AsrTier} from '../../../services/asr';
import {
  getEngine,
  getNeuralEngine,
  getPhononSupport,
} from '../../../services/tts';
import {
  createAudioFileDecoder,
  createAudioSession,
  createMicSource,
} from './bindings/audio';
import {
  createAppleSpeechBackend,
  type AppleTranscriptionModule,
} from './bindings/appleSpeech';
import {
  createPlaybackKeeper,
  keepAwake,
  micPermission,
} from './bindings/platform';
import {createSpeechTtsBackend} from './bindings/speechTts';
import {
  createWhisperRnBackend,
  installedWhisperTiers,
} from './bindings/whisperRn';
import type {VoiceChatPort} from './mode/chatPort';
import {planVoiceMemory, type VoiceMemoryPlan} from './mode/memoryPolicy';
import type {VoiceSettings} from './port';
import {listeningLocale} from './stt/language';
import {FallbackSttAdapter} from './stt/fallbackAdapter';
import {selectStt, whisperTierFor, type SttChoice} from './stt/select';
import {SystemSttAdapter} from './stt/systemAdapter';
import type {SttAdapter} from './stt/types';
import {WhisperSttAdapter} from './stt/whisperAdapter';
import {defaultVoice, findVoice, type TtsEngineId} from './tts/voices';
import type {VoiceDeviceClass} from './types';
import {VoiceEngine} from './VoiceEngine';

export interface CreateVoicePortOptions {
  chat: VoiceChatPort;
  deviceClass: VoiceDeviceClass;
  /** Languages of the phone, most preferred first (BCP-47). */
  deviceLocales: readonly string[];
  /** `AppleTranscription` of `@react-native-ai/apple`, once it is a dependency. */
  appleTranscription?: AppleTranscriptionModule;
  /**
   * Makes sure the Whisper model of this tier is on the phone; called when
   * Apple's recogniser fails and Whisper takes over.
   */
  ensureWhisper?: (tier: AsrTier) => Promise<void>;
  /** Memory the app may still take with the chat model loaded, when measured. */
  freeBytes?: number;
  initial?: {
    voiceId?: string | null;
    rate?: number;
    settings?: Partial<VoiceSettings>;
  };
  onPersist?: (state: {
    voiceId: string | null;
    rate: number;
    settings: VoiceSettings;
  }) => void;
  /** Notification copy for Android's read-aloud foreground service. */
  playbackCopy?: {title: string; stopLabel: string; channelName: string};
}

const NEURAL: Exclude<TtsEngineId, 'system'>[] = [
  'kitten',
  'kokoro',
  'phonon',
  'supertonic',
];

async function installedEngines(): Promise<TtsEngineId[]> {
  const present = await Promise.all(
    NEURAL.map(id =>
      getEngine(id)
        .isInstalled()
        .catch(() => false),
    ),
  );
  return NEURAL.filter((_, index) => present[index]);
}

export async function createVoicePort(
  options: CreateVoicePortOptions,
): Promise<{
  port: VoiceEngine;
  stt: SttChoice;
  memory: VoiceMemoryPlan;
}> {
  const platform = Platform.OS === 'ios' ? 'ios' : 'android';
  const language = options.initial?.settings?.language ?? 'auto';
  const system = options.appleTranscription
    ? createAppleSpeechBackend(options.appleTranscription)
    : null;

  const [whisperInstalled, systemLocales, phonon] = await Promise.all([
    installedWhisperTiers(),
    system ? system.supportedLocales().catch(() => []) : Promise.resolve([]),
    getPhononSupport()
      .then(support => support.supported)
      .catch(() => false),
  ]);
  let engines = await installedEngines();
  const locale = (setting: string) =>
    listeningLocale(
      {setting, deviceLocales: options.deviceLocales},
      systemLocales,
    );
  const systemLocale = locale(language);
  const systemOnDevice = Boolean(
    system && systemLocale && (await system.support(systemLocale))?.onDevice,
  );

  const choice = selectStt({
    platform,
    osVersion: String(Platform.Version),
    deviceClass: options.deviceClass,
    systemOnDevice,
    whisperInstalled,
    systemModule: Boolean(system),
  });
  const spokenLanguage =
    language === 'auto' ? (options.deviceLocales[0] ?? 'en') : language;
  const facts = () =>
    ({
      deviceClass: options.deviceClass,
      platform,
      phononSupported: phonon,
      installedEngines: engines,
      language: spokenLanguage,
    }) as const;
  const chosenVoice =
    findVoice(options.initial?.voiceId) ?? defaultVoice(facts()).voice;
  const memory = planVoiceMemory({
    deviceClass: options.deviceClass,
    platform,
    stt: choice,
    voice: chosenVoice,
    systemSttAvailable: systemOnDevice,
    freeBytes: options.freeBytes,
  });

  const tier = (): AsrTier =>
    memory.stt.whisperTier ?? whisperTierFor(options.deviceClass);
  const whisper = () =>
    new WhisperSttAdapter(createWhisperRnBackend(tier), {
      // Decodes are slower beside a loaded chat model on small phones.
      partialIntervalMs: options.deviceClass <= 'B' ? 1400 : 900,
    });
  // Apple's recogniser with Whisper behind it: any failure of the first
  // moves the dictation to the second instead of ending it.
  const stt: SttAdapter =
    memory.stt.adapter === 'system' && system
      ? new FallbackSttAdapter(
          new SystemSttAdapter(system, async setting => {
            const match = locale(setting);
            if (!match) {
              throw new Error(`no on-device recognition for ${setting}`);
            }
            return match;
          }),
          async () => {
            await options.ensureWhisper?.(tier());
            return whisper();
          },
        )
      : whisper();

  const port = new VoiceEngine({
    stt,
    tts: createSpeechTtsBackend(),
    session: createAudioSession(),
    mic: createMicSource(),
    chat: options.chat,
    keepAwake,
    permission: micPermission,
    keeper: createPlaybackKeeper(
      options.playbackCopy ?? {
        title: 'AntiChat',
        stopLabel: 'Stop',
        channelName: 'Read aloud',
      },
    ),
    decoder: createAudioFileDecoder(),
    facts,
    installEngine: async (id, onProgress) => {
      if (id === 'system') {
        return;
      }
      await getNeuralEngine(id).downloadModel(onProgress);
      engines = await installedEngines();
    },
    voiceModeAvailable: memory.voiceMode !== 'unavailable',
    dictationWarmMs: memory.dictationWarmMs,
    voiceWarmMs: memory.voiceWarmMs,
    initial: {
      ...options.initial,
      // A voice the memory plan swapped out is not restored.
      voiceId:
        memory.voice.id === chosenVoice.id
          ? options.initial?.voiceId
          : memory.voice.id,
    },
    onPersist: options.onPersist,
  });
  return {port, stt: memory.stt, memory};
}
