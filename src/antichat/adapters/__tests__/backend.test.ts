import AsyncStorage from '@react-native-async-storage/async-storage';
import {DevSettings} from 'react-native';

import {fakePortNames, getPorts, setPorts} from '..';
import {
  currentBackend,
  fakeOptions,
  loadBackend,
  resetBackendForTests,
  setBackend,
} from '../backend';
import {FakeChat} from '../../contracts/fakes';

const mockLaunch = {options: {} as Record<string, string>};
let mockDevBuild = true;

jest.mock('../../spike/native', () => ({
  getLaunchConfig: () => mockLaunch,
}));
jest.mock('../../spike-ui/launch', () => ({
  isDevBuild: () => mockDevBuild,
}));

jest.mock('@react-native-async-storage/async-storage', () => {
  const data = new Map<string, string>();
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (key: string) => data.get(key) ?? null),
      setItem: jest.fn(async (key: string, value: string) => {
        data.set(key, value);
      }),
      clear: jest.fn(async () => data.clear()),
    },
  };
});

const KEY = 'antichat.dev.backend';

describe('backend choice', () => {
  beforeEach(async () => {
    await AsyncStorage.clear();
    mockLaunch.options = {};
    mockDevBuild = true;
    resetBackendForTests();
    setPorts();
    jest.spyOn(DevSettings, 'reload').mockImplementation(() => {});
  });

  afterEach(() => {
    jest.restoreAllMocks();
    resetBackendForTests();
    setPorts();
  });

  it('is the real engine unless something says otherwise', async () => {
    expect(await loadBackend()).toBe('real');
    expect(currentBackend()).toBe('real');
    expect(fakeOptions()).toEqual({});
  });

  it('suites that never load a choice get the fakes', () => {
    expect(currentBackend()).toBe('fake');
    expect(fakePortNames()).toHaveLength(8);
    expect(getPorts().chat).toBeInstanceOf(FakeChat);
  });

  it('remembers a choice with its tuning and reloads into it', async () => {
    await loadBackend();
    await setBackend('fake', {tokensPerSecond: 60, firstTokenMs: 0});
    expect(DevSettings.reload).toHaveBeenCalled();

    resetBackendForTests();
    expect(await loadBackend()).toBe('fake');
    expect(fakeOptions()).toEqual({tokensPerSecond: 60, firstTokenMs: 0});

    // Switching without tuning keeps the stored tuning.
    await setBackend('real');
    resetBackendForTests();
    expect(await loadBackend()).toBe('real');
    expect(fakeOptions()).toEqual({tokensPerSecond: 60, firstTokenMs: 0});
  });

  it('lets a launch argument win and stores it', async () => {
    await AsyncStorage.setItem(KEY, JSON.stringify({backend: 'real'}));
    mockLaunch.options = {antichatBackend: 'fake', antichatFakeRate: '30'};
    expect(await loadBackend()).toBe('fake');
    expect(fakeOptions()).toEqual({tokensPerSecond: 30});

    mockLaunch.options = {};
    resetBackendForTests();
    expect(await loadBackend()).toBe('fake');
    expect(fakeOptions()).toEqual({tokensPerSecond: 30});
  });

  it('reads the older plain value and survives rubbish', async () => {
    await AsyncStorage.setItem(KEY, 'fake');
    expect(await loadBackend()).toBe('fake');

    resetBackendForTests();
    await AsyncStorage.setItem(KEY, '{not json');
    expect(await loadBackend()).toBe('real');

    resetBackendForTests();
    await AsyncStorage.setItem(
      KEY,
      JSON.stringify({backend: 'fake', fake: {tokensPerSecond: -3}}),
    );
    expect(await loadBackend()).toBe('fake');
    expect(fakeOptions()).toEqual({});
  });

  it('a release build is always real', async () => {
    mockDevBuild = false;
    await AsyncStorage.setItem(KEY, JSON.stringify({backend: 'fake'}));
    mockLaunch.options = {antichatBackend: 'fake'};
    expect(await loadBackend()).toBe('real');

    await setBackend('fake');
    expect(currentBackend()).toBe('real');
    expect(DevSettings.reload).not.toHaveBeenCalled();
  });

  it('serves fakes for every port when the fake is selected', async () => {
    await setBackend('fake', {tokensPerSecond: 15});
    setPorts();
    expect(fakePortNames()).toHaveLength(8);
    expect(getPorts().chat).toBeInstanceOf(FakeChat);
  });

  it('names the ports that are still fakes when the engine is selected', async () => {
    await loadBackend();
    expect(fakePortNames().sort()).toEqual(['files', 'memory']);
  });
});
