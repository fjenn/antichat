/**
 * What the app remembers about the user's model choices: whether first run
 * was started, automatic or manual selection, "think longer", the consent for
 * the unrestricted add-on, and how an interrupted download should continue.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {makeAutoObservable, runInAction} from 'mobx';

const STORAGE_KEY = 'antichat.models.prefs.v1';

interface Stored {
  started: boolean;
  selection: string;
  thinking: boolean;
  unrestrictedConsentAt: number | null;
  waitForWifi: boolean;
  userPaused: boolean;
  celebrated: boolean;
  notifyAsked: boolean;
  holdDownload: boolean;
}

const DEFAULTS: Stored = {
  started: false,
  selection: 'auto',
  thinking: false,
  unrestrictedConsentAt: null,
  waitForWifi: false,
  userPaused: false,
  celebrated: false,
  notifyAsked: false,
  holdDownload: false,
};

export class ModelPrefs implements Stored {
  /** "Get started" was tapped. */
  started = DEFAULTS.started;
  /** `auto`: the app picks. Otherwise the id of the model the user chose. */
  selection = DEFAULTS.selection;
  /** "Think longer" is on for new messages. Off by default. */
  thinking = DEFAULTS.thinking;
  /** When the user confirmed age and responsibility for the add-on. */
  unrestrictedConsentAt: number | null = DEFAULTS.unrestrictedConsentAt;
  /** The first download waits for Wi-Fi instead of using mobile data. */
  waitForWifi = DEFAULTS.waitForWifi;
  /** The user paused the first download; it stays paused across restarts. */
  userPaused = DEFAULTS.userPaused;
  /** The "ready" moment was shown once. */
  celebrated = DEFAULTS.celebrated;
  /** The notification question was asked (or declined) once. */
  notifyAsked = DEFAULTS.notifyAsked;
  /** The user deleted the last model: nothing downloads until they ask. */
  holdDownload = DEFAULTS.holdDownload;
  loaded = false;

  constructor() {
    makeAutoObservable(this);
  }

  get automatic(): boolean {
    return this.selection === 'auto';
  }

  async load(): Promise<void> {
    let stored: Partial<Stored> = {};
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      stored = raw ? JSON.parse(raw) : {};
    } catch {
      // Unreadable: defaults.
    }
    runInAction(() => {
      Object.assign(this, {...DEFAULTS, ...stored});
      this.loaded = true;
    });
  }

  set(patch: Partial<Stored>): void {
    Object.assign(this, patch);
    this.save();
  }

  /** Debug: back to a fresh install. */
  async reset(): Promise<void> {
    runInAction(() => Object.assign(this, DEFAULTS));
    await AsyncStorage.removeItem(STORAGE_KEY);
  }

  private save(): void {
    const stored: Stored = {
      started: this.started,
      selection: this.selection,
      thinking: this.thinking,
      unrestrictedConsentAt: this.unrestrictedConsentAt,
      waitForWifi: this.waitForWifi,
      userPaused: this.userPaused,
      celebrated: this.celebrated,
      notifyAsked: this.notifyAsked,
      holdDownload: this.holdDownload,
    };
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(stored)).catch(() => {});
  }
}
