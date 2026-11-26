import '../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';
import {Alert} from 'react-native';
import {UnistylesRuntime} from 'react-native-unistyles';

import {hapticsEnabled} from '../../ui/primitives/haptics';
import {
  restoreUpstreamBaggage,
  suppressedAlerts,
  switchOffUpstreamBaggage,
} from '../baggage';
import {parseDeepLink} from '../deeplinks';
import {Preferences} from '../preferences';

describe('deep links', () => {
  it('parses the routes the shell has', () => {
    expect(parseDeepLink('antichat://chat')).toEqual({
      route: 'chat',
      conversationId: null,
      prompt: undefined,
    });
    expect(parseDeepLink('antichat://chat/c42?q=hello%20there')).toEqual({
      route: 'chat',
      conversationId: 'c42',
      prompt: 'hello there',
    });
    expect(parseDeepLink('pocketpal://settings')).toEqual({route: 'settings'});
  });

  it('ignores other schemes and unknown routes', () => {
    expect(parseDeepLink('https://example.com/chat')).toBeNull();
    expect(parseDeepLink('antichat://benchmark')).toBeNull();
    expect(parseDeepLink('not a url')).toBeNull();
  });
});

describe('upstream baggage', () => {
  afterEach(restoreUpstreamBaggage);

  it('captures upstream alerts instead of showing them', () => {
    const native = jest.spyOn(Alert, 'alert').mockImplementation(() => {});
    switchOffUpstreamBaggage();
    Alert.alert('Download failed', 'No space left');
    expect(native).not.toHaveBeenCalled();
    expect(suppressedAlerts()).toEqual([
      expect.objectContaining({
        title: 'Download failed',
        message: 'No space left',
      }),
    ]);
    restoreUpstreamBaggage();
    Alert.alert('Shown');
    expect(native).toHaveBeenCalledTimes(1);
    native.mockRestore();
  });
});

describe('preferences', () => {
  beforeEach(() => AsyncStorage.clear());

  it('applies and stores theme, accent and haptics', async () => {
    const setTheme = jest.spyOn(UnistylesRuntime, 'setTheme');
    const adaptive = jest.spyOn(UnistylesRuntime, 'setAdaptiveThemes');
    const update = jest.spyOn(UnistylesRuntime, 'updateTheme');

    const preferences = new Preferences();
    await preferences.load();
    expect(preferences).toMatchObject({
      themeMode: 'system',
      accent: 'blue',
      haptics: true,
      loaded: true,
    });
    expect(adaptive).toHaveBeenLastCalledWith(true);

    preferences.setThemeMode('dark');
    expect(adaptive).toHaveBeenLastCalledWith(false);
    expect(setTheme).toHaveBeenLastCalledWith('dark');
    preferences.setAccent('green');
    expect(update).toHaveBeenCalledWith('dark', expect.any(Function));
    preferences.setHaptics(false);
    expect(hapticsEnabled()).toBe(false);

    const restored = new Preferences();
    await restored.load();
    expect(restored).toMatchObject({
      themeMode: 'dark',
      accent: 'green',
      haptics: false,
    });
    restored.setHaptics(true);
  });

  it('falls back to defaults on unreadable data', async () => {
    await AsyncStorage.setItem(
      'antichat.preferences.v1',
      '{"themeMode":"sepia","accent":"teal"}',
    );
    const preferences = new Preferences();
    await preferences.load();
    expect(preferences).toMatchObject({themeMode: 'system', accent: 'blue'});
  });
});
