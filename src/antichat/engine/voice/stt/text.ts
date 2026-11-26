/** Transcript text hygiene shared by the recognisers. */

const NON_SPEECH_TAG = /\[[^\]]*\]|\([^)]*\)|[♪♫]+/g;

/**
 * Lines Whisper invents on silence or noise. Matched against the whole
 * segment only, and only when little speech was heard.
 */
const PHANTOMS = new Set([
  'thank you',
  'thanks',
  'thank you very much',
  'thanks for watching',
  'thank you for watching',
  'you',
  'bye',
  'okay',
  'so',
  'vielen dank',
  'untertitel der amara org community',
  'untertitel im auftrag des zdf fur funk 2017',
  'gracias',
  'merci',
  'sous titres realises para la communaute d amara org',
]);

/** Lowercase words without punctuation or accents: for comparing transcripts. */
export function wordsOf(text: string): string[] {
  return text
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^\p{L}\p{N}\s']/gu, ' ')
    .split(/\s+/)
    .filter(Boolean);
}

export const sameWords = (a: string, b: string): boolean =>
  wordsOf(a).join(' ') === wordsOf(b).join(' ');

export function isPhantom(text: string, voicedMs: number): boolean {
  const key = wordsOf(text).join(' ');
  if (!key) {
    return true;
  }
  return voicedMs < 1200 && PHANTOMS.has(key);
}

/** Removes "[BLANK_AUDIO]", "(music)" and repeated spaces. */
export const stripNonSpeech = (text: string): string =>
  text.replace(NON_SPEECH_TAG, ' ').replace(/\s+/g, ' ').trim();

export function tidySegment(text: string, punctuate = true): string {
  let out = stripNonSpeech(text);
  if (!punctuate) {
    out = out
      .replace(/[.,!?;:¿¡…]+(?=\s|$)/g, '')
      .replace(/(^|\s)[¿¡]+/g, '$1')
      .replace(/\s+/g, ' ')
      .trim();
    return out;
  }
  // A segment that starts a sentence starts with a capital.
  return out.replace(/^\p{Ll}/u, c => c.toUpperCase());
}

/** Segments in order, one space apart; no space before closing punctuation. */
export function joinSegments(parts: readonly string[]): string {
  return parts
    .map(part => part.trim())
    .filter(Boolean)
    .join(' ')
    .replace(/\s+([,.!?;:])/g, '$1');
}

/**
 * Leading words two consecutive partials agree on (LocalAgreement-2).
 * Returned in the newer partial's spelling.
 */
export function stablePrefix(previous: string, next: string): string {
  const a = previous.trim().split(/\s+/).filter(Boolean);
  const b = next.trim().split(/\s+/).filter(Boolean);
  let n = 0;
  while (
    n < a.length &&
    n < b.length &&
    wordsOf(a[n]!).join('') === wordsOf(b[n]!).join('')
  ) {
    n++;
  }
  return b.slice(0, n).join(' ');
}
