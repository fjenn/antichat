import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {useT} from '../../locales';
import {typography} from '../../theme';
import {Icon, Skeleton, Text} from '../primitives';
import {Group, SettingsPage} from '../settings/components';
import {capabilityLines, type CapabilityLine} from './capabilityList';

function phoneName(): string | undefined {
  try {
    const DeviceInfo = require('react-native-device-info').default;
    const model: string = DeviceInfo.getModel();
    return model && model !== 'unknown' ? model : undefined;
  } catch {
    return undefined;
  }
}

/**
 * What this phone can do: one plain list. What works first, then what does
 * not, each with the reason ("Needs a phone with 8 GB memory").
 */
export function PhoneCapabilitiesScreen() {
  const t = useT();
  const port = getPorts().model;
  const capabilities = usePort(port, current => current.capabilities);
  const device = usePort(port, current => current.device);
  const ramGb = device
    ? Math.round(device.snapshot.totalRamBytes / 1024 ** 3)
    : undefined;
  const lines = capabilities ? capabilityLines(t, capabilities) : [];
  const works = lines.filter(line => line.available);
  const missing = lines.filter(line => !line.available);
  return (
    <SettingsPage testID="capabilities-page" title={t('capabilities.title')}>
      <View style={styles.head}>
        <Icon name="phone" size={28} color="textSecondary" strokeWidth={1.6} />
        <View style={styles.headTexts}>
          <Text variant="headline">
            {phoneName() ?? t('capabilities.phone')}
          </Text>
          {ramGb && ramGb <= 32 ? (
            <Text testID="capabilities-memory" color="textSecondary">
              {t('capabilities.memory', {ram: ramGb})}
            </Text>
          ) : null}
        </View>
      </View>
      <Text color="textSecondary" style={styles.intro}>
        {t('capabilities.intro')}
      </Text>
      {capabilities ? null : (
        <View style={styles.loading} accessibilityLabel={t('common.loading')}>
          <Skeleton width="80%" />
          <Skeleton width="64%" />
          <Skeleton width="72%" />
        </View>
      )}
      <Group testID="capabilities-works" title={t('capabilities.works')}>
        {works.map(line => (
          <Line key={line.id} line={line} />
        ))}
      </Group>
      <Group testID="capabilities-missing" title={t('capabilities.notHere')}>
        {missing.map(line => (
          <Line key={line.id} line={line} />
        ))}
      </Group>
    </SettingsPage>
  );
}

function Line({line}: {line: CapabilityLine}) {
  return (
    <View
      testID={`capability-${line.id}`}
      accessible
      accessibilityLabel={[line.title, line.detail].filter(Boolean).join(', ')}
      style={styles.line}>
      <View style={styles.icon}>
        <Icon
          name={line.icon}
          size={20}
          color={line.available ? 'textPrimary' : 'textTertiary'}
        />
      </View>
      <View style={styles.texts}>
        <Text color={line.available ? 'textPrimary' : 'textSecondary'}>
          {line.title}
        </Text>
        {line.detail ? (
          <Text variant="footnote" color="textSecondary">
            {line.detail}
          </Text>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.lg,
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
  },
  headTexts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  intro: {
    paddingHorizontal: theme.spacing.lg,
    marginTop: -theme.spacing.sm,
  },
  loading: {
    gap: theme.spacing.md,
    paddingHorizontal: theme.spacing.lg,
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
