import {V1} from '../../../app/scope';
import React, {memo, useEffect, useRef, useState} from 'react';
import {Pressable, View} from 'react-native';
import Animated, {FadeIn, useReducedMotion} from 'react-native-reanimated';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../../adapters';
import type {ChatMessageView} from '../../../contracts';
import {useT} from '../../../locales';
import {ContextMenu, Icon, haptics, type IconName} from '../../primitives';
import {useThreadActions} from './actions';
import {VersionSwitcher} from './VersionSwitcher';

const COPIED_MS = 1600;

/**
 * A plain pressable, not the animated one: a long thread mounts eight of
 * these per answer while it scrolls, and the dim is all the feedback needed.
 */
function ActionButton({
  icon,
  label,
  onPress,
  active = false,
  testID,
}: {
  icon: IconName;
  label: string;
  onPress?: () => void;
  active?: boolean;
  testID?: string;
}) {
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{selected: active}}
      hitSlop={4}
      onPress={() => {
        haptics.tap();
        onPress?.();
      }}
      style={({pressed}) => [styles.button, pressed && styles.pressed]}>
      <Icon
        name={icon}
        size={18}
        strokeWidth={1.9}
        color={active ? 'textPrimary' : 'textSecondary'}
      />
    </Pressable>
  );
}

export interface ActionRowProps {
  message: ChatMessageView;
  /** The thread is busy: switching versions has to wait. */
  busy: boolean;
}

/**
 * The quiet icon row under a finished answer: versions, copy, read aloud,
 * good, bad, try again, share, more.
 */
export const ActionRow = memo(function Actions({
  message,
  busy,
}: ActionRowProps) {
  const t = useT();
  const actions = useThreadActions();
  const reduceMotion = useReducedMotion();
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const speaking = usePort(
    getPorts().voice,
    voice =>
      voice.speech.status !== 'idle' && voice.speech.messageId === message.id,
  );

  const copy = () => {
    actions.copy(message, true);
    setCopied(true);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(false), COPIED_MS);
  };

  return (
    <Animated.View
      testID="answer-actions"
      entering={reduceMotion ? undefined : FadeIn.duration(180)}
      style={styles.row}>
      {message.version && message.version.count > 1 ? (
        <VersionSwitcher
          testID="answer-versions"
          index={message.version.index}
          count={message.version.count}
          disabled={busy}
          onChange={index => actions.switchVersion(message, index)}
        />
      ) : null}
      <ActionButton
        testID="answer-copy"
        icon={copied ? 'check' : 'copy'}
        label={t(copied ? 'thread.copied' : 'thread.copy')}
        onPress={copy}
      />
      {V1.readAloud ? (
        <ActionButton
          testID="answer-read-aloud"
          icon={speaking ? 'square' : 'readAloud'}
          label={t(speaking ? 'thread.stopReading' : 'thread.readAloud')}
          active={speaking}
          onPress={() => actions.readAloud(message)}
        />
      ) : null}
      <ActionButton
        testID="answer-good"
        icon={message.feedback === 'up' ? 'thumbsUpFilled' : 'thumbsUp'}
        label={t('thread.good')}
        active={message.feedback === 'up'}
        onPress={() =>
          actions.setFeedback(message, message.feedback === 'up' ? null : 'up')
        }
      />
      <ActionButton
        testID="answer-bad"
        icon={message.feedback === 'down' ? 'thumbsDownFilled' : 'thumbsDown'}
        label={t('thread.bad')}
        active={message.feedback === 'down'}
        onPress={() =>
          actions.setFeedback(
            message,
            message.feedback === 'down' ? null : 'down',
          )
        }
      />
      <ActionButton
        testID="answer-regenerate"
        icon="retry"
        label={t('thread.regenerate')}
        onPress={() => actions.regenerate(message)}
      />
      <ActionButton
        testID="answer-share"
        icon="share"
        label={t('thread.share')}
        onPress={() => actions.share(message)}
      />
      <ContextMenu
        items={[
          {id: 'branch', title: t('thread.branch'), icon: 'branch'},
          {id: 'select', title: t('thread.selectText'), icon: 'selectText'},
        ]}
        onSelect={id =>
          id === 'branch'
            ? actions.branch(message)
            : actions.selectText(message)
        }>
        <View
          testID="answer-more"
          accessible
          accessibilityRole="button"
          accessibilityLabel={t('thread.more')}
          style={styles.button}>
          <Icon name="more" size={18} strokeWidth={1.9} color="textSecondary" />
        </View>
      </ContextMenu>
    </Animated.View>
  );
});

const styles = StyleSheet.create(theme => ({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'wrap',
    // The first glyph lines up with the text above it.
    marginStart: -9,
    marginTop: theme.spacing.xxs,
  },
  button: {
    width: 36,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pressed: {
    opacity: 0.5,
  },
}));
