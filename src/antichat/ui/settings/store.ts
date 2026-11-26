/**
 * Settings M6 owns, stored on the phone. Theme, accent and haptics stay in
 * the shell's `preferences`; personalisation is M7's store
 * (`engine/prompt/personalization.ts`); model choices are in
 * `ui/models/modelPrefs.ts`.
 *
 * Other milestones read from here:
 *  - `showSpeed`: M2 shows the per-answer speed line when set.
 *  - `expertOverrides()`: the model adapter applies context, threads and GPU
 *    at load (a change reloads the model in use); the request seam applies
 *    the temperature to every chat request.
 *  - `useLocation`: off, the location tool is never offered.
 *
 * The memory switch is not here: the memory engine's own settings are the
 * one source of truth (Settings > Personalization > Memory).
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {makeAutoObservable, runInAction} from 'mobx';

import {setLocale} from '../../locales';

const STORAGE_KEY = 'antichat.settings.v1';

export const CONTEXT_SIZES = [2048, 4096, 8192, 16384, 32768] as const;
export const THREAD_COUNTS = [2, 4, 6, 8] as const;
export const TEMPERATURES = [0.2, 0.5, 0.7, 1.0, 1.2] as const;

export interface ExpertSettings {
  /** Tokens; null = the app decides. */
  contextSize: number | null;
  /** CPU threads; null = the app decides. */
  threads: number | null;
  /** `off` forces the processor only. */
  gpu: 'auto' | 'off';
  /** Sampling temperature; null = the model's own default. */
  temperature: number | null;
}

export const DEFAULT_EXPERT: ExpertSettings = {
  contextSize: null,
  threads: null,
  gpu: 'auto',
  temperature: null,
};

interface Stored {
  language: string;
  expertMode: boolean;
  expert: ExpertSettings;
  showSpeed: boolean;
  voiceId: string | null;
  /** "Use my location": the location tool may be offered. */
  useLocation: boolean;
}

const DEFAULTS: Stored = {
  language: 'system',
  expertMode: false,
  expert: DEFAULT_EXPERT,
  showSpeed: false,
  voiceId: null,
  useLocation: true,
};

export interface SettingsEnvironment {
  /** The phone's preferred language tag ("de-AT"). */
  deviceLanguage?: () => string | undefined;
  /** Applies the chosen voice to the voice engine. */
  applyVoice?: (voiceId: string) => void;
  /** Applies "Use my location" to the tool engine. */
  applyLocation?: (allowed: boolean) => void;
  /** Reloads the model in use so new load-time expert values take effect. */
  reloadModel?: () => void;
}

function applyLocationToTools(allowed: boolean): void {
  try {
    (
      require('../../engine/tools/builtin/location') as typeof import('../../engine/tools/builtin/location')
    ).setLocationAllowed(allowed);
  } catch {
    // No tool engine (tests).
  }
}

/**
 * Unload and load the model in use again, once no answer is being written,
 * so a new context size, thread count or GPU choice applies right away.
 */
function reloadActiveModel(): void {
  const attempt = (tries: number) => {
    try {
      const {getPorts} =
        require('../../adapters') as typeof import('../../adapters');
      const {modelStore} =
        require('../../../store') as typeof import('../../../store');
      const model = getPorts().model;
      const id = model.activeModelId;
      if (!id) {
        return;
      }
      if (modelStore.inferencing) {
        if (tries > 0) {
          setTimeout(() => attempt(tries - 1), 1000);
        }
        return;
      }
      model
        .unload()
        .then(() => model.load(id))
        .catch(() => {});
    } catch {
      // No model port (tests).
    }
  };
  attempt(120);
}

/** Keys of `ExpertSettings` that only apply when the model loads. */
const LOAD_KEYS = ['contextSize', 'threads', 'gpu'] as const;

function deviceLanguageTag(): string | undefined {
  try {
    const {getLocales} = require('react-native-localize');
    return getLocales()[0]?.languageTag;
  } catch {
    return undefined;
  }
}

export class SettingsStore implements Stored {
  /** `system`, or a language tag the app has strings for. */
  language = DEFAULTS.language;
  expertMode = DEFAULTS.expertMode;
  expert: ExpertSettings = {...DEFAULT_EXPERT};
  showSpeed = DEFAULTS.showSpeed;
  /** The voice for read aloud and voice chat; null = the engine's default. */
  voiceId: string | null = DEFAULTS.voiceId;
  useLocation = DEFAULTS.useLocation;
  loaded = false;

  private env: SettingsEnvironment = {
    deviceLanguage: deviceLanguageTag,
    applyLocation: applyLocationToTools,
    reloadModel: reloadActiveModel,
  };
  private reloadTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    makeAutoObservable<SettingsStore, 'env' | 'reloadTimer'>(this, {
      env: false,
      reloadTimer: false,
    });
  }

  /** Wire the things a setting acts on. */
  connect(env: SettingsEnvironment): void {
    this.env = {...this.env, ...env};
    if (this.loaded) {
      this.apply();
    }
  }

  async load(): Promise<void> {
    let stored: Partial<Stored> = {};
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      stored = raw ? JSON.parse(raw) : {};
    } catch {
      // Unreadable: defaults.
    }
    // Keys of older versions (the temporary-chat default, a second memory
    // switch) are dropped.
    const known = Object.fromEntries(
      Object.entries(stored).filter(([key]) => key in DEFAULTS),
    ) as Partial<Stored>;
    runInAction(() => {
      Object.assign(this, {
        ...DEFAULTS,
        ...known,
        expert: {...DEFAULT_EXPERT, ...known.expert},
      });
      this.loaded = true;
    });
    this.apply();
  }

  setLanguage(language: string): void {
    this.language = language;
    this.applyLanguage();
    this.save();
  }

  setUseLocation(value: boolean): void {
    this.useLocation = value;
    this.env.applyLocation?.(value);
    this.save();
  }

  setExpertMode(value: boolean): void {
    const before = this.loadValues();
    this.expertMode = value;
    this.save();
    this.reloadIfChanged(before);
  }

  setExpert(patch: Partial<ExpertSettings>): void {
    const before = this.loadValues();
    this.expert = {...this.expert, ...patch};
    this.save();
    this.reloadIfChanged(before);
  }

  resetExpert(): void {
    const before = this.loadValues();
    this.expert = {...DEFAULT_EXPERT};
    this.save();
    this.reloadIfChanged(before);
  }

  /** The load-time values in force (all null when expert mode is off). */
  private loadValues(): string {
    return JSON.stringify(
      LOAD_KEYS.map(key => (this.expertMode ? this.expert[key] : null)),
    );
  }

  /** Several picks in a row reload once. */
  private reloadIfChanged(before: string): void {
    if (this.loadValues() === before || !this.env.reloadModel) {
      return;
    }
    if (this.reloadTimer) {
      clearTimeout(this.reloadTimer);
    }
    this.reloadTimer = setTimeout(() => {
      this.reloadTimer = null;
      this.env.reloadModel?.();
    }, 800);
  }

  setShowSpeed(value: boolean): void {
    this.showSpeed = value;
    this.save();
  }

  setVoice(voiceId: string): void {
    this.voiceId = voiceId;
    this.env.applyVoice?.(voiceId);
    this.save();
  }

  /** What the model adapter should override; empty when expert mode is off. */
  expertOverrides(): Partial<{
    contextSize: number;
    threads: number;
    gpuLayers: 0;
    temperature: number;
  }> {
    if (!this.expertMode) {
      return {};
    }
    const {contextSize, threads, gpu, temperature} = this.expert;
    return {
      ...(contextSize !== null ? {contextSize} : null),
      ...(threads !== null ? {threads} : null),
      ...(gpu === 'off' ? {gpuLayers: 0 as const} : null),
      ...(temperature !== null ? {temperature} : null),
    };
  }

  private apply(): void {
    this.applyLanguage();
    this.env.applyLocation?.(this.useLocation);
    if (this.voiceId !== null) {
      this.env.applyVoice?.(this.voiceId);
    }
  }

  private applyLanguage(): void {
    const tag =
      this.language === 'system'
        ? (this.env.deviceLanguage?.() ?? 'en')
        : this.language;
    setLocale(tag);
  }

  private save(): void {
    const stored: Stored = {
      language: this.language,
      expertMode: this.expertMode,
      expert: this.expert,
      showSpeed: this.showSpeed,
      voiceId: this.voiceId,
      useLocation: this.useLocation,
    };
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(stored)).catch(() => {});
  }
}

export const settingsStore = new SettingsStore();
