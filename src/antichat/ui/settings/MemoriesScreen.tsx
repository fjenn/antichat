import React, {useRef} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {useT} from '../../locales';
import {IconButton, Text, toast, type SheetHandle} from '../primitives';
import {ConfirmSheet, Group, Row, SettingsPage} from './components';
import {EmptyState} from './EmptyState';

/**
 * What AntiChat remembers. The entry point and the list live here; M9's
 * memory engine fills the port and may replace this screen with a richer one.
 */
export function MemoriesScreen() {
  const t = useT();
  const memory = getPorts().memory;
  const memories = usePort(memory, port => port.memories);
  const confirm = useRef<SheetHandle>(null);
  return (
    <SettingsPage
      testID="settings-memories-page"
      title={t('settings.personal.memoryManage')}>
      {memories.length === 0 ? (
        <EmptyState
          icon="memory"
          title={t('settings.personal.memoryEmpty')}
          hint={t('settings.personal.memoryEmptyHint')}
        />
      ) : (
        <>
          <Group>
            {memories.map(item => (
              <View key={item.id} style={styles.memory}>
                <Text style={styles.text}>{item.text}</Text>
                <IconButton
                  icon="delete"
                  size={36}
                  iconSize={18}
                  accessibilityLabel={t('common.remove', {name: item.text})}
                  onPress={() => {
                    memory
                      .remove(item.id)
                      .then(() =>
                        toast.show({
                          message: t('settings.personal.memoryDeleted'),
                        }),
                      )
                      .catch(() => {});
                  }}
                />
              </View>
            ))}
          </Group>
          <Group>
            <Row
              testID="memories-delete-all"
              title={t('settings.personal.memoryDeleteAll')}
              destructive
              onPress={() => {
                confirm.current?.present().catch(() => {});
              }}
            />
          </Group>
        </>
      )}
      <ConfirmSheet
        ref={confirm}
        testID="memories-confirm"
        title={t('settings.personal.memoryDeleteAllTitle')}
        message={t('settings.personal.memoryDeleteAllMessage')}
        confirmLabel={t('settings.personal.memoryDeleteAll')}
        cancelLabel={t('common.cancel')}
        destructive
        onConfirm={() => {
          memory
            .removeAll()
            .then(() =>
              toast.show({message: t('settings.personal.memoriesDeleted')}),
            )
            .catch(() => {});
        }}
      />
    </SettingsPage>
  );
}

const styles = StyleSheet.create(theme => ({
  memory: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingStart: theme.spacing.lg,
    paddingEnd: theme.spacing.sm,
    paddingVertical: theme.spacing.sm,
  },
  text: {
    flex: 1,
  },
}));
