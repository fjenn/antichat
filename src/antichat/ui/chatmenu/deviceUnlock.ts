/**
 * "Prove it is you": Face ID / Touch ID / fingerprint, or the phone's
 * passcode. Locked chats ask for it before they show anything.
 *
 * Behind an interface so screens and tests do not depend on the native
 * module. The implementation uses `react-native-keychain` (already in the
 * project): a random secret is stored under biometric / passcode access
 * control, and reading it back makes the system show its own unlock prompt.
 * No PIN of our own, nothing leaves the phone.
 *
 * Native settings this needs (integration lane):
 *  - iOS: `NSFaceIDUsageDescription` in Info.plist. Without it iOS skips
 *    Face ID and asks for the passcode.
 *  - Android: `USE_BIOMETRIC` (merged in from the library's manifest).
 */
import {Platform} from 'react-native';

export type UnlockResult = 'ok' | 'cancelled' | 'unavailable';

export interface DeviceUnlock {
  /** Has this phone a passcode or biometrics set up at all? */
  available(): Promise<boolean>;
  /** Shows the system prompt. `reason` is the line the prompt displays. */
  authenticate(reason: string, cancelLabel: string): Promise<UnlockResult>;
}

const SERVICE = 'ai.antichat.chatlock';

function randomSecret(): string {
  let out = '';
  for (let i = 0; i < 32; i++) {
    out += Math.floor(Math.random() * 16).toString(16);
  }
  return out;
}

export const keychainUnlock: DeviceUnlock = {
  async available() {
    const Keychain = require('react-native-keychain');
    try {
      if ((await Keychain.getSupportedBiometryType()) !== null) {
        return true;
      }
      // iOS falls back to the passcode; Android's keystore prompt needs an
      // enrolled biometric.
      return Platform.OS === 'ios'
        ? await Keychain.isPasscodeAuthAvailable()
        : false;
    } catch {
      return false;
    }
  },

  async authenticate(reason, cancelLabel) {
    const Keychain = require('react-native-keychain');
    const accessControl =
      Keychain.ACCESS_CONTROL.BIOMETRY_ANY_OR_DEVICE_PASSCODE;
    try {
      if (!(await keychainUnlock.available())) {
        return 'unavailable';
      }
      if (!(await Keychain.hasGenericPassword({service: SERVICE}))) {
        const stored = await Keychain.setGenericPassword(
          'chatlock',
          randomSecret(),
          {
            service: SERVICE,
            accessControl,
            accessible: Keychain.ACCESSIBLE.WHEN_PASSCODE_SET_THIS_DEVICE_ONLY,
          },
        );
        if (!stored) {
          return 'unavailable';
        }
      }
      const found = await Keychain.getGenericPassword({
        service: SERVICE,
        accessControl,
        authenticationPrompt: {title: reason, cancel: cancelLabel},
      });
      return found ? 'ok' : 'cancelled';
    } catch {
      // The user cancelled, or the prompt failed: either way, stay locked.
      return 'cancelled';
    }
  },
};

let current: DeviceUnlock = keychainUnlock;

export function deviceUnlock(): DeviceUnlock {
  return current;
}

/** Tests and the history lab: replace the unlock (reset with no argument). */
export function setDeviceUnlock(next?: DeviceUnlock): void {
  current = next ?? keychainUnlock;
}
