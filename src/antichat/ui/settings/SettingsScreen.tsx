import {s as connectorStrings} from '../connectors/strings';
import React from 'react';
import {observer} from 'mobx-react';

import {LINKS} from '../../app/links';
import {useT} from '../../locales';
import {modelCoordinator, plainName, useModels} from '../models';
import {Group, Row, SettingsPage} from './components';
import {useOpen} from './navigation';
import {openInAppBrowser} from './openLink';

/**
 * Settings, in the structure people know from ChatGPT: the app, then what
 * runs on the phone, then the fine print, then the source code, privacy
 * policy and support (in the in-app browser). Every other row opens one
 * short screen.
 */
export const SettingsScreen = observer(function Settings() {
  const t = useT();
  const open = useOpen();
  const {port, models, activeModelId} = useModels();
  const {prefs} = modelCoordinator();
  const active = port.models.find(model => model.id === activeModelId);
  const modelValue = prefs.automatic
    ? t('settings.automatic')
    : active
      ? plainName(t, active, models)
      : undefined;
  return (
    <SettingsPage testID="settings" title={t('settings.title')}>
      <Group>
        <Row
          testID="settings-general"
          icon="settings"
          title={t('settings.general')}
          chevron
          onPress={() => open('SettingsGeneral')}
        />
        <Row
          testID="settings-personalization"
          icon="person"
          title={t('settings.personalization')}
          chevron
          onPress={() => open('SettingsPersonalization')}
        />
        <Row
          testID="settings-voice"
          icon="voice"
          title={t('settings.voice')}
          chevron
          onPress={() => open('SettingsVoice')}
        />
        <Row
          testID="open-connectors"
          icon="web"
          title={connectorStrings.title}
          chevron
          onPress={() => open('Connectors' as never)}
        />
        <Row
          testID="settings-data"
          icon="data"
          title={t('settings.data')}
          chevron
          onPress={() => open('SettingsData')}
        />
      </Group>
      <Group>
        <Row
          testID="settings-models"
          icon="sparkles"
          title={t('settings.models')}
          value={modelValue}
          chevron
          onPress={() => open('Models')}
        />
        <Row
          testID="settings-storage"
          icon="storage"
          title={t('settings.storage')}
          chevron
          onPress={() => open('Storage')}
        />
        <Row
          testID="settings-capabilities"
          icon="phone"
          title={t('settings.capabilities')}
          chevron
          onPress={() => open('PhoneCapabilities')}
        />
      </Group>
      <Group>
        <Row
          testID="settings-privacy"
          icon="privacy"
          title={t('settings.privacy')}
          chevron
          onPress={() => open('SettingsPrivacy')}
        />
        <Row
          testID="settings-about"
          icon="info"
          title={t('settings.about')}
          chevron
          onPress={() => open('SettingsAbout')}
        />
        <Row
          testID="settings-advanced"
          icon="advanced"
          title={t('settings.advanced')}
          chevron
          onPress={() => open('SettingsAdvanced')}
        />
      </Group>
      <Group>
        <Row
          testID="settings-github"
          icon="github"
          title={t('settings.github')}
          chevron
          onPress={() => openInAppBrowser(LINKS.github)}
        />
        <Row
          testID="settings-privacy-policy"
          icon="document"
          title={t('settings.privacyPolicy')}
          chevron
          onPress={() => openInAppBrowser(LINKS.privacyPolicy)}
        />
        <Row
          testID="settings-support"
          icon="support"
          title={t('settings.support')}
          chevron
          onPress={() => openInAppBrowser(LINKS.support)}
        />
      </Group>
    </SettingsPage>
  );
});
