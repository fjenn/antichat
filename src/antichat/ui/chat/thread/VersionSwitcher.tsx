import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../../locales';
import {Icon, PressableScale, Text} from '../../primitives';

export interface VersionSwitcherProps {
  index: number;
  count: number;
  disabled?: boolean;
  onChange: (index: number) => void;
  testID?: string;
}

/** "‹ 2/3 ›": steps through the versions of an answer or an edited message. */
export function VersionSwitcher({
  index,
  count,
  disabled = false,
  onChange,
  testID,
}: VersionSwitcherProps) {
  const t = useT();
  const canBack = !disabled && index > 0;
  const canForward = !disabled && index < count - 1;
  return (
    <View
      testID={testID}
      accessible
      accessibilityRole="adjustable"
      accessibilityLabel={t('thread.versionOf', {index: index + 1, count})}
      accessibilityActions={[{name: 'increment'}, {name: 'decrement'}]}
      onAccessibilityAction={event => {
        if (event.nativeEvent.actionName === 'increment' && canForward) {
          onChange(index + 1);
        } else if (event.nativeEvent.actionName === 'decrement' && canBack) {
          onChange(index - 1);
        }
      }}
      style={styles.row}>
      <PressableScale
        testID={testID ? `${testID}-previous` : undefined}
        accessibilityLabel={t('thread.previousVersion')}
        disabled={!canBack}
        haptic
        hitSlop={8}
        onPress={() => onChange(index - 1)}
        style={styles.step}>
        <Icon
          name="chevronBack"
          size={18}
          color={canBack ? 'textSecondary' : 'textTertiary'}
        />
      </PressableScale>
      <Text
        testID={testID ? `${testID}-label` : undefined}
        variant="footnote"
        color="textSecondary"
        style={styles.label}>
        {index + 1}/{count}
      </Text>
      <PressableScale
        testID={testID ? `${testID}-next` : undefined}
        accessibilityLabel={t('thread.nextVersion')}
        disabled={!canForward}
        haptic
        hitSlop={8}
        onPress={() => onChange(index + 1)}
        style={styles.step}>
        <Icon
          name="chevronForward"
          size={18}
          color={canForward ? 'textSecondary' : 'textTertiary'}
        />
      </PressableScale>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    minHeight: 36,
  },
  step: {
    width: 24,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  label: {
    minWidth: 28,
    textAlign: 'center',
    fontVariant: ['tabular-nums'],
    fontWeight: '500',
    paddingHorizontal: theme.spacing.xxs,
  },
}));
