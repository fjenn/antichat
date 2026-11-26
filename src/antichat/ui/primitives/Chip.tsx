import React from 'react';
import {View, type StyleProp, type ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {translate} from '../../locales';
import type {ColorToken} from '../../theme';
import {Icon} from './Icon';
import type {IconName} from './icons';
import {PressableScale} from './PressableScale';
import {Text} from './Text';

export interface ChipProps {
  label: string;
  icon?: IconName;
  selected?: boolean;
  onPress?: () => void;
  /** Shows an x that removes the chip (tool chips, file chips). */
  onRemove?: () => void;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

export function Chip({
  label,
  icon,
  selected = false,
  onPress,
  onRemove,
  disabled = false,
  style,
  testID,
}: ChipProps) {
  const color: ColorToken = disabled
    ? 'textTertiary'
    : selected
      ? 'onAccentSoft'
      : 'textPrimary';
  return (
    <View style={[styles.chip(selected), style]}>
      <PressableScale
        testID={testID}
        accessibilityRole="button"
        accessibilityLabel={label}
        accessibilityState={{selected, disabled}}
        disabled={disabled || !onPress}
        haptic
        hitSlop={6}
        onPress={onPress}
        style={styles.body}>
        {icon ? <Icon name={icon} size={16} color={color} /> : null}
        <Text variant="calloutStrong" color={color} numberOfLines={1}>
          {label}
        </Text>
      </PressableScale>
      {onRemove ? (
        <PressableScale
          accessibilityRole="button"
          accessibilityLabel={translate('common.remove', {name: label})}
          hitSlop={10}
          haptic
          onPress={onRemove}
          style={styles.remove}>
          <Icon name="close" size={14} color={color} strokeWidth={2.5} />
        </PressableScale>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  chip: (selected: boolean) => ({
    minHeight: 36,
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    borderRadius: theme.radii.pill,
    paddingHorizontal: theme.spacing.md,
    gap: theme.spacing.xs,
    backgroundColor: selected ? theme.colors.accentSoft : 'transparent',
    borderWidth: selected ? 0 : 1,
    borderColor: theme.colors.border,
  }),
  body: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs + theme.spacing.xxs,
    paddingVertical: theme.spacing.xs + theme.spacing.xxs,
    flexShrink: 1,
  },
  remove: {
    marginStart: theme.spacing.xxs,
    paddingVertical: theme.spacing.xs,
  },
}));
