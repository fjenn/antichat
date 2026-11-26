/**
 * Which locked chats have been unlocked in this sitting. Nothing is stored:
 * leaving the app locks them all again.
 */
import {AppState} from 'react-native';
import {makeAutoObservable} from 'mobx';

import {translate} from '../../locales';
import {deviceUnlock, type UnlockResult} from './deviceUnlock';

class LockState {
  private readonly unlocked = new Set<string>();
  /** Bumped on every change; observers read it to re-render. */
  version = 0;

  constructor() {
    makeAutoObservable(this);
  }

  isUnlocked(conversationId: string): boolean {
    // Touch the observable so observers follow changes of the set.
    return this.version >= 0 && this.unlocked.has(conversationId);
  }

  markUnlocked(conversationId: string): void {
    this.unlocked.add(conversationId);
    this.version++;
  }

  forget(conversationId: string): void {
    if (this.unlocked.delete(conversationId)) {
      this.version++;
    }
  }

  lockAll(): void {
    if (this.unlocked.size > 0) {
      this.unlocked.clear();
      this.version++;
    }
  }
}

export const lockState = new LockState();

/** Asks the phone to verify its owner. */
export function verifyOwner(): Promise<UnlockResult> {
  return deviceUnlock().authenticate(
    translate('lock.prompt'),
    translate('common.cancel'),
  );
}

/** Unlocks one chat for this sitting; false when the user did not pass. */
export async function unlockChat(conversationId: string): Promise<boolean> {
  if (lockState.isUnlocked(conversationId)) {
    return true;
  }
  if ((await verifyOwner()) !== 'ok') {
    return false;
  }
  lockState.markUnlocked(conversationId);
  return true;
}

let watching = false;

/** Locks everything again when the app goes to the background. */
export function watchAppForRelock(): void {
  if (watching) {
    return;
  }
  watching = true;
  AppState.addEventListener('change', state => {
    if (state === 'background') {
      lockState.lockAll();
    }
  });
}
