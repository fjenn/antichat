/**
 * Preferences the shell owns: theme, accent, haptics. Loaded once before the
 * first frame so the app never flashes the wrong theme.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {makeAutoObservable, runInAction} from 'mobx';

import {
  ACCENT_NAMES,
  DEFAULT_ACCENT,
  applyAccent,
  applyThemeMode,
  type AccentName,
  type ThemeMode,
} from '../theme';
import {setHapticsEnabled} from '../ui/primitives/haptics';

const STORAGE_KEY = 'antichat.preferences.v1';
const MODES: readonly ThemeMode[] = ['system', 'light', 'dark'];

interface Stored {
  themeMode: ThemeMode;
  accent: AccentName;
  haptics: boolean;
}

export class Preferences {
  themeMode: ThemeMode = 'system';
  accent: AccentName = DEFAULT_ACCENT;
  haptics = true;
  loaded = false;

  constructor() {
    makeAutoObservable(this);
  }

  async load(): Promise<void> {
    let stored: Partial<Stored> = {};
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      stored = raw ? JSON.parse(raw) : {};
    } catch {
      // Unreadable preferences fall back to the defaults.
    }
    runInAction(() => {
      if (stored.themeMode && MODES.includes(stored.themeMode)) {
        this.themeMode = stored.themeMode;
      }
      if (stored.accent && ACCENT_NAMES.includes(stored.accent)) {
        this.accent = stored.accent;
      }
      if (typeof stored.haptics === 'boolean') {
        this.haptics = stored.haptics;
      }
      this.loaded = true;
    });
    this.apply();
  }

  setThemeMode(mode: ThemeMode): void {
    this.themeMode = mode;
    applyThemeMode(mode);
    this.save();
  }

  setAccent(accent: AccentName): void {
    this.accent = accent;
    applyAccent(accent);
    this.save();
  }

  setHaptics(enabled: boolean): void {
    this.haptics = enabled;
    setHapticsEnabled(enabled);
    this.save();
  }

  private apply(): void {
    applyThemeMode(this.themeMode);
    applyAccent(this.accent);
    setHapticsEnabled(this.haptics);
  }

  private save(): void {
    const stored: Stored = {
      themeMode: this.themeMode,
      accent: this.accent,
      haptics: this.haptics,
    };
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(stored)).catch(() => {
      // Not saved: the choice still holds for this run.
    });
  }
}

export const preferences = new Preferences();
