import React, {useEffect} from 'react';
import Animated, {
  Easing,
  cancelAnimation,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import type {ColorToken, TextVariant} from '../../../theme';
import {Text} from '../../primitives';

/** 0 → 1 → 0, forever; still when Reduce Motion is on. */
function usePulse(periodMs: number) {
  const pulse = useSharedValue(0);
  const reduceMotion = useReducedMotion();
  useEffect(() => {
    if (reduceMotion) {
      pulse.value = 0.5;
      return;
    }
    pulse.value = withRepeat(
      withTiming(1, {
        duration: periodMs / 2,
        easing: Easing.inOut(Easing.quad),
      }),
      -1,
      true,
    );
    return () => cancelAnimation(pulse);
  }, [periodMs, pulse, reduceMotion]);
  return pulse;
}

/** The dot that stands in for an answer before its first word. */
export function PendingDot({testID}: {testID?: string}) {
  const pulse = usePulse(1100);
  const animated = useAnimatedStyle(() => ({
    opacity: 0.55 + pulse.value * 0.45,
    transform: [{scale: 0.82 + pulse.value * 0.26}],
  }));
  return <Animated.View testID={testID} style={[styles.dot, animated]} />;
}

/** Text that breathes while something is in progress ("Thinking"). */
export function PulsingText({
  children,
  variant = 'body',
  color = 'textSecondary',
}: {
  children: string;
  variant?: TextVariant;
  color?: ColorToken;
}) {
  const pulse = usePulse(1400);
  const animated = useAnimatedStyle(() => ({
    opacity: 0.45 + pulse.value * 0.55,
  }));
  return (
    <Animated.View style={animated}>
      <Text variant={variant} color={color} numberOfLines={1}>
        {children}
      </Text>
    </Animated.View>
  );
}

const styles = StyleSheet.create(theme => ({
  dot: {
    width: 14,
    height: 14,
    borderRadius: 7,
    marginVertical: 5,
    backgroundColor: theme.colors.textPrimary,
  },
}));
