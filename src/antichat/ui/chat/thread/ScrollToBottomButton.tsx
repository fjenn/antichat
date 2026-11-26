import React, {useEffect} from 'react';
import Animated, {
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withSpring,
  withTiming,
  type SharedValue,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../../locales';
import {motion} from '../../../theme';
import {IconButton} from '../../primitives';

export interface ScrollToBottomButtonProps {
  visible: boolean;
  /** Height of the composer dock: the button floats just above it. */
  composerHeight: SharedValue<number>;
  onPress: () => void;
}

/** Floats over the thread when the newest message is out of sight. */
export function ScrollToBottomButton({
  visible,
  composerHeight,
  onPress,
}: ScrollToBottomButtonProps) {
  const t = useT();
  const shown = useSharedValue(0);
  const reduceMotion = useReducedMotion();

  useEffect(() => {
    shown.value =
      reduceMotion || !visible
        ? withTiming(visible ? 1 : 0, {duration: motion.duration.fast})
        : withSpring(1, motion.spring.snappy);
  }, [reduceMotion, shown, visible]);

  // Scale only: glass does not draw inside a view that is partly transparent.
  const animated = useAnimatedStyle(() => ({
    bottom: composerHeight.value + CLEARANCE - TOUCH_PAD,
    transform: [{translateY: (1 - shown.value) * 10}, {scale: shown.value}],
  }));

  return (
    <Animated.View
      pointerEvents={visible ? 'box-none' : 'none'}
      accessibilityElementsHidden={!visible}
      importantForAccessibility={visible ? 'auto' : 'no-hide-descendants'}
      style={[styles.holder, animated]}>
      <IconButton
        testID="scroll-to-bottom"
        icon="arrowDown"
        variant="glass"
        size={SIZE}
        iconSize={18}
        accessibilityLabel={t('thread.scrollToBottom')}
        onPress={onPress}
      />
    </Animated.View>
  );
}

const SIZE = 36;
/** Clear space between the composer and the visible button. */
const CLEARANCE = 8;
/** The touch target (44) is larger than the button; it reaches below it. */
const TOUCH_PAD = (44 - SIZE) / 2;

const styles = StyleSheet.create({
  holder: {
    position: 'absolute',
    alignSelf: 'center',
  },
});
