import React, {useRef, useState} from 'react';
import {ActivityIndicator} from 'react-native';
import {observer} from 'mobx-react';
import {useUnistyles} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {shellSession} from '../../app/session';
import {useT} from '../../locales';
import {toast, type SheetHandle} from '../primitives';
import {ConfirmSheet, Group, Row, SettingsPage} from './components';
import {
  exportChats,
  importChats,
  phoneArchiveStore,
  phoneTransferDevice,
} from './data/transfer';
import {useOpen} from './navigation';

type Busy = 'export' | 'import' | null;

/**
 * Data controls: archived chats, a copy of everything in ChatGPT's export
 * format, importing a ChatGPT export, temporary chats by default, and
 * deleting everything.
 */
export const DataControlsScreen = observer(function DataControls() {
  const t = useT();
  const open = useOpen();
  const {theme} = useUnistyles();
  const conversations = getPorts().conversations;
  const archivedCount = usePort(conversations, port => port.archived().length);
  const confirm = useRef<SheetHandle>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const spinner = (
    <ActivityIndicator size="small" color={theme.colors.textSecondary} />
  );

  const runExport = async () => {
    setBusy('export');
    try {
      const outcome = await exportChats(
        phoneArchiveStore(),
        phoneTransferDevice(),
      );
      if (outcome.kind === 'empty') {
        toast.show({message: t('settings.data_.exportEmpty')});
      }
    } catch {
      toast.show({message: t('settings.data_.exportFailed'), kind: 'error'});
    } finally {
      setBusy(null);
    }
  };

  const runImport = async () => {
    setBusy('import');
    try {
      const outcome = await importChats(
        phoneArchiveStore(),
        phoneTransferDevice(),
      );
      if (outcome.kind === 'imported') {
        toast.show({
          message:
            outcome.count === 0
              ? t('settings.data_.importedNone')
              : outcome.count === 1
                ? t('settings.data_.importedOne')
                : t('settings.data_.imported', {count: outcome.count}),
          kind: outcome.count > 0 ? 'success' : 'info',
        });
      }
    } catch {
      toast.show({message: t('settings.data_.importFailed'), kind: 'error'});
    } finally {
      setBusy(null);
    }
  };

  return (
    <SettingsPage testID="settings-data-page" title={t('settings.data')}>
      <Group>
        <Row
          testID="data-archived"
          icon="archive"
          title={t('settings.data_.archived')}
          value={archivedCount > 0 ? String(archivedCount) : undefined}
          chevron
          onPress={() => open('SettingsArchived')}
        />
      </Group>
      <Group footer={t('settings.data_.footer')}>
        <Row
          testID="data-export"
          icon="upload"
          title={
            busy === 'export'
              ? t('settings.data_.exporting')
              : t('settings.data_.export')
          }
          subtitle={t('settings.data_.exportHint')}
          trailing={busy === 'export' ? spinner : undefined}
          disabled={busy !== null}
          onPress={() => {
            runExport().catch(() => {});
          }}
        />
        <Row
          testID="data-import"
          icon="download"
          title={
            busy === 'import'
              ? t('settings.data_.importing')
              : t('settings.data_.import')
          }
          subtitle={t('settings.data_.importHint')}
          trailing={busy === 'import' ? spinner : undefined}
          disabled={busy !== null}
          onPress={() => {
            runImport().catch(() => {});
          }}
        />
      </Group>
      <Group>
        <Row
          testID="data-delete-all"
          icon="delete"
          title={t('settings.data_.deleteAll')}
          destructive
          onPress={() => {
            confirm.current?.present().catch(() => {});
          }}
        />
      </Group>
      <ConfirmSheet
        ref={confirm}
        testID="delete-all-confirm"
        title={t('settings.data_.deleteAllTitle')}
        message={t('settings.data_.deleteAllMessage')}
        confirmLabel={t('settings.data_.deleteAllConfirm')}
        cancelLabel={t('common.cancel')}
        destructive
        onConfirm={() => {
          conversations
            .removeAll()
            .then(() => {
              shellSession.newChat();
              toast.show({message: t('settings.data_.deletedAll')});
            })
            .catch(() =>
              toast.show({message: t('errors.generic'), kind: 'error'}),
            );
        }}
      />
    </SettingsPage>
  );
});
