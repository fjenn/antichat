import React from 'react';
import {View, type StyleProp, type ViewStyle} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts} from '../../adapters';
import {useT} from '../../locales';
import {Icon, PressableScale, Text} from '../primitives';
import {useOnline} from './useConnectivity';

export interface NeedsConnectionProps {
  /** The online-only control (a tool chip, a row of the + sheet). */
  children: React.ReactNode;
  /** Put "Needs a connection" under the control (rows) or leave it out (chips). */
  label?: boolean;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * Wraps a control that needs the internet. Online it is just the control.
 * Offline the control is greyed, cannot be pressed, and says why.
 */
export function NeedsConnection({
  children,
  label = true,
  style,
  testID,
}: NeedsConnectionProps) {
  const t = useT();
  const online = useOnline();
  if (online) {
    return <>{children}</>;
  }
  return (
    <View
      testID={testID}
      accessible
      accessibilityState={{disabled: true}}
      accessibilityHint={t('connectivity.needsConnection')}
      style={style}>
      <View pointerEvents="none" style={styles.dimmed}>
        {children}
      </View>
      {label ? (
        <Text variant="caption" color="textTertiary" style={styles.label}>
          {t('connectivity.needsConnection')}
        </Text>
      ) : null}
    </View>
  );
}

export interface OfflineAnswerNoteProps {
  /** Runs the search again; shown as available once the phone is online. */
  onRetry: () => void;
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * One line under an answer that wanted to search while offline, with a retry
 * that only works once the connection is back.
 */
export function OfflineAnswerNote({
  onRetry,
  style,
  testID = 'offline-answer-note',
}: OfflineAnswerNoteProps) {
  const t = useT();
  const online = useOnline();
  return (
    <View testID={testID} style={[styles.note, style]}>
      <Icon name="offline" size={16} color="textSecondary" />
      <Text variant="footnote" color="textSecondary" style={styles.grow}>
        {t('connectivity.wantedSearch')}
      </Text>
      <PressableScale
        testID={`${testID}-retry`}
        accessibilityRole="button"
        accessibilityLabel={t('connectivity.searchWhenOnline')}
        accessibilityState={{disabled: !online}}
        disabled={!online}
        hitSlop={10}
        onPress={() => {
          if (online) {
            onRetry();
          } else {
            getPorts()
              .connectivity.refresh()
              .catch(() => {});
          }
        }}>
        <Text
          variant="footnote"
          color={online ? 'textPrimary' : 'textTertiary'}
          style={styles.action}>
          {t('connectivity.searchWhenOnline')}
        </Text>
      </PressableScale>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  dimmed: {
    opacity: 0.4,
  },
  label: {
    marginTop: theme.spacing.xxs,
    paddingHorizontal: theme.spacing.md,
  },
  note: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
  },
  grow: {
    flex: 1,
  },
  action: {
    fontWeight: '600',
  },
}));
