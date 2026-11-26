import React, {useEffect, useMemo, useRef} from 'react';
import {Platform, ScrollView, TextInput} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import type {ChatMessageView} from '../../contracts';
import {useT} from '../../locales';
import {typography} from '../../theme';
import {Sheet, Text, type SheetHandle} from '../primitives';
import {flowMarkdown} from './format';
import {AnswerMarkdown} from './thread/AnswerMarkdown';

export interface SelectTextSheetProps {
  message: ChatMessageView | null;
  onClose: () => void;
  /** "Ask AntiChat": the selection becomes a quote in the composer. */
  onAsk: (text: string) => void;
}

/**
 * A whole message as one run of selectable text. In the thread an answer is
 * laid out block by block and a selection cannot cross blocks; here it can.
 */
export function SelectTextSheet({
  message,
  onClose,
  onAsk,
}: SelectTextSheetProps) {
  const t = useT();
  const {theme} = useUnistyles();
  const sheet = useRef<SheetHandle>(null);
  useEffect(() => {
    if (message) {
      sheet.current?.present().catch(() => {});
    }
  }, [message]);

  const items = useMemo(
    () => [
      {
        text: t('thread.askAbout'),
        icon: 'arrowshape.turn.up.left',
        onPress: (event: {text: string}) => {
          onAsk(event.text);
          sheet.current?.dismiss().catch(() => {});
        },
      },
    ],
    [onAsk, t],
  );

  return (
    <Sheet
      ref={sheet}
      testID="select-text-sheet"
      title={t('thread.selectTitle')}
      detents={[0.6, 1]}
      onDismiss={onClose}>
      {message ? (
        <ScrollView
          nestedScrollEnabled
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}>
          {message.role === 'assistant' ? (
            <AnswerMarkdown
              testID="select-text"
              text={flowMarkdown(message.text)}
              layout="flow"
              selectable
              selectionItems={items}
            />
          ) : Platform.OS === 'ios' ? (
            // On iOS only a text field lets a range be selected.
            <TextInput
              testID="select-text"
              value={message.text}
              editable={false}
              multiline
              scrollEnabled={false}
              maxFontSizeMultiplier={typography.body.maxFontSizeMultiplier}
              selectionColor={theme.colors.accent}
              style={styles.plain}
            />
          ) : (
            <Text testID="select-text" selectable>
              {message.text}
            </Text>
          )}
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
  plain: {
    padding: 0,
    fontSize: theme.typography.body.fontSize,
    lineHeight: theme.typography.body.lineHeight,
    letterSpacing: theme.typography.body.letterSpacing,
    color: theme.colors.textPrimary,
  },
}));
