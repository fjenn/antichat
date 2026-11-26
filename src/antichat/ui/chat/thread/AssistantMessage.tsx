import React, {memo, useEffect, useState} from 'react';
import {View, type LayoutChangeEvent} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../../locales';
import {ContextMenu, InlineError, Text} from '../../primitives';
import {errorMessage} from '../format';
import {ActionRow} from './ActionRow';
import {AnswerExtras} from './AnswerExtras';
import {MemoryUsedChip} from '../../memory';
import {openMemoryScreen as openMemory} from '../../../app/navigate';
import {useThreadActions} from './actions';
import {AnswerMarkdown} from './AnswerMarkdown';
import {FollowUps} from './FollowUps';
import {ReasoningRow} from './ReasoningRow';
import {typesetSoon, useScrollPace} from './scrollPace';
import {PendingDot, PulsingText} from './StatusBits';
import type {ThreadRow} from './ThreadController';

export interface AssistantMessageProps {
  row: ThreadRow;
}

/**
 * Heights of answers that have been laid out, by message id. A row that
 * comes back during a fast scroll takes its place at once with this height.
 */
const measured = new Map<string, number>();
const MEASURED_MAX = 600;

/** An answer: plain text on the page, no bubble. */
export const AssistantMessage = memo(function Answer({
  row,
}: AssistantMessageProps) {
  const t = useT();
  const actions = useThreadActions();
  const {message, stream, live, phase, busy, followUps} = row;
  // Typesetting an answer is the costly part of mounting a row. While the
  // list is flung, a row that enters shows the bare text in the space the
  // answer took before; the real thing follows when the scroll slows down.
  const pace = useScrollPace();
  const [typeset, setTypeset] = useState(live || pace === 'normal');
  useEffect(() => {
    if (pace === 'normal' && !typeset) {
      return typesetSoon(() => setTypeset(true));
    }
  }, [pace, typeset]);
  const onLayout = (event: LayoutChangeEvent) => {
    if (typeset) {
      if (measured.size > MEASURED_MAX) {
        measured.clear();
      }
      measured.set(message.id, event.nativeEvent.layout.height);
    }
  };
  if (!typeset) {
    const height = measured.get(message.id);
    return (
      <View
        testID="assistant-message"
        style={[styles.row, styles.draft, height ? {height} : null]}>
        <Text numberOfLines={height ? undefined : 12}>
          {message.text.slice(0, 1200)}
        </Text>
      </View>
    );
  }

  const waiting = live && message.status === 'pending';
  const thinking = live && phase === 'thinking';
  const hasText = !!stream || message.text.length > 0;
  const done = !live && message.status !== 'error';
  const failed = message.status === 'error';

  return (
    <View testID="assistant-message" onLayout={onLayout} style={styles.row}>
      {message.reasoning || thinking ? (
        <ReasoningRow message={message} thinking={thinking} />
      ) : waiting && phase === 'working' ? (
        <PulsingText>
          {row.phaseLabel && row.phaseLabel !== 'loading_model'
            ? row.phaseLabel
            : t('status.loadingModel')}
        </PulsingText>
      ) : waiting ? (
        <PendingDot testID="answer-pending" />
      ) : null}
      {hasText ? (
        <ContextMenu
          trigger="longPress"
          items={[
            {id: 'copy', title: t('thread.copy'), icon: 'copy'},
            {id: 'select', title: t('thread.selectText'), icon: 'selectText'},
            {
              id: 'regenerate',
              title: t('thread.regenerate'),
              icon: 'retry',
              disabled: busy,
            },
            {
              id: 'branch',
              title: t('thread.branch'),
              icon: 'branch',
              disabled: live,
            },
          ]}
          onSelect={id => {
            if (id === 'copy') {
              actions.copy(message);
            } else if (id === 'select') {
              actions.selectText(message);
            } else if (id === 'regenerate') {
              actions.regenerate(message);
            } else {
              actions.branch(message);
            }
          }}>
          <View accessible={false}>
            <AnswerMarkdown
              testID="answer-text"
              text={message.text}
              stream={stream}
            />
          </View>
        </ContextMenu>
      ) : null}
      {failed ? (
        <InlineError
          testID="answer-error"
          message={errorMessage(message.error)}
          onRetry={
            message.error?.retryable === false
              ? undefined
              : () => actions.retry(message)
          }
          style={hasText ? styles.errorAfterText : undefined}
        />
      ) : null}
      {done && hasText ? <ActionRow message={message} busy={busy} /> : null}
      {/* Web sources and the Connect card of this answer's tools. */}
      {done ? <AnswerExtras messageId={message.id} /> : null}
      {/* M9: which saved memories this answer drew on. */}
      {done && hasText ? (
        <MemoryUsedChip messageId={message.id} onManage={openMemory} />
      ) : null}
      {done && row.last ? <FollowUps items={followUps} /> : null}
    </View>
  );
});

const styles = StyleSheet.create(theme => ({
  row: {
    paddingHorizontal: theme.spacing.xl,
    paddingTop: theme.spacing.sm,
    paddingBottom: theme.spacing.md,
  },
  draft: {
    overflow: 'hidden',
  },
  errorAfterText: {
    marginTop: theme.spacing.md,
  },
}));
