import React, {useEffect} from 'react';
import {View} from 'react-native';
import Animated, {
  Easing,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

export interface ProgressBarProps {
  /** 0..1, or null while the amount is not known yet. */
  fraction: number | null;
  /** Grey instead of the accent: nothing is moving. */
  idle?: boolean;
  accessibilityLabel: string;
  testID?: string;
}

/** A thin, calm bar. Moves smoothly between reports; pulses when unknown. */
export function ProgressBar({
  fraction,
  idle = false,
  accessibilityLabel,
  testID,
}: ProgressBarProps) {
  const reduceMotion = useReducedMotion();
  const width = useSharedValue(fraction ?? 0);
  const pulse = useSharedValue(1);
  const unknown = fraction === null;

  useEffect(() => {
    const next = Math.min(1, Math.max(0, fraction ?? 0));
    width.value = reduceMotion
      ? next
      : withTiming(next, {duration: 400, easing: Easing.out(Easing.quad)});
  }, [fraction, reduceMotion, width]);

  useEffect(() => {
    if (unknown && !reduceMotion) {
      pulse.value = withRepeat(
        withTiming(0.35, {duration: 900, easing: Easing.inOut(Easing.quad)}),
        -1,
        true,
      );
    } else {
      pulse.value = withTiming(1, {duration: 150});
    }
  }, [pulse, reduceMotion, unknown]);

  const fill = useAnimatedStyle(() => ({
    width: `${(unknown ? 1 : width.value) * 100}%`,
    opacity: pulse.value,
  }));

  return (
    <View
      testID={testID}
      accessible
      accessibilityRole="progressbar"
      accessibilityLabel={accessibilityLabel}
      accessibilityValue={
        unknown
          ? undefined
          : {min: 0, max: 100, now: Math.round((fraction ?? 0) * 100)}
      }
      style={styles.track}>
      <Animated.View style={[styles.fill(idle || unknown), fill]} />
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  track: {
    height: 4,
    borderRadius: 2,
    overflow: 'hidden',
    backgroundColor: theme.colors.surfacePressed,
  },
  fill: (quiet: boolean) => ({
    height: 4,
    borderRadius: 2,
    backgroundColor: quiet ? theme.colors.textTertiary : theme.colors.accent,
  }),
}));
