import React from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import type {ConnectorsStore} from '../../engine/mcp/store';
import {Button, Icon, Text, toast} from '../primitives';
import {AppLogo} from './AppLogo';
import {s} from './strings';

export interface ConnectAppCardProps {
  store: ConnectorsStore;
  /** Toolkit slug; null = an app the directory does not have. */
  slug: string | null;
  name: string;
  /** Called once the app is connected (the chat runs the request again). */
  onConnected?: () => void;
  /** Opens the Connectors screen, for an app that is not in the list. */
  onOpenConnectors?: () => void;
  /** Without the card's own background, for use inside a sheet. */
  plain?: boolean;
  testID?: string;
}

/**
 * The card a chat shows when the model needs an app that is not connected
 * (the `connect_app` tool, or a plain "connect my Gmail"). One button starts
 * the hosted sign-in; the card follows the connection state by itself.
 */
export const ConnectAppCard = observer(function ConnectCard({
  store,
  slug,
  name,
  onConnected,
  onOpenConnectors,
  plain = false,
  testID = 'connect-card',
}: ConnectAppCardProps) {
  const online = store.online;
  const connected = slug ? store.isConnected(slug) : false;
  const connecting = !!slug && store.connecting === slug;
  const logo = slug
    ? store.toolkits.find(toolkit => toolkit.slug === slug)?.logo
    : undefined;

  const connect = async () => {
    if (!slug) {
      return;
    }
    const done = await store.connect(slug);
    if (done) {
      toast.show({message: s.connectedToast(name), kind: 'success'});
      onConnected?.();
    } else if (!store.error) {
      toast.show({message: s.notConnectedToast(name)});
    }
  };

  return (
    <View testID={testID} style={plain ? styles.plain : styles.card}>
      <View style={styles.head}>
        <AppLogo name={name} uri={online ? logo : undefined} size={44} />
        <View style={styles.texts}>
          <Text variant="headline" numberOfLines={1}>
            {connected ? name : s.cardTitle(name)}
          </Text>
          <Text variant="footnote" color="textSecondary">
            {connected
              ? s.connected
              : slug
                ? s.cardSubtitle(name)
                : s.cardUnknown(name)}
          </Text>
        </View>
        {connected ? <Icon name="check" size={22} color="success" /> : null}
      </View>
      {connected ? null : !slug ? (
        <Button
          testID={`${testID}-open`}
          label={s.openConnectors}
          variant="secondary"
          fullWidth
          onPress={onOpenConnectors}
        />
      ) : connecting ? (
        <View style={styles.actions}>
          <Button
            testID={`${testID}-waiting`}
            label={s.waiting}
            loading
            fullWidth
            style={styles.grow}
          />
          <Button
            testID={`${testID}-cancel`}
            label={s.cancel}
            variant="ghost"
            onPress={() => store.cancelConnecting()}
          />
        </View>
      ) : (
        <Button
          testID={`${testID}-connect`}
          label={online ? s.connect : s.offline}
          icon={online ? undefined : 'offline'}
          disabled={!online || !!store.connecting}
          fullWidth
          onPress={connect}
        />
      )}
      {!connected && store.error && !connecting ? (
        <Text variant="footnote" color="danger" accessibilityRole="alert">
          {store.error}
        </Text>
      ) : null}
    </View>
  );
});

const styles = StyleSheet.create(theme => ({
  card: {
    gap: theme.spacing.md,
    padding: theme.spacing.lg,
    borderRadius: theme.radii.xl,
    backgroundColor: theme.colors.surface,
    maxWidth: 420,
  },
  plain: {
    gap: theme.spacing.lg,
  },
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
  },
  grow: {
    flex: 1,
  },
}));
