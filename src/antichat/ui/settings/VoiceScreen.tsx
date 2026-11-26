import React from 'react';

import {useT} from '../../locales';
import {DictationSettings} from '../voice';
import {SettingsPage} from './components';

/**
 * Voice. The first version has dictation only (M11): language and
 * punctuation. The voice list and hands-free rows come back with read-aloud
 * and voice mode.
 */
export function VoiceScreen() {
  const t = useT();
  return (
    <SettingsPage testID="settings-voice-page" title={t('settings.voice')}>
      <DictationSettings />
    </SettingsPage>
  );
}
