import React, {useEffect, useState} from 'react';
import {Linking, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {usePort} from '../../adapters';
import type {VoicePort} from '../../engine/voice/port';
import {GlassSurface, IconButton, PressableScale, Text} from '../primitives';
import {formatElapsed, voiceStrings as s} from './strings';
import {Waveform} from './Waveform';

export interface DictationBarProps {
  voice: VoicePort;
  /** The dictated text, to put into the composer field (never sent by itself). */
  onText: (text: string) => void;
  testID?: string;
}

/**
 * What the composer shows while dictating: cancel on the left, the words as
 * they are recognised (settled words dark, the changing tail light), a
 * waveform with the elapsed time, and confirm on the right. Renders nothing
 * while dictation is idle, so the composer can mount it in its own slot.
 */
export function DictationBar({
  voice,
  onText,
  testID = 'dictation-bar',
}: DictationBarProps) {
  const state = usePort(voice, port => port.dictation);
  const [now, setNow] = useState(() => Date.now());
  const listening = state.status === 'listening';
  useEffect(() => {
    if (!listening) {
      return;
    }
    const timer = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(timer);
  }, [listening]);

  if (state.status === 'idle') {
    return null;
  }
  const setup = (voice as {setup?: {phase: string; fraction: number}}).setup;
  const failed = state.status === 'failed';
  const partial = listening ? state.partial : '';
  const stable = listening ? partial.slice(0, state.stableLength) : '';
  const tail = partial.slice(stable.length);
  const noPermission = failed && state.error.code === 'permission_denied';
  const hint = failed
    ? noPermission
      ? s.dictation.noPermission
      : state.error.code === 'mic_unavailable'
        ? s.dictation.micBusy
        : state.error.code === 'model_missing'
          ? s.dictation.noModel
          : s.dictation.failed
    : state.status === 'starting'
      ? setup?.phase === 'downloading'
        ? // First use: the speech model is fetched once (adapters/voice.ts).
          `Getting the speech model… ${Math.round(setup.fraction * 100)}%`
        : s.dictation.starting
      : state.status === 'transcribing'
        ? s.dictation.transcribing
        : s.dictation.listening;

  return (
    <GlassSurface testID={testID} radius={28} style={styles.bar}>
      <IconButton
        testID="dictation-cancel"
        icon="close"
        size={36}
        accessibilityLabel={s.dictation.cancel}
        onPress={() => voice.cancelDictation()}
      />
      <View style={styles.middle}>
        {partial ? (
          <Text
            testID="dictation-text"
            numberOfLines={3}
            ellipsizeMode="head"
            accessibilityLiveRegion="polite">
            {stable}
            <Text color="textTertiary">{tail}</Text>
          </Text>
        ) : noPermission ? (
          // Only Settings can change a refused permission.
          <PressableScale
            testID="dictation-open-settings"
            accessibilityRole="button"
            accessibilityHint={s.dictation.openSettings}
            onPress={() => {
              Linking.openSettings().catch(() => {});
            }}>
            <Text testID="dictation-hint" color="danger">
              {hint}
            </Text>
          </PressableScale>
        ) : (
          <Text
            testID="dictation-hint"
            color={failed ? 'danger' : 'textTertiary'}>
            {hint}
          </Text>
        )}
        {listening ? (
          <View style={styles.meter}>
            <Waveform level={state.level} active />
            <Text variant="caption" color="textSecondary" style={styles.time}>
              {formatElapsed(now - state.startedAt)}
            </Text>
          </View>
        ) : null}
      </View>
      {failed ? (
        noPermission ? null : (
          <IconButton
            testID="dictation-retry"
            icon="mic"
            size={36}
            accessibilityLabel={s.dictation.retry}
            onPress={() => {
              voice.startDictation().catch(() => {});
            }}
          />
        )
      ) : (
        <IconButton
          testID="dictation-confirm"
          icon="check"
          variant="accent"
          size={36}
          iconSize={20}
          disabled={!listening}
          accessibilityLabel={s.dictation.confirm}
          onPress={() => {
            voice
              .finishDictation()
              .then(text => {
                if (text) {
                  onText(text);
                }
              })
              .catch(() => {});
          }}
        />
      )}
    </GlassSurface>
  );
}

const styles = StyleSheet.create(theme => ({
  bar: {
    minHeight: theme.sizes.composerMinHeight,
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: theme.spacing.sm,
  },
  middle: {
    flex: 1,
    minHeight: 36,
    justifyContent: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.xs,
  },
  meter: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    overflow: 'hidden',
  },
  time: {
    fontVariant: ['tabular-nums'],
  },
}));
