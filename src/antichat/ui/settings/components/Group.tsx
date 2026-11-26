import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {Text} from '../../primitives';

export interface GroupProps {
  /** Quiet label above the card. */
  title?: string;
  /** Explanation under the card. */
  footer?: string;
  children: React.ReactNode;
  testID?: string;
}

/**
 * A card of rows with hairlines between them: the building block of every
 * settings screen.
 */
export function Group({title, footer, children, testID}: GroupProps) {
  const rows = React.Children.toArray(children).filter(Boolean);
  if (rows.length === 0) {
    return null;
  }
  return (
    <View testID={testID} style={styles.group}>
      {title ? (
        <Text
          variant="footnote"
          color="textSecondary"
          accessibilityRole="header"
          style={styles.label}>
          {title}
        </Text>
      ) : null}
      <View style={styles.card}>
        {rows.map((row, index) => (
          <React.Fragment key={index}>
            {index > 0 ? <View style={styles.hairline} /> : null}
            {row}
          </React.Fragment>
        ))}
      </View>
      {footer ? (
        <Text variant="footnote" color="textSecondary" style={styles.label}>
          {footer}
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  group: {
    gap: theme.spacing.sm,
  },
  label: {
    paddingHorizontal: theme.spacing.lg,
  },
  card: {
    borderRadius: theme.radii.xl,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
    overflow: 'hidden',
  },
  hairline: {
    height: StyleSheet.hairlineWidth,
    marginStart: theme.spacing.lg,
    backgroundColor: theme.colors.border,
  },
}));
