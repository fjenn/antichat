import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {LINKS} from '../../app/links';
import {useT} from '../../locales';
import {Text} from '../primitives';
import {licencePackages} from './about/packages';
import {Group, Row, SettingsPage} from './components';
import {useOpen} from './navigation';
import {openInAppBrowser} from './openLink';

function appVersion(): string {
  try {
    const DeviceInfo = require('react-native-device-info').default;
    return `${DeviceInfo.getVersion()} (${DeviceInfo.getBuildNumber()})`;
  } catch {
    return '';
  }
}

/** About: version, licences, the source code, privacy policy and support. */
export function AboutScreen() {
  const t = useT();
  const open = useOpen();
  return (
    <SettingsPage testID="settings-about-page" title={t('settings.about')}>
      <View style={styles.head}>
        <Text variant="largeTitle" align="center">
          {t('app.name')}
        </Text>
        <Text color="textSecondary" align="center">
          {t('settings.about_.tagline')}
        </Text>
      </View>
      <Group>
        <Row
          testID="about-version"
          title={t('settings.about_.version')}
          value={appVersion()}
        />
        <Row
          testID="about-licences"
          title={t('settings.about_.licences')}
          value={String(licencePackages().length)}
          chevron
          onPress={() => open('SettingsLicences')}
        />
      </Group>
      <Group>
        <Row
          testID="about-github"
          icon="github"
          title={t('settings.github')}
          chevron
          onPress={() => openInAppBrowser(LINKS.github)}
        />
        <Row
          testID="about-privacyPolicy"
          icon="document"
          title={t('settings.privacyPolicy')}
          chevron
          onPress={() => openInAppBrowser(LINKS.privacyPolicy)}
        />
        <Row
          testID="about-support"
          icon="support"
          title={t('settings.support')}
          chevron
          onPress={() => openInAppBrowser(LINKS.support)}
        />
      </Group>
    </SettingsPage>
  );
}

const styles = StyleSheet.create(theme => ({
  head: {
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingVertical: theme.spacing.xxl,
    paddingHorizontal: theme.spacing.xl,
  },
}));
