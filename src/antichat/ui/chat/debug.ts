/**
 * Handles of the chat screen for the unattended checks (`auto.ts`) and a
 * request to run them. Debug builds only; nothing in the product reads this.
 */
import {Platform, Settings} from 'react-native';

import type {ComposerHandle} from '../composer/Composer';
import type {ThreadController} from './thread/ThreadController';
import type {ThreadListHandle} from './thread/ThreadList';

export const threadDebug: {
  current: ThreadListHandle | null;
  controller: ThreadController | null;
  composer: ComposerHandle | null;
} = {current: null, controller: null, composer: null};

export type AutoSource = 'script15' | 'script30' | 'script60' | 'model';

const SOURCES: readonly AutoSource[] = [
  'script15',
  'script30',
  'script60',
  'model',
];

export const isAutoSource = (value: unknown): value is AutoSource =>
  SOURCES.includes(value as AutoSource);

let requested: AutoSource | null | undefined;
const listeners = new Set<() => void>();

/** iOS: `-antichatAuto script60`. Android: `…/dev/auto/script60` deep link. */
export function autoRequest(): AutoSource | null {
  if (requested === undefined) {
    requested = null;
    if (Platform.OS === 'ios') {
      try {
        const value = Settings.get('antichatAuto');
        requested = isAutoSource(value) ? value : null;
      } catch {
        // No settings module.
      }
    }
  }
  return requested;
}

export function requestAuto(source: AutoSource): void {
  requested = source;
  listeners.forEach(listener => listener());
}

export function clearAutoRequest(): void {
  requested = null;
}

export function subscribeAuto(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
