import React, {useMemo, useRef, useState} from 'react';
import {FlatList, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {
  Button,
  IconButton,
  ListRow,
  Sheet,
  Skeleton,
  Text,
  TextField,
  Toggle,
  toast,
  type SheetHandle,
} from '../primitives';
import {EmptyState, Header, shortDate, type ScreenNavigation} from './parts';
import {useMemoryUi} from './registry';
import {ms} from './strings';
import {MAX_MEMORY_TEXT, type MemoryRow} from './types';
import {useChanges, useLive} from './useLive';

/** Rows whose text has every word of the query. */
export function filterMemories(rows: MemoryRow[], query: string): MemoryRow[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) {
    return rows;
  }
  return rows.filter(row => {
    const text = row.text.toLowerCase();
    return words.every(word => text.includes(word));
  });
}

/** Manage memories: list, search, add, edit, delete, delete all, pause. */
export function MemoryScreen({navigation}: {navigation: ScreenNavigation}) {
  const memory = useMemoryUi();
  useChanges(memory);
  const state = memory.state();
  const loaded = useLive(memory, () => memory.list());
  const [query, setQuery] = useState('');
  const [editing, setEditing] = useState<MemoryRow | null>(null);
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const editSheet = useRef<SheetHandle>(null);
  const confirmSheet = useRef<SheetHandle>(null);

  const rows = useMemo(
    () =>
      filterMemories(
        [...(loaded ?? [])].sort((a, b) => b.updatedAt - a.updatedAt),
        query,
      ),
    [loaded, query],
  );
  const total = loaded?.length ?? 0;

  const openEditor = (row: MemoryRow | null) => {
    setEditing(row);
    setDraft(row?.text ?? '');
    editSheet.current?.present();
  };

  const save = async () => {
    const text = draft.trim();
    if (!text || busy) {
      return;
    }
    setBusy(true);
    try {
      if (editing) {
        if (text !== editing.text) {
          await memory.edit(editing.id, text);
        }
      } else {
        const outcome = await memory.add(text);
        if (outcome === 'duplicate') {
          toast.show({message: ms('duplicate')});
        } else if (outcome === 'rejected') {
          toast.show({message: ms('rejected'), kind: 'error'});
        } else {
          toast.show({message: ms('saved'), kind: 'success'});
        }
      }
      await editSheet.current?.dismiss();
    } catch {
      toast.show({message: ms('rejected'), kind: 'error'});
    } finally {
      setBusy(false);
    }
  };

  const remove = async (row: MemoryRow) => {
    await editSheet.current?.dismiss();
    await memory.remove(row.id);
    toast.show({message: ms('deleted')});
  };

  const removeAll = async () => {
    await confirmSheet.current?.dismiss();
    await memory.removeAll();
    setQuery('');
    toast.show({message: ms('deletedAll')});
  };

  const header = (
    <View style={styles.top}>
      {state.enabled ? (
        <ListRow
          title={ms('pause')}
          subtitle={ms('pauseHint')}
          trailing={
            <Toggle
              testID="memory-pause"
              value={state.paused}
              onValueChange={value => {
                memory.setPaused(value).catch(() => {});
              }}
              accessibilityLabel={ms('pause')}
              accessibilityHint={ms('pauseHint')}
            />
          }
        />
      ) : (
        <View testID="memory-off" style={styles.off}>
          <Text variant="callout" color="textSecondary" style={styles.offText}>
            {ms('off')}
          </Text>
          <Button
            testID="memory-turn-on"
            label={ms('turnOn')}
            variant="secondary"
            onPress={() => {
              memory.setEnabled(true).catch(() => {});
            }}
          />
        </View>
      )}
      {total > 0 ? (
        <TextField
          testID="memory-search"
          shape="pill"
          icon="search"
          clearable
          placeholder={ms('search')}
          value={query}
          onChangeText={setQuery}
          autoCorrect={false}
          returnKeyType="search"
        />
      ) : null}
      {total > 0 ? (
        <Text variant="footnote" color="textSecondary" style={styles.count}>
          {total === 1 ? ms('countOne') : ms('count', {count: total})}
        </Text>
      ) : null}
    </View>
  );

  return (
    <View testID="memory-screen" style={styles.screen}>
      <Header
        title={ms('title')}
        onBack={() => navigation.goBack()}
        trailing={
          <IconButton
            testID="memory-add"
            icon="add"
            variant="glass"
            accessibilityLabel={ms('add')}
            onPress={() => openEditor(null)}
          />
        }
      />
      <FlatList
        data={rows}
        keyExtractor={row => row.id}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="on-drag"
        contentContainerStyle={styles.content}
        ListHeaderComponent={header}
        renderItem={({item}) => (
          <ListRow
            testID={`memory-row-${item.id}`}
            title={item.text}
            titleLines={4}
            subtitle={`${ms(
              item.origin === 'learned' ? 'originLearned' : 'originSaved',
            )} · ${shortDate(item.updatedAt)}`}
            onPress={() => openEditor(item)}
            trailing={
              <IconButton
                testID={`memory-delete-${item.id}`}
                icon="delete"
                size={36}
                iconSize={18}
                accessibilityLabel={`${ms('delete')}: ${item.text}`}
                onPress={() => {
                  remove(item).catch(() => {});
                }}
              />
            }
          />
        )}
        ListEmptyComponent={
          loaded === undefined ? (
            <View style={styles.loading}>
              <Skeleton height={20} width="80%" />
              <Skeleton height={20} width="60%" />
              <Skeleton height={20} width="70%" />
            </View>
          ) : total === 0 ? (
            <EmptyState
              testID="memory-empty"
              icon="sparkles"
              title={ms('empty')}
              hint={ms('emptyHint')}
            />
          ) : (
            <EmptyState
              testID="memory-no-results"
              icon="search"
              title={ms('noResults', {query: query.trim()})}
            />
          )
        }
        ListFooterComponent={
          total > 0 ? (
            <Button
              testID="memory-delete-all"
              label={ms('deleteAll')}
              variant="ghost"
              icon="delete"
              onPress={() => confirmSheet.current?.present()}
              style={styles.deleteAll}
            />
          ) : undefined
        }
      />

      <Sheet
        ref={editSheet}
        testID="memory-editor"
        title={editing ? ms('edit') : ms('add')}>
        <TextField
          testID="memory-editor-text"
          value={draft}
          onChangeText={setDraft}
          placeholder={ms('addPlaceholder')}
          multiline
          maxLength={MAX_MEMORY_TEXT}
        />
        <Button
          testID="memory-editor-save"
          label={ms('save')}
          fullWidth
          loading={busy}
          disabled={draft.trim().length === 0}
          onPress={() => {
            save().catch(() => {});
          }}
        />
        {editing ? (
          <Button
            testID="memory-editor-delete"
            label={ms('delete')}
            variant="destructive"
            fullWidth
            onPress={() => {
              remove(editing).catch(() => {});
            }}
          />
        ) : null}
      </Sheet>

      <Sheet
        ref={confirmSheet}
        testID="memory-confirm-delete-all"
        title={ms('deleteAllTitle')}>
        <Text variant="callout" color="textSecondary" align="center">
          {ms('deleteAllBody')}
        </Text>
        <Button
          testID="memory-confirm-delete-all-yes"
          label={ms('deleteAllConfirm')}
          variant="destructive"
          fullWidth
          onPress={() => {
            removeAll().catch(() => {});
          }}
        />
        <Button
          label={ms('cancel')}
          variant="secondary"
          fullWidth
          onPress={() => confirmSheet.current?.dismiss()}
        />
      </Sheet>
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    paddingHorizontal: theme.spacing.md,
    paddingBottom: rt.insets.bottom + theme.spacing.xxl,
  },
  top: {
    gap: theme.spacing.md,
    paddingBottom: theme.spacing.sm,
  },
  off: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    padding: theme.spacing.md,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
  },
  offText: {
    flex: 1,
  },
  count: {
    paddingHorizontal: theme.spacing.md,
  },
  loading: {
    gap: theme.spacing.lg,
    padding: theme.spacing.md,
  },
  deleteAll: {
    alignSelf: 'center',
    marginTop: theme.spacing.xl,
  },
}));
