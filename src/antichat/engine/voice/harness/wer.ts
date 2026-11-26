/** Word error rate between a reference and a recognised text. */
import {wordsOf} from '../stt/text';

export interface WerResult {
  wer: number;
  errors: number;
  words: number;
}

/** Spelled-out small numbers and digits count as the same word. */
const NUMBERS: Record<string, string> = {
  zero: '0',
  one: '1',
  two: '2',
  three: '3',
  four: '4',
  five: '5',
  six: '6',
  seven: '7',
  eight: '8',
  nine: '9',
  ten: '10',
  eleven: '11',
  twelve: '12',
  fifteen: '15',
  twenty: '20',
  thirty: '30',
};

const canonical = (text: string): string[] =>
  wordsOf(text).map(word => NUMBERS[word] ?? word);

/** Levenshtein distance over words (substitutions, insertions, deletions). */
export function wordErrors(reference: string, hypothesis: string): WerResult {
  const ref = canonical(reference);
  const hyp = canonical(hypothesis);
  let previous = Array.from({length: hyp.length + 1}, (_, j) => j);
  for (let i = 1; i <= ref.length; i++) {
    const row = [i];
    for (let j = 1; j <= hyp.length; j++) {
      row[j] = Math.min(
        previous[j]! + 1,
        row[j - 1]! + 1,
        previous[j - 1]! + (ref[i - 1] === hyp[j - 1] ? 0 : 1),
      );
    }
    previous = row;
  }
  const errors = previous[hyp.length]!;
  return {errors, words: ref.length, wer: ref.length ? errors / ref.length : 0};
}

/** Corpus WER: total errors over total reference words. */
export function corpusWer(results: readonly WerResult[]): number {
  const words = results.reduce((sum, r) => sum + r.words, 0);
  return words ? results.reduce((sum, r) => sum + r.errors, 0) / words : 0;
}
