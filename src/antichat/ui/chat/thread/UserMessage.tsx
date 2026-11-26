import React, {memo, useState} from 'react';
import {Image, View, type TextLayoutEvent} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {ChatMessageView} from '../../../contracts';
import {useT} from '../../../locales';
import {ContextMenu, Icon, PressableScale, Text} from '../../primitives';
import {isLoadableImage} from '../format';
import {useThreadActions} from './actions';
import {VersionSwitcher} from './VersionSwitcher';

/** A long message is folded to this many lines until it is expanded. */
const FOLD_LINES = 10;

export interface UserMessageProps {
  message: ChatMessageView;
  busy: boolean;
}

/** The user's message: a tinted bubble on the trailing side. */
export const UserMessage = memo(function UserBubble({
  message,
  busy,
}: UserMessageProps) {
  const t = useT();
  const actions = useThreadActions();
  const [lines, setLines] = useState(0);
  const [expanded, setExpanded] = useState(false);
  const foldable = lines > FOLD_LINES + 2;

  const onTextLayout = (event: TextLayoutEvent) => {
    // Measured once, unfolded; folding must not change the answer.
    if (lines === 0) {
      setLines(event.nativeEvent.lines.length);
    }
  };

  const images = message.attachments?.filter(a => a.kind === 'image') ?? [];
  const files = message.attachments?.filter(a => a.kind !== 'image') ?? [];

  return (
    <View testID="user-message" style={styles.row}>
      {images.length > 0 ? (
        <View style={styles.images}>
          {images.map(image =>
            isLoadableImage(image.uri) ? (
              <Image
                key={image.id}
                source={{uri: image.uri}}
                accessibilityLabel={image.name}
                style={styles.image}
              />
            ) : (
              <View
                key={image.id}
                accessible
                accessibilityLabel={image.name}
                style={[styles.image, styles.imageMissing]}>
                <Icon name="image" size={28} color="textTertiary" />
              </View>
            ),
          )}
        </View>
      ) : null}
      {files.map(file => (
        <View key={file.id} style={styles.file}>
          <Icon name="document" size={18} color="textSecondary" />
          <Text variant="callout" numberOfLines={1} style={styles.fileName}>
            {file.name}
          </Text>
        </View>
      ))}
      {message.text ? (
        <ContextMenu
          trigger="longPress"
          items={[
            {id: 'copy', title: t('thread.copy'), icon: 'copy'},
            {id: 'select', title: t('thread.selectText'), icon: 'selectText'},
            {
              id: 'edit',
              title: t('thread.edit'),
              icon: 'rename',
              disabled: busy,
            },
          ]}
          onSelect={id => {
            if (id === 'copy') {
              actions.copy(message);
            } else if (id === 'select') {
              actions.selectText(message);
            } else {
              actions.edit(message);
            }
          }}
          style={styles.menu}>
          <View
            accessible
            accessibilityLabel={`${t('thread.you')}: ${message.text}`}
            accessibilityHint={t('chatRow.hint')}
            style={styles.bubble}>
            <Text
              testID="user-message-text"
              color="onAccentSoft"
              numberOfLines={foldable && !expanded ? FOLD_LINES : undefined}
              onTextLayout={onTextLayout}>
              {message.text}
            </Text>
          </View>
        </ContextMenu>
      ) : null}
      {foldable ? (
        <PressableScale
          accessibilityRole="button"
          haptic
          hitSlop={10}
          onPress={() => setExpanded(value => !value)}
          style={styles.fold}>
          <Text variant="footnote" color="textSecondary">
            {t(expanded ? 'thread.showLess' : 'thread.showMore')}
          </Text>
        </PressableScale>
      ) : null}
      {message.version && message.version.count > 1 ? (
        <VersionSwitcher
          testID="message-versions"
          index={message.version.index}
          count={message.version.count}
          disabled={busy}
          onChange={index => actions.switchVersion(message, index)}
        />
      ) : null}
    </View>
  );
});

const styles = StyleSheet.create(theme => ({
  row: {
    alignItems: 'flex-end',
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
    paddingBottom: theme.spacing.sm,
    gap: theme.spacing.xs,
  },
  menu: {
    maxWidth: '78%',
  },
  bubble: {
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.sm + theme.spacing.xxs,
    borderRadius: theme.radii.xl,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.accentSoft,
  },
  images: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    gap: theme.spacing.xs,
    maxWidth: '78%',
  },
  image: {
    width: 132,
    height: 132,
    borderRadius: theme.radii.lg,
    backgroundColor: theme.colors.surface,
  },
  imageMissing: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  file: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    maxWidth: '78%',
    minHeight: 44,
    paddingHorizontal: theme.spacing.md,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
  },
  fileName: {
    flexShrink: 1,
  },
  fold: {
    paddingHorizontal: theme.spacing.xs,
  },
}));
