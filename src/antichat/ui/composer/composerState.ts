import {V1} from '../../app/scope';
/**
 * The composer's rules as pure functions: which button sits at the end of
 * the pill, when a paste becomes an attachment, what is finally sent.
 */
import type {DeviceClass} from '../../contracts';

export type TrailingState = 'voice' | 'send' | 'stop' | 'disabled';

/**
 * The four-state button:
 *   nothing typed, idle       → voice
 *   something to send         → send (also while an answer runs: interrupt)
 *   nothing typed, generating → stop
 *   something that cannot go  → disabled (only spaces, a file still loading)
 */
export function trailingState(input: {
  text: string;
  attachments: number;
  /** An attachment is still being read. */
  preparing: boolean;
  generating: boolean;
}): TrailingState {
  const hasText = input.text.trim().length > 0;
  if (hasText || input.attachments > 0) {
    return input.preparing ? 'disabled' : 'send';
  }
  if (input.generating) {
    return 'stop';
  }
  // The first version has no voice mode: an empty field shows a resting send.
  return input.text.length > 0 || !V1.voiceMode ? 'disabled' : 'voice';
}

/** From how many pasted characters a paste becomes an attachment. */
export function pasteLimitFor(deviceClass: DeviceClass | null): number {
  switch (deviceClass) {
    case 'A':
      return 2000;
    case 'B':
      return 4000;
    case 'C':
      return 8000;
    case 'D':
    case 'E':
      return 10000;
    default:
      return 4000;
  }
}

export interface PasteSplit {
  /** The field's text without the pasted run. */
  text: string;
  pasted: string;
}

/**
 * Typing changes the text by a character or a word; a paste inserts a long
 * run at once. Returns that run when it reaches `limit`, else null.
 */
export function detectLargePaste(
  previous: string,
  next: string,
  limit: number,
): PasteSplit | null {
  if (next.length - previous.length < limit) {
    return null;
  }
  let start = 0;
  const max = Math.min(previous.length, next.length);
  while (start < max && previous[start] === next[start]) {
    start++;
  }
  let endPrevious = previous.length;
  let endNext = next.length;
  while (
    endPrevious > start &&
    endNext > start &&
    previous[endPrevious - 1] === next[endNext - 1]
  ) {
    endPrevious--;
    endNext--;
  }
  const pasted = next.slice(start, endNext);
  if (pasted.length < limit) {
    return null;
  }
  return {text: next.slice(0, start) + next.slice(endNext), pasted};
}

export interface PastedText {
  id: string;
  text: string;
}

/**
 * The message as the model gets it: the quoted passage first, the typed
 * text, then every pasted run in its own block.
 */
export function composeMessage(input: {
  text: string;
  quote?: string | null;
  pastes?: readonly PastedText[];
}): string {
  const parts: string[] = [];
  const quote = input.quote?.trim();
  if (quote) {
    parts.push(
      quote
        .split('\n')
        .map(line => `> ${line}`)
        .join('\n'),
    );
  }
  const text = input.text.trim();
  if (text) {
    parts.push(text);
  }
  for (const paste of input.pastes ?? []) {
    const body = paste.text.trim();
    if (body) {
      parts.push(body);
    }
  }
  return parts.join('\n\n');
}

/** Rows of text the field shows before it scrolls inside. */
export const MAX_LINES = 7;

export function inputHeights(lineHeight: number, padding: number) {
  return {
    min: lineHeight + padding * 2,
    max: lineHeight * MAX_LINES + padding * 2,
  };
}
