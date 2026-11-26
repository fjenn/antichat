import React from 'react';
import type {StyleProp, ViewStyle} from 'react-native';
import Animated, {
  FadeIn,
  FadeOut,
  useReducedMotion,
} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../locales';
import {Icon, Text} from '../primitives';
import {useOnline} from './useConnectivity';

export interface OfflinePillProps {
  style?: StyleProp<ViewStyle>;
  testID?: string;
}

/**
 * A small "Offline" pill for the top bar. It is the whole offline message:
 * no banner, no dialog, because chat keeps working. Draws nothing online.
 */
export function OfflinePill({
  style,
  testID = 'offline-pill',
}: OfflinePillProps) {
  const t = useT();
  const online = useOnline();
  const reduceMotion = useReducedMotion();
  if (online) {
    return null;
  }
  return (
    <Animated.View
      testID={testID}
      accessible
      accessibilityRole="text"
      accessibilityLabel={t('connectivity.offlineLabel')}
      accessibilityLiveRegion="polite"
      entering={reduceMotion ? undefined : FadeIn.duration(200)}
      exiting={reduceMotion ? undefined : FadeOut.duration(200)}
      style={[styles.pill, style]}>
      <Icon name="offline" size={13} color="textSecondary" strokeWidth={2.2} />
      <Text
        variant="caption"
        color="textSecondary"
        numberOfLines={1}
        maxFontSizeMultiplier={1.3}>
        {t('connectivity.offline')}
      </Text>
    </Animated.View>
  );
}

const styles = StyleSheet.create(theme => ({
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.sm + theme.spacing.xxs,
    paddingVertical: theme.spacing.xs,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.surface,
  },
}));
