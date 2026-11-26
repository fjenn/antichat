import React, {useRef, useState} from 'react';
import {observer} from 'mobx-react';

import {getPorts, usePort} from '../../adapters';
import type {ModelView} from '../../contracts';
import {useT} from '../../locales';
import {ModelNotices} from '../onboarding/ModelNotices';
import {toast, type SheetHandle} from '../primitives';
import {
  ConfirmSheet,
  Group,
  Row,
  SettingsPage,
  ToggleRow,
} from '../settings/components';
import {useOpen} from '../settings/navigation';
import {formatBytes} from './format';
import {useModels} from './hooks';
import {ModelDetailsSheet} from './ModelDetailsSheet';
import {plainName, tagline} from './ModelMenu';
import {ModelRow, type ModelRowAction} from './ModelRow';
import {isArriving, isInstalled, roleOf, storeSections} from './naming';
import {modelCoordinator} from './shared';

/**
 * The model store (Settings > Models, and "Manage models" in the model menu):
 * every catalogue model this phone can run, grouped as the pick for this
 * phone, faster, smarter and unrestricted. Each card: name, one line, size and
 * fit label, one action; the rest is under Details (tap the card).
 */
export const ManageModelsScreen = observer(function ManageModels() {
  const t = useT();
  const open = useOpen();
  const {port, models, activeModelId} = useModels();
  const metered = usePort(getPorts().connectivity, c => c.metered);
  const coordinator = modelCoordinator();
  const {prefs} = coordinator;
  const [selected, setSelected] = useState<ModelView | undefined>();
  const details = useRef<SheetHandle>(null);
  const confirmDelete = useRef<SheetHandle>(null);
  const confirmMetered = useRef<SheetHandle>(null);
  const consentSheet = useRef<SheetHandle>(null);

  const sections = storeSections(port);
  const installedCount = port.models.filter(isInstalled).length;
  const selectedName = selected ? plainName(t, selected, models) : '';

  const present = (sheet: React.RefObject<SheetHandle | null>) => {
    sheet.current?.present().catch(() => {});
  };

  const startDownload = (model: ModelView, allowMetered = false) => {
    if (model.unrestricted && prefs.unrestrictedConsentAt === null) {
      setSelected(model);
      present(consentSheet);
      return;
    }
    if (metered && !allowMetered) {
      setSelected(model);
      present(confirmMetered);
      return;
    }
    const nothingYet = !port.models.some(
      other => isInstalled(other) || isArriving(other),
    );
    if (nothingYet) {
      // The first model (first run's "Other options"): it becomes the one in
      // use as soon as it is ready.
      coordinator.prefs.set({waitForWifi: false});
      coordinator.choose(model.recommended ? 'auto' : model.id);
      return;
    }
    coordinator.download(model.id, {allowMetered});
  };

  const act = (model: ModelView, action: ModelRowAction) => {
    switch (action) {
      case 'use':
        // Choosing the app's own pick hands the choice back to the app.
        coordinator.choose(
          model.id === models.smart?.id && prefs.automatic ? 'auto' : model.id,
        );
        break;
      case 'download':
        startDownload(model);
        break;
      case 'pause':
        port.pause(model.id);
        break;
      case 'resume':
        port.resume(model.id).catch(() => {});
        break;
      case 'retry':
        port.retry(model.id).catch(() => {});
        break;
      case 'cancel':
        port.cancel(model.id).catch(() => {});
        break;
      case 'details':
        setSelected(model);
        present(details);
        break;
      case 'delete':
        setSelected(model);
        present(confirmDelete);
        break;
    }
  };

  const row = (model: ModelView) => {
    const role = roleOf(model.id, models);
    return (
      <ModelRow
        key={model.id}
        model={model}
        role={role}
        // Unrestricted rows are told apart by their own names.
        name={
          role === 'unrestricted'
            ? model.displayName
            : plainName(t, model, models)
        }
        tagline={tagline(t, role)}
        description={model.summary ?? tagline(t, role)}
        inUse={model.id === activeModelId && model.state.status === 'loaded'}
        onAction={action => act(model, action)}
      />
    );
  };

  return (
    <SettingsPage testID="models-page" title={t('models.title')}>
      <ModelNotices />

      <Group
        testID="models-recommended"
        title={t('models.store.recommended')}
        footer={t('models.store.recommendedHint')}>
        {sections.recommended.map(row)}
      </Group>

      {sections.faster.length > 0 ? (
        <Group testID="models-faster" title={t('models.store.faster')}>
          {sections.faster.map(row)}
        </Group>
      ) : null}

      {sections.smarter.length > 0 ? (
        <Group testID="models-smarter" title={t('models.store.smarter')}>
          {sections.smarter.map(row)}
        </Group>
      ) : null}

      {sections.unrestricted.length > 0 ? (
        <Group
          testID="models-unrestricted"
          title={t('models.store.unrestricted')}
          footer={
            sections.unrestricted.some(isInstalled)
              ? t('models.unrestricted.installedHint')
              : t('models.store.unrestrictedHint')
          }>
          {sections.unrestricted.map(row)}
        </Group>
      ) : null}

      <Group footer={t('models.automaticHint')}>
        <ToggleRow
          testID="models-automatic"
          title={t('models.automatic')}
          value={prefs.automatic}
          onValueChange={automatic =>
            coordinator.choose(
              automatic
                ? 'auto'
                : (activeModelId ?? models.smart?.id ?? 'auto'),
            )
          }
        />
      </Group>

      <Group>
        <Row
          testID="models-storage"
          icon="storage"
          title={t('models.storageRow')}
          chevron
          onPress={() => open('Storage')}
        />
        <Row
          testID="models-capabilities"
          icon="phone"
          title={t('models.capabilitiesRow')}
          chevron
          onPress={() => open('PhoneCapabilities')}
        />
      </Group>

      <ModelDetailsSheet ref={details} model={selected} />
      <ConfirmSheet
        ref={confirmDelete}
        testID="model-delete-confirm"
        title={t('models.deleteTitle', {name: selectedName})}
        message={t(
          installedCount <= 1
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
        ref={confirmMetered}
        testID="model-metered-confirm"
        title={t('models.meteredTitle')}
        message={t('models.meteredMessage', {
          name: selectedName,
          size: formatBytes(selected?.downloadBytes ?? 0),
        })}
        confirmLabel={t('models.meteredConfirm')}
        cancelLabel={t('models.meteredCancel')}
        onConfirm={() => {
          if (selected) {
            startDownload(selected, true);
          }
        }}
      />
      <ConfirmSheet
        ref={consentSheet}
        testID="unrestricted-consent"
        title={t('models.unrestricted.consentTitle')}
        message={t('models.unrestricted.consentMessage')}
        confirmLabel={t('models.unrestricted.consentConfirm', {
          size: formatBytes(selected?.downloadBytes ?? 0),
        })}
        cancelLabel={t('models.unrestricted.consentCancel')}
        onConfirm={() => {
          if (selected) {
            prefs.set({unrestrictedConsentAt: Date.now()});
            startDownload(selected);
          }
        }}
      />
    </SettingsPage>
  );
});
