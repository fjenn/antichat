import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {Icon, IconButton, Text, type IconName} from '../primitives';
import {ms} from './strings';

/** What a pushed screen gets from the stack; kept loose on purpose. */
export interface ScreenNavigation {
  goBack(): void;
  navigate(...args: any[]): void;
}

/** Top bar of a pushed screen: back, centred title, one optional action. */
export function Header({
  title,
  onBack,
  trailing,
}: {
  title: string;
  onBack: () => void;
  trailing?: React.ReactNode;
}) {
  return (
    <View style={styles.bar}>
      <IconButton
        testID="header-back"
        icon="chevronBack"
        variant="glass"
        accessibilityLabel={ms('back')}
        onPress={onBack}
      />
      <Text
        variant="headline"
        align="center"
        numberOfLines={1}
        accessibilityRole="header"
        style={styles.title}>
        {title}
      </Text>
      <View style={styles.trailing}>{trailing}</View>
    </View>
  );
}

export function SectionLabel({children}: {children: string}) {
  return (
    <Text
      variant="footnote"
      color="textSecondary"
      accessibilityRole="header"
      style={styles.section}>
      {children}
    </Text>
  );
}

export function EmptyState({
  icon,
  title,
  hint,
  testID,
}: {
  icon: IconName;
  title: string;
  hint?: string;
  testID?: string;
}) {
  return (
    <View testID={testID} style={styles.empty}>
      <Icon name={icon} size={28} color="textTertiary" />
      <Text variant="bodyStrong" align="center">
        {title}
      </Text>
      {hint ? (
        <Text variant="callout" color="textSecondary" align="center">
          {hint}
        </Text>
      ) : null}
    </View>
  );
}

/** "12 Nov" this year, "12 Nov 2025" otherwise. */
export function shortDate(time: number, now: number = Date.now()): string {
  const date = new Date(time);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  try {
    return date.toLocaleDateString(undefined, {
      day: 'numeric',
      month: 'short',
      year: sameYear ? undefined : 'numeric',
    });
  } catch {
    return date.toDateString();
  }
}

const styles = StyleSheet.create((theme, rt) => ({
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingTop: rt.insets.top + theme.spacing.xs,
    paddingBottom: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
  },
  title: {
    flex: 1,
  },
  trailing: {
    minWidth: theme.sizes.topBarButton,
    alignItems: 'flex-end',
  },
  section: {
    paddingHorizontal: theme.spacing.md,
    paddingTop: theme.spacing.lg,
    paddingBottom: theme.spacing.xs,
  },
  empty: {
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingVertical: theme.spacing.huge,
    paddingHorizontal: theme.spacing.xxl,
  },
}));
