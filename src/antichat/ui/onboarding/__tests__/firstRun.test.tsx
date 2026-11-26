import '../../../testing/setup';

import React from 'react';
import {Text} from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import {mountHarness, unmountHarness} from '../../../testing/uiHarness';
import {FirstRunGate} from '../FirstRunGate';
import {SetupCard} from '../SetupCard';
import {useComposerReadiness} from '../useComposerReadiness';
import {WelcomeScreen} from '../WelcomeScreen';

jest.mock('../notifications', () => ({
  notificationPermission: jest.fn(async () => 'undetermined'),
  requestNotificationPermission: jest.fn(async () => true),
  notifyAssistantReady: jest.fn(async () => false),
}));

function Composer() {
  const {ready, placeholder} = useComposerReadiness();
  return <Text testID="composer">{ready ? 'ready' : placeholder}</Text>;
}

const advance = async (ms: number) => {
  await act(async () => {
    await jest.advanceTimersByTimeAsync(ms);
  });
};

describe('welcome screen', () => {
  it('has one button and says how big the download is', () => {
    const onStart = jest.fn();
    render(<WelcomeScreen downloadSize="5.2 GB" onStart={onStart} />);
    expect(screen.getAllByRole('button')).toHaveLength(1);
    expect(
      screen.getByText(
        'Free. No account. One download of about 5.2 GB sets it up.',
      ),
    ).toBeTruthy();
    fireEvent.press(screen.getByRole('button', {name: 'Get started'}));
    expect(onStart).toHaveBeenCalledTimes(1);
  });

  it('names no model and asks nothing', () => {
    render(<WelcomeScreen onStart={() => {}} />);
    expect(screen.queryByText(/gemma|qwen|model|GB/i)).toBeNull();
    expect(
      screen.getByText('Free. No account. One download sets it up.'),
    ).toBeTruthy();
  });

  it('says that the download waits when offline', () => {
    render(<WelcomeScreen offline onStart={() => {}} />);
    expect(screen.getByText(/You’re offline/)).toBeTruthy();
  });
});

/** The fake engine starts on real timers; the download is then stepped. */
async function mount(options?: Parameters<typeof mountHarness>[0]) {
  const harness = await mountHarness(options);
  jest.useFakeTimers();
  return harness;
}

describe('first run', () => {
  beforeEach(() => AsyncStorage.clear());
  afterEach(() => {
    unmountHarness();
    jest.useRealTimers();
  });

  it('opens the model store from "Other options" without downloading', async () => {
    const {ports, coordinator} = await mount({model: {fresh: true}});
    const onOpenStore = jest.fn();
    render(
      <FirstRunGate onOpenStore={onOpenStore}>
        <SetupCard />
      </FirstRunGate>,
    );
    await advance(100);
    fireEvent.press(screen.getByTestId('get-started'));
    await advance(50);
    fireEvent.press(screen.getByTestId('pick-other'));
    await advance(300);
    expect(onOpenStore).toHaveBeenCalledTimes(1);
    expect(screen.queryByTestId('pick')).toBeNull();
    expect(coordinator.prefs.started).toBe(true);
    expect(ports.model.stateOf('fake-small').status).toBe('not_installed');
  });

  it('goes from the welcome screen to a ready assistant with one tap', async () => {
    const {ports, coordinator} = await mount({model: {fresh: true}});
    render(
      <FirstRunGate>
        <SetupCard />
        <Composer />
      </FirstRunGate>,
    );
    await advance(100);
    // The chat is mounted underneath, but nothing downloads before the tap.
    expect(screen.getByTestId('welcome')).toBeTruthy();
    expect(ports.model.stateOf('fake-small').status).toBe('not_installed');

    fireEvent.press(screen.getByTestId('get-started'));
    await advance(50);
    // The pick for this phone, one card, one button.
    expect(screen.getByTestId('pick-card')).toBeTruthy();
    expect(screen.getByTestId('pick-line').props.children).toMatch(
      /^Best for (this phone|your .+) · 2\.3 GB · fast$/,
    );
    expect(ports.model.stateOf('fake-small').status).toBe('not_installed');
    fireEvent.press(screen.getByTestId('pick-download'));
    await advance(300);
    expect(screen.queryByTestId('welcome')).toBeNull();
    expect(screen.queryByTestId('pick')).toBeNull();
    expect(screen.getByText('Downloading your assistant')).toBeTruthy();
    expect(screen.getByTestId('setup-line').props.children).toMatch(
      /of 2\.3 GB · about \d+ sec left|of 2\.3 GB · almost done/,
    );
    expect(screen.getByTestId('composer').props.children).toBe(
      'Ready when the download finishes',
    );
    expect(screen.queryByText(/AntiChat Large|fake-/)).toBeNull();

    await advance(8000);
    expect(coordinator.chatReady).toBe(true);
    expect(screen.getByText('Your assistant is ready')).toBeTruthy();
    expect(screen.getByTestId('composer').props.children).toBe('ready');

    // The moment passes and the card goes away.
    await advance(7000);
    expect(screen.queryByTestId('setup-card')).toBeNull();
  });

  it('pauses and resumes from the card', async () => {
    const {ports, coordinator} = await mount({model: {fresh: true}});
    coordinator.getStarted();
    render(
      <>
        <SetupCard />
        <Composer />
      </>,
    );
    await advance(500);
    fireEvent.press(screen.getByTestId('setup-pause'));
    expect(screen.getByTestId('setup-title').props.children).toBe(
      'Download paused',
    );
    expect(screen.getByTestId('composer').props.children).toBe(
      'Download paused',
    );
    const before = ports.model.stateOf('fake-small');
    await advance(3000);
    expect(ports.model.stateOf('fake-small')).toEqual(before);

    fireEvent.press(screen.getByTestId('setup-resume'));
    await advance(300);
    expect(screen.getByText('Downloading your assistant')).toBeTruthy();
    await advance(8000);
    expect(coordinator.chatReady).toBe(true);
  });

  it('offers a retry when the download fails', async () => {
    const {ports, coordinator} = await mount({model: {fresh: true}});
    coordinator.prefs.set({started: true});
    await act(async () => {
      ports.model.setState('fake-small', {
        status: 'failed',
        reason: 'download_failed',
        stage: 'download',
        retryable: true,
        resumeTo: 'not_installed',
      });
    });
    render(<SetupCard />);
    expect(screen.getByText('The download stopped')).toBeTruthy();
    expect(
      screen.getByText('Nothing is lost. It continues where it stopped.'),
    ).toBeTruthy();
    fireEvent.press(screen.getByTestId('setup-retry'));
    await advance(8000);
    expect(coordinator.chatReady).toBe(true);
  });

  it('sends "not enough space" to Storage', async () => {
    const {ports, coordinator} = await mount({model: {fresh: true}});
    coordinator.prefs.set({started: true});
    await act(async () => {
      ports.model.setState('fake-small', {
        status: 'failed',
        reason: 'storage_full',
        stage: 'download',
        retryable: false,
        resumeTo: 'not_installed',
      });
    });
    const onOpenStorage = jest.fn();
    render(<SetupCard onOpenStorage={onOpenStorage} />);
    expect(screen.getByText('Not enough space')).toBeTruthy();
    fireEvent.press(screen.getByTestId('setup-storage'));
    expect(onOpenStorage).toHaveBeenCalled();
  });

  it('asks for notifications only from the card, and only once', async () => {
    const notifications = require('../notifications');
    const {ports, coordinator} = await mount({model: {fresh: true}});
    coordinator.prefs.set({started: true});
    await act(async () => {
      ports.model.setState('fake-small', {
        status: 'downloading',
        paused: false,
        progress: {
          receivedBytes: 1e9,
          totalBytes: 5e9,
          fraction: 0.2,
          etaSeconds: 240,
        },
      });
    });
    render(<SetupCard />);
    await advance(50);
    expect(notifications.requestNotificationPermission).not.toHaveBeenCalled();
    fireEvent.press(screen.getByTestId('setup-notify'));
    await advance(50);
    expect(notifications.requestNotificationPermission).toHaveBeenCalledTimes(
      1,
    );
    expect(coordinator.prefs.notifyAsked).toBe(true);
    expect(screen.queryByTestId('setup-notify')).toBeNull();
  });

  it('shows nothing once an assistant is in use', async () => {
    await mount();
    render(
      <>
        <SetupCard />
        <Composer />
      </>,
    );
    expect(screen.queryByTestId('setup-card')).toBeNull();
    expect(screen.getByTestId('composer').props.children).toBe('ready');
  });
});
