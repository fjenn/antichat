import React, {useCallback} from 'react';
import {FlatList, View} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {ScreenHeader} from '../../app/screens/ScreenHeader';
import type {ConversationView} from '../../contracts';
import {useT} from '../../locales';
import {lockState} from '../chatmenu/lockState';
import {Icon, Text} from '../primitives';
import {shortDate} from '../search/dates';
import {ChatRow, type ChatRowAction} from './ChatRow';
import {deleteChat, openChat, unarchiveChat} from './historyActions';
import {historyUi} from './historyUi';
import {closeOpenSwipeRow} from './SwipeActions';

/**
 * Archived chats: out of the drawer and out of search, kept until deleted.
 * Tap reads one; swipe or touch and hold to bring it back or delete it.
 * Settings → Data controls links here (M6).
 */
export const ArchivedChatsScreen = observer(function ArchivedChats() {
  const t = useT();
  const navigation = useNavigation();
  const {conversations} = getPorts();
  const archived = usePort(conversations, port => port.archived());
  const pending = historyUi.pendingDeleteIds;
  const lockVersion = lockState.version;
  const rows = archived.filter(conversation => !pending.has(conversation.id));
  const now = Date.now();

  const onAction = useCallback(
    (action: ChatRowAction, conversation: ConversationView) => {
      switch (action) {
        case 'open':
          openChat(conversation)
            .then(opened => {
              if (opened) {
                navigation.navigate('Main', {screen: 'Chat'});
              }
            })
            .catch(() => {});
          break;
        case 'unarchive':
          unarchiveChat(conversation);
          break;
        case 'delete':
          deleteChat(conversation);
          break;
      }
    },
    [navigation],
  );

  return (
    <View testID="archived-chats" style={styles.screen}>
      <ScreenHeader title={t('archive.title')} />
      <FlatList
        testID="archived-list"
        data={rows}
        extraData={lockVersion}
        keyExtractor={conversation => conversation.id}
        onScrollBeginDrag={closeOpenSwipeRow}
        contentContainerStyle={styles.list}
        renderItem={({item}) => (
          <ChatRow
            conversation={item}
            variant="archive"
            unlocked={item.locked && lockState.isUnlocked(item.id)}
            detail={shortDate(item.updatedAt, now, {
              today: t('drawer.today'),
              yesterday: t('drawer.yesterday'),
            })}
            onAction={onAction}
            onRenameDone={noop}
          />
        )}
        ListEmptyComponent={
          <View testID="archived-empty" style={styles.empty}>
            <Icon name="archive" size={28} color="textTertiary" />
            <Text variant="bodyStrong" align="center">
              {t('archive.emptyTitle')}
            </Text>
            <Text variant="callout" color="textSecondary" align="center">
              {t('archive.emptyBody')}
            </Text>
          </View>
        }
      />
    </View>
  );
});

function noop(): void {}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  list: {
    paddingHorizontal: theme.spacing.sm,
    paddingBottom: rt.insets.bottom + theme.spacing.xl,
  },
  empty: {
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingTop: theme.spacing.huge + theme.spacing.xl,
    paddingHorizontal: theme.spacing.xxxl,
  },
}));
