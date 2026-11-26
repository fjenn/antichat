/**
 * The voice port of the first version: dictation only.
 *
 * The real engine (`engine/voice`) is built on the first tap on the
 * microphone, not at launch. On iOS 26+ it uses Apple's on-device
 * SpeechTranscriber (the first tap installs the language's system assets if
 * they are missing); everywhere else, or when Apple has not got the
 * language, Whisper: the first tap fetches the model for this phone class
 * (upstream's installer and Hugging Face address) and shows the progress in
 * the dictation bar's "starting" state. Later taps start at once.
 *
 * The Voice settings (dictation language, punctuation) live here, persisted,
 * so Settings > Voice works before the engine exists and the engine starts
 * with them.
 *
 * Read-aloud and voice mode are not in this version; their members answer
 * from a neutral stand-in until the engine exists and are not mounted.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';

import {FakeVoice} from '../contracts/fakes';
import type {VoiceEngine} from '../engine/voice';
import {
  loadAppleTranscription,
  type AppleTranscriptionModule,
} from '../engine/voice/bindings/appleSpeech';
import type {
  DictationState,
  VoicePort,
  VoiceSettings,
} from '../engine/voice/port';
import {listeningLocale} from '../engine/voice/stt/language';
import {whisperTierFor} from '../engine/voice/stt/select';
import type {AsrTier} from '../../services/asr';
import {voiceError} from '../engine/voice/types';
import {asVoicePort} from '../ui/voice/port';

const STORAGE_KEY = 'antichat.voice.v1';

interface StoredVoice {
  voiceId: string | null;
  rate: number;
  settings: VoiceSettings;
}

/**
 * Apple's recogniser when it can take this language on the phone, its
 * assets installed (a quiet system download on the first tap); else null.
 */
async function readyApple(
  apple: AppleTranscriptionModule | undefined,
  setting: string,
  locales: readonly string[],
): Promise<AppleTranscriptionModule | null> {
  if (!apple) {
    return null;
  }
  const skip = (why: string) => {
    console.log(`[voice] Apple recogniser not used: ${why}`);
    return null;
  };
  try {
    const supported = (await apple.getModelInfo('en')).supportedLocales ?? [];
    const locale = listeningLocale(
      {setting, deviceLocales: locales},
      supported,
    );
    if (!locale) {
      return skip(`no locale for ${setting} (${supported.length} supported)`);
    }
    const info = await apple.getModelInfo(locale);
    if (!info.isAvailable || !info.supportsLocale) {
      return skip(`${locale} unavailable (${info.assets ?? 'no assets'})`);
    }
    if (info.assets !== 'installed') {
      await apple.prepare(locale);
    }
    return apple;
  } catch (error) {
    return skip(String(error));
  }
}

export type DictationSetup =
  | {phase: 'idle'}
  | {phase: 'downloading'; fraction: number}
  | {phase: 'loading'};

export interface LazyVoicePort extends VoicePort {
  /** What the first tap is waiting for (the bar's small print). */
  readonly setup: DictationSetup;
}

function deviceLocales(): string[] {
  try {
    const {getLocales} = require('react-native-localize');
    return getLocales().map((l: {languageTag: string}) => l.languageTag);
  } catch {
    return ['en'];
  }
}

function deviceClass(): 'A' | 'B' | 'C' | 'D' | 'E' {
  try {
    const {sharedModelRuntime} = require('./model');
    return sharedModelRuntime().engine.deviceClass ?? 'B';
  } catch {
    return 'B';
  }
}

export function createLazyVoicePort(): LazyVoicePort {
  const neutral = asVoicePort(new FakeVoice());
  const listeners = new Set<() => void>();
  let inner: VoiceEngine | null = null;
  let building: Promise<VoiceEngine> | null = null;
  let setup: DictationSetup = {phase: 'idle'};
  let own: DictationState = {status: 'idle'};
  let cancelled = false;
  let stored: StoredVoice = {
    voiceId: null,
    rate: 1,
    settings: neutral.settings,
  };
  const loaded = Promise.resolve()
    .then(() => AsyncStorage.getItem(STORAGE_KEY))
    .then(raw => {
      const value = raw ? (JSON.parse(raw) as Partial<StoredVoice>) : {};
      stored = {
        voiceId: value.voiceId ?? null,
        rate: value.rate ?? 1,
        settings: {...stored.settings, ...value.settings},
      };
      emit();
    })
    .catch(() => {});
  const save = (next: StoredVoice) => {
    stored = next;
    Promise.resolve()
      .then(() => AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next)))
      .catch(() => {});
  };

  const emit = () => listeners.forEach(listener => listener());
  const set = (next: DictationState, phase: DictationSetup = setup) => {
    own = next;
    setup = phase;
    emit();
  };

  /** Fetches this tier's Whisper model when it is missing. */
  const ensureWhisper = async (tier: AsrTier, showProgress: boolean) => {
    const {whisperAsrEngine} =
      require('../../services/asr') as typeof import('../../services/asr');
    if (await whisperAsrEngine.isInstalled(tier)) {
      return;
    }
    if (showProgress) {
      set({status: 'starting'}, {phase: 'downloading', fraction: 0});
    }
    await whisperAsrEngine.downloadModel(tier, fraction => {
      if (showProgress) {
        set({status: 'starting'}, {phase: 'downloading', fraction});
      }
    });
  };

  const create = async (
    apple: AppleTranscriptionModule | null,
    locales: string[],
    phoneClass: ReturnType<typeof deviceClass>,
  ): Promise<VoiceEngine> => {
    if (!apple) {
      await ensureWhisper(whisperTierFor(phoneClass), true);
    }
    set({status: 'starting'}, {phase: 'loading'});
    const {createVoicePort} =
      require('../engine/voice/native') as typeof import('../engine/voice/native');
    const created = await createVoicePort({
      // Dictation never sends by itself; voice mode is not in this version.
      chat: {
        send: async () => {
          throw new Error('voice mode is not in this version');
        },
        stop: () => undefined,
      } as never,
      deviceClass: phoneClass as never,
      deviceLocales: locales,
      appleTranscription: apple ?? undefined,
      // Apple's recogniser failed mid-dictation: Whisper takes over.
      ensureWhisper: tier => ensureWhisper(tier, false),
      initial: stored,
      onPersist: save,
    });
    // One line per launch: which recogniser dictation runs on and why.
    console.log(
      `[voice] dictation on ${created.stt.adapter}` +
        (created.stt.whisperTier ? ` (${created.stt.whisperTier})` : '') +
        `: ${created.stt.reason}`,
    );
    return created.port;
  };

  const build = (): Promise<VoiceEngine> => {
    building ??= (async () => {
      await loaded;
      const locales = deviceLocales();
      const phoneClass = deviceClass();
      const apple = await readyApple(
        loadAppleTranscription(),
        stored.settings.language,
        locales,
      );
      let engine: VoiceEngine;
      try {
        engine = await create(apple, locales, phoneClass);
      } catch (error) {
        if (!apple) {
          throw error;
        }
        console.log(`[voice] Apple recogniser failed to start: ${error}`);
        engine = await create(null, locales, phoneClass);
      }
      inner = engine;
      inner.subscribe(emit);
      setup = {phase: 'idle'};
      return inner;
    })().catch(error => {
      building = null;
      throw error;
    });
    return building;
  };

  const special: Partial<LazyVoicePort> = {
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    async startDictation() {
      cancelled = false;
      let engine = inner;
      if (!engine) {
        set({status: 'starting'});
        try {
          engine = await build();
        } catch (error) {
          set(
            {
              status: 'failed',
              error: voiceError('model_missing', String(error), true),
            },
            {phase: 'idle'},
          );
          return;
        }
        own = {status: 'idle'};
        if (cancelled) {
          emit();
          return;
        }
      }
      if (own.status !== 'idle') {
        own = {status: 'idle'};
      }
      try {
        await engine.startDictation();
      } catch (error) {
        // Never a crash: the bar shows the inline error row instead.
        set({status: 'failed', error: voiceError('failed', error)});
      }
    },
    async finishDictation() {
      try {
        return inner ? await inner.finishDictation() : '';
      } catch (error) {
        set({status: 'failed', error: voiceError('failed', error)});
        return '';
      }
    },
    updateSettings(patch: Partial<VoiceSettings>) {
      if (inner) {
        // The engine persists through `onPersist`.
        inner.updateSettings(patch);
        return;
      }
      save({...stored, settings: {...stored.settings, ...patch}});
      emit();
    },
    cancelDictation() {
      cancelled = true;
      if (inner) {
        return inner.cancelDictation();
      }
      set({status: 'idle'});
    },
  };

  return new Proxy({} as LazyVoicePort, {
    // `asVoicePort` tells an engine port by `'onEvent' in port`; without
    // this trap the empty target said no, the port was wrapped in the
    // contract shim, and Settings > Voice changes went nowhere.
    has(_target, key) {
      return key === 'setup' || key in special || key in neutral;
    },
    get(_target, key: string) {
      if (key === 'dictation') {
        return own.status !== 'idle' || !inner ? own : inner.dictation;
      }
      if (key === 'setup') {
        return setup;
      }
      if (key === 'settings') {
        return inner ? inner.settings : stored.settings;
      }
      if (key in special) {
        return (special as Record<string, unknown>)[key];
      }
      const source = (inner ?? neutral) as unknown as Record<string, unknown>;
      const value = source[key];
      return typeof value === 'function' ? value.bind(source) : value;
    },
  });
}

let shared: LazyVoicePort | null = null;

export function voicePort(): LazyVoicePort {
  shared ??= createLazyVoicePort();
  return shared;
}
