import React, {useCallback, useEffect, useSyncExternalStore} from 'react';
import {FlatList, Keyboard, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ConversationPort, SearchHit} from '../../contracts';
import {useT} from '../../locales';
import {Icon, PressableScale, Text} from '../primitives';
import {shortDate} from './dates';
import {Highlighted} from './Highlighted';
import {recentSearches} from './recentSearches';
import {useChatSearch} from './useChatSearch';

export interface SearchPanelProps {
  port: ConversationPort;
  query: string;
  /** Chats waiting out an undo: not shown. */
  hidden?: ReadonlySet<string>;
  onOpen: (hit: SearchHit, query: string) => void;
  /** A recent search was tapped: put it in the field. */
  onPickRecent: (query: string) => void;
  now?: number;
}

/**
 * What the drawer shows while the search field is in use: recent searches
 * under an empty field, results as soon as something is typed.
 */
export function SearchPanel({
  port,
  query,
  hidden,
  onOpen,
  onPickRecent,
  now,
}: SearchPanelProps) {
  const t = useT();
  const recent = useSyncExternalStore(
    recentSearches.subscribe,
    recentSearches.list,
    recentSearches.list,
  );
  useEffect(() => {
    recentSearches.load().catch(() => {});
  }, []);

  const trimmed = query.trim();
  const {hits, answeredQuery, pending} = useChatSearch(port, query, hidden);
  const today = now ?? Date.now();

  const renderHit = useCallback(
    ({item}: {item: SearchHit}) => (
      <SearchResultRow
        hit={item}
        date={shortDate(item.conversation.updatedAt, today, {
          today: t('drawer.today'),
          yesterday: t('drawer.yesterday'),
        })}
        onPress={() => onOpen(item, trimmed)}
      />
    ),
    [onOpen, t, today, trimmed],
  );

  if (!trimmed) {
    if (recent.length === 0) {
      return (
        <View testID="search-empty" style={styles.message}>
          <Icon name="search" size={28} color="textTertiary" />
          <Text variant="callout" color="textSecondary" align="center">
            {t('search.hint')}
          </Text>
        </View>
      );
    }
    return (
      <View testID="search-recent" style={styles.fill}>
        <View style={styles.recentHeader}>
          <Text
            variant="footnote"
            color="textTertiary"
            accessibilityRole="header">
            {t('search.recent')}
          </Text>
          <PressableScale
            testID="search-recent-clear"
            accessibilityRole="button"
            accessibilityLabel={t('search.clearRecent')}
            hitSlop={12}
            onPress={() => recentSearches.clear()}>
            <Text variant="footnote" color="textSecondary">
              {t('search.clear')}
            </Text>
          </PressableScale>
        </View>
        {recent.map((item, index) => (
          <View key={item} style={styles.recentRow}>
            <PressableScale
              testID={`search-recent-${index}`}
              accessibilityRole="button"
              accessibilityLabel={t('search.searchFor', {query: item})}
              scale={false}
              onPress={() => onPickRecent(item)}
              style={styles.recentMain}>
              <Icon name="recent" size={18} color="textTertiary" />
              <Text numberOfLines={1} style={styles.recentText}>
                {item}
              </Text>
            </PressableScale>
            <PressableScale
              accessibilityRole="button"
              accessibilityLabel={t('common.remove', {name: item})}
              hitSlop={10}
              onPress={() => recentSearches.remove(item)}
              style={styles.recentRemove}>
              <Icon name="close" size={16} color="textTertiary" />
            </PressableScale>
          </View>
        ))}
      </View>
    );
  }

  // Nothing found, and the answer on screen belongs to what is typed now.
  if (hits.length === 0 && !pending && answeredQuery === trimmed) {
    return (
      <View testID="search-no-results" style={styles.message}>
        <Text variant="bodyStrong" align="center">
          {t('search.noResultsTitle')}
        </Text>
        <Text variant="callout" color="textSecondary" align="center">
          {t('drawer.noResults', {query: trimmed})}
        </Text>
      </View>
    );
  }

  return (
    <FlatList
      testID="search-results"
      data={hits}
      keyExtractor={hit => hit.conversation.id}
      renderItem={renderHit}
      keyboardShouldPersistTaps="handled"
      keyboardDismissMode="on-drag"
      onScrollBeginDrag={Keyboard.dismiss}
      showsVerticalScrollIndicator={false}
      contentContainerStyle={styles.results}
      initialNumToRender={12}
      windowSize={7}
    />
  );
}

function SearchResultRow({
  hit,
  date,
  onPress,
}: {
  hit: SearchHit;
  date: string;
  onPress: () => void;
}) {
  const t = useT();
  const title = hit.conversation.title || t('shell.untitledChat');
  // Without a snippet the ranges belong to the title.
  const titleMatches = hit.snippet ? hit.titleMatches : hit.matches;
  return (
    <PressableScale
      testID={`search-hit-${hit.conversation.id}`}
      accessibilityRole="button"
      accessibilityLabel={[title, hit.snippet, date].filter(Boolean).join(', ')}
      scale={false}
      onPress={onPress}
      style={styles.hit}>
      <View style={styles.hitTop}>
        <View style={styles.hitTitle}>
          <Highlighted text={title} matches={titleMatches} numberOfLines={1} />
        </View>
        <Text variant="footnote" color="textTertiary" numberOfLines={1}>
          {date}
        </Text>
      </View>
      {hit.snippet ? (
        <Highlighted
          text={hit.snippet}
          matches={hit.matches}
          variant="callout"
          color="textSecondary"
          matchColor="textPrimary"
          numberOfLines={2}
        />
      ) : null}
    </PressableScale>
  );
}

const styles = StyleSheet.create(theme => ({
  fill: {
    flex: 1,
    paddingHorizontal: theme.spacing.sm,
  },
  message: {
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingTop: theme.spacing.huge + theme.spacing.xl,
    paddingHorizontal: theme.spacing.xxl,
  },
  recentHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: theme.spacing.md,
    paddingTop: theme.spacing.lg,
    paddingBottom: theme.spacing.xs,
  },
  recentRow: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  recentMain: {
    flex: 1,
    minHeight: theme.sizes.hitTarget,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm,
  },
  recentText: {
    flex: 1,
  },
  recentRemove: {
    width: theme.sizes.hitTarget,
    height: theme.sizes.hitTarget,
    alignItems: 'center',
    justifyContent: 'center',
  },
  results: {
    paddingHorizontal: theme.spacing.sm,
    paddingTop: theme.spacing.xs,
    paddingBottom: theme.spacing.xxl,
  },
  hit: {
    gap: theme.spacing.xxs,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm + theme.spacing.xxs,
    borderRadius: theme.radii.md,
    borderCurve: 'continuous',
  },
  hitTop: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: theme.spacing.sm,
  },
  hitTitle: {
    flex: 1,
  },
}));
