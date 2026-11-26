import React from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import {devToolsEnabled, switchShell} from '../../app/flags';
import {useT} from '../../locales';
import {ScenarioControls} from '../models/runtime/ScenarioControls';
import type {MenuItem} from '../primitives';
import {Text, toast} from '../primitives';
import {Group, MenuRow, Row, SettingsPage, ToggleRow} from './components';
import {useOpen} from './navigation';
import {
  CONTEXT_SIZES,
  TEMPERATURES,
  THREAD_COUNTS,
  settingsStore,
} from './store';

const AUTO = 'auto';

/**
 * Advanced: the expert parameters PocketPal showed on its main settings
 * screen, behind one row and off by default. The app's own choices apply
 * until expert mode is switched on.
 */
export const AdvancedScreen = observer(function Advanced() {
  const t = useT();
  const {expert, expertMode} = settingsStore;
  const auto = t('settings.advanced_.auto');

  const numberItems = (
    values: readonly number[],
    current: number | null,
    label: (value: number) => string,
  ): MenuItem[] => [
    {id: AUTO, title: auto, checked: current === null},
    ...values.map(value => ({
      id: String(value),
      title: label(value),
      checked: current === value,
    })),
  ];
  const pick = (id: string): number | null => (id === AUTO ? null : Number(id));
  const tokens = (value: number) =>
    t('settings.advanced_.contextValue', {
      value: value.toLocaleString('en-US'),
    });

  return (
    <SettingsPage
      testID="settings-advanced-page"
      title={t('settings.advanced')}>
      <Text color="textSecondary" style={styles.intro}>
        {t('settings.advanced_.intro')}
      </Text>
      <Group>
        <ToggleRow
          testID="expert-mode"
          title={t('settings.advanced_.expert')}
          subtitle={t('settings.advanced_.expertHint')}
          value={expertMode}
          onValueChange={value => settingsStore.setExpertMode(value)}
        />
      </Group>

      {expertMode ? (
        <Group footer={t('settings.advanced_.applies')}>
          <MenuRow
            testID="expert-context"
            title={t('settings.advanced_.context')}
            value={
              expert.contextSize === null ? auto : tokens(expert.contextSize)
            }
            items={numberItems(CONTEXT_SIZES, expert.contextSize, tokens)}
            onSelect={id => settingsStore.setExpert({contextSize: pick(id)})}
          />
          <MenuRow
            testID="expert-threads"
            title={t('settings.advanced_.threads')}
            value={expert.threads === null ? auto : String(expert.threads)}
            items={numberItems(THREAD_COUNTS, expert.threads, String)}
            onSelect={id => settingsStore.setExpert({threads: pick(id)})}
          />
          <MenuRow
            testID="expert-gpu"
            title={t('settings.advanced_.gpu')}
            value={expert.gpu === 'off' ? t('settings.advanced_.gpuOff') : auto}
            items={[
              {id: 'auto', title: auto, checked: expert.gpu === 'auto'},
              {
                id: 'off',
                title: t('settings.advanced_.gpuOff'),
                checked: expert.gpu === 'off',
              },
            ]}
            onSelect={id =>
              settingsStore.setExpert({gpu: id === 'off' ? 'off' : 'auto'})
            }
          />
          <MenuRow
            testID="expert-temperature"
            title={t('settings.advanced_.temperature')}
            value={
              expert.temperature === null ? auto : expert.temperature.toFixed(1)
            }
            items={numberItems(TEMPERATURES, expert.temperature, value =>
              value.toFixed(1),
            )}
            onSelect={id => settingsStore.setExpert({temperature: pick(id)})}
          />
          <Row
            testID="expert-reset"
            title={t('settings.advanced_.reset')}
            onPress={() => {
              settingsStore.resetExpert();
              toast.show({message: t('settings.advanced_.resetDone')});
            }}
          />
        </Group>
      ) : null}

      <Group>
        <ToggleRow
          testID="show-speed"
          title={t('settings.advanced_.showSpeed')}
          subtitle={t('settings.advanced_.showSpeedHint')}
          value={settingsStore.showSpeed}
          onValueChange={value => settingsStore.setShowSpeed(value)}
        />
      </Group>

      {devToolsEnabled() ? <DeveloperSection /> : null}
    </SettingsPage>
  );
});

/** Debug builds only: the design gallery, upstream's UI, the scripted backend. */
const DeveloperSection = observer(function Developer() {
  const t = useT();
  const open = useOpen();
  return (
    <View style={styles.sections}>
      <Group title={t('settings.advanced_.developer')}>
        <Row
          testID="open-gallery"
          title={t('settings.advanced_.gallery')}
          chevron
          onPress={() =>
            (open as unknown as (screen: string) => void)('Gallery')
          }
        />
        <Row
          testID="show-upstream"
          title={t('settings.advanced_.upstream')}
          subtitle={t('settings.advanced_.upstreamHint')}
          onPress={() => {
            switchShell('upstream').catch(() => {});
          }}
        />
      </Group>
      <ScenarioControls />
    </View>
  );
});

const styles = StyleSheet.create(theme => ({
  intro: {
    paddingHorizontal: theme.spacing.lg,
  },
  sections: {
    gap: theme.spacing.xxl,
  },
}));
