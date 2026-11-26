import '../../testing/setup';

import AsyncStorage from '@react-native-async-storage/async-storage';

import {asVoicePort} from '../../ui/voice/port';
import {createLazyVoicePort} from '../voice';

describe('lazy voice port', () => {
  it('is an engine port, so Settings > Voice reaches it before the first tap', async () => {
    const port = createLazyVoicePort();
    expect(asVoicePort(port)).toBe(port);
    let changes = 0;
    port.subscribe(() => changes++);
    expect(port.settings.language).toBe('auto');
    port.updateSettings({language: 'de'});
    expect(port.settings.language).toBe('de');
    expect(changes).toBeGreaterThan(0);
    await new Promise(resolve => setTimeout(resolve, 0));
    const saved = JSON.parse(
      (await AsyncStorage.getItem('antichat.voice.v1')) ?? '{}',
    );
    expect(saved.settings.language).toBe('de');

    // A new launch starts with the saved choice.
    const next = createLazyVoicePort();
    await new Promise(resolve => setTimeout(resolve, 0));
    expect(next.settings.language).toBe('de');
  });
});
