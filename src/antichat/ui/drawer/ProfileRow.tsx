import React, {useEffect, useSyncExternalStore} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {
  getPersonalization,
  loadPersonalization,
  subscribePersonalization,
} from '../../engine/prompt/personalization';
import {useT} from '../../locales';
import {Icon, PressableScale, Text} from '../primitives';

function nickname(): string {
  return getPersonalization().nickname.trim();
}

/** First letters of up to two words: "Ada Lovelace" → "AL". */
export function initialsOf(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map(word => Array.from(word)[0]?.toUpperCase() ?? '')
    .join('');
}

/**
 * The row at the foot of the drawer: who is using the app, and the way into
 * Settings. There is no account; the name is the one the user gave under
 * Personalization, and without one the row simply says "Settings".
 */
export function ProfileRow({onPress}: {onPress: () => void}) {
  const t = useT();
  const name = useSyncExternalStore(
    subscribePersonalization,
    nickname,
    nickname,
  );
  useEffect(() => {
    loadPersonalization().catch(() => {});
  }, []);

  return (
    <PressableScale
      testID="drawer-settings"
      accessibilityRole="button"
      accessibilityLabel={
        name ? `${name}, ${t('drawer.settings')}` : t('drawer.settings')
      }
      scale={false}
      onPress={onPress}
      style={styles.row}>
      <View style={styles.avatar}>
        {name ? (
          <Text variant="caption" color="onAccent" maxFontSizeMultiplier={1.2}>
            {initialsOf(name)}
          </Text>
        ) : (
          <Icon name="user" size={16} color="onAccent" />
        )}
      </View>
      <Text variant="bodyStrong" numberOfLines={1} style={styles.name}>
        {name || t('drawer.settings')}
      </Text>
      <Icon name="settings" size={20} color="textSecondary" />
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  row: {
    minHeight: theme.sizes.row,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.md,
  },
  avatar: {
    width: 32,
    height: 32,
    borderRadius: 16,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors.accent,
  },
  name: {
    flex: 1,
  },
}));
