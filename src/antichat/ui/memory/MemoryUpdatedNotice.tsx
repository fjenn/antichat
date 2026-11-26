import React, {useRef} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {
  Button,
  Icon,
  PressableScale,
  Sheet,
  Text,
  type SheetHandle,
} from '../primitives';
import {useMemoryUi} from './registry';
import {ms} from './strings';
import {useChanges} from './useLive';

export interface MemoryUpdatedNoticeProps {
  conversationId: string | null | undefined;
  /** Opens the manage screen; the button is hidden without it. */
  onManage?: () => void;
  testID?: string;
}

/**
 * The small "Memory updated" line of a chat. Renders nothing until memory
 * saved or changed something during this chat; a tap shows what, with Undo.
 */
export function MemoryUpdatedNotice({
  conversationId,
  onManage,
  testID = 'memory-updated',
}: MemoryUpdatedNoticeProps) {
  const memory = useMemoryUi();
  useChanges(memory);
  const sheet = useRef<SheetHandle>(null);
  const changes = conversationId ? memory.changes(conversationId) : [];
  if (changes.length === 0) {
    return null;
  }
  return (
    <>
      <PressableScale
        testID={testID}
        accessibilityRole="button"
        accessibilityLabel={ms('updated')}
        accessibilityHint={ms('updatedHint')}
        hitSlop={10}
        onPress={() => sheet.current?.present()}
        style={styles.notice}>
        <Icon name="sparkles" size={14} color="textSecondary" />
        <Text variant="footnote" color="textSecondary">
          {ms('updated')}
        </Text>
      </PressableScale>
      <Sheet ref={sheet} testID={`${testID}-sheet`} title={ms('updated')}>
        <View style={styles.list}>
          {changes.map(change => (
            <View key={change.key} style={styles.item}>
              <View style={styles.texts}>
                <Text variant="body">{change.text}</Text>
                {change.kind === 'updated' && change.previousText ? (
                  <Text variant="footnote" color="textSecondary">
                    {ms('wasBefore', {text: change.previousText})}
                  </Text>
                ) : null}
              </View>
              <Button
                testID={`${testID}-undo-${change.memoryId}`}
                label={ms('undo')}
                variant="secondary"
                onPress={() => {
                  memory.undoChange(change).catch(() => {});
                }}
              />
            </View>
          ))}
        </View>
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
  notice: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingVertical: theme.spacing.xs,
  },
  list: {
    gap: theme.spacing.md,
  },
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
    padding: theme.spacing.md,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
}));
