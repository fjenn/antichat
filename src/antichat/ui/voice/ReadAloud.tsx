import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {usePort} from '../../adapters';
import type {VoicePort} from '../../engine/voice/port';
import {GlassSurface, IconButton, PressableScale, Text} from '../primitives';
import {Glyph} from './Glyphs';
import {voiceStrings as s} from './strings';

const RATES = [1, 1.25, 1.5, 2, 0.75];

/**
 * The read-aloud button of an answer's action row: starts reading that
 * message, and turns into stop while it is the one being read.
 */
export function ReadAloudButton({
  voice,
  messageId,
  text,
  size = 32,
}: {
  voice: VoicePort;
  messageId: string;
  text: string;
  size?: number;
}) {
  const active = usePort(
    voice,
    port =>
      port.speech.status !== 'idle' && port.speech.messageId === messageId,
  );
  return (
    <IconButton
      testID={`read-aloud-${messageId}`}
      icon={active ? 'stop' : 'readAloud'}
      size={size}
      iconSize={18}
      accessibilityLabel={active ? s.readAloud.stop : s.readAloud.play}
      onPress={() => {
        if (active) {
          voice.stopSpeech();
        } else {
          voice.speak(messageId, text).catch(() => {});
        }
      }}
    />
  );
}

/**
 * Offsets of the sentence being read in that message's text (for the thread
 * to highlight it), or null when this message is not being read.
 */
export function useSpokenRange(
  voice: VoicePort,
  messageId: string,
): {start: number; end: number} | null {
  const state = usePort(voice, port => port.speech);
  return (state.status === 'speaking' || state.status === 'paused') &&
    state.messageId === messageId
    ? state.range
    : null;
}

/**
 * The small player shown above the composer while an answer is read:
 * previous / pause / next, progress, speed, close. Renders nothing when idle.
 */
export function ReadAloudBar({
  voice,
  testID = 'read-aloud-bar',
}: {
  voice: VoicePort;
  testID?: string;
}) {
  const state = usePort(voice, port => port.speech);
  if (state.status === 'idle') {
    return null;
  }
  const playing = state.status === 'speaking';
  const live = state.status === 'speaking' || state.status === 'paused';
  const rate = live ? state.rate : 1;
  const many = live && state.sentenceCount > 1;
  return (
    <GlassSurface testID={testID} radius={24} style={styles.bar}>
      {many ? (
        <Control
          label={s.readAloud.previous}
          testID="read-aloud-previous"
          onPress={() => voice.skipSpeech(-1)}>
          <Glyph name="previous" size={13} />
        </Control>
      ) : null}
      <Control
        testID="read-aloud-toggle"
        label={playing ? s.readAloud.pause : s.readAloud.resume}
        disabled={!live}
        onPress={() => (playing ? voice.pauseSpeech() : voice.resumeSpeech())}>
        <Glyph
          name={playing ? 'pause' : 'play'}
          size={15}
          color={live ? 'textPrimary' : 'textTertiary'}
        />
      </Control>
      {many ? (
        <Control
          label={s.readAloud.next}
          testID="read-aloud-next"
          onPress={() => voice.skipSpeech(1)}>
          <Glyph name="next" size={13} />
        </Control>
      ) : null}
      <View style={styles.middle}>
        {live ? (
          <View
            style={styles.track}
            accessibilityRole="progressbar"
            accessibilityValue={{
              min: 0,
              max: 100,
              now: Math.round(state.progress * 100),
            }}>
            <View
              testID="read-aloud-progress"
              style={styles.fill(state.progress)}
            />
          </View>
        ) : (
          <Text variant="caption" color="textSecondary">
            {s.readAloud.preparing}
          </Text>
        )}
      </View>
      <PressableScale
        testID="read-aloud-speed"
        accessibilityRole="button"
        accessibilityLabel={`${s.readAloud.speed}, ${rate}×`}
        haptic
        onPress={() =>
          voice.setSpeechRate(
            RATES[(RATES.indexOf(rate) + 1) % RATES.length] ?? 1,
          )
        }
        style={styles.speed}>
        <Text variant="caption" color="textPrimary">{`${rate}×`}</Text>
      </PressableScale>
      <IconButton
        testID="read-aloud-close"
        icon="close"
        size={32}
        iconSize={18}
        accessibilityLabel={s.readAloud.stop}
        onPress={() => voice.stopSpeech()}
      />
    </GlassSurface>
  );
}

function Control({
  children,
  label,
  onPress,
  disabled,
  testID,
}: {
  children: React.ReactNode;
  label: string;
  onPress: () => void;
  disabled?: boolean;
  testID?: string;
}) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{disabled: !!disabled}}
      disabled={disabled}
      haptic
      hitSlop={6}
      onPress={onPress}
      style={styles.control}>
      {children}
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  bar: {
    alignSelf: 'center',
    minHeight: 48,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
  },
  control: {
    width: 36,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  middle: {
    width: 96,
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.xs,
  },
  track: {
    height: 4,
    borderRadius: 2,
    backgroundColor: theme.colors.controlTrack,
    overflow: 'hidden',
  },
  fill: (progress: number) => ({
    width: `${Math.round(Math.min(1, Math.max(0, progress)) * 100)}%`,
    height: 4,
    borderRadius: 2,
    backgroundColor: theme.colors.textPrimary,
  }),
  speed: {
    minWidth: 44,
    height: 32,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.surface,
  },
}));
