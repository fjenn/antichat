import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ColorToken} from '../../../theme';
import {
  ContextMenu,
  Icon,
  PressableScale,
  Text,
  Toggle,
  type IconName,
  type MenuItem,
} from '../../primitives';

export interface RowProps {
  title: string;
  subtitle?: string;
  icon?: IconName;
  /** Short value at the end ("System", "5.2 GB"). */
  value?: string;
  /** The row opens another screen. */
  chevron?: boolean;
  /** Custom trailing content. */
  trailing?: React.ReactNode;
  onPress?: () => void;
  destructive?: boolean;
  disabled?: boolean;
  accessibilityHint?: string;
  testID?: string;
}

/** One line of a settings card. */
export function Row({
  title,
  subtitle,
  icon,
  value,
  chevron = false,
  trailing,
  onPress,
  destructive = false,
  disabled = false,
  accessibilityHint,
  testID,
}: RowProps) {
  const color: ColorToken = disabled
    ? 'textTertiary'
    : destructive
      ? 'danger'
      : 'textPrimary';
  const content = (
    <View style={styles.row}>
      {icon ? <Icon name={icon} size={20} color={color} /> : null}
      <View style={styles.texts}>
        <Text variant="body" color={color}>
          {title}
        </Text>
        {subtitle ? (
          <Text variant="footnote" color="textSecondary">
            {subtitle}
          </Text>
        ) : null}
      </View>
      {value ? (
        <Text
          variant="body"
          color="textSecondary"
          numberOfLines={1}
          style={styles.value}>
          {value}
        </Text>
      ) : null}
      {trailing}
      {chevron ? (
        <Icon name="chevronForward" size={18} color="textTertiary" />
      ) : null}
    </View>
  );
  if (!onPress) {
    return <View testID={testID}>{content}</View>;
  }
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={[title, value, subtitle].filter(Boolean).join(', ')}
      accessibilityHint={accessibilityHint}
      accessibilityState={{disabled}}
      disabled={disabled}
      scale={false}
      onPress={onPress}>
      {content}
    </PressableScale>
  );
}

export interface ToggleRowProps
  extends Pick<RowProps, 'title' | 'subtitle' | 'icon' | 'disabled'> {
  value: boolean;
  onValueChange: (value: boolean) => void;
  testID?: string;
}

/** A row with a switch. The switch is the control; the row is not a button. */
export function ToggleRow({
  title,
  subtitle,
  icon,
  disabled,
  value,
  onValueChange,
  testID,
}: ToggleRowProps) {
  return (
    <Row
      // The row carries the state in its id, so a UI test can read it on both
      // platforms ("haptics-toggle-on").
      testID={testID ? `${testID}-${value ? 'on' : 'off'}` : undefined}
      title={title}
      subtitle={subtitle}
      icon={icon}
      disabled={disabled}
      trailing={
        <Toggle
          testID={testID}
          value={value}
          disabled={disabled}
          onValueChange={onValueChange}
          accessibilityLabel={title}
          accessibilityHint={subtitle}
        />
      }
    />
  );
}

export interface MenuRowProps
  extends Pick<RowProps, 'title' | 'subtitle' | 'icon' | 'value'> {
  items: MenuItem[];
  onSelect: (id: string) => void;
  testID?: string;
}

/** A row whose value is picked from a native menu. */
export function MenuRow({
  title,
  subtitle,
  icon,
  value,
  items,
  onSelect,
  testID,
}: MenuRowProps) {
  return (
    <ContextMenu items={items} onSelect={onSelect}>
      <PressableScale
        testID={testID}
        accessibilityRole="button"
        accessibilityLabel={[title, value].filter(Boolean).join(', ')}
        scale={false}>
        <View style={styles.row}>
          {icon ? <Icon name={icon} size={20} /> : null}
          <View style={styles.texts}>
            <Text variant="body">{title}</Text>
            {subtitle ? (
              <Text variant="footnote" color="textSecondary">
                {subtitle}
              </Text>
            ) : null}
          </View>
          {value ? (
            <Text
              variant="body"
              color="textSecondary"
              numberOfLines={1}
              style={styles.value}>
              {value}
            </Text>
          ) : null}
          <Icon name="chevronDown" size={16} color="textTertiary" />
        </View>
      </PressableScale>
    </ContextMenu>
  );
}

const styles = StyleSheet.create(theme => ({
  row: {
    minHeight: 54,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  value: {
    flexShrink: 1,
    maxWidth: '50%',
  },
}));
