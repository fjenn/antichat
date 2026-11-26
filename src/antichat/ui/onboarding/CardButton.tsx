import React from 'react';
import type {StyleProp, ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {Icon, PressableScale, Text, type IconName} from '../primitives';

export interface CardButtonProps {
  label: string;
  onPress: () => void;
  icon?: IconName;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * The quiet button on a grey card. The shared secondary button is the same
 * grey as the card and would read as plain text there, so this one takes the
 * screen's own colour, like `RoundAction`.
 */
export function CardButton({
  label,
  onPress,
  icon,
  style,
  testID,
}: CardButtonProps) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      haptic
      onPress={onPress}
      style={[styles.button, style]}>
      {icon ? <Icon name={icon} size={18} /> : null}
      <Text variant="button" numberOfLines={2} align="center">
        {label}
      </Text>
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  button: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xl,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.backgroundElevated,
    boxShadow: theme.elevation.raised,
  },
}));
