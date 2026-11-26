import React, {useEffect, useRef} from 'react';
import {AccessibilityInfo, Animated, Easing} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {PressableScale} from '../primitives';

export type OrbState =
  | 'starting'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'muted'
  | 'paused';

export interface VoiceOrbProps {
  state: OrbState;
  /** 0..1 microphone level while listening. */
  level?: number;
  size?: number;
  accessibilityLabel: string;
  onPress?: () => void;
  testID?: string;
}

/**
 * The voice mode orb. One accent-coloured circle whose motion says what is
 * happening: it swells with the user's voice while listening, breathes
 * slowly while thinking, pulses while speaking, and rests dimmed when muted
 * or paused. With Reduce Motion on, only size and opacity steps remain.
 */
export function VoiceOrb({
  state,
  level = 0,
  size = 72,
  accessibilityLabel,
  onPress,
  testID = 'voice-orb',
}: VoiceOrbProps) {
  const {theme} = useUnistyles();
  const scale = useRef(new Animated.Value(1)).current;
  const halo = useRef(new Animated.Value(0)).current;
  const reduceMotion = useRef(false);

  useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled()
      .then(on => {
        reduceMotion.current = on;
      })
      .catch(() => {});
  }, []);

  // Looping motion per state.
  useEffect(() => {
    const loopOf = (to: number, ms: number) =>
      Animated.loop(
        Animated.sequence([
          Animated.timing(scale, {
            toValue: to,
            duration: ms,
            easing: Easing.inOut(Easing.quad),
            useNativeDriver: true,
          }),
          Animated.timing(scale, {
            toValue: 1,
            duration: ms,
            easing: Easing.inOut(Easing.quad),
            useNativeDriver: true,
          }),
        ]),
      );
    let loop: Animated.CompositeAnimation | null = null;
    if (!reduceMotion.current) {
      if (state === 'thinking' || state === 'starting') {
        loop = loopOf(0.9, 900);
      } else if (state === 'speaking') {
        loop = loopOf(1.12, 420);
      }
    }
    if (loop) {
      loop.start();
    } else if (state !== 'listening') {
      Animated.timing(scale, {
        toValue: 1,
        duration: 150,
        useNativeDriver: true,
      }).start();
    }
    Animated.timing(halo, {
      toValue: state === 'speaking' ? 1 : 0,
      duration: 250,
      useNativeDriver: true,
    }).start();
    return () => loop?.stop();
  }, [state, scale, halo]);

  // While listening the orb follows the voice.
  useEffect(() => {
    if (state === 'listening') {
      Animated.timing(scale, {
        toValue: 1 + Math.min(1, level) * 0.28,
        duration: 90,
        useNativeDriver: true,
      }).start();
    }
  }, [level, state, scale]);

  const resting = state === 'muted' || state === 'paused';
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      accessibilityState={{busy: state === 'thinking' || state === 'starting'}}
      haptic
      scale={false}
      disabled={!onPress}
      onPress={onPress}
      style={[styles.hit, {width: size * 1.5, height: size * 1.5}]}>
      <Animated.View
        style={[
          styles.halo,
          {
            width: size * 1.4,
            height: size * 1.4,
            borderRadius: size,
            backgroundColor: theme.colors.accentSoft,
            opacity: halo,
            transform: [{scale}],
          },
        ]}
      />
      <Animated.View
        testID={`${testID}-${state}`}
        style={{
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: resting
            ? theme.colors.controlTrack
            : theme.colors.accent,
          opacity: state === 'thinking' || state === 'starting' ? 0.7 : 1,
          transform: [{scale}],
        }}
      />
    </PressableScale>
  );
}

const styles = StyleSheet.create({
  hit: {alignItems: 'center', justifyContent: 'center'},
  halo: {position: 'absolute'},
});
