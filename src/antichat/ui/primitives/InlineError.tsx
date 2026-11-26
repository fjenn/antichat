import React from 'react';
import {View, type StyleProp, type ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {translate} from '../../locales';
import {Icon} from './Icon';
import {PressableScale} from './PressableScale';
import {Text} from './Text';

export interface InlineErrorProps {
  message: string;
  /** Shows a retry action at the end of the row. */
  onRetry?: () => void;
  retryLabel?: string;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * An error shown where it happened (under an answer, in a list) instead of an
 * alert. Announced to screen readers when it appears.
 */
export function InlineError({
  message,
  onRetry,
  retryLabel,
  style,
  testID,
}: InlineErrorProps) {
  const retry = retryLabel ?? translate('common.retry');
  return (
    <View testID={testID} style={[styles.row, style]}>
      <Icon name="alert" size={18} color="danger" />
      {/* The text is the alert; the row stays a container so that the retry
          button remains reachable on its own. */}
      <Text
        variant="callout"
        color="danger"
        accessibilityRole="alert"
        accessibilityLiveRegion="polite"
        style={styles.message}>
        {message}
      </Text>
      {onRetry ? (
        <PressableScale
          accessibilityRole="button"
          accessibilityLabel={retry}
          haptic
          hitSlop={12}
          onPress={onRetry}>
          <Text variant="calloutStrong" color="textPrimary">
            {retry}
          </Text>
        </PressableScale>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    minHeight: 44,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.dangerSoft,
  },
  message: {
    flex: 1,
  },
}));
