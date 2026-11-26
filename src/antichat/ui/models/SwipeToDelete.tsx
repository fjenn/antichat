import React, {useRef} from 'react';
import {View} from 'react-native';
import Swipeable, {
  type SwipeableMethods,
} from 'react-native-gesture-handler/ReanimatedSwipeable';
import {StyleSheet} from 'react-native-unistyles';

import {Icon, PressableScale, Text} from '../primitives';

export interface SwipeToDeleteProps {
  children: React.ReactNode;
  label: string;
  onDelete: () => void;
  enabled?: boolean;
}

/**
 * Swipe a row towards the start of the line to reveal Delete. The same
 * action is always reachable from the row's menu, for people who do not
 * swipe and for screen readers.
 */
export function SwipeToDelete({
  children,
  label,
  onDelete,
  enabled = true,
}: SwipeToDeleteProps) {
  const swipeable = useRef<SwipeableMethods>(null);
  if (!enabled) {
    return <>{children}</>;
  }
  return (
    <Swipeable
      ref={swipeable}
      friction={1.6}
      rightThreshold={36}
      overshootRight={false}
      renderRightActions={() => (
        <PressableScale
          accessibilityRole="button"
          accessibilityLabel={label}
          scale={false}
          onPress={() => {
            swipeable.current?.close();
            onDelete();
          }}
          style={styles.action}>
          <Icon name="delete" size={20} color="onAccent" />
          <Text variant="caption" color="onAccent" numberOfLines={1}>
            {label}
          </Text>
        </PressableScale>
      )}>
      <View style={styles.row}>{children}</View>
    </Swipeable>
  );
}

const styles = StyleSheet.create(theme => ({
  row: {
    backgroundColor: theme.colors.surface,
  },
  action: {
    width: 88,
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.xxs,
    backgroundColor: theme.colors.danger,
  },
}));
