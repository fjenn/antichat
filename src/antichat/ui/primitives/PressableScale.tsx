import React, {useCallback} from 'react';
import {
  Pressable,
  type GestureResponderEvent,
  type PressableProps,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import Animated, {
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withSpring,
  withTiming,
} from 'react-native-reanimated';

import {motion} from '../../theme';
import {haptics} from './haptics';

const AnimatedPressable = Animated.createAnimatedComponent(Pressable);

export interface PressableScaleProps extends Omit<PressableProps, 'style'> {
  style?: StyleProp<ViewStyle>;
  /** Shrink while pressed. Off for wide rows, which only dim. */
  scale?: boolean;
  /** Play the light tap on press. */
  haptic?: boolean;
}

/**
 * The press feedback every control shares: a quick dim, plus a slight shrink
 * for compact controls. Reduce Motion keeps the dim and drops the shrink.
 */
export function PressableScale({
  style,
  scale = true,
  haptic = false,
  onPressIn,
  onPressOut,
  onPress,
  disabled,
  ...rest
}: PressableScaleProps) {
  const pressed = useSharedValue(0);
  const reduceMotion = useReducedMotion();
  const shrink = scale && !reduceMotion;

  const animated = useAnimatedStyle(() => ({
    opacity: 1 - pressed.value * (1 - motion.pressOpacity),
    transform: [
      {scale: shrink ? 1 - pressed.value * (1 - motion.pressScale) : 1},
    ],
  }));

  const handleIn = useCallback(
    (event: GestureResponderEvent) => {
      pressed.value = withTiming(1, {duration: motion.duration.fast});
      onPressIn?.(event);
    },
    [onPressIn, pressed],
  );
  const handleOut = useCallback(
    (event: GestureResponderEvent) => {
      pressed.value = withSpring(0, motion.spring.snappy);
      onPressOut?.(event);
    },
    [onPressOut, pressed],
  );
  const handlePress = useCallback(
    (event: GestureResponderEvent) => {
      if (haptic) {
        haptics.tap();
      }
      onPress?.(event);
    },
    [haptic, onPress],
  );

  return (
    <AnimatedPressable
      {...rest}
      disabled={disabled}
      onPressIn={handleIn}
      onPressOut={handleOut}
      onPress={onPress || haptic ? handlePress : undefined}
      style={[style, animated]}
    />
  );
}
