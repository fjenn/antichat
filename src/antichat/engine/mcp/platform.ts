/**
 * The React Native side of the connectors: keychain, storage, randomness,
 * the browser and the deep links that come back from it.
 *
 * Sign-in pages open in an in-app sheet (`react-native-inappbrowser-reborn`:
 * ASWebAuthenticationSession on iOS, a Custom Tab on Android) that closes
 * itself when the page redirects to `antichat://…`. Where the sheet is not
 * available they open in the system browser and return through a deep link.
 */
import 'react-native-get-random-values';

import * as RNFS from '@dr.pogodin/react-native-fs';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {Linking, Platform} from 'react-native';
import {InAppBrowser} from 'react-native-inappbrowser-reborn';
import * as Keychain from 'react-native-keychain';
import {v4 as uuidv4} from 'uuid';

import {isDevBuild} from '../../spike-ui/launch';
import type {FetchLike} from './client';
import {OAUTH_REDIRECT_URI, OAuthError, type SecureStore} from './oauth';
import {CONNECT_CALLBACK_URL, RelayClient} from './relay';
import {setLocalHttpAllowed, type ConnectorsDeps} from './store';

export const keychainStore: SecureStore = {
  async get(key) {
    const entry = await Keychain.getGenericPassword({service: key});
    return entry ? entry.password : null;
  },
  async set(key, value) {
    await Keychain.setGenericPassword('antichat', value, {
      service: key,
      accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
  },
  async remove(key) {
    await Keychain.resetGenericPassword({service: key});
  },
};

const INSTALL_KEY = 'ai.antichat.connectors.install';
let installId: Promise<string> | null = null;

/**
 * The relay's bearer: a UUIDv4 made on first use of Connectors and kept in
 * the keychain. It identifies this install and nothing else.
 */
export function getInstallId(
  store: SecureStore = keychainStore,
): Promise<string> {
  installId ??= (async () => {
    try {
      const existing = await store.get(INSTALL_KEY);
      if (existing && /^[0-9a-f-]{36}$/i.test(existing)) {
        return existing;
      }
    } catch {}
    const created = uuidv4();
    await store.set(INSTALL_KEY, created).catch(() => {});
    return created;
  })();
  return installId;
}

export function randomBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  (globalThis as any).crypto.getRandomValues(bytes);
  return bytes;
}

type Waiter = {
  prefix: string;
  resolve: (url: string) => void;
  reject: (error: Error) => void;
};
let waiter: Waiter | null = null;
const SIGN_IN_TIMEOUT_MS = 5 * 60_000;

async function sheetAvailable(): Promise<boolean> {
  try {
    return await InAppBrowser.isAvailable();
  } catch {
    return false;
  }
}

/**
 * Open a page in the in-app sign-in sheet and wait until it redirects to
 * `callbackPrefix` ('returned', with the redirect URL) or the person closes
 * it ('cancelled'). Null when there is no sheet on this phone.
 */
export async function openSignInSheet(
  url: string,
  callbackPrefix: string,
): Promise<{outcome: 'returned' | 'cancelled'; url?: string} | null> {
  if (!(await sheetAvailable())) {
    return null;
  }
  const result = await InAppBrowser.openAuth(url, callbackPrefix, {
    // Keep the browser's cookies: a person already signed in to the service
    // does not sign in again.
    ephemeralWebSession: false,
    showTitle: true,
    enableUrlBarHiding: true,
    enableDefaultShare: false,
  });
  if (result.type === 'success' && result.url) {
    return {outcome: 'returned', url: result.url};
  }
  return {outcome: 'cancelled'};
}

/** Open a sign-in page and wait for the redirect to come back. */
export async function openAuth(
  url: string,
  redirectUri: string,
): Promise<string> {
  const sheet = await openSignInSheet(url, redirectUri).catch(() => null);
  if (sheet?.outcome === 'returned' && sheet.url) {
    return sheet.url;
  }
  if (sheet) {
    throw new OAuthError('cancelled', 'Sign-in was cancelled.');
  }
  return openAuthInBrowser(url, redirectUri);
}

/** Without the sheet: the system browser, back through the deep link. */
function openAuthInBrowser(url: string, redirectUri: string): Promise<string> {
  waiter?.reject(new OAuthError('cancelled', 'Sign-in was started again.'));
  return new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      waiter = null;
      reject(new OAuthError('cancelled', 'Sign-in was not finished.'));
    }, SIGN_IN_TIMEOUT_MS);
    waiter = {
      prefix: redirectUri,
      resolve: value => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: error => {
        clearTimeout(timer);
        reject(error);
      },
    };
    Linking.openURL(url).catch(() => {
      waiter?.reject(
        new OAuthError('cancelled', 'Could not open the browser.'),
      );
      waiter = null;
    });
  });
}

export type ConnectorLink = 'oauth' | 'connected' | null;

/**
 * Hand a deep link to the connectors. Returns what it was, or null when it
 * is not one of ours.
 */
export function handleConnectorLink(
  url: string | null | undefined,
): ConnectorLink {
  if (!url) {
    return null;
  }
  const lower = url.toLowerCase();
  if (lower.startsWith(OAUTH_REDIRECT_URI)) {
    if (waiter && lower.startsWith(waiter.prefix.toLowerCase())) {
      const current = waiter;
      waiter = null;
      current.resolve(url);
    }
    return 'oauth';
  }
  return lower.startsWith(CONNECT_CALLBACK_URL) ? 'connected' : null;
}

/**
 * Debug builds: `relayBaseUrl` in the dev file `Documents/antichat-m5.json`
 * (Android: `files/antichat-m5.json`) points the app at a relay on the Mac
 * (`tools/antichat/relay-local.sh`), e.g. `http://192.168.1.35:8790`. On the
 * Android emulator `127.0.0.1`/`localhost` become `10.0.2.2`. Release builds
 * always use the hosted relay.
 */
export async function readRelayOverride(): Promise<string | null> {
  // A test build can carry its relay (env ANTICHAT_RELAY_URL at bundle time,
  // babel.config.js); production builds are made without it.
  const baked =
    typeof __ANTICHAT_RELAY_URL__ === 'string' ? __ANTICHAT_RELAY_URL__ : '';
  if (/^https?:\/\/\S+$/i.test(baked)) {
    return baked;
  }
  if (!isDevBuild()) {
    return null;
  }
  try {
    const path = `${RNFS.DocumentDirectoryPath}/antichat-m5.json`;
    if (!(await RNFS.exists(path))) {
      return null;
    }
    const url: unknown = JSON.parse(
      await RNFS.readFile(path, 'utf8'),
    )?.relayBaseUrl;
    if (typeof url !== 'string' || !/^https?:\/\/\S+$/i.test(url)) {
      return null;
    }
    return Platform.OS === 'android'
      ? url.replace(
          /^(https?:\/\/)(127\.0\.0\.1|localhost)(?=[:/]|$)/i,
          '$110.0.2.2',
        )
      : url;
  } catch {
    return null;
  }
}

export function createPlatformDeps(isOnline: () => boolean): ConnectorsDeps {
  setLocalHttpAllowed(isDevBuild());
  const doFetch = fetch as unknown as FetchLike;
  return {
    relay: new RelayClient({
      fetch: doFetch,
      installId: () => getInstallId(),
      platform: Platform.OS,
      baseUrlOverride: readRelayOverride(),
    }),
    storage: AsyncStorage,
    secure: keychainStore,
    fetch: doFetch,
    randomBytes,
    openUrl: url => Linking.openURL(url),
    openSheet: async (url, callbackPrefix) => {
      const sheet = await openSignInSheet(url, callbackPrefix);
      if (!sheet) {
        await Linking.openURL(url);
        // The browser path: the deep link and the checks finish the connect.
        return new Promise<never>(() => {});
      }
      return sheet.outcome;
    },
    openAuth,
    isOnline,
    clientInfo: {name: 'AntiChat Mobile', version: '0.1.0'},
  };
}
