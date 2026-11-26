import '../../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';

import {getLocale, registerLocale, setLocale} from '../../../locales';
import {SettingsStore} from '../store';

const flush = () => new Promise(resolve => setTimeout(resolve, 0));

describe('settings store', () => {
  beforeEach(async () => {
    await AsyncStorage.clear();
    setLocale('en');
  });

  it('starts with the defaults', async () => {
    const store = new SettingsStore();
    await store.load();
    expect(store.loaded).toBe(true);
    expect(store.language).toBe('system');
    expect(store.useLocation).toBe(true);
    expect(store.expertMode).toBe(false);
    expect(store.showSpeed).toBe(false);
    expect(store.expertOverrides()).toEqual({});
  });

  it('keeps every setting across a restart', async () => {
    const first = new SettingsStore();
    first.connect({reloadModel: undefined, applyLocation: undefined});
    await first.load();
    registerLocale('de', {});
    first.setLanguage('de');
    first.setUseLocation(false);
    first.setExpertMode(true);
    first.setExpert({contextSize: 4096, threads: 4, gpu: 'off'});
    first.setExpert({temperature: 0.5});
    first.setShowSpeed(true);
    first.setVoice('alder');
    await flush();

    const second = new SettingsStore();
    await second.load();
    expect(second.language).toBe('de');
    expect(second.useLocation).toBe(false);
    expect(second.expertMode).toBe(true);
    expect(second.expert).toEqual({
      contextSize: 4096,
      threads: 4,
      gpu: 'off',
      temperature: 0.5,
    });
    expect(second.showSpeed).toBe(true);
    expect(second.voiceId).toBe('alder');
  });

  it('applies language, location and voice when loaded', async () => {
    registerLocale('de', {});
    await AsyncStorage.setItem(
      'antichat.settings.v1',
      // `memoryEnabled` is a key of an older version: dropped.
      JSON.stringify({
        language: 'de',
        memoryEnabled: false,
        useLocation: false,
        voiceId: 'v2',
      }),
    );
    const applyLocation = jest.fn();
    const applyVoice = jest.fn();
    const store = new SettingsStore();
    store.connect({applyLocation, applyVoice});
    await store.load();
    expect(getLocale()).toBe('de');
    expect(applyLocation).toHaveBeenCalledWith(false);
    expect(applyVoice).toHaveBeenCalledWith('v2');
    expect('memoryEnabled' in store).toBe(false);
  });

  it('reloads the model once when a load-time expert value changes', async () => {
    jest.useFakeTimers();
    try {
      const reloadModel = jest.fn();
      const store = new SettingsStore();
      store.connect({reloadModel});
      await store.load();
      // Off: values are kept but nothing applies, so nothing reloads.
      store.setExpert({contextSize: 4096});
      jest.advanceTimersByTime(1000);
      expect(reloadModel).not.toHaveBeenCalled();
      store.setExpertMode(true);
      store.setExpert({threads: 4});
      jest.advanceTimersByTime(1000);
      expect(reloadModel).toHaveBeenCalledTimes(1);
      // Temperature applies per request: no reload.
      store.setExpert({temperature: 0.5});
      jest.advanceTimersByTime(1000);
      expect(reloadModel).toHaveBeenCalledTimes(1);
    } finally {
      jest.useRealTimers();
    }
  });

  it('follows the phone language on "system"', async () => {
    registerLocale('de', {});
    const store = new SettingsStore();
    store.connect({deviceLanguage: () => 'de-AT'});
    await store.load();
    expect(getLocale()).toBe('de');
    store.setLanguage('en');
    expect(getLocale()).toBe('en');
    store.setLanguage('system');
    expect(getLocale()).toBe('de');
  });

  it('hands expert values to the model adapter only in expert mode', async () => {
    const store = new SettingsStore();
    store.connect({reloadModel: undefined});
    await store.load();
    store.setExpert({contextSize: 8192, gpu: 'off', temperature: 0.7});
    expect(store.expertOverrides()).toEqual({});
    store.setExpertMode(true);
    expect(store.expertOverrides()).toEqual({
      contextSize: 8192,
      gpuLayers: 0,
      temperature: 0.7,
    });
    store.resetExpert();
    expect(store.expertOverrides()).toEqual({});
  });

  it('falls back to the defaults when the stored value is unreadable', async () => {
    await AsyncStorage.setItem('antichat.settings.v1', '{not json');
    const store = new SettingsStore();
    await store.load();
    expect(store.loaded).toBe(true);
    expect(store.useLocation).toBe(true);
  });
});
