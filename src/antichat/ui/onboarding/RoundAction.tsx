import React from 'react';
import {StyleSheet} from 'react-native-unistyles';

import {Icon, PressableScale, type IconName} from '../primitives';

export interface RoundActionProps {
  icon: IconName;
  accessibilityLabel: string;
  onPress: () => void;
  testID?: string;
}

/**
 * A small round button that sits on a card (pause, resume, download): the
 * card is grey, so the button takes the screen's own colour.
 */
export function RoundAction({
  icon,
  accessibilityLabel,
  onPress,
  testID,
}: RoundActionProps) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      haptic
      hitSlop={6}
      onPress={onPress}
      style={styles.button}>
      <Icon name={icon} size={18} strokeWidth={2.2} />
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  button: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors.backgroundElevated,
    boxShadow: theme.elevation.raised,
  },
}));
