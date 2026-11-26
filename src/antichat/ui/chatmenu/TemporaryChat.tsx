import React from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {shellSession} from '../../app/session';
import {useT} from '../../locales';
import {Icon, PressableScale, Text, haptics} from '../primitives';

/** Switches the new, still empty chat between normal and temporary. */
export function setTemporaryChat(on: boolean): void {
  // `installShellBridge` passes the switch on to the store.
  shellSession.setTemporary(on);
}

/**
 * The toggle in the top bar of a new chat: an outlined speech bubble that
 * fills in when the chat is temporary.
 */
export const TemporaryToggle = observer(function TemporaryChatToggle() {
  const t = useT();
  const {theme} = useUnistyles();
  const on = shellSession.temporary;
  return (
    <PressableScale
      testID="temporary-toggle"
      accessibilityRole="switch"
      accessibilityLabel={t('temporary.toggle')}
      accessibilityHint={t('temporary.hint')}
      accessibilityState={{checked: on}}
      onPress={() => {
        haptics.selection();
        setTemporaryChat(!on);
      }}
      style={styles.toggle}>
      <View
        style={[
          styles.toggleInner,
          // Inline: on Android a swapped Unistyles style lost its radius.
          {
            borderRadius: 17,
            backgroundColor: on ? theme.colors.textPrimary : 'transparent',
          },
        ]}>
        <Icon
          name="temporary"
          size={20}
          color={on ? 'background' : 'textPrimary'}
        />
      </View>
    </PressableScale>
  );
});

/** What the empty screen says once the new chat is temporary. */
export function TemporaryIntro() {
  const t = useT();
  return (
    <View testID="temporary-intro" style={styles.intro}>
      <View style={styles.badge}>
        <Icon name="temporary" size={28} />
      </View>
      <Text variant="title" align="center" accessibilityRole="header">
        {t('temporary.title')}
      </Text>
      <Text variant="callout" color="textSecondary" align="center">
        {t('temporary.body')}
      </Text>
    </View>
  );
}

/** The small label under the top bar while a temporary chat is open. */
export function TemporaryBadge() {
  const t = useT();
  return (
    <View
      testID="temporary-badge"
      accessible
      accessibilityLabel={`${t('temporary.title')}. ${t('temporary.hint')}`}
      style={styles.chip}>
      <Icon name="temporary" size={14} color="textSecondary" />
      <Text variant="caption" color="textSecondary" numberOfLines={1}>
        {t('temporary.title')}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  toggle: {
    width: theme.sizes.hitTarget,
    height: theme.sizes.hitTarget,
    alignItems: 'center',
    justifyContent: 'center',
  },
  toggleInner: {
    width: 34,
    height: 34,
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  intro: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.xxxl,
  },
  badge: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: theme.spacing.sm,
    backgroundColor: theme.colors.surface,
  },
  chip: {
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.xs,
    borderRadius: theme.radii.pill,
    backgroundColor: theme.colors.surface,
  },
}));
