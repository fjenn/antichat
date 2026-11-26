import React from 'react';
import {View, type StyleProp, type ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ColorToken} from '../../theme';
import {Icon} from './Icon';
import type {IconName} from './icons';
import {PressableScale} from './PressableScale';
import {Text} from './Text';

export interface ListRowProps {
  title: string;
  subtitle?: string;
  icon?: IconName;
  /** Short value at the end of the row ("2.1 GB", "System"). */
  value?: string;
  /** Show a chevron: the row opens another screen. */
  chevron?: boolean;
  /** Custom trailing content, e.g. a `Toggle`. */
  trailing?: React.ReactNode;
  onPress?: () => void;
  onLongPress?: () => void;
  selected?: boolean;
  destructive?: boolean;
  disabled?: boolean;
  /** Lines of title before it truncates. Chat rows use 1. */
  titleLines?: number;
  accessibilityLabel?: string;
  accessibilityHint?: string;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

export function ListRow({
  title,
  subtitle,
  icon,
  value,
  chevron = false,
  trailing,
  onPress,
  onLongPress,
  selected = false,
  destructive = false,
  disabled = false,
  titleLines = 2,
  accessibilityLabel,
  accessibilityHint,
  style,
  testID,
}: ListRowProps) {
  const color: ColorToken = disabled
    ? 'textTertiary'
    : destructive
      ? 'danger'
      : 'textPrimary';
  const content = (
    <View style={styles.row(selected)}>
      {icon ? <Icon name={icon} size={20} color={color} /> : null}
      <View style={styles.texts}>
        <Text variant="body" color={color} numberOfLines={titleLines}>
          {title}
        </Text>
        {subtitle ? (
          <Text variant="footnote" color="textSecondary" numberOfLines={3}>
            {subtitle}
          </Text>
        ) : null}
      </View>
      {value ? (
        <Text variant="body" color="textSecondary" numberOfLines={1}>
          {value}
        </Text>
      ) : null}
      {trailing}
      {chevron ? (
        <Icon name="chevronForward" size={18} color="textTertiary" />
      ) : null}
    </View>
  );

  // A row that only hosts a control (a toggle) is not itself a button.
  if (!onPress && !onLongPress) {
    return (
      <View testID={testID} style={style}>
        {content}
      </View>
    );
  }
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={
        accessibilityLabel ??
        [title, subtitle, value].filter(Boolean).join(', ')
      }
      accessibilityHint={accessibilityHint}
      accessibilityState={{selected, disabled}}
      disabled={disabled}
      scale={false}
      onPress={onPress}
      onLongPress={onLongPress}
      style={style}>
      {content}
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  row: (selected: boolean) => ({
    minHeight: theme.sizes.row,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm + theme.spacing.xxs,
    borderRadius: theme.radii.md,
    backgroundColor: selected ? theme.colors.surface : 'transparent',
  }),
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
}));
