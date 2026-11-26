import React, {memo} from 'react';
import Animated, {FadeIn, useReducedMotion} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../../locales';
import {Icon, PressableScale, Text} from '../../primitives';
import {useThreadActions} from './actions';

/** Suggested next messages under the newest answer. Tapping one sends it. */
export const FollowUps = memo(function Suggestions({
  items,
}: {
  items: readonly string[];
}) {
  const t = useT();
  const actions = useThreadActions();
  const reduceMotion = useReducedMotion();
  if (items.length === 0) {
    return null;
  }
  return (
    <Animated.View
      testID="follow-ups"
      accessibilityLabel={t('thread.followUps')}
      entering={reduceMotion ? undefined : FadeIn.duration(220)}
      style={styles.list}>
      {items.map((item, index) => (
        <PressableScale
          key={item}
          testID={`follow-up-${index}`}
          accessibilityRole="button"
          accessibilityLabel={item}
          haptic
          scale={false}
          onPress={() => actions.followUp(item)}
          style={[styles.item, index > 0 && styles.divided]}>
          <Icon name="quote" size={16} color="textTertiary" />
          <Text variant="callout" color="textSecondary" style={styles.text}>
            {item}
          </Text>
        </PressableScale>
      ))}
    </Animated.View>
  );
});

const styles = StyleSheet.create(theme => ({
  list: {
    marginTop: theme.spacing.md,
  },
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    minHeight: 44,
    paddingVertical: theme.spacing.sm,
  },
  divided: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: theme.colors.border,
  },
  text: {
    flex: 1,
  },
}));
