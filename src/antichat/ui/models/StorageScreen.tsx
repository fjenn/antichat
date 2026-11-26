import React, {useEffect, useRef, useState} from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts} from '../../adapters';
import {shellSession} from '../../app/session';
import type {ModelView} from '../../contracts';
import {useT, type MessageKey} from '../../locales';
import type {ColorToken} from '../../theme';
import {IconButton, Text, toast, type SheetHandle} from '../primitives';
import {ConfirmSheet, Group, Row, SettingsPage} from '../settings/components';
import {useOpen} from '../settings/navigation';
import {formatBytes} from './format';
import {useModels} from './hooks';
import {plainName} from './ModelMenu';
import {isInstalled} from './naming';
import {modelCoordinator} from './shared';
import {
  LOW_STORAGE_BYTES,
  phoneStorageProbe,
  storageBreakdown,
  type StorageBreakdown,
} from './storage';
import {V1} from '../../app/scope';
import {SwipeToDelete} from './SwipeToDelete';

type SegmentKey = 'models' | 'voices' | 'images' | 'chats' | 'other';

const SEGMENTS: Array<{
  key: SegmentKey;
  color: ColorToken;
  label: MessageKey;
}> = [
  {key: 'models', color: 'accent', label: 'storage.models'},
  {key: 'voices', color: 'success', label: 'storage.voices'},
  {key: 'images', color: 'warning', label: 'storage.images'},
  {key: 'chats', color: 'textSecondary', label: 'storage.chats'},
  {key: 'other', color: 'textTertiary', label: 'storage.other'},
];

/** Voices, images and the rest are listed only when they take space. */
const ALWAYS_IN_LEGEND: ReadonlySet<SegmentKey> = new Set(['models', 'chats']);

/**
 * Storage: one bar for the phone, the models with their sizes (swipe or tap
 * the bin to delete), and the two clean-up actions.
 */
export const StorageScreen = observer(function Storage() {
  const t = useT();
  const open = useOpen();
  const {port, models} = useModels();
  const coordinator = modelCoordinator();
  const [breakdown, setBreakdown] = useState<StorageBreakdown | null>(null);
  const [selected, setSelected] = useState<ModelView | undefined>();
  const confirmModel = useRef<SheetHandle>(null);
  const confirmChats = useRef<SheetHandle>(null);
  const installed = port.models.filter(isInstalled);
  // Recount when a model arrives or goes.
  const signature = port.models
    .map(model => `${model.id}:${model.state.status}`)
    .join('|');

  useEffect(() => {
    let live = true;
    storageBreakdown(port.models, phoneStorageProbe())
      .then(next => {
        if (live) {
          setBreakdown(next);
        }
      })
      .catch(() => {});
    return () => {
      live = false;
    };
    // `signature` stands for the models.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signature]);

  const ours = breakdown
    ? breakdown.models + breakdown.voices + breakdown.images + breakdown.chats
    : 0;
  const selectedName = selected ? plainName(t, selected, models) : '';

  return (
    <SettingsPage testID="storage-page" title={t('storage.title')}>
      <View style={styles.summary}>
        <Text testID="storage-used" variant="title">
          {t('storage.used', {size: formatBytes(ours)})}
        </Text>
        <Text testID="storage-free" color="textSecondary">
          {breakdown
            ? t('storage.free', {size: formatBytes(breakdown.free)})
            : ' '}
        </Text>
        <View
          style={styles.bar}
          accessible
          accessibilityRole="image"
          accessibilityLabel={t('storage.used', {size: formatBytes(ours)})}>
          {breakdown
            ? SEGMENTS.map(segment => (
                <View
                  key={segment.key}
                  style={styles.segment(
                    segment.color,
                    share(breakdown[segment.key], breakdown.total),
                  )}
                />
              ))
            : null}
        </View>
        <View style={styles.legend}>
          {SEGMENTS.filter(
            segment =>
              ALWAYS_IN_LEGEND.has(segment.key) ||
              (breakdown?.[segment.key] ?? 0) > 0,
          ).map(segment => (
            <View key={segment.key} style={styles.legendItem}>
              <View style={styles.dot(segment.color)} />
              <Text variant="footnote" color="textSecondary">
                {t(segment.label)}
                {breakdown ? ` ${formatBytes(breakdown[segment.key])}` : ''}
              </Text>
            </View>
          ))}
        </View>
        {breakdown && breakdown.free < LOW_STORAGE_BYTES ? (
          <Text testID="storage-low" variant="footnote" color="warning">
            {t('storage.low')}
          </Text>
        ) : null}
      </View>

      <Group testID="storage-models" title={t('storage.installed')}>
        {installed.length === 0 ? (
          <View style={styles.empty}>
            <Text color="textSecondary">{t('storage.noModels')}</Text>
          </View>
        ) : (
          installed.map(model => {
            const name = plainName(t, model, models);
            const ask = () => {
              setSelected(model);
              confirmModel.current?.present().catch(() => {});
            };
            return (
              <SwipeToDelete
                key={model.id}
                label={t('models.delete')}
                onDelete={ask}>
                <View style={styles.model}>
                  <Text style={styles.grow} numberOfLines={1}>
                    {name}
                  </Text>
                  <Text color="textSecondary">
                    {formatBytes(model.downloadBytes)}
                  </Text>
                  <IconButton
                    testID={`storage-delete-${model.id}`}
                    icon="delete"
                    size={36}
                    iconSize={18}
                    accessibilityLabel={t('common.remove', {name})}
                    onPress={ask}
                  />
                </View>
              </SwipeToDelete>
            );
          })
        )}
        <Row
          testID="storage-manage"
          title={t('storage.manage')}
          chevron
          onPress={() => open('Models')}
        />
      </Group>

      <Group>
        {V1.readAloud || V1.voiceMode ? (
          <Row
            testID="storage-clear-voices"
            title={t('storage.clearVoices')}
            onPress={() =>
              toast.show({
                message: t(
                  (breakdown?.voices ?? 0) > 0
                    ? 'storage.clearVoicesDone'
                    : 'storage.nothingToClear',
                ),
              })
            }
          />
        ) : null}
        <Row
          testID="storage-delete-chats"
          title={t('storage.deleteChats')}
          destructive
          onPress={() => {
            confirmChats.current?.present().catch(() => {});
          }}
        />
      </Group>

      <ConfirmSheet
        ref={confirmModel}
        testID="storage-delete-confirm"
        title={t('models.deleteTitle', {name: selectedName})}
        message={t(
          installed.length <= 1
            ? 'models.deleteLastMessage'
            : 'models.deleteMessage',
          {size: formatBytes(selected?.downloadBytes ?? 0)},
        )}
        confirmLabel={t('models.deleteConfirm')}
        cancelLabel={t('common.cancel')}
        destructive
        onConfirm={() => {
          if (selected) {
            coordinator
              .remove(selected.id)
              .then(() =>
                toast.show({
                  message: t('models.deleted', {name: selectedName}),
                }),
              )
              .catch(() => {});
          }
        }}
      />
      <ConfirmSheet
        ref={confirmChats}
        testID="storage-chats-confirm"
        title={t('settings.data_.deleteAllTitle')}
        message={t('settings.data_.deleteAllMessage')}
        confirmLabel={t('settings.data_.deleteAllConfirm')}
        cancelLabel={t('common.cancel')}
        destructive
        onConfirm={() => {
          getPorts()
            .conversations.removeAll()
            .then(() => {
              shellSession.newChat();
              toast.show({message: t('settings.data_.deletedAll')});
            })
            .catch(() => {});
        }}
      />
    </SettingsPage>
  );
});

/** A segment that exists is always visible, however small. */
function share(bytes: number, total: number): number {
  if (bytes <= 0 || total <= 0) {
    return 0;
  }
  return Math.max(0.012, bytes / total);
}

const styles = StyleSheet.create(theme => ({
  summary: {
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
  },
  bar: {
    height: 12,
    flexDirection: 'row',
    gap: 2,
    marginTop: theme.spacing.sm,
    borderRadius: 6,
    overflow: 'hidden',
    backgroundColor: theme.colors.surfacePressed,
  },
  segment: (color: ColorToken, part: number) => ({
    width: `${part * 100}%`,
    display: part > 0 ? 'flex' : 'none',
    backgroundColor: theme.colors[color],
  }),
  legend: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    columnGap: theme.spacing.lg,
    rowGap: theme.spacing.xs,
    marginTop: theme.spacing.xs,
  },
  legendItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
  },
  dot: (color: ColorToken) => ({
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: theme.colors[color],
  }),
  empty: {
    padding: theme.spacing.lg,
  },
  model: {
    minHeight: 54,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    paddingStart: theme.spacing.lg,
    paddingEnd: theme.spacing.sm,
  },
  grow: {
    flex: 1,
  },
}));
