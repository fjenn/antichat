/**
 * Which UI a debug build shows. Release builds always show AntiChat. In a
 * debug build the developer menu (and Settings) can switch to upstream's
 * PocketPal UI for side-by-side comparison; the choice survives reloads.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {DevSettings, Platform, Settings} from 'react-native';

const KEY = 'antichat.dev.upstreamUI';
const TOOLS_KEY = 'antichat.dev.tools';

let devTools = false;

/**
 * Developer rows and screens (connector previews, the design gallery, the
 * scripted-download scenarios, the history lab, the perf probe). Off in every
 * build until switched on: the React Native developer menu has "AntiChat:
 * developer tools on/off"; iOS UI tests pass `-antichatDevTools 1`.
 */
export function devToolsEnabled(): boolean {
  return devTools;
}

/** Tests, and the boot sequence. */
export function setDevTools(on: boolean): void {
  devTools = on;
}

function launchArgument(): boolean {
  if (Platform.OS !== 'ios') {
    return false;
  }
  try {
    const asked = Settings.get('antichatDevTools');
    return asked === '1' || asked === 1 || asked === true;
  } catch {
    return false;
  }
}

/** Reads the stored switch; call before the first screen is drawn. */
export async function loadDevTools(): Promise<boolean> {
  if (!__DEV__) {
    return false;
  }
  if (launchArgument()) {
    devTools = true;
    return true;
  }
  try {
    devTools = (await AsyncStorage.getItem(TOOLS_KEY)) === '1';
  } catch {
    devTools = false;
  }
  return devTools;
}

async function switchDevTools(on: boolean): Promise<void> {
  await AsyncStorage.setItem(TOOLS_KEY, on ? '1' : '0');
  DevSettings.reload();
}

export type ShellChoice = 'antichat' | 'upstream';

export async function loadShellChoice(): Promise<ShellChoice> {
  if (!__DEV__) {
    return 'antichat';
  }
  await loadDevTools();
  try {
    return (await AsyncStorage.getItem(KEY)) === '1' ? 'upstream' : 'antichat';
  } catch {
    return 'antichat';
  }
}

/** Debug builds only: store the choice and reload the app into it. */
export async function switchShell(choice: ShellChoice): Promise<void> {
  if (!__DEV__) {
    return;
  }
  await AsyncStorage.setItem(KEY, choice === 'upstream' ? '1' : '0');
  DevSettings.reload();
}

let registered = false;

/** Adds the two switches to the React Native developer menu. */
export function registerDevMenu(): void {
  if (!__DEV__ || registered) {
    return;
  }
  registered = true;
  DevSettings.addMenuItem('AntiChat: show PocketPal UI', () => {
    switchShell('upstream').catch(() => {});
  });
  DevSettings.addMenuItem('AntiChat: show AntiChat UI', () => {
    switchShell('antichat').catch(() => {});
  });
  DevSettings.addMenuItem('AntiChat: developer tools on/off', () => {
    switchDevTools(!devTools).catch(() => {});
  });
}
