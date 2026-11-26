import React, {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {TextInput, View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import type {ConversationView} from '../../contracts';
import {offlineChats} from '../../engine/offline';
import {useT} from '../../locales';
import {typography} from '../../theme';
import {
  ContextMenu,
  Icon,
  PressableScale,
  Text,
  type MenuItem,
} from '../primitives';
import {
  SwipeActions,
  closeOpenSwipeRow,
  type SwipeAction,
} from './SwipeActions';

export type ChatRowAction =
  | 'open'
  | 'share'
  | 'rename'
  | 'pin'
  | 'archive'
  | 'unarchive'
  | 'delete';

export interface ChatRowProps {
  conversation: ConversationView;
  selected?: boolean;
  /** The row is a text field holding the title. */
  renaming?: boolean;
  /** A locked chat shows its title only once it has been unlocked. */
  unlocked?: boolean;
  /** `archive`: the row lives in the archive list. */
  variant?: 'drawer' | 'archive';
  /** Small grey text at the end of the row (the archive list's date). */
  detail?: string;
  onAction: (action: ChatRowAction, conversation: ConversationView) => void;
  onRenameDone: (conversation: ConversationView, title: string | null) => void;
}

/**
 * One chat in a list: tap opens it, touch-and-hold shows the menu, a swipe
 * towards the start shows archive and delete. Rename turns the row itself
 * into a text field.
 */
export const ChatRow = memo(
  observer(function Row({
    conversation,
    selected = false,
    renaming = false,
    unlocked = false,
    variant = 'drawer',
    detail,
    onAction,
    onRenameDone,
  }: ChatRowProps) {
    const t = useT();
    const hidden = conversation.locked && !unlocked;
    const offline = offlineChats.has(conversation.id);
    const title = hidden
      ? t('lock.rowTitle')
      : conversation.title || t('shell.untitledChat');
    const testID = `chat-row-${conversation.id}`;

    const menu = useMemo<MenuItem[]>(() => {
      if (variant === 'archive') {
        return [
          {id: 'unarchive', title: t('chatRow.unarchive'), icon: 'unarchive'},
          {
            id: 'delete',
            title: t('chatRow.delete'),
            icon: 'delete',
            destructive: true,
          },
        ];
      }
      return [
        ...(hidden
          ? []
          : ([
              {id: 'share', title: t('chatRow.share'), icon: 'share'},
              {id: 'rename', title: t('chatRow.rename'), icon: 'rename'},
            ] satisfies MenuItem[])),
        {
          id: 'pin',
          title: t(conversation.pinned ? 'chatRow.unpin' : 'chatRow.pin'),
          icon: conversation.pinned ? 'unpin' : 'pin',
        },
        {id: 'archive', title: t('chatRow.archive'), icon: 'archive'},
        {
          id: 'delete',
          title: t('chatRow.delete'),
          icon: 'delete',
          destructive: true,
        },
      ];
    }, [conversation.pinned, hidden, t, variant]);

    const swipe = useMemo<SwipeAction[]>(
      () => [
        variant === 'archive'
          ? {id: 'unarchive', label: t('chatRow.unarchive'), icon: 'unarchive'}
          : {id: 'archive', label: t('chatRow.archive'), icon: 'archive'},
        {
          id: 'delete',
          label: t('chatRow.delete'),
          icon: 'delete',
          destructive: true,
        },
      ],
      [t, variant],
    );

    const act = useCallback(
      (action: string) => onAction(action as ChatRowAction, conversation),
      [conversation, onAction],
    );

    if (renaming) {
      return (
        <RenameField
          testID={`${testID}-rename`}
          initial={conversation.title}
          onDone={next => onRenameDone(conversation, next)}
        />
      );
    }

    const label = [
      title,
      conversation.pinned ? t('chatRow.pinnedSuffix') : null,
      offline ? t('chatRow.offlineSuffix') : null,
      conversation.locked ? t('lock.lockedSuffix') : null,
      detail,
    ]
      .filter(Boolean)
      .join(', ');

    return (
      <SwipeActions testID={`${testID}-swipe`} actions={swipe} onAction={act}>
        <ContextMenu trigger="longPress" items={menu} onSelect={act}>
          <PressableScale
            testID={testID}
            accessibilityRole="button"
            accessibilityLabel={label}
            accessibilityHint={t('chatRow.hint')}
            accessibilityState={{selected}}
            scale={false}
            onPress={() => {
              // A tap while a row shows its actions only puts that row back.
              if (!closeOpenSwipeRow()) {
                act('open');
              }
            }}
            // Keeps the press from firing when the long-press opens the menu.
            onLongPress={noop}
            style={styles.row(selected)}>
            <Text
              variant="body"
              color={hidden ? 'textSecondary' : 'textPrimary'}
              numberOfLines={1}
              style={styles.title}>
              {title}
            </Text>
            {detail ? (
              <Text variant="footnote" color="textTertiary" numberOfLines={1}>
                {detail}
              </Text>
            ) : null}
            {offline ? (
              <Icon name="offline" size={14} color="textTertiary" />
            ) : null}
            {conversation.locked ? (
              <Icon
                name={hidden ? 'lock' : 'unlock'}
                size={16}
                color="textTertiary"
              />
            ) : null}
          </PressableScale>
        </ContextMenu>
      </SwipeActions>
    );
  }),
);

function noop(): void {}

/** The row as a text field: Return or leaving the field saves. */
function RenameField({
  initial,
  onDone,
  testID,
}: {
  initial: string;
  onDone: (title: string | null) => void;
  testID?: string;
}) {
  const t = useT();
  const {theme} = useUnistyles();
  const [value, setValue] = useState(initial);
  const done = useRef(false);
  const input = useRef<React.ComponentRef<typeof TextInput>>(null);

  // Focus after the row has been laid out, so the keyboard opens once.
  useEffect(() => {
    const timer = setTimeout(() => input.current?.focus(), 50);
    return () => clearTimeout(timer);
  }, []);

  const finish = (next: string | null) => {
    if (!done.current) {
      done.current = true;
      onDone(next);
    }
  };

  return (
    <View style={styles.renameRow}>
      <TextInput
        ref={input}
        testID={testID}
        value={value}
        onChangeText={setValue}
        accessibilityLabel={t('chatRow.renameField')}
        selectTextOnFocus
        returnKeyType="done"
        submitBehavior="blurAndSubmit"
        autoCapitalize="sentences"
        maxLength={120}
        maxFontSizeMultiplier={typography.button.maxFontSizeMultiplier}
        selectionColor={theme.colors.accent}
        cursorColor={theme.colors.accent}
        keyboardAppearance={theme.dark ? 'dark' : 'light'}
        onSubmitEditing={() => finish(value)}
        onBlur={() => finish(value)}
        style={styles.renameInput}
      />
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  row: (selected: boolean) => ({
    minHeight: theme.sizes.hitTarget,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.md,
    paddingVertical: theme.spacing.sm + theme.spacing.xxs,
    borderRadius: theme.radii.md,
    borderCurve: 'continuous',
    // Opaque, so the swipe actions stay hidden behind a resting row.
    backgroundColor: selected ? theme.colors.surface : theme.colors.drawer,
  }),
  title: {
    flex: 1,
  },
  renameRow: {
    minHeight: theme.sizes.hitTarget,
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.md,
    borderRadius: theme.radii.md,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
    borderWidth: 1,
    borderColor: theme.colors.textTertiary,
  },
  renameInput: {
    paddingVertical: theme.spacing.sm,
    fontSize: typography.body.fontSize,
    letterSpacing: typography.body.letterSpacing,
    color: theme.colors.textPrimary,
    textAlign: 'auto',
  },
}));
