import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {devToolsEnabled} from '../../app/flags';
import {Keyboard, View, type TextInput} from 'react-native';
import {
  useDrawerStatus,
  type DrawerContentComponentProps,
} from '@react-navigation/drawer';
import {LegendList, type LegendListRef} from '@legendapp/list/react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {shellSession} from '../../app/session';
import type {ConversationView, SearchHit} from '../../contracts';
import {useT} from '../../locales';
import {lockState} from '../chatmenu/lockState';
import {
  Icon,
  IconButton,
  PressableScale,
  Skeleton,
  Text,
  TextField,
} from '../primitives';
import {recentSearches} from '../search/recentSearches';
import {SearchPanel} from '../search/SearchPanel';
import {ChatRow, type ChatRowAction} from './ChatRow';
import {
  archiveChat,
  deleteChat,
  openChat,
  renameChat,
  shareChat,
  togglePin,
} from './historyActions';
import {historyUi} from './historyUi';
import {ProfileRow} from './ProfileRow';
import {buildDrawerItems, monthName, type DrawerItem} from './sections';
import {V1} from '../../app/scope';
import {drawerShortcuts, subscribeDrawerShortcuts} from './shortcuts';
import {closeOpenSwipeRow} from './SwipeActions';

type Navigation = DrawerContentComponentProps['navigation'];

/** Rough row height before a row has been measured. */
const ESTIMATED_ROW = 46;

/**
 * The drawer: search, new chat, shortcut rows, pinned chats, the history in
 * date groups, and the profile row that leads to Settings. While the search
 * field is in use the list gives way to recent searches and results.
 */
export const DrawerContent = observer(function Drawer({
  navigation,
}: DrawerContentComponentProps) {
  const t = useT();
  const {conversations} = getPorts();
  const all = usePort(conversations, port => port.conversations);
  const loaded = usePort(
    conversations,
    port => (port as {loaded?: boolean}).loaded ?? true,
  );
  const shortcuts = useSyncExternalStore(
    subscribeDrawerShortcuts,
    drawerShortcuts,
    drawerShortcuts,
  );

  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const field = useRef<React.ComponentRef<typeof TextInput>>(null);
  const list = useRef<LegendListRef>(null);

  const activeId = shellSession.activeConversationId;
  const renamingId = historyUi.renamingRowId;
  const pendingDeletes = historyUi.pendingDeleteIds;
  const lockVersion = lockState.version;

  // The clock only matters at day boundaries; read it when the list changes.
  const items = useMemo(
    () =>
      buildDrawerItems(
        all,
        Date.now(),
        {
          pinned: t('drawer.pinned'),
          today: t('drawer.today'),
          yesterday: t('drawer.yesterday'),
          previous7Days: t('drawer.previous7Days'),
          previous30Days: t('drawer.previous30Days'),
          month: monthName,
        },
        pendingDeletes,
      ),
    [all, pendingDeletes, t],
  );

  const endSearch = useCallback(() => {
    setQuery('');
    setSearching(false);
    field.current?.blur();
    Keyboard.dismiss();
  }, []);

  // A closed drawer is a fresh drawer the next time it opens.
  const status = useDrawerStatus();
  useEffect(() => {
    if (status === 'closed') {
      endSearch();
      closeOpenSwipeRow();
      historyUi.startRowRename(null);
    }
  }, [endSearch, status]);

  const showChat = useCallback(() => {
    navigation.navigate('Main', {screen: 'Chat'});
    navigation.closeDrawer();
  }, [navigation]);

  const startNewChat = useCallback(() => {
    shellSession.newChat();
    showChat();
  }, [showChat]);

  const onRowAction = useCallback(
    (action: ChatRowAction, conversation: ConversationView) => {
      switch (action) {
        case 'open':
          openChat(conversation)
            .then(opened => {
              if (opened) {
                showChat();
              }
            })
            .catch(() => {});
          break;
        case 'share':
          shareChat(conversation);
          break;
        case 'rename':
          closeOpenSwipeRow();
          historyUi.startRowRename(conversation.id);
          break;
        case 'pin':
          togglePin(conversation);
          break;
        case 'archive':
          archiveChat(conversation);
          break;
        case 'delete':
          deleteChat(conversation);
          break;
      }
    },
    [showChat],
  );

  const onRenameDone = useCallback(
    (conversation: ConversationView, title: string | null) => {
      historyUi.startRowRename(null);
      if (title !== null) {
        renameChat(conversation, title);
      }
    },
    [],
  );

  // The row being renamed must sit above the keyboard.
  useEffect(() => {
    if (!renamingId) {
      return;
    }
    const index = items.findIndex(item => item.key === renamingId);
    if (index >= 0) {
      list.current?.scrollToIndex({index, animated: true, viewPosition: 0.15});
    }
    // Only when a rename starts, not while the list changes under it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [renamingId]);

  const openHit = useCallback(
    (hit: SearchHit, typed: string) => {
      recentSearches.add(typed);
      openChat(hit.conversation, {messageId: hit.messageId, query: typed})
        .then(opened => {
          if (opened) {
            showChat();
          }
        })
        .catch(() => {});
    },
    [showChat],
  );

  const renderItem = useCallback(
    ({item}: {item: DrawerItem}) =>
      item.kind === 'header' ? (
        <Text
          variant="footnote"
          color="textTertiary"
          accessibilityRole="header"
          style={styles.sectionTitle}>
          {item.title}
        </Text>
      ) : (
        <ChatRow
          conversation={item.conversation}
          selected={activeId === item.conversation.id}
          renaming={renamingId === item.conversation.id}
          unlocked={
            item.conversation.locked &&
            lockState.isUnlocked(item.conversation.id)
          }
          onAction={onRowAction}
          onRenameDone={onRenameDone}
        />
      ),
    // `lockVersion` re-renders the rows when a chat is unlocked.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [activeId, lockVersion, onRenameDone, onRowAction, renamingId],
  );

  const header = (
    <View style={styles.shortcuts}>
      <ShortcutRow
        testID="drawer-new-chat-row"
        icon="newChat"
        title={t('shell.newChat')}
        onPress={startNewChat}
      />
      {(V1.drawerShortcuts ? shortcuts : []).map(shortcut => (
        <ShortcutRow
          key={shortcut.id}
          testID={`drawer-shortcut-${shortcut.id}`}
          icon={shortcut.icon}
          title={shortcut.title()}
          onPress={() => shortcut.onPress(navigation)}
        />
      ))}
    </View>
  );

  const inSearch = searching || query.length > 0;

  return (
    <View testID="drawer" style={styles.container}>
      <View style={styles.top}>
        <TextField
          ref={field}
          testID="drawer-search"
          shape="pill"
          icon="search"
          clearable
          value={query}
          onChangeText={setQuery}
          onFocus={() => {
            closeOpenSwipeRow();
            setSearching(true);
          }}
          placeholder={t('drawer.search')}
          returnKeyType="search"
          autoCorrect={false}
          autoCapitalize="none"
          containerStyle={styles.search}
        />
        {inSearch ? (
          <PressableScale
            testID="drawer-search-cancel"
            accessibilityRole="button"
            accessibilityLabel={t('common.cancel')}
            hitSlop={8}
            onPress={endSearch}
            style={styles.cancel}>
            <Text variant="body" numberOfLines={1}>
              {t('common.cancel')}
            </Text>
          </PressableScale>
        ) : (
          <IconButton
            testID="drawer-new-chat"
            icon="newChat"
            accessibilityLabel={t('shell.newChat')}
            onPress={startNewChat}
          />
        )}
      </View>

      {inSearch ? (
        <View style={styles.body}>
          <SearchPanel
            port={conversations}
            query={query}
            hidden={pendingDeletes}
            onOpen={openHit}
            onPickRecent={setQuery}
          />
        </View>
      ) : (
        <LegendList
          ref={list}
          testID="drawer-list"
          data={items}
          renderItem={renderItem}
          keyExtractor={keyOf}
          getItemType={typeOf}
          estimatedItemSize={ESTIMATED_ROW}
          recycleItems
          extraData={`${activeId}|${renamingId}|${lockVersion}`}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
          onScrollBeginDrag={() => {
            closeOpenSwipeRow();
            if (devToolsEnabled()) {
              require('./dev/perfProbe').perfProbe.onScroll(items.length);
            }
          }}
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.list}
          style={styles.body}
          ListHeaderComponent={header}
          ListEmptyComponent={
            loaded ? (
              <View testID="drawer-empty" style={styles.empty}>
                <Icon name="temporary" size={28} color="textTertiary" />
                <Text variant="callout" color="textSecondary" align="center">
                  {t('drawer.empty')}
                </Text>
              </View>
            ) : (
              <View
                accessibilityLabel={t('common.loading')}
                style={styles.loading}>
                <Skeleton width="62%" />
                <Skeleton width="84%" />
                <Skeleton width="48%" />
                <Skeleton width="70%" />
              </View>
            )
          }
        />
      )}

      {inSearch ? null : (
        <View style={styles.footer}>
          <ProfileRow
            onPress={() => {
              navigation.navigate('Main', {screen: 'Settings'});
              navigation.closeDrawer();
            }}
          />
        </View>
      )}
    </View>
  );
});

function keyOf(item: DrawerItem): string {
  return item.key;
}

function typeOf(item: DrawerItem): string {
  return item.kind;
}

function ShortcutRow({
  icon,
  title,
  onPress,
  testID,
}: {
  icon: React.ComponentProps<typeof Icon>['name'];
  title: string;
  onPress: () => void;
  testID?: string;
}) {
  return (
    <PressableScale
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={title}
      scale={false}
      onPress={onPress}
      style={styles.shortcut}>
      <Icon name={icon} size={20} />
      <Text variant="body" numberOfLines={1} style={styles.shortcutTitle}>
        {title}
      </Text>
    </PressableScale>
  );
}

export type {Navigation as DrawerNavigation};

const styles = StyleSheet.create((theme, rt) => ({
  container: {
    flex: 1,
    backgroundColor: theme.colors.drawer,
    paddingTop: rt.insets.top + theme.spacing.xs,
  },
  top: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingStart: theme.spacing.lg,
    paddingEnd: theme.spacing.sm,
    paddingBottom: theme.spacing.sm,
  },
  search: {
    flex: 1,
  },
  cancel: {
    minHeight: theme.sizes.hitTarget,
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.sm,
  },
  body: {
    flex: 1,
  },
  list: {
    paddingHorizontal: theme.spacing.sm,
    paddingBottom: theme.spacing.lg,
  },
  shortcuts: {
    paddingBottom: theme.spacing.xs,
  },
  shortcut: {
    minHeight: theme.sizes.hitTarget,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm + theme.spacing.xxs,
    borderRadius: theme.radii.md,
  },
  shortcutTitle: {
    flex: 1,
  },
  sectionTitle: {
    paddingHorizontal: theme.spacing.md,
    paddingTop: theme.spacing.lg,
    paddingBottom: theme.spacing.xs,
  },
  empty: {
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingTop: theme.spacing.huge,
    paddingHorizontal: theme.spacing.xl,
  },
  loading: {
    gap: theme.spacing.xl,
    paddingTop: theme.spacing.xl,
    paddingHorizontal: theme.spacing.md,
  },
  footer: {
    paddingHorizontal: theme.spacing.sm,
    paddingTop: theme.spacing.xs,
    paddingBottom: rt.insets.bottom + theme.spacing.xs,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: theme.colors.border,
  },
}));
