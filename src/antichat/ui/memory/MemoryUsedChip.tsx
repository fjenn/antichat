import React, {useRef} from 'react';
import {ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {Button, Chip, Sheet, Text, type SheetHandle} from '../primitives';
import {SectionLabel} from './parts';
import {useMemoryUi} from './registry';
import {ms} from './strings';
import {useLive} from './useLive';

export interface MemoryUsedChipProps {
  /** Id of the assistant message. */
  messageId: string;
  /** Opens the manage screen; the button is hidden without it. */
  onManage?: () => void;
  /**
   * Also show the chip when memories were in the prompt but the answer did
   * not visibly draw on any. Off by default: the always-sent memories are in
   * every prompt.
   */
  showUncited?: boolean;
  testID?: string;
}

/**
 * "Memory used" under an answer. Renders nothing unless the answer drew on
 * a memory; a tap lists the memories that were in its prompt.
 */
export function MemoryUsedChip({
  messageId,
  onManage,
  showUncited = false,
  testID = 'memory-used',
}: MemoryUsedChipProps) {
  const memory = useMemoryUi();
  const used = useLive(memory, () => memory.usedBy(messageId), [messageId]);
  const sheet = useRef<SheetHandle>(null);
  const cited = (used ?? []).filter(item => item.cited);
  const others = (used ?? []).filter(item => !item.cited);
  if (cited.length === 0 && !(showUncited && others.length > 0)) {
    return null;
  }
  return (
    <>
      <Chip
        testID={testID}
        icon="sparkles"
        label={ms('used')}
        onPress={() => sheet.current?.present()}
      />
      <Sheet ref={sheet} testID={`${testID}-sheet`} title={ms('usedTitle')}>
        <ScrollView style={styles.scroll} contentContainerStyle={styles.list}>
          {cited.map(item => (
            <View key={item.memoryId} style={styles.item}>
              <Text variant="body">{item.text}</Text>
            </View>
          ))}
          {others.length > 0 ? (
            <>
              {cited.length > 0 ? (
                <SectionLabel>{ms('usedAlso')}</SectionLabel>
              ) : null}
              {others.map(item => (
                <View key={item.memoryId} style={styles.item}>
                  <Text variant="body" color="textSecondary">
                    {item.text}
                  </Text>
                </View>
              ))}
            </>
          ) : null}
        </ScrollView>
        {onManage ? (
          <Button
            testID={`${testID}-manage`}
            label={ms('manage')}
            variant="ghost"
            fullWidth
            onPress={() => {
              sheet.current?.dismiss();
              onManage();
            }}
          />
        ) : null}
      </Sheet>
    </>
  );
}

const styles = StyleSheet.create(theme => ({
  scroll: {
    maxHeight: 360,
  },
  list: {
    gap: theme.spacing.sm,
  },
  item: {
    padding: theme.spacing.md,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
  },
}));
