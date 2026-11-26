import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {usePort} from '../../adapters';
import type {VoicePort} from '../../engine/voice/port';
import {GlassSurface, IconButton, PressableScale, Text} from '../primitives';
import {voiceStrings as s} from './strings';
import {VoiceOrb} from './VoiceOrb';

export interface VoiceModeDockProps {
  voice: VoicePort;
  testID?: string;
}

/**
 * Voice mode inside the chat: sits above the composer while a session runs.
 * The orb in the middle shows the state and is the interrupt button; mute on
 * the left, end on the right; the live transcript of the user's turn below
 * the state. The turns themselves appear in the thread as normal messages.
 * Renders nothing while voice mode is off.
 */
export function VoiceModeDock({
  voice,
  testID = 'voice-dock',
}: VoiceModeDockProps) {
  const state = usePort(voice, port => port.voiceMode);
  if (state.status === 'off') {
    return null;
  }
  const muted = state.status === 'muted';
  const canInterrupt =
    state.status === 'speaking' || state.status === 'thinking';
  const paused = state.status === 'paused';
  const partial = state.status === 'listening' ? state.partial : '';
  return (
    <GlassSurface testID={testID} radius={32} style={styles.dock}>
      <View style={styles.row}>
        <PressableScale
          testID="voice-mute"
          accessibilityRole="switch"
          accessibilityLabel={muted ? s.mode.unmute : s.mode.mute}
          accessibilityState={{checked: muted}}
          haptic
          onPress={() => voice.setMuted(!muted)}
          style={[styles.side, muted && styles.sideOn]}>
          <Text variant="caption" color={muted ? 'danger' : 'textPrimary'}>
            {muted ? s.mode.unmute : s.mode.mute}
          </Text>
        </PressableScale>
        <VoiceOrb
          state={state.status}
          level={state.status === 'listening' ? state.level : 0}
          accessibilityLabel={
            paused
              ? s.mode.orbResume
              : canInterrupt
                ? s.mode.orbInterrupt
                : s.mode[state.status]
          }
          onPress={
            paused
              ? () => {
                  voice.resumeVoiceMode().catch(() => {});
                }
              : canInterrupt
                ? () => voice.interrupt()
                : undefined
          }
        />
        <IconButton
          testID="voice-end"
          icon="close"
          variant="filled"
          size={44}
          accessibilityLabel={s.mode.end}
          onPress={() => voice.stopVoiceMode()}
        />
      </View>
      <Text
        testID="voice-status"
        variant="footnote"
        color="textSecondary"
        align="center"
        numberOfLines={2}
        accessibilityLiveRegion="polite">
        {partial ||
          (state.status === 'speaking'
            ? s.mode.tapToInterrupt
            : s.mode[state.status])}
      </Text>
    </GlassSurface>
  );
}

const styles = StyleSheet.create(theme => ({
  dock: {
    alignSelf: 'stretch',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.xs,
    paddingBottom: theme.spacing.md,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  side: {
    minWidth: 64,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.md,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.surface,
  },
  sideOn: {
    backgroundColor: theme.colors.dangerSoft,
  },
}));
