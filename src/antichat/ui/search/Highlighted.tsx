import React from 'react';

import type {ColorToken, TextVariant} from '../../theme';
import {Text} from '../primitives';

export interface HighlightedProps {
  text: string;
  /** [start, end) ranges of `text` to mark; may be unsorted or overlap. */
  matches?: ReadonlyArray<readonly [number, number]>;
  variant?: TextVariant;
  color?: ColorToken;
  /** Colour of the marked runs. */
  matchColor?: ColorToken;
  numberOfLines?: number;
}

export interface Run {
  text: string;
  match: boolean;
}

/** Splits `text` into plain and marked runs. */
export function splitRuns(
  text: string,
  matches: ReadonlyArray<readonly [number, number]> = [],
): Run[] {
  const ranges = matches
    .map(([start, end]) => [
      Math.max(0, Math.min(start, text.length)),
      Math.max(0, Math.min(end, text.length)),
    ])
    .filter(([start, end]) => end > start)
    .sort((a, b) => a[0] - b[0]);
  const runs: Run[] = [];
  let cursor = 0;
  for (const [start, end] of ranges) {
    if (end <= cursor) {
      continue;
    }
    const from = Math.max(start, cursor);
    if (from > cursor) {
      runs.push({text: text.slice(cursor, from), match: false});
    }
    runs.push({text: text.slice(from, end), match: true});
    cursor = end;
  }
  if (cursor < text.length) {
    runs.push({text: text.slice(cursor), match: false});
  }
  return runs;
}

/** Text with the search words set in semibold. */
export function Highlighted({
  text,
  matches,
  variant = 'body',
  color = 'textPrimary',
  matchColor = 'textPrimary',
  numberOfLines,
}: HighlightedProps) {
  return (
    <Text variant={variant} color={color} numberOfLines={numberOfLines}>
      {splitRuns(text, matches).map((run, index) =>
        run.match ? (
          <Text key={index} variant={variant} color={matchColor} style={STRONG}>
            {run.text}
          </Text>
        ) : (
          run.text
        ),
      )}
    </Text>
  );
}

const STRONG = {fontWeight: '700'} as const;
