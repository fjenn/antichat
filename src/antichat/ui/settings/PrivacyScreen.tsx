import React from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import type {ColorToken} from '../../theme';
import {useT} from '../../locales';
import {typography} from '../../theme';
import {Icon, Text, type IconName} from '../primitives';
import {Group, SettingsPage, ToggleRow} from './components';
import {settingsStore} from './store';

/**
 * The privacy explainer: what stays on the phone, what goes online and when,
 * and what never happens. Plain sentences, no policy language. On top, the
 * one privacy switch: "Use my location".
 */
export const PrivacyScreen = observer(function Privacy() {
  const t = useT();
  return (
    <SettingsPage testID="settings-privacy-page" title={t('settings.privacy')}>
      <Text variant="title" style={styles.lead}>
        {t('settings.privacy_.lead')}
      </Text>
      <Group>
        <ToggleRow
          testID="use-location"
          icon="location"
          title={t('settings.privacy_.location')}
          subtitle={t('settings.privacy_.locationHint')}
          value={settingsStore.useLocation}
          onValueChange={value => settingsStore.setUseLocation(value)}
        />
      </Group>
      <Group title={t('settings.privacy_.staysTitle')}>
        <Line
          icon="check"
          color="success"
          title={t('settings.privacy_.stays1')}
        />
        <Line
          icon="check"
          color="success"
          title={t('settings.privacy_.stays2')}
        />
        <Line
          icon="check"
          color="success"
          title={t('settings.privacy_.stays3')}
        />
        <Line
          icon="check"
          color="success"
          title={t('settings.privacy_.stays4')}
        />
      </Group>
      <Group title={t('settings.privacy_.onlineTitle')}>
        <Line
          icon="download"
          title={t('settings.privacy_.online1')}
          hint={t('settings.privacy_.online1Hint')}
        />
        <Line
          icon="web"
          title={t('settings.privacy_.online2')}
          hint={t('settings.privacy_.online2Hint')}
        />
        <Line
          icon="external"
          title={t('settings.privacy_.online3')}
          hint={t('settings.privacy_.online3Hint')}
        />
      </Group>
      <Group
        title={t('settings.privacy_.neverTitle')}
        footer={t('settings.privacy_.footer')}>
        <Line icon="close" title={t('settings.privacy_.never1')} />
        <Line icon="close" title={t('settings.privacy_.never2')} />
        <Line icon="close" title={t('settings.privacy_.never3')} />
      </Group>
    </SettingsPage>
  );
});

function Line({
  icon,
  color = 'textSecondary',
  title,
  hint,
}: {
  icon: IconName;
  color?: ColorToken;
  title: string;
  hint?: string;
}) {
  return (
    <View style={styles.line}>
      <View style={styles.icon}>
        <Icon name={icon} size={18} color={color} strokeWidth={2.2} />
      </View>
      <View style={styles.texts}>
        <Text>{title}</Text>
        {hint ? (
          <Text variant="footnote" color="textSecondary">
            {hint}
          </Text>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  lead: {
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
  },
  line: {
    flexDirection: 'row',
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
  },
  icon: {
    height: typography.body.lineHeight,
    justifyContent: 'center',
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
}));
