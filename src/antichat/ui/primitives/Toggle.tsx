import React, {useEffect} from 'react';
import {Pressable} from 'react-native';
import Animated, {
  interpolateColor,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withSpring,
  withTiming,
} from 'react-native-reanimated';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {motion} from '../../theme';
import {haptics} from './haptics';

export interface ToggleProps {
  value: boolean;
  onValueChange: (value: boolean) => void;
  accessibilityLabel: string;
  accessibilityHint?: string;
  disabled?: boolean;
  testID?: string;
}

const TRACK_WIDTH = 51;
const TRACK_HEIGHT = 31;
const THUMB = 27;
const TRAVEL = TRACK_WIDTH - THUMB - 4;

/**
 * A switch drawn by us, so it is the same on both platforms and takes the
 * accent colour. The track sits in a 44-point touch target.
 */
export function Toggle({
  value,
  onValueChange,
  accessibilityLabel,
  accessibilityHint,
  disabled = false,
  testID,
}: ToggleProps) {
  const {theme, rt} = useUnistyles();
  const reduceMotion = useReducedMotion();
  const progress = useSharedValue(value ? 1 : 0);
  const direction = rt.rtl ? -1 : 1;
  const off = theme.colors.controlTrack;
  const on = theme.colors.accent;

  useEffect(() => {
    progress.value = reduceMotion
      ? withTiming(value ? 1 : 0, {duration: motion.duration.instant})
      : withSpring(value ? 1 : 0, motion.spring.snappy);
  }, [progress, reduceMotion, value]);

  const track = useAnimatedStyle(() => ({
    backgroundColor: interpolateColor(progress.value, [0, 1], [off, on]),
  }));
  const thumb = useAnimatedStyle(() => ({
    transform: [{translateX: progress.value * TRAVEL * direction}],
  }));

  return (
    <Pressable
      testID={testID}
      accessibilityRole="switch"
      accessibilityLabel={accessibilityLabel}
      accessibilityHint={accessibilityHint}
      accessibilityState={{checked: value, disabled}}
      disabled={disabled}
      hitSlop={8}
      onPress={() => {
        haptics.selection();
        onValueChange(!value);
      }}
      style={styles.target(disabled)}>
      <Animated.View style={[styles.track, track]}>
        <Animated.View style={[styles.thumb, thumb]} />
      </Animated.View>
    </Pressable>
  );
}

const styles = StyleSheet.create(theme => ({
  target: (disabled: boolean) => ({
    minHeight: 44,
    justifyContent: 'center',
    opacity: disabled ? 0.4 : 1,
  }),
  track: {
    width: TRACK_WIDTH,
    height: TRACK_HEIGHT,
    borderRadius: TRACK_HEIGHT / 2,
    padding: 2,
    justifyContent: 'center',
  },
  thumb: {
    width: THUMB,
    height: THUMB,
    borderRadius: THUMB / 2,
    backgroundColor: theme.colors.controlThumb,
    boxShadow: '0px 1px 3px rgba(0, 0, 0, 0.25)',
  },
}));
