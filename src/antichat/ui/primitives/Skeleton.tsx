import React, {useEffect, useState} from 'react';
import {
  View,
  type DimensionValue,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import LinearGradient from 'react-native-linear-gradient';
import Animated, {
  Easing,
  cancelAnimation,
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {motion} from '../../theme';

export interface SkeletonProps {
  width?: DimensionValue;
  height?: number;
  radius?: number;
  style?: StyleProp<ViewStyle>;
}

/**
 * A placeholder block with a light sweep. With Reduce Motion it is a still
 * block. Hidden from screen readers: the parent announces "Loading".
 */
export function Skeleton({
  width = '100%',
  height = 16,
  radius = 8,
  style,
}: SkeletonProps) {
  const {theme, rt} = useUnistyles();
  const reduceMotion = useReducedMotion();
  const [span, setSpan] = useState(0);
  const sweep = useSharedValue(0);

  useEffect(() => {
    if (reduceMotion || span === 0) {
      return;
    }
    sweep.value = 0;
    sweep.value = withRepeat(
      withTiming(1, {
        duration: motion.duration.shimmer,
        easing: Easing.inOut(Easing.ease),
      }),
      -1,
    );
    return () => cancelAnimation(sweep);
  }, [reduceMotion, span, sweep]);

  const direction = rt.rtl ? -1 : 1;
  const animated = useAnimatedStyle(() => ({
    transform: [{translateX: (sweep.value * 2 - 1) * span * direction}],
  }));

  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      onLayout={event => setSpan(event.nativeEvent.layout.width)}
      style={[styles.block(width, height, radius), style]}>
      {reduceMotion ? null : (
        <Animated.View style={[styles.sweep, animated]}>
          <LinearGradient
            start={{x: 0, y: 0.5}}
            end={{x: 1, y: 0.5}}
            colors={[
              theme.colors.skeleton,
              theme.colors.skeletonHighlight,
              theme.colors.skeleton,
            ]}
            style={styles.sweep}
          />
        </Animated.View>
      )}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  block: (width: DimensionValue, height: number, radius: number) => ({
    width,
    height,
    borderRadius: radius,
    backgroundColor: theme.colors.skeleton,
    overflow: 'hidden',
  }),
  sweep: {
    ...StyleSheet.absoluteFillObject,
  },
}));
