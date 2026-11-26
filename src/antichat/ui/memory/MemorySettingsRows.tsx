import React from 'react';

import {Toggle} from '../primitives';
import {Group, Row} from '../settings/components';
import {useMemoryUi} from './registry';
import {ms} from './strings';
import {useChanges} from './useLive';

/**
 * The memory rows of Settings > Personalization: the master switch,
 * "reference past chats" and the way into the manage screen.
 */
export function MemorySettingsRows({onManage}: {onManage: () => void}) {
  const memory = useMemoryUi();
  useChanges(memory);
  const state = memory.state();
  return (
    <Group testID="memory-settings" title={'Memory'}>
      <Row
        title={ms('settingsEnabled')}
        subtitle={ms('settingsEnabledHint')}
        trailing={
          <Toggle
            testID="memory-enabled"
            value={state.enabled}
            onValueChange={value => {
              memory.setEnabled(value).catch(() => {});
            }}
            accessibilityLabel={ms('settingsEnabled')}
            accessibilityHint={ms('settingsEnabledHint')}
          />
        }
      />
      <Row
        title={ms('settingsChats')}
        subtitle={ms('settingsChatsHint')}
        disabled={!state.enabled}
        trailing={
          <Toggle
            testID="memory-reference-chats"
            value={state.enabled && state.referenceChats}
            disabled={!state.enabled}
            onValueChange={value => {
              memory.setReferenceChats(value).catch(() => {});
            }}
            accessibilityLabel={ms('settingsChats')}
            accessibilityHint={ms('settingsChatsHint')}
          />
        }
      />
      <Row
        testID="memory-manage"
        icon="sparkles"
        title={ms('manage')}
        chevron
        onPress={onManage}
      />
    </Group>
  );
}
