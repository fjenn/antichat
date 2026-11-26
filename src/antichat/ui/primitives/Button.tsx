import React from 'react';
import {
  ActivityIndicator,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import type {ColorToken} from '../../theme';
import {Icon} from './Icon';
import type {IconName} from './icons';
import {PressableScale} from './PressableScale';
import {Text} from './Text';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'destructive';
export type ButtonSize = 'md' | 'lg';

export interface ButtonProps {
  label: string;
  onPress?: () => void;
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
  loading?: boolean;
  disabled?: boolean;
  /** Stretch to the width of the parent. */
  fullWidth?: boolean;
  accessibilityHint?: string;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

const LABEL_COLOR: Record<ButtonVariant, ColorToken> = {
  primary: 'background',
  secondary: 'textPrimary',
  ghost: 'textPrimary',
  destructive: 'danger',
};

export function Button({
  label,
  onPress,
  variant = 'primary',
  size = 'md',
  icon,
  loading = false,
  disabled = false,
  fullWidth = false,
  accessibilityHint,
  style,
  testID,
}: ButtonProps) {
  const {theme} = useUnistyles();
  const inactive = disabled || loading;
  const color: ColorToken = disabled ? 'textTertiary' : LABEL_COLOR[variant];
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={accessibilityHint}
      accessibilityState={{disabled: inactive, busy: loading}}
      disabled={inactive}
      haptic
      onPress={onPress}
      style={[fullWidth ? styles.stretch : styles.hug, style]}>
      <View style={styles.box(variant, size, disabled)}>
        {loading ? (
          <ActivityIndicator size="small" color={theme.colors[color]} />
        ) : icon ? (
          <Icon name={icon} size={18} color={color} />
        ) : null}
        <Text variant="button" color={color} numberOfLines={2} align="center">
          {label}
        </Text>
      </View>
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  stretch: {alignSelf: 'stretch'},
  hug: {alignSelf: 'flex-start'},
  box: (variant: ButtonVariant, size: ButtonSize, disabled: boolean) => ({
    // minHeight, not height: the label grows with Dynamic Type.
    minHeight: size === 'lg' ? 52 : 44,
    paddingHorizontal: size === 'lg' ? theme.spacing.xxl : theme.spacing.xl,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.pill,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    backgroundColor:
      variant === 'primary'
        ? disabled
          ? theme.colors.surfacePressed
          : theme.colors.textPrimary
        : variant === 'secondary'
          ? theme.colors.surface
          : variant === 'destructive'
            ? theme.colors.dangerSoft
            : 'transparent',
  }),
}));
