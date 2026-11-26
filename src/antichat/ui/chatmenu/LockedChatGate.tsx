import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ConversationView} from '../../contracts';
import {useT} from '../../locales';
import {Button, Icon, Text} from '../primitives';
import {unlockChat} from './lockState';

/**
 * Shown in place of the thread while a locked chat has not been unlocked:
 * after the app comes back from the background, or when a link opened the
 * chat directly.
 */
export function LockedChatGate({
  conversation,
}: {
  conversation: ConversationView;
}) {
  const t = useT();
  return (
    <View testID="locked-gate" style={styles.gate}>
      <View style={styles.badge}>
        <Icon name="lock" size={28} />
      </View>
      <Text variant="title" align="center" accessibilityRole="header">
        {t('lock.gateTitle')}
      </Text>
      <Text variant="callout" color="textSecondary" align="center">
        {t('lock.gateBody')}
      </Text>
      <Button
        testID="locked-gate-unlock"
        label={t('lock.unlock')}
        icon="unlock"
        onPress={() => {
          unlockChat(conversation.id).catch(() => {});
        }}
        style={styles.button}
      />
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  gate: {
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
  button: {
    alignSelf: 'center',
    marginTop: theme.spacing.lg,
  },
}));
