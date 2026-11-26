/**
 * How an answer is typeset. One place, so the thread, the reasoning sheet and
 * the select-text sheet agree, and so a theme change is one object swap.
 */
import {Platform} from 'react-native';
import type {MarkdownStyle} from 'react-native-enriched-markdown';

import type {AppTheme} from '../../../theme';

export const MONO_FONT = Platform.select({
  ios: 'Menlo',
  default: 'monospace',
}) as string;

export type MarkdownVariant = 'answer' | 'reasoning';

/** Space between two blocks of an answer. */
const BLOCK_GAP = 14;

const SYNTAX = {
  light: {
    keyword: '#AF2D8C',
    string: '#1E7B34',
    number: '#9A5B00',
    constant: '#9A5B00',
    comment: '#7B7F86',
    function: '#2457C5',
    type: '#0F7B87',
    variable: '#0D0D0D',
    property: '#2457C5',
    tag: '#AF2D8C',
    attribute: '#9A5B00',
    operator: '#5D5D5D',
    punctuation: '#5D5D5D',
  },
  dark: {
    keyword: '#F08BD0',
    string: '#8BD49C',
    number: '#F2B46B',
    constant: '#F2B46B',
    comment: '#8A8F98',
    function: '#8AB4FF',
    type: '#7AD3DD',
    variable: '#FFFFFF',
    property: '#8AB4FF',
    tag: '#F08BD0',
    attribute: '#F2B46B',
    operator: '#B4B4B4',
    punctuation: '#B4B4B4',
  },
} as const;

export function createMarkdownStyle(
  theme: AppTheme,
  variant: MarkdownVariant = 'answer',
): MarkdownStyle {
  const {colors} = theme;
  const reasoning = variant === 'reasoning';
  const text = reasoning ? colors.textSecondary : colors.textPrimary;
  const fontSize = reasoning ? 15 : 16;
  const lineHeight = reasoning ? 22 : 24;
  const body = {color: text, fontSize, lineHeight};
  const block = {...body, marginTop: 0, marginBottom: BLOCK_GAP};
  const heading = (size: number, height: number, top: number) => ({
    color: text,
    fontSize: size,
    lineHeight: height,
    fontWeight: '600',
    marginTop: top,
    marginBottom: 8,
  });
  // A black-and-white accent cannot mark a link by colour alone.
  const neutral = theme.accentName === 'neutral';
  const link = neutral ? colors.textPrimary : colors.accent;

  return {
    paragraph: block,
    h1: heading(24, 30, 8),
    h2: heading(20, 26, 8),
    h3: heading(17, 24, 6),
    h4: heading(16, 24, 4),
    h5: heading(16, 24, 4),
    h6: heading(16, 24, 4),
    list: {
      ...block,
      marginLeft: 4,
      gapWidth: 8,
      itemSpacing: 6,
      bulletColor: text,
      bulletSize: 5,
      markerColor: text,
      markerMinWidth: 22,
    },
    blockquote: {
      ...block,
      color: colors.textSecondary,
      borderWidth: 3,
      borderColor: colors.border,
      gapWidth: 12,
      padding: 0,
      backgroundColor: 'transparent',
    },
    codeBlock: {
      marginTop: 2,
      marginBottom: BLOCK_GAP + 2,
      fontFamily: MONO_FONT,
      fontSize: 14,
      lineHeight: 21,
      color: colors.textPrimary,
      backgroundColor: colors.surface,
      borderColor: 'transparent',
      borderWidth: 0,
      borderRadius: theme.radii.md,
      padding: 14,
      syntaxColors: SYNTAX[theme.scheme],
    },
    code: {
      fontFamily: MONO_FONT,
      fontSize: fontSize - 2,
      color: colors.textPrimary,
      backgroundColor: colors.surface,
      borderColor: 'transparent',
    },
    link: {color: link, underline: neutral},
    strong: {fontWeight: 'bold', color: text},
    em: {fontStyle: 'italic', color: text},
    strikethrough: {color: colors.textSecondary},
    underline: {color: text},
    thematicBreak: {
      color: colors.border,
      height: 1,
      marginTop: 10,
      marginBottom: 10 + BLOCK_GAP,
    },
    table: {
      ...body,
      fontSize: 15,
      lineHeight: 21,
      marginTop: 2,
      marginBottom: BLOCK_GAP + 2,
      headerBackgroundColor: colors.surface,
      headerTextColor: colors.textPrimary,
      rowEvenBackgroundColor: 'transparent',
      rowOddBackgroundColor: 'transparent',
      borderColor: colors.border,
      borderWidth: 1,
      borderRadius: theme.radii.sm,
      cellPaddingHorizontal: 12,
      cellPaddingVertical: 9,
    },
    taskList: {
      borderColor: colors.textTertiary,
      checkedColor: colors.accent,
      checkmarkColor: colors.onAccent,
      checkedTextColor: text,
      checkedStrikethrough: false,
    },
    image: {
      borderRadius: theme.radii.md,
      marginTop: 2,
      marginBottom: BLOCK_GAP,
      resizeMode: 'cover',
      maxHeight: 320,
    },
    math: {
      color: text,
      fontSize: fontSize + 1,
      marginTop: 2,
      marginBottom: BLOCK_GAP,
      padding: 0,
      textAlign: 'left',
      backgroundColor: 'transparent',
    },
    inlineMath: {color: text},
    highlight: {color: colors.onAccentSoft, backgroundColor: colors.accentSoft},
    spoiler: {color: colors.textTertiary},
  };
}
