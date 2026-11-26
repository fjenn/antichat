/**
 * The voice catalogue: a short curated list instead of PocketPal's engine and
 * tier sheets. Sizes are the download and the memory the engine needs while
 * loaded (from `src/services/tts/constants.ts`); ids are the speech library's.
 */
import type {VoiceDeviceClass, VoicePlatform} from '../types';

export type TtsEngineId =
  | 'system'
  | 'kitten'
  | 'kokoro'
  | 'phonon'
  | 'supertonic';

export interface EngineSpec {
  id: TtsEngineId;
  /** One download per engine, shared by its voices. */
  downloadBytes: Record<VoicePlatform, number>;
  /** Peak memory while loaded; 0 = outside the app's budget. */
  runtimeBytes: Record<VoicePlatform, number>;
  /** BCP-47 base languages; '*' = whatever the phone has. */
  languages: readonly string[];
  /** Lowest class that may load it beside the chat model. */
  minClass: VoiceDeviceClass;
}

const MIB = 1024 * 1024;

export const TTS_ENGINES: Record<TtsEngineId, EngineSpec> = {
  system: {
    id: 'system',
    downloadBytes: {ios: 0, android: 0},
    runtimeBytes: {ios: 0, android: 0},
    languages: ['*'],
    minClass: 'A',
  },
  kitten: {
    id: 'kitten',
    downloadBytes: {ios: 57 * MIB, android: 57 * MIB},
    runtimeBytes: {ios: 200_000_000, android: 200_000_000},
    languages: ['en'],
    minClass: 'B',
  },
  phonon: {
    id: 'phonon',
    downloadBytes: {ios: 171_554_733, android: 67_098_394},
    runtimeBytes: {ios: 200 * MIB, android: 200 * MIB},
    languages: ['en'],
    minClass: 'B',
  },
  kokoro: {
    id: 'kokoro',
    downloadBytes: {ios: 330 * MIB, android: 107 * MIB},
    runtimeBytes: {ios: 500_000_000, android: 350_000_000},
    languages: ['en', 'zh'],
    minClass: 'C',
  },
  supertonic: {
    id: 'supertonic',
    downloadBytes: {ios: 398_352_949, android: 398_352_949},
    runtimeBytes: {ios: 500_000_000, android: 500_000_000},
    // Supertonic v3: 31 languages; the ones we expose a voice for.
    languages: ['en', 'de', 'es', 'fr', 'it', 'pt', 'nl', 'pl', 'ko', 'ja'],
    minClass: 'C',
  },
};

export interface CatalogVoice {
  /** `<engine>:<engine voice id>`; stable, stored in settings. */
  id: string;
  engine: TtsEngineId;
  engineVoiceId: string;
  displayName: string;
  /** BCP-47; 'multi' for a voice that follows the text's language. */
  languageTag: string;
  gender?: 'f' | 'm';
}

/** `system:default` stands for the phone's own voice in the text's language. */
export const SYSTEM_VOICE: CatalogVoice = {
  id: 'system:default',
  engine: 'system',
  engineVoiceId: '',
  displayName: 'System',
  languageTag: 'multi',
};

export const CURATED_VOICES: readonly CatalogVoice[] = [
  {
    id: 'phonon:Juniper',
    engine: 'phonon',
    engineVoiceId: 'Juniper',
    displayName: 'Juniper',
    languageTag: 'en-US',
    gender: 'f',
  },
  {
    id: 'phonon:Easton',
    engine: 'phonon',
    engineVoiceId: 'Easton',
    displayName: 'Easton',
    languageTag: 'en-US',
    gender: 'm',
  },
  {
    id: 'kokoro:af_heart',
    engine: 'kokoro',
    engineVoiceId: 'af_heart',
    displayName: 'Heart',
    languageTag: 'en-US',
    gender: 'f',
  },
  {
    id: 'kokoro:am_michael',
    engine: 'kokoro',
    engineVoiceId: 'am_michael',
    displayName: 'Michael',
    languageTag: 'en-US',
    gender: 'm',
  },
  {
    id: 'kokoro:bf_emma',
    engine: 'kokoro',
    engineVoiceId: 'bf_emma',
    displayName: 'Emma',
    languageTag: 'en-GB',
    gender: 'f',
  },
  {
    id: 'kitten:expr-voice-2-f',
    engine: 'kitten',
    engineVoiceId: 'expr-voice-2-f',
    displayName: 'Bella',
    languageTag: 'en-US',
    gender: 'f',
  },
  {
    id: 'supertonic:F1',
    engine: 'supertonic',
    engineVoiceId: 'F1',
    displayName: 'Sol',
    languageTag: 'multi',
    gender: 'f',
  },
  {
    id: 'supertonic:M1',
    engine: 'supertonic',
    engineVoiceId: 'M1',
    displayName: 'Arlo',
    languageTag: 'multi',
    gender: 'm',
  },
  SYSTEM_VOICE,
];

const CLASS_ORDER: VoiceDeviceClass[] = ['A', 'B', 'C', 'D', 'E'];
export const classAtLeast = (
  cls: VoiceDeviceClass,
  min: VoiceDeviceClass,
): boolean => CLASS_ORDER.indexOf(cls) >= CLASS_ORDER.indexOf(min);

const base = (tag: string) => tag.toLowerCase().split(/[-_]/)[0]!;

export interface VoiceFacts {
  deviceClass: VoiceDeviceClass;
  platform: VoicePlatform;
  /** Language the voice has to speak (BCP-47). */
  language: string;
  /** The speech library says Phonon runs on this phone (≥3 GB, iOS 18+). */
  phononSupported: boolean;
  /** Engines whose files are on disk. */
  installedEngines: readonly TtsEngineId[];
}

export const speaksLanguage = (
  voice: CatalogVoice,
  language: string,
): boolean => {
  const engine = TTS_ENGINES[voice.engine];
  return (
    engine.languages.includes('*') || engine.languages.includes(base(language))
  );
};

/** Voices this phone may use for `language`, best first; the system voice is always last. */
export function voicesFor(facts: VoiceFacts): CatalogVoice[] {
  return CURATED_VOICES.filter(voice => {
    const engine = TTS_ENGINES[voice.engine];
    if (!classAtLeast(facts.deviceClass, engine.minClass)) {
      return false;
    }
    if (voice.engine === 'phonon' && !facts.phononSupported) {
      return false;
    }
    // Low storage and low memory option only where Kokoro is too heavy.
    if (
      voice.engine === 'kitten' &&
      classAtLeast(facts.deviceClass, 'C') &&
      facts.phononSupported
    ) {
      return false;
    }
    return speaksLanguage(voice, facts.language);
  });
}

export interface VoiceChoice {
  /** What speaks right now: the best voice whose engine is installed. */
  voice: CatalogVoice;
  /** The recommended voice when it still needs a download, with its size. */
  offer?: {voice: CatalogVoice; downloadBytes: number};
}

/**
 * Default per class:
 * - A (4 GB): the system voice; a neural engine does not fit beside the model.
 * - B (6 GB): Phonon where supported (about 200 MB loaded, fastest first
 *   audio), else Kitten (57 MB download).
 * - C and up: Phonon, else Kokoro; Supertonic for other languages.
 * Until the recommended engine is downloaded, the system voice speaks.
 */
export function defaultVoice(facts: VoiceFacts): VoiceChoice {
  const candidates = voicesFor(facts);
  const recommended = candidates[0] ?? SYSTEM_VOICE;
  const usable =
    candidates.find(
      v => v.engine === 'system' || facts.installedEngines.includes(v.engine),
    ) ?? SYSTEM_VOICE;
  if (recommended.id === usable.id || recommended.engine === 'system') {
    return {voice: usable};
  }
  return {
    voice: usable,
    offer: {
      voice: recommended,
      downloadBytes:
        TTS_ENGINES[recommended.engine].downloadBytes[facts.platform],
    },
  };
}

export const findVoice = (
  id: string | null | undefined,
): CatalogVoice | undefined => CURATED_VOICES.find(voice => voice.id === id);

/** Download size and loaded memory of a voice's engine on this platform. */
export function voiceCost(voice: CatalogVoice, platform: VoicePlatform) {
  const engine = TTS_ENGINES[voice.engine];
  return {
    downloadBytes: engine.downloadBytes[platform],
    runtimeBytes: engine.runtimeBytes[platform],
  };
}
