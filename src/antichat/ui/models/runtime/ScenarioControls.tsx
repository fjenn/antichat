import React from 'react';
import {DevSettings} from 'react-native';
import {observer} from 'mobx-react';

import {getPorts} from '../../../adapters';
import {useT} from '../../../locales';
import {Group, MenuRow, Row} from '../../settings/components';
import {modelCoordinator} from '../shared';
import {modelRuntime} from './index';

type ScenarioKey = 'speed' | 'network' | 'storage' | 'device' | 'failure';

const OPTIONS: Record<ScenarioKey, readonly string[]> = {
  speed: ['demo', 'wifi', 'slow'],
  network: ['real', 'wifi', 'cellular', 'offline'],
  storage: ['real', 'tight', 'full'],
  device: ['real', 'small', 'mid', 'large'],
  failure: ['none', 'network', 'checksum', 'load'],
};

const LABEL = {
  speed: 'settings.advanced_.speed',
  network: 'settings.advanced_.network',
  storage: 'settings.advanced_.storageCase',
  device: 'settings.advanced_.device',
  failure: 'settings.advanced_.failure',
} as const;

/**
 * Debug builds: what the scripted model backend plays (speed, network, free
 * space, which phone, one failure). Draws nothing when the app runs on
 * another backend.
 */
export const ScenarioControls = observer(function Controls() {
  const t = useT();
  const runtime = modelRuntime();
  if ((runtime.engine as unknown) !== getPorts().model) {
    return null;
  }
  const {scenario} = runtime;
  const coordinator = modelCoordinator();
  const set = (key: ScenarioKey, value: string) => {
    scenario.set({[key]: value});
    // Another phone or another disk: classify again, as a launch would.
    if ((key === 'device' || key === 'storage') && !coordinator.prefs.started) {
      runtime.engine.initialize().catch(() => {});
    }
  };
  const startOver = async () => {
    await runtime.reset();
    await coordinator.prefs.reset();
    DevSettings.reload();
  };
  return (
    <Group
      title={t('settings.advanced_.scripted')}
      footer={t('settings.advanced_.scriptedFooter')}>
      {(Object.keys(OPTIONS) as ScenarioKey[]).map(key => (
        <MenuRow
          key={key}
          testID={`scenario-${key}`}
          title={t(LABEL[key])}
          value={scenario[key]}
          items={OPTIONS[key].map(option => ({
            id: option,
            title: option,
            checked: scenario[key] === option,
          }))}
          onSelect={id => set(key, id)}
        />
      ))}
      <Row
        testID="scenario-start-over"
        title={t('settings.advanced_.startOver')}
        destructive
        onPress={() => {
          startOver().catch(() => {});
        }}
      />
    </Group>
  );
});
