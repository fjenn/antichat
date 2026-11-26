/**
 * Which backend the ports talk to. The app always uses the real engine; a
 * debug build can switch to the in-memory fakes, so UI flows and screenshots
 * do not depend on a model being on the device.
 *
 * `loadBackend()` runs once before the first screen (AntiChatGate awaits
 * it); after that `currentBackend()` answers synchronously.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
import {DevSettings, Platform, Settings} from 'react-native';

import {getLaunchConfig} from '../spike/native';
import {isDevBuild} from '../spike-ui/launch';

export type Backend = 'fake' | 'real';

/** How the fake chat behaves; set together with the choice of the fake. */
export interface FakeTuning {
  tokensPerSecond?: number;
  firstTokenMs?: number;
}

const KEY = 'antichat.dev.backend';

interface Stored {
  backend: Backend;
  fake?: FakeTuning;
}

let current: Backend | null = null;
let tuning: FakeTuning = {};

const isBackend = (value: unknown): value is Backend =>
  value === 'fake' || value === 'real';

function positive(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? value
    : undefined;
}

function parseTuning(value: unknown): FakeTuning {
  if (!value || typeof value !== 'object') {
    return {};
  }
  const raw = value as Record<string, unknown>;
  const result: FakeTuning = {};
  const tokensPerSecond = positive(raw.tokensPerSecond);
  const firstTokenMs = raw.firstTokenMs === 0 ? 0 : positive(raw.firstTokenMs);
  if (tokensPerSecond !== undefined) {
    result.tokensPerSecond = tokensPerSecond;
  }
  if (firstTokenMs !== undefined) {
    result.firstTokenMs = firstTokenMs;
  }
  return result;
}

function parseStored(raw: string | null): Partial<Stored> {
  if (!raw) {
    return {};
  }
  // Older value: just the name.
  if (isBackend(raw)) {
    return {backend: raw};
  }
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return {
      backend: isBackend(parsed.backend) ? parsed.backend : undefined,
      fake: parseTuning(parsed.fake),
    };
  } catch {
    return {};
  }
}

async function persist(): Promise<void> {
  const stored: Stored = {backend: current ?? 'real', fake: tuning};
  try {
    await AsyncStorage.setItem(KEY, JSON.stringify(stored));
  } catch {
    // Not saved: the choice still holds until the next launch.
  }
}

/**
 * Launch arguments exist on iOS only; Android switches through a deep link
 * (`antichat://dev/backend/fake`, see `app/deeplinks.ts`). iOS puts
 * `-name value` arguments into the user defaults, which `Settings` reads.
 */
function launchChoice(): {backend?: Backend; fake: FakeTuning} {
  let backend: unknown;
  let rate: unknown;
  if (Platform.OS === 'ios') {
    try {
      backend = Settings.get('antichatBackend');
      rate = Settings.get('antichatFakeRate');
    } catch {
      // No settings module (Jest).
    }
  }
  if (backend === undefined) {
    try {
      const options = getLaunchConfig().options ?? {};
      backend = options.antichatBackend;
      rate = rate ?? options.antichatFakeRate;
    } catch {
      // No native launch module in this build.
    }
  }
  return {
    backend: isBackend(backend) ? backend : undefined,
    fake: parseTuning({tokensPerSecond: Number(rate)}),
  };
}

/**
 * Resolves the backend for this launch. Order: a launch argument
 * (`-antichatBackend fake|real`, remembered), the stored choice, `real`.
 * Release builds are always `real`.
 */
export async function loadBackend(): Promise<Backend> {
  if (!isDevBuild()) {
    current = 'real';
    tuning = {};
    return current;
  }
  let stored: Partial<Stored> = {};
  try {
    stored = parseStored(await AsyncStorage.getItem(KEY));
  } catch {
    // Unreadable: fall through to the default.
  }
  const launch = launchChoice();
  tuning = {...(stored.fake ?? {}), ...launch.fake};
  current = launch.backend ?? stored.backend ?? 'real';
  if (
    (launch.backend && launch.backend !== stored.backend) ||
    Object.keys(launch.fake).length > 0
  ) {
    await persist();
  }
  return current;
}

/**
 * The backend in use. Before `loadBackend()` has run this is `real`, except
 * under Jest, where suites that never load a choice get the fakes.
 */
export function currentBackend(): Backend {
  return current ?? (process.env.NODE_ENV === 'test' ? 'fake' : 'real');
}

/** Speed of the fake chat, for frame measurements at a fixed token rate. */
export function fakeOptions(): FakeTuning {
  return {...tuning};
}

/**
 * Debug builds: store the choice and reload the app into it. `fake` tuning
 * replaces what was stored; leave it out to keep it.
 */
export async function setBackend(
  choice: Backend,
  fake?: FakeTuning,
): Promise<void> {
  if (!isDevBuild()) {
    return;
  }
  current = choice;
  if (fake) {
    tuning = parseTuning(fake);
  }
  await persist();
  try {
    DevSettings.reload();
  } catch {
    // No dev bridge (an embedded debug bundle): applies at the next launch.
  }
}

/** Tests: forget the loaded choice. */
export function resetBackendForTests(): void {
  current = null;
  tuning = {};
}
