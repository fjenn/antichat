import React, {useEffect, useRef, useSyncExternalStore} from 'react';
import {ScrollView} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../locales';
import {Sheet, Text, type SheetHandle} from '../primitives';
import {AnswerMarkdown} from './thread/AnswerMarkdown';
import type {ThreadController} from './thread/ThreadController';

export interface ReasoningSheetProps {
  controller: ThreadController;
  /** The message whose thinking is shown; null closes the sheet. */
  messageId: string | null;
  onClose: () => void;
}

function ReasoningText({
  controller,
  messageId,
}: {
  controller: ThreadController;
  messageId: string;
}) {
  const text = useSyncExternalStore(
    controller.subscribeReasoning,
    () => controller.reasoningOf(messageId),
    () => controller.reasoningOf(messageId),
  );
  return <AnswerMarkdown text={text} variant="reasoning" selectable />;
}

/**
 * The model's own thinking, in a sheet. While the model is still thinking
 * the text keeps arriving.
 */
export function ReasoningSheet({
  controller,
  messageId,
  onClose,
}: ReasoningSheetProps) {
  const t = useT();
  const sheet = useRef<SheetHandle>(null);
  useEffect(() => {
    if (messageId) {
      sheet.current?.present().catch(() => {});
    }
  }, [messageId]);
  return (
    <Sheet
      ref={sheet}
      testID="reasoning-sheet"
      title={t('thread.reasoningTitle')}
      detents={[0.5, 1]}
      onDismiss={onClose}>
      {messageId ? (
        <ScrollView
          nestedScrollEnabled
          showsVerticalScrollIndicator={false}
          contentContainerStyle={styles.content}>
          <ReasoningText controller={controller} messageId={messageId} />
        </ScrollView>
      ) : (
        <Text color="textSecondary"> </Text>
      )}
    </Sheet>
  );
}

const styles = StyleSheet.create(theme => ({
  content: {
    paddingBottom: theme.spacing.xxxl,
  },
}));
