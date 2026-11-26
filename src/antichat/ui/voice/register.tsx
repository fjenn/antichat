/**
 * The one place the chat screen, the composer and Settings connect to the
 * voice UI. Version 1 is dictation only.
 *
 *   // chat screen, once (returns the function that undoes it):
 *   useEffect(() => registerVoiceUi({
 *     insertText: text => composer.current?.insertText(text),
 *   }), []);
 *
 *   // composer
 *   const dictating = useDictating();
 *   {dictating ? <DictationLayer /> : <the field and its buttons>}
 *   <DictationButton />                      // the mic button
 *
 *   // Settings > Voice
 *   <DictationSettings />
 */
import React from 'react';

import {usePort} from '../../adapters';
import type {VoicePort} from '../../engine/voice/port';
import {IconButton} from '../primitives';
import {DictationBar} from './DictationBar';
import {getVoicePort} from './port';
import {voiceStrings as s} from './strings';

export interface VoiceUiHost {
  /** Puts dictated text into the composer field. It is never sent by itself. */
  insertText(text: string): void;
}

let host: VoiceUiHost | null = null;
let override: VoicePort | null = null;
const port = (): VoicePort => override ?? getVoicePort();

/**
 * Connects the voice UI to the chat screen. `voice` is only for check
 * screens and tests; the app leaves it out and gets the app's voice port.
 */
export function registerVoiceUi(next: VoiceUiHost, voice?: VoicePort) {
  host = next;
  override = voice ?? null;
  return () => {
    if (host === next) {
      host = null;
      override = null;
    }
  };
}

/** What the composer's mic button calls (`DictationButton` does it itself). */
export const voiceUi = {
  dictate(): void {
    port()
      .startDictation()
      .catch(() => {});
  },
  cancelDictation(): void {
    port().cancelDictation();
  },
};

/** True while the dictation bar stands in for the composer field. */
export function useDictating(voice: VoicePort = port()): boolean {
  return usePort(voice, p => p.dictation.status !== 'idle');
}

/**
 * The composer's mic button: starts dictation; off while one is starting or
 * finishing (while listening the bar has replaced the composer anyway).
 */
export function DictationButton({
  voice = port(),
  size = 36,
  disabled = false,
  testID = 'composer-dictate',
}: {
  voice?: VoicePort;
  size?: number;
  disabled?: boolean;
  testID?: string;
}) {
  const status = usePort(voice, p => p.dictation.status);
  return (
    <IconButton
      testID={testID}
      icon="mic"
      size={size}
      disabled={disabled || (status !== 'idle' && status !== 'failed')}
      accessibilityLabel={s.dictation.start}
      onPress={() => {
        voice.startDictation().catch(() => {});
      }}
    />
  );
}

/**
 * The dictation bar, handing its text to the registered host. Renders
 * nothing while dictation is idle.
 */
export function DictationLayer({voice = port()}: {voice?: VoicePort}) {
  return <DictationBar voice={voice} onText={text => host?.insertText(text)} />;
}
