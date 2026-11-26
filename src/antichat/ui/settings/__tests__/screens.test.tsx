import '../../../testing/setup';

import React from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import {InAppBrowser} from 'react-native-inappbrowser-reborn';

import {LINKS} from '../../../app/links';
import {preferences} from '../../../app/preferences';
import {
  DEFAULT_PERSONALIZATION,
  getPersonalization,
  loadPersonalization,
  personalizationBlocks,
  resetPersonalization,
} from '../../../engine/prompt/personalization';
import en from '../../../locales/en.m6.json';
import {mountHarness, unmountHarness} from '../../../testing/uiHarness';
import {AboutScreen} from '../AboutScreen';
import {AdvancedScreen} from '../AdvancedScreen';
import {DataControlsScreen} from '../DataControlsScreen';
import {GeneralScreen} from '../GeneralScreen';
import {MemoriesScreen} from '../MemoriesScreen';
import {PersonalizationScreen} from '../PersonalizationScreen';
import {PrivacyScreen} from '../PrivacyScreen';
import {SettingsScreen} from '../SettingsScreen';
import {settingsStore} from '../store';

const mockNavigate = jest.fn();
jest.mock('@react-navigation/native', () => ({
  useNavigation: () => ({navigate: mockNavigate, goBack: jest.fn()}),
}));

const flush = () => act(async () => {});

/** Picks an item of a (mocked) native menu around a row. */
function pickFromMenu(rowTestID: string, id: string) {
  let node = screen.getByTestId(rowTestID).parent;
  while (node && !node.props.onPressAction) {
    node = node.parent;
  }
  act(() => node!.props.onPressAction({nativeEvent: {event: id}}));
}

beforeEach(async () => {
  mockNavigate.mockClear();
  await AsyncStorage.clear();
  resetPersonalization();
});
afterEach(() => unmountHarness());

describe('Settings', () => {
  it('has ChatGPT’s sections, each opening its own screen', async () => {
    await mountHarness();
    render(<SettingsScreen />);
    const rows: Array<[string, string]> = [
      ['settings-general', 'SettingsGeneral'],
      ['settings-personalization', 'SettingsPersonalization'],
      ['settings-voice', 'SettingsVoice'],
      ['settings-data', 'SettingsData'],
      ['settings-models', 'Models'],
      ['settings-storage', 'Storage'],
      ['settings-capabilities', 'PhoneCapabilities'],
      ['settings-privacy', 'SettingsPrivacy'],
      ['settings-about', 'SettingsAbout'],
      ['settings-advanced', 'SettingsAdvanced'],
    ];
    for (const [testID, route] of rows) {
      fireEvent.press(screen.getByTestId(testID));
      expect(mockNavigate).toHaveBeenLastCalledWith('Main', {
        screen: route,
        params: undefined,
      });
    }
    // The model row says "Automatic", not a model name.
    expect(screen.getByText('Automatic')).toBeTruthy();
    expect(screen.queryByText(/context|sampling|threads|GGUF/i)).toBeNull();
  });

  it('opens GitHub, the privacy policy and support in the in-app browser', async () => {
    (InAppBrowser.isAvailable as jest.Mock).mockResolvedValue(true);
    await mountHarness();
    const links: Array<[string, string]> = [
      ['settings-github', LINKS.github],
      ['settings-privacy-policy', LINKS.privacyPolicy],
      ['settings-support', LINKS.support],
    ];
    render(<SettingsScreen />);
    expect(screen.getByText('View on GitHub')).toBeTruthy();
    for (const [testID, url] of links) {
      fireEvent.press(screen.getByTestId(testID));
      await flush();
      expect(InAppBrowser.open).toHaveBeenLastCalledWith(
        url,
        expect.any(Object),
      );
    }
    unmountHarness();
    render(<AboutScreen />);
    fireEvent.press(screen.getByTestId('about-github'));
    await flush();
    expect(InAppBrowser.open).toHaveBeenLastCalledWith(
      LINKS.github,
      expect.any(Object),
    );
    (InAppBrowser.isAvailable as jest.Mock).mockResolvedValue(false);
  });
});

describe('General', () => {
  it('changes theme, accent and haptics in the shell preferences', async () => {
    await mountHarness();
    render(<GeneralScreen />);
    pickFromMenu('theme-row', 'dark');
    expect(preferences.themeMode).toBe('dark');
    expect(screen.getByText('Dark')).toBeTruthy();
    fireEvent.press(screen.getByTestId('accent-green'));
    expect(preferences.accent).toBe('green');
    fireEvent.press(screen.getByTestId('haptics-toggle'));
    expect(preferences.haptics).toBe(false);
    expect(screen.getByTestId('haptics-toggle-off')).toBeTruthy();
    // Back to the defaults for the other suites.
    act(() => {
      preferences.setThemeMode('system');
      preferences.setAccent('blue');
      preferences.setHaptics(true);
    });
  });
});

describe('Personalization', () => {
  it('writes exactly the prompt engine’s schema, and it survives a restart', async () => {
    await mountHarness();
    render(<PersonalizationScreen />);
    pickFromMenu('personality-preset', 'candid');
    fireEvent.press(screen.getByTestId('dial-warmth-more'));
    fireEvent.press(screen.getByTestId('dial-emoji-less'));
    fireEvent.changeText(
      screen.getByTestId('custom-instructions'),
      'Answer in short sentences.',
    );
    fireEvent.changeText(screen.getByTestId('about-nickname'), 'Sam');
    fireEvent.changeText(screen.getByTestId('about-occupation'), 'Nurse');
    fireEvent.changeText(screen.getByTestId('about-more'), 'Lives in Lisbon.');
    await flush();

    const expected = {
      ...DEFAULT_PERSONALIZATION,
      preset: 'candid',
      warmth: 'more',
      emoji: 'less',
      customInstructions: 'Answer in short sentences.',
      nickname: 'Sam',
      occupation: 'Nurse',
      aboutYou: 'Lives in Lisbon.',
    };
    expect(getPersonalization()).toEqual(expected);
    // No key the schema does not have.
    expect(Object.keys(getPersonalization()).sort()).toEqual(
      Object.keys(DEFAULT_PERSONALIZATION).sort(),
    );

    // What the system prompt gets from it.
    const text = personalizationBlocks(getPersonalization(), 'C')
      .map(block => block.text)
      .join('\n');
    expect(text).toContain('candid');
    expect(text).toContain('Name: Sam');
    expect(text).toContain('Answer in short sentences.');

    // A restart reads the same values back.
    resetPersonalization();
    expect(await loadPersonalization()).toEqual(expected);
  });

  it('switches customisation off without losing what was typed', async () => {
    await mountHarness();
    render(<PersonalizationScreen />);
    fireEvent.changeText(screen.getByTestId('about-nickname'), 'Sam');
    fireEvent.press(screen.getByTestId('personalization-enabled'));
    expect(getPersonalization().enabled).toBe(false);
    expect(getPersonalization().nickname).toBe('Sam');
    expect(personalizationBlocks(getPersonalization(), 'C')).toEqual([]);
  });

  it('holds the memory rows (M9) and the way to the memory screen', async () => {
    await mountHarness();
    render(<PersonalizationScreen />);
    expect(screen.getByTestId('memory-settings')).toBeTruthy();
    fireEvent.press(screen.getByTestId('memory-manage'));
    expect(mockNavigate).toHaveBeenLastCalledWith('Main', {
      screen: 'Memory',
      params: undefined,
    });
  });
});

describe('Memories', () => {
  it('lists what is remembered and deletes all after a confirmation', async () => {
    const {ports} = await mountHarness();
    render(<MemoriesScreen />);
    const count = ports.memory.memories.length;
    expect(count).toBeGreaterThan(0);
    expect(screen.getByText(ports.memory.memories[0].text)).toBeTruthy();
    fireEvent.press(screen.getByTestId('memories-delete-all'));
    await flush();
    // Nothing is deleted before the confirmation.
    expect(ports.memory.memories).toHaveLength(count);
    fireEvent.press(screen.getByTestId('memories-confirm-confirm'));
    await flush();
    expect(ports.memory.memories).toHaveLength(0);
    expect(screen.getByText('Nothing remembered yet.')).toBeTruthy();
  });
});

describe('Data controls', () => {
  it('deletes all chats only after the confirmation', async () => {
    const {ports} = await mountHarness();
    render(<DataControlsScreen />);
    expect(ports.conversations.conversations.length).toBeGreaterThan(0);
    fireEvent.press(screen.getByTestId('data-delete-all'));
    await flush();
    expect(ports.conversations.conversations.length).toBeGreaterThan(0);
    fireEvent.press(screen.getByTestId('delete-all-confirm-cancel'));
    await flush();
    expect(ports.conversations.conversations.length).toBeGreaterThan(0);

    fireEvent.press(screen.getByTestId('data-delete-all'));
    await flush();
    fireEvent.press(screen.getByTestId('delete-all-confirm-confirm'));
    await flush();
    expect(ports.conversations.conversations).toHaveLength(0);
  });

  it('opens the archive', async () => {
    await mountHarness();
    render(<DataControlsScreen />);
    expect(screen.queryByTestId('temporary-default')).toBeNull();
    fireEvent.press(screen.getByTestId('data-archived'));
    expect(mockNavigate).toHaveBeenLastCalledWith('Main', {
      screen: 'SettingsArchived',
      params: undefined,
    });
  });
});

describe('Advanced', () => {
  it('hides the expert parameters until expert mode is on', async () => {
    const reloadModel = jest.fn();
    settingsStore.connect({reloadModel});
    await mountHarness();
    render(<AdvancedScreen />);
    expect(screen.queryByTestId('expert-context')).toBeNull();
    fireEvent.press(screen.getByTestId('expert-mode'));
    expect(screen.getByTestId('expert-context')).toBeTruthy();
    pickFromMenu('expert-context', '4096');
    expect(settingsStore.expert.contextSize).toBe(4096);
    expect(screen.getByText('4,096 tokens')).toBeTruthy();
    fireEvent.press(screen.getByTestId('expert-reset'));
    expect(settingsStore.expert.contextSize).toBeNull();
    fireEvent.press(screen.getByTestId('expert-mode'));
    expect(screen.queryByTestId('expert-context')).toBeNull();
    // The context size applied for a moment: the model reloads (once).
    await act(() => new Promise(resolve => setTimeout(resolve, 900)));
    expect(reloadModel).toHaveBeenCalledTimes(1);
  });
});

describe('Privacy', () => {
  it('says what stays, what goes online and what never happens', () => {
    render(<PrivacyScreen />);
    expect(screen.getByText('Stays on this phone')).toBeTruthy();
    expect(screen.getByText('Goes online, and when')).toBeTruthy();
    expect(screen.getByText('Never')).toBeTruthy();
  });

  it('switches "Use my location"', () => {
    const applyLocation = jest.fn();
    settingsStore.connect({applyLocation});
    render(<PrivacyScreen />);
    expect(settingsStore.useLocation).toBe(true);
    fireEvent.press(screen.getByTestId('use-location'));
    expect(settingsStore.useLocation).toBe(false);
    expect(applyLocation).toHaveBeenLastCalledWith(false);
    act(() => settingsStore.setUseLocation(true));
  });
});

describe('M6 strings', () => {
  it('are all non-empty text', () => {
    const walk = (node: unknown, path: string): void => {
      if (typeof node === 'string') {
        expect(node.trim().length).toBeGreaterThan(0);
        expect(node).not.toBe(path);
        return;
      }
      Object.entries(node as Record<string, unknown>).forEach(([key, value]) =>
        walk(value, path ? `${path}.${key}` : key),
      );
    };
    walk(en, '');
  });
});
