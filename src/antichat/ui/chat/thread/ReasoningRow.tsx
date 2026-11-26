import React, {memo} from 'react';
import {StyleSheet} from 'react-native-unistyles';

import type {ChatMessageView} from '../../../contracts';
import {useT} from '../../../locales';
import {Icon, PressableScale, Text} from '../../primitives';
import {formatThinkingTime} from '../format';
import {useThreadActions} from './actions';
import {PulsingText} from './StatusBits';

/**
 * One line above an answer: "Thinking" while the model reasons, then
 * "Thought for 5s". Tapping it opens the model's own text in a sheet.
 */
export const ReasoningRow = memo(function Reasoning({
  message,
  thinking,
}: {
  message: ChatMessageView;
  thinking: boolean;
}) {
  const t = useT();
  const actions = useThreadActions();
  const duration = message.reasoning?.durationMs;
  const label = thinking
    ? t('thread.thinking')
    : duration
      ? t('thread.thoughtFor', {duration: formatThinkingTime(duration)})
      : t('thread.thought');
  return (
    <PressableScale
      testID="reasoning-row"
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={t('thread.reasoningHint')}
      scale={false}
      hitSlop={8}
      onPress={() => actions.openReasoning(message)}
      style={styles.row}>
      {thinking ? (
        <PulsingText>{label}</PulsingText>
      ) : (
        <Text color="textSecondary" numberOfLines={1}>
          {label}
        </Text>
      )}
      <Icon name="chevronForward" size={16} color="textTertiary" />
    </PressableScale>
  );
});

const styles = StyleSheet.create(theme => ({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: theme.spacing.xxs,
    minHeight: 32,
    marginBottom: theme.spacing.xs,
  },
}));
