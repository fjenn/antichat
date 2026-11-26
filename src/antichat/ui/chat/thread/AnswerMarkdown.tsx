import React, {memo, useMemo} from 'react';
import {Linking} from 'react-native';
import {
  EnrichedMarkdownText,
  type EnrichedMarkdownTextProps,
  type MarkdownStream,
  type StreamingConfig,
} from 'react-native-enriched-markdown';
import {useUnistyles} from 'react-native-unistyles';

import {translate} from '../../../locales';
import {typography} from '../../../theme';
import {haptics, toast} from '../../primitives';
import {FLAGS} from './markdownFlags';
import {createMarkdownStyle, type MarkdownVariant} from './markdownStyle';

/**
 * Tokens reach the view through the answer's native stream, so a streaming
 * row never re-renders in React. `smooth` paces bursts word by word; code is
 * highlighted once, at the closing fence; tables grow row by row.
 */
const STREAMING: StreamingConfig = {
  animation: {type: 'fade', duration: 220},
  smooth: true,
  codeBlockMode: 'progressive',
  tableMode: 'progressive',
  mediaMode: 'progressive',
};

const openLink = (event: {url: string}) => {
  Linking.openURL(event.url).catch(() => {});
};

const codeCopied = () => {
  haptics.tap();
  toast.show({message: translate('thread.codeCopied')});
};

export interface AnswerMarkdownProps {
  /** The finished text. Ignored while `stream` is set. */
  text: string;
  stream?: MarkdownStream;
  variant?: MarkdownVariant;
  /**
   * `block` lays the answer out as blocks (tables, code headers, maths).
   * `flow` is one text view: plainer, but a selection can span all of it.
   */
  layout?: 'block' | 'flow';
  selectable?: boolean;
  /** Extra items of the text-selection menu. */
  selectionItems?: EnrichedMarkdownTextProps['contextMenuItems'];
  testID?: string;
}

export const AnswerMarkdown = memo(function Markdown({
  text,
  stream,
  variant = 'answer',
  layout = 'block',
  selectable = false,
  selectionItems,
  testID,
}: AnswerMarkdownProps) {
  const {theme} = useUnistyles();
  const style = useMemo(
    () => createMarkdownStyle(theme, variant),
    [theme, variant],
  );
  return (
    <EnrichedMarkdownText
      testID={testID}
      flavor={layout === 'block' ? 'github' : 'commonmark'}
      markdown={stream ? undefined : text}
      stream={stream}
      streamingConfig={STREAMING}
      markdownStyle={style}
      md4cFlags={FLAGS}
      selectable={selectable}
      selectionColor={theme.colors.accentSoft}
      contextMenuItems={selectionItems}
      // Long-press belongs to the message menu, not to a block's own popup.
      enableBlockContextMenu={selectable}
      enableLinkPreview={false}
      enableTaskListItemToggle={false}
      maxFontSizeMultiplier={typography.body.maxFontSizeMultiplier}
      onLinkPress={openLink}
      onCopyPress={codeCopied}
    />
  );
});
