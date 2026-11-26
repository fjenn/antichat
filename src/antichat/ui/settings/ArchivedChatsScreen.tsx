import React from 'react';
import {View} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {shellSession} from '../../app/session';
import {useT} from '../../locales';
import {
  ContextMenu,
  IconButton,
  PressableScale,
  Text,
  toast,
} from '../primitives';
import {Group, SettingsPage} from './components';
import {EmptyState} from './EmptyState';

/** Archived chats: open one, move it back to the list, or delete it. */
export function ArchivedChatsScreen() {
  const t = useT();
  const navigation = useNavigation();
  const conversations = getPorts().conversations;
  const archived = usePort(conversations, port => port.archived());
  const act = (id: string, action: string) => {
    if (action === 'unarchive') {
      conversations
        .setArchived(id, false)
        .then(() => toast.show({message: t('settings.data_.unarchived')}))
        .catch(() => {});
    } else if (action === 'delete') {
      conversations
        .remove(id)
        .then(() => toast.show({message: t('toast.chatDeleted')}))
        .catch(() => {});
    }
  };
  return (
    <SettingsPage
      testID="settings-archived-page"
      title={t('settings.data_.archived')}>
      {archived.length === 0 ? (
        <EmptyState
          icon="archive"
          title={t('settings.data_.archivedEmpty')}
          hint={t('settings.data_.archivedEmptyHint')}
        />
      ) : (
        <Group>
          {archived.map(chat => (
            <View key={chat.id} style={styles.row}>
              <PressableScale
                testID={`archived-${chat.id}`}
                accessibilityRole="button"
                accessibilityLabel={chat.title}
                scale={false}
                onPress={() => {
                  shellSession.open(chat.id);
                  navigation.navigate('Main', {screen: 'Chat'});
                }}
                style={styles.title}>
                <Text numberOfLines={1}>
                  {chat.title || t('shell.untitledChat')}
                </Text>
              </PressableScale>
              <ContextMenu
                items={[
                  {
                    id: 'unarchive',
                    title: t('settings.data_.unarchive'),
                    icon: 'archive',
                  },
                  {
                    id: 'delete',
                    title: t('chatRow.delete'),
                    icon: 'delete',
                    destructive: true,
                  },
                ]}
                onSelect={action => act(chat.id, action)}>
                <IconButton
                  testID={`archived-more-${chat.id}`}
                  icon="more"
                  size={36}
                  iconSize={18}
                  accessibilityLabel={t('shell.moreActions')}
                />
              </ContextMenu>
            </View>
          ))}
        </Group>
      )}
    </SettingsPage>
  );
}

const styles = StyleSheet.create(theme => ({
  row: {
    minHeight: 54,
    flexDirection: 'row',
    alignItems: 'center',
    paddingEnd: theme.spacing.sm,
  },
  title: {
    flex: 1,
    alignSelf: 'stretch',
    justifyContent: 'center',
    paddingStart: theme.spacing.lg,
    paddingEnd: theme.spacing.sm,
  },
}));
