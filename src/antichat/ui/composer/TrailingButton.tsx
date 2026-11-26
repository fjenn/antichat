import React, {useEffect} from 'react';
import {View} from 'react-native';
import Animated, {
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withSpring,
  withTiming,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../locales';
import {motion, type ColorToken} from '../../theme';
import {Icon, PressableScale, type IconName} from '../primitives';
import type {TrailingState} from './composerState';

export const TRAILING_SIZE = 36;

interface Face {
  icon: IconName;
  size: number;
  fill: ColorToken;
  ink: ColorToken;
}

const FACES: Record<TrailingState, Face> = {
  voice: {icon: 'voice', size: 20, fill: 'accent', ink: 'onAccent'},
  send: {icon: 'send', size: 20, fill: 'textPrimary', ink: 'background'},
  stop: {icon: 'stop', size: 16, fill: 'textPrimary', ink: 'background'},
  disabled: {
    icon: 'send',
    size: 20,
    fill: 'surfacePressed',
    ink: 'textTertiary',
  },
};

const ORDER: TrailingState[] = ['voice', 'send', 'stop', 'disabled'];

function FaceLayer({state, active}: {state: TrailingState; active: boolean}) {
  const face = FACES[state];
  const shown = useSharedValue(active ? 1 : 0);
  const reduceMotion = useReducedMotion();
  useEffect(() => {
    shown.value =
      active && !reduceMotion
        ? withSpring(1, motion.spring.snappy)
        : withTiming(active ? 1 : 0, {duration: motion.duration.fast});
  }, [active, reduceMotion, shown]);
  const animated = useAnimatedStyle(() => ({
    opacity: shown.value,
    transform: [{scale: 0.6 + shown.value * 0.4}],
  }));
  return (
    <Animated.View style={[styles.face(face.fill), animated]}>
      <Icon
        name={face.icon}
        size={face.size}
        color={face.ink}
        strokeWidth={2.4}
      />
    </Animated.View>
  );
}

export interface TrailingButtonProps {
  state: TrailingState;
  onPress: () => void;
  onLongPress?: () => void;
}

/**
 * The button at the end of the composer. One control, four faces: voice
 * mode, send, stop, and a greyed arrow when there is nothing to send.
 */
export function TrailingButton({
  state,
  onPress,
  onLongPress,
}: TrailingButtonProps) {
  const t = useT();
  const label =
    state === 'voice'
      ? t('composer.voice')
      : state === 'stop'
        ? t('composer.stop')
        : state === 'send'
          ? t('composer.send')
          : t('composer.disabled');
  return (
    <PressableScale
      testID={`composer-${state}`}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{disabled: state === 'disabled'}}
      disabled={state === 'disabled'}
      hitSlop={6}
      onPress={onPress}
      onLongPress={onLongPress}
      style={styles.button}>
      <View style={styles.button} pointerEvents="none">
        {ORDER.map(face => (
          <FaceLayer key={face} state={face} active={face === state} />
        ))}
      </View>
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  button: {
    width: TRAILING_SIZE,
    height: TRAILING_SIZE,
  },
  face: (fill: ColorToken) => ({
    ...StyleSheet.absoluteFillObject,
    borderRadius: TRAILING_SIZE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors[fill],
  }),
}));
