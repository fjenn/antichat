import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {Icon, Text, type IconName} from '../primitives';

/** A quiet "nothing here yet", centred in the page. */
export function EmptyState({
  icon,
  title,
  hint,
}: {
  icon: IconName;
  title: string;
  hint?: string;
}) {
  return (
    <View style={styles.box}>
      <Icon name={icon} size={28} color="textTertiary" strokeWidth={1.6} />
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

const styles = StyleSheet.create(theme => ({
  box: {
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingVertical: theme.spacing.huge + theme.spacing.xxl,
    paddingHorizontal: theme.spacing.xxl,
  },
}));
