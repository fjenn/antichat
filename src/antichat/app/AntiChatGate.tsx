import React, {useEffect, useState, type ComponentType} from 'react';
import {Appearance, StyleSheet, View} from 'react-native';
import {observer} from 'mobx-react';

import {loadBackend} from '../adapters/backend';
import {loadShellChoice, registerDevMenu, type ShellChoice} from './flags';
import {preferences} from './preferences';

export interface AntiChatGateProps {
  /** Upstream's root, shown only when a debug build asks for it. */
  upstream: ComponentType;
}

/**
 * Mounted by upstream's `App.tsx` in place of its own navigation. Shows the
 * AntiChat shell; a debug build can switch to upstream's UI for comparison
 * (developer menu, or Settings).
 *
 * Nothing is drawn until the stored theme is known, so the first frame is
 * already in the right colours.
 */
export const AntiChatGate = observer(function Gate({
  upstream: Upstream,
}: AntiChatGateProps) {
  const [choice, setChoice] = useState<ShellChoice | null>(null);
  // Which backend the ports talk to has to be known before the first screen.
  const [backendKnown, setBackendKnown] = useState(false);

  useEffect(() => {
    registerDevMenu();
    loadShellChoice()
      .then(setChoice)
      .catch(() => setChoice('antichat'));
    preferences.load().catch(() => {});
    loadBackend()
      .catch(() => {})
      .finally(() => setBackendKnown(true));
  }, []);

  if (choice === 'upstream') {
    return <Upstream />;
  }
  if (choice === null || !preferences.loaded || !backendKnown) {
    return (
      <View
        style={
          Appearance.getColorScheme() === 'dark' ? styles.dark : styles.light
        }
      />
    );
  }
  // Loaded lazily so a build showing upstream's UI never evaluates ours.
  const {AntiChatApp} = require('./AntiChatApp');
  return <AntiChatApp />;
});

const styles = StyleSheet.create({
  light: {flex: 1, backgroundColor: '#FFFFFF'},
  dark: {flex: 1, backgroundColor: '#000000'},
});
