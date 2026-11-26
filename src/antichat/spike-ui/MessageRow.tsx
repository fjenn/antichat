import React, {memo} from 'react';
import {Linking, StyleSheet, Text, View} from 'react-native';
import {
  EnrichedMarkdownText,
  type StreamingConfig,
} from 'react-native-enriched-markdown';

import type {Message} from './store';

/**
 * Tokens reach the view through the message's native markdown stream, so a
 * streaming row never re-renders in React. `smooth` paces bursts word by
 * word; code is highlighted once at the closing fence.
 */
const STREAMING: StreamingConfig = {
  animation: 'fade',
  smooth: true,
  codeBlockMode: 'progressive',
  tableMode: 'progressive',
};

const openLink = (event: {url: string}) => {
  Linking.openURL(event.url).catch(() => {});
};

export const MessageRow = memo(function Row({message}: {message: Message}) {
  if (message.role === 'user') {
    return (
      <View style={styles.userRow}>
        <View style={styles.bubble}>
          <Text style={styles.userText}>{message.text}</Text>
        </View>
      </View>
    );
  }
  return (
    <View style={styles.assistantRow}>
      <EnrichedMarkdownText
        flavor="github"
        markdown={message.stream ? undefined : message.text}
        stream={message.stream}
        streamingConfig={STREAMING}
        onLinkPress={openLink}
        markdownStyle={MARKDOWN_STYLE}
      />
    </View>
  );
});

const MARKDOWN_STYLE = {
  paragraph: {fontSize: 16, lineHeight: 24, color: '#0d0d0d'},
  h2: {fontSize: 20, lineHeight: 28, color: '#0d0d0d'},
  list: {fontSize: 16, lineHeight: 24, color: '#0d0d0d'},
} as const;

const styles = StyleSheet.create({
  userRow: {alignItems: 'flex-end', paddingHorizontal: 16, paddingVertical: 8},
  bubble: {
    maxWidth: '78%',
    backgroundColor: '#f1f1f1',
    borderRadius: 20,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  userText: {fontSize: 16, lineHeight: 22, color: '#0d0d0d'},
  assistantRow: {paddingHorizontal: 16, paddingVertical: 8},
});
