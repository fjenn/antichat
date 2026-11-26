import '../../../testing/setup';

import React from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import {mountHarness, unmountHarness} from '../../../testing/uiHarness';
import {ManageModelsScreen} from '../ManageModelsScreen';
import {useModelMenu, type ModelMenuState} from '../ModelMenu';
import {PhoneCapabilitiesScreen} from '../PhoneCapabilitiesScreen';

const mockNavigate = jest.fn();
jest.mock('@react-navigation/native', () => ({
  useNavigation: () => ({navigate: mockNavigate, goBack: jest.fn()}),
}));
jest.mock('react-native-gesture-handler/ReanimatedSwipeable', () => {
  const {View} = require('react-native');
  return {
    __esModule: true,
    default: ({children}: {children: React.ReactNode}) => (
      <View>{children}</View>
    ),
  };
});

const advance = async (ms: number) => {
  await act(async () => {
    await jest.advanceTimersByTimeAsync(ms);
  });
};

async function mount() {
  const harness = await mountHarness();
  jest.useFakeTimers();
  return harness;
}

beforeEach(() => AsyncStorage.clear());
afterEach(() => {
  unmountHarness();
  jest.useRealTimers();
});

describe('Manage models', () => {
  it('uses plain names and never the model’s own', async () => {
    await mount();
    render(<ManageModelsScreen />);
    expect(screen.getByText('Smart')).toBeTruthy();
    expect(screen.getByTestId('model-in-use-smart')).toBeTruthy();
    expect(screen.getByText('Best for this phone')).toBeTruthy();
    expect(screen.getByText('Runs great · 2.3 GB')).toBeTruthy();
    expect(screen.getByText('Recommended for this phone')).toBeTruthy();
    expect(screen.getByTestId('models-unrestricted')).toBeTruthy();
    expect(screen.queryByText(/AntiChat Large|fake-|Gemma|Qwen/)).toBeNull();
    // The fake's large model is installed: it is the deeper, slower choice.
    expect(screen.getByText('Smartest')).toBeTruthy();
  });

  it('switches to another installed model and back to automatic', async () => {
    const {ports, coordinator} = await mount();
    render(<ManageModelsScreen />);
    fireEvent.press(screen.getByTestId('model-row-smartest'));
    await advance(2000);
    expect(ports.model.activeModelId).toBe('fake-large');
    expect(coordinator.prefs.automatic).toBe(false);
    expect(screen.getByTestId('models-automatic-off')).toBeTruthy();
    expect(screen.getByTestId('model-in-use-smartest')).toBeTruthy();

    fireEvent.press(screen.getByTestId('models-automatic'));
    await advance(2000);
    expect(ports.model.activeModelId).toBe('fake-small');
    expect(coordinator.prefs.automatic).toBe(true);
  });

  it('deletes a model after a confirmation and can add it again', async () => {
    const {ports} = await mount();
    render(<ManageModelsScreen />);
    // Through the row's menu (the mocked native menu exposes its handler).
    let menu = screen.getByTestId('model-more-smartest').parent;
    while (menu && !menu.props.onPressAction) {
      menu = menu.parent;
    }
    act(() => menu!.props.onPressAction({nativeEvent: {event: 'delete'}}));
    await advance(10);
    expect(screen.getByText('Delete Smartest?')).toBeTruthy();
    expect(ports.model.stateOf('fake-large').status).toBe('ready');
    fireEvent.press(screen.getByTestId('model-delete-confirm-confirm'));
    await advance(100);
    expect(ports.model.stateOf('fake-large').status).toBe('not_installed');

    // It moved to "Available for this phone" with a download button.
    fireEvent.press(screen.getByTestId('model-download-smartest'));
    await advance(500);
    expect(ports.model.stateOf('fake-large').status).toBe('downloading');
    fireEvent.press(screen.getByTestId('model-pause-smartest'));
    expect(screen.getByText(/^Paused · \d+%$/)).toBeTruthy();
    fireEvent.press(screen.getByTestId('model-resume-smartest'));
    await advance(20000);
    expect(ports.model.stateOf('fake-large').status).toBe('ready');
    // A download by hand does not change the model in use.
    expect(ports.model.activeModelId).toBe('fake-small');
  });

  it('warns when the model to delete is the only one', async () => {
    const {ports} = await mount();
    await act(async () => {
      await ports.model.remove('fake-large');
    });
    render(<ManageModelsScreen />);
    let menu = screen.getByTestId('model-more-smart').parent;
    while (menu && !menu.props.onPressAction) {
      menu = menu.parent;
    }
    act(() => menu!.props.onPressAction({nativeEvent: {event: 'delete'}}));
    await advance(10);
    expect(
      screen.getByText(/chat stops working until you download/),
    ).toBeTruthy();
  });

  it('asks before a download on mobile data', async () => {
    const {ports} = await mount();
    await act(async () => {
      await ports.model.remove('fake-large');
      ports.connectivity.set(true, true);
    });
    render(<ManageModelsScreen />);
    fireEvent.press(screen.getByTestId('model-download-smartest'));
    await advance(10);
    expect(screen.getByText('Download on mobile data?')).toBeTruthy();
    expect(ports.model.stateOf('fake-large').status).toBe('not_installed');
    fireEvent.press(screen.getByTestId('model-metered-confirm-confirm'));
    await advance(500);
    expect(ports.model.stateOf('fake-large').status).toBe('downloading');
  });

  it('shows the unrestricted model openly and asks once for 18+', async () => {
    const {ports, coordinator} = await mount();
    render(<ManageModelsScreen />);
    expect(screen.getByTestId('models-unrestricted')).toBeTruthy();
    fireEvent.press(screen.getByTestId('model-download-unrestricted'));
    await advance(10);
    expect(screen.getByText('Unrestricted models are for adults')).toBeTruthy();
    expect(ports.model.stateOf('fake-open').status).toBe('not_installed');

    // One confirmation, no extra switch.
    fireEvent.press(screen.getByTestId('unrestricted-consent-confirm'));
    await advance(500);
    expect(coordinator.prefs.unrestrictedConsentAt).not.toBeNull();
    expect(ports.model.stateOf('fake-open').status).toBe('downloading');
    await advance(20000);
    expect(ports.model.stateOf('fake-open').status).toBe('ready');
    // Installed: it offers "Use", and is still not in use by itself.
    expect(screen.getByTestId('model-use-unrestricted')).toBeTruthy();
    expect(ports.model.activeModelId).toBe('fake-small');
  });
});

describe('model menu', () => {
  function Probe({onState}: {onState: (state: ModelMenuState) => void}) {
    onState(useModelMenu(() => mockNavigate('manage')));
    return null;
  }

  it('lists installed models by plain name, think longer and manage', async () => {
    const {ports, coordinator} = await mount();
    let state!: ModelMenuState;
    render(<Probe onState={next => (state = next)} />);
    expect(state.title).toBe('AntiChat');
    expect(state.items.map(item => item.title)).toEqual([
      'Smart',
      'Smartest',
      'Think longer',
      'Manage models',
    ]);
    expect(state.items[0].checked).toBe(true);
    expect(state.items[2].checked).toBe(false);

    act(() => state.onSelect('think'));
    expect(coordinator.prefs.thinking).toBe(true);
    expect(state.items[2].checked).toBe(true);

    act(() => state.onSelect('model:fake-large'));
    await advance(2000);
    expect(ports.model.activeModelId).toBe('fake-large');
    expect(state.title).toBe('AntiChat Smartest');

    act(() => state.onSelect('manage'));
    expect(mockNavigate).toHaveBeenCalledWith('manage');
  });

  it('offers no model choice when only one is installed', async () => {
    const {ports} = await mount();
    await act(async () => {
      await ports.model.remove('fake-large');
    });
    let state!: ModelMenuState;
    render(<Probe onState={next => (state = next)} />);
    expect(state.items.map(item => item.title)).toEqual([
      'Think longer',
      'Manage models',
    ]);
  });
});

describe('What this phone can do', () => {
  it('lists what works and gives the reason for what does not', async () => {
    const {ports} = await mountHarness();
    render(<PhoneCapabilitiesScreen />);
    expect(screen.getByText('Works on this phone')).toBeTruthy();
    expect(screen.getByText('Chat, writing and questions')).toBeTruthy();
    expect(screen.queryByText('Not on this phone')).toBeNull();

    act(() => {
      ports.model.capabilities = {
        ...ports.model.capabilities!,
        thinking: {
          available: false,
          reason: {kind: 'needs_class', minClass: 'C', marketedRamGb: 8},
        },
      };
      ports.model.setState('fake-small', ports.model.stateOf('fake-small'));
    });
    expect(screen.getByText('Not on this phone')).toBeTruthy();
    expect(screen.getByText('Needs a phone with 8 GB memory')).toBeTruthy();
  });
});
