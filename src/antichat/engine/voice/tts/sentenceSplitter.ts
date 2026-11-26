/**
 * Cuts a growing Markdown answer into units that can be spoken one by one
 * while the model is still writing.
 *
 * A unit is a sentence, a list item, a heading, a table row or a whole code
 * block. A full stop only ends a sentence when what follows looks like a new
 * one, so abbreviations ("e.g.", "Dr."), initials, decimals, version numbers,
 * list numbers, URLs, inline code and German ordinals ("am 3. Mai") stay in
 * one piece. Because that needs the next word, a sentence is released when
 * the text after it arrives, or at `flush()`.
 *
 * Units keep their source text and offsets; turning them into words to say
 * is `normalizeForSpeech`.
 */

export type SpeechUnitKind = 'sentence' | 'heading' | 'list' | 'table' | 'code';

export interface SpeechUnit {
  index: number;
  kind: SpeechUnitKind;
  /** Source text of the unit, Markdown included. */
  raw: string;
  /** Offsets of `raw` in the whole text. */
  start: number;
  end: number;
}

export interface SplitterOptions {
  /** BCP-47 language of the text; switches language-specific rules. */
  language?: string;
  /**
   * Let the first unit end at a clause ("…, ") once it is `firstClauseChars`
   * long, so speech starts sooner on a long opening sentence.
   */
  firstClause?: boolean;
  firstClauseChars?: number;
  /** A unit longer than this is cut at a clause or a space. */
  maxChars?: number;
}

/**
 * Tokens that end in a full stop without ending a sentence (lowercase, no
 * final dot). Words that often close a sentence themselves ("etc.", "p.m.",
 * "usw.") are left out on purpose: the capital that follows decides.
 */
const ABBREVIATIONS = new Set([
  // English
  'mr',
  'mrs',
  'ms',
  'dr',
  'prof',
  'sr',
  'jr',
  'st',
  'mt',
  'vs',
  'e.g',
  'i.e',
  'eg',
  'ie',
  'approx',
  'fig',
  'inc',
  'ltd',
  'corp',
  'dept',
  'gov',
  'capt',
  'sgt',
  'u.s',
  'u.k',
  'ph.d',
  'cf',
  'vol',
  // German
  'z.b',
  'bzw',
  'u.a',
  'd.h',
  'ggf',
  'evtl',
  'inkl',
  'exkl',
  'bspw',
  'sog',
  'vgl',
  'zzgl',
  'z.t',
  'i.d.r',
  // Spanish / French / Italian
  'sra',
  'srta',
  'ud',
  'uds',
  'p.ej',
  'mme',
  'mlle',
  'dott',
]);

/** Abbreviations only when a number follows: "No. 5", "ca. 20", "Jan. 3". */
const ABBREVIATIONS_BEFORE_DIGIT = new Set([
  'no',
  'nr',
  'pp',
  'ca',
  'tel',
  'ext',
  'núm',
  'pág',
  'str',
  'art',
  'abs',
  'jan',
  'feb',
  'mar',
  'apr',
  'jun',
  'jul',
  'aug',
  'sep',
  'sept',
  'oct',
  'nov',
  'dec',
]);

const ORDINAL_DOT_LANGUAGES = new Set([
  'de',
  'da',
  'nb',
  'no',
  'fi',
  'cs',
  'sk',
  'pl',
  'hu',
  'hr',
  'sl',
  'sr',
  'tr',
  'et',
  'lv',
  'is',
]);

const TERMINALS = '.!?…';
const CJK_TERMINALS = '。！？';
const CLOSERS = '"\'”’»)]}*_`';
const FENCE = /^[ \t]{0,3}(```|~~~)/;

const isSpace = (c: string | undefined) => c === ' ' || c === '\t';
const isLower = (c: string) => c !== c.toUpperCase() && c === c.toLowerCase();

export class SentenceSplitter {
  private buf = '';
  private base = 0;
  private index = 0;
  private lineStart = true;
  private readonly ordinalDot: boolean;
  private readonly firstClause: boolean;
  private readonly firstClauseChars: number;
  private readonly maxChars: number;

  constructor(options: SplitterOptions = {}) {
    const language = (options.language ?? 'en').toLowerCase().split(/[-_]/)[0]!;
    this.ordinalDot = ORDINAL_DOT_LANGUAGES.has(language);
    this.firstClause = options.firstClause ?? false;
    this.firstClauseChars = options.firstClauseChars ?? 60;
    this.maxChars = options.maxChars ?? 320;
  }

  push(delta: string): SpeechUnit[] {
    this.buf += delta;
    return this.drain(false);
  }

  /** The text is complete: releases what is still held back. */
  flush(): SpeechUnit[] {
    return this.drain(true);
  }

  private drain(final: boolean): SpeechUnit[] {
    const units: SpeechUnit[] = [];
    for (;;) {
      this.skipBlank();
      if (!this.buf) {
        break;
      }
      const cut = this.nextCut(final);
      if (cut === null) {
        break;
      }
      const raw = this.buf.slice(0, cut.end);
      if (!cut.drop && raw.trim()) {
        units.push({
          index: this.index++,
          kind: cut.kind ?? this.kindOf(raw),
          raw,
          start: this.base,
          end: this.base + cut.end,
        });
      }
      this.lineStart = raw.endsWith('\n');
      this.buf = this.buf.slice(cut.end);
      this.base += cut.end;
    }
    return units;
  }

  private skipBlank(): void {
    let n = 0;
    while (n < this.buf.length && /\s/.test(this.buf[n]!)) {
      if (this.buf[n] === '\n') {
        this.lineStart = true;
      }
      n++;
    }
    this.buf = this.buf.slice(n);
    this.base += n;
  }

  private kindOf(raw: string): SpeechUnitKind {
    if (!this.lineStart) {
      return 'sentence';
    }
    if (/^#{1,6}\s/.test(raw)) {
      return 'heading';
    }
    if (/^([-*+•]|\d{1,3}[.)])\s/.test(raw)) {
      return 'list';
    }
    return raw.startsWith('|') ? 'table' : 'sentence';
  }

  private nextCut(
    final: boolean,
  ): {end: number; kind?: SpeechUnitKind; drop?: boolean} | null {
    const buf = this.buf;

    // Blocks that are taken whole: reasoning and fenced code.
    if (buf.startsWith('<think>') || (!final && '<think>'.startsWith(buf))) {
      const close = buf.indexOf('</think>');
      if (close < 0) {
        return final ? {end: buf.length, drop: true} : null;
      }
      return {end: close + '</think>'.length, drop: true};
    }
    if (this.lineStart) {
      if (!final && /^[`~]{1,2}$/.test(buf)) {
        return null;
      }
      const fence = FENCE.exec(buf);
      if (fence) {
        const close = buf.indexOf('\n' + fence[1], fence[0].length);
        if (close < 0) {
          return final ? {end: buf.length, kind: 'code'} : null;
        }
        const lineEnd = buf.indexOf('\n', close + 1);
        if (lineEnd < 0 && !final) {
          return null;
        }
        return {end: lineEnd < 0 ? buf.length : lineEnd + 1, kind: 'code'};
      }
    }

    let inCode = false;
    for (let i = 0; i < buf.length; i++) {
      const c = buf[i]!;
      if (c === '\n') {
        return {end: i + 1};
      }
      if (c === '`') {
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        continue;
      }
      if (CJK_TERMINALS.includes(c)) {
        let end = i + 1;
        while (end < buf.length && '」』”’）'.includes(buf[end]!)) {
          end++;
        }
        return {end};
      }
      if (!TERMINALS.includes(c)) {
        continue;
      }
      // The whole run of terminals and closing marks: `?!"`, `.)`, `.**`
      let end = i + 1;
      while (end < buf.length && (TERMINALS + CLOSERS).includes(buf[end]!)) {
        end++;
      }
      if (end >= buf.length) {
        if (final) {
          return {end};
        }
        return this.softCut();
      }
      if (!isSpace(buf[end]) && buf[end] !== '\n') {
        i = end - 1; // "3.14", "example.com", "v1.2": no sentence end
        continue;
      }
      let next = end;
      while (next < buf.length && isSpace(buf[next])) {
        next++;
      }
      if (next >= buf.length && !final) {
        return this.softCut();
      }
      if (this.endsSentence(i, c, buf[next])) {
        return {end};
      }
      i = end - 1;
    }
    if (final) {
      return {end: buf.length};
    }
    return this.softCut();
  }

  /** Is the terminal at `at` a sentence end, given the next visible character? */
  private endsSentence(
    at: number,
    c: string,
    next: string | undefined,
  ): boolean {
    if (next === undefined || next === '\n') {
      return true;
    }
    if (/\p{L}/u.test(next) && isLower(next)) {
      return false;
    }
    if (c !== '.') {
      return true;
    }
    const before = this.buf.slice(0, at);
    const token = /(\S+)$/.exec(before)?.[1] ?? '';
    const word = token.replace(/^[("'“‘*_[]+/, '');
    if (!word) {
      return false;
    }
    const lower = word.toLowerCase();
    if (ABBREVIATIONS.has(lower)) {
      return false;
    }
    if (ABBREVIATIONS_BEFORE_DIGIT.has(lower) && /\d/.test(next)) {
      return false;
    }
    // Initials: "J. K. Rowling"
    if (/^\p{Lu}$/u.test(word)) {
      return false;
    }
    if (/^\d+$/.test(word)) {
      // "1. First item" at the start of a line is a list number.
      if (this.lineStart && before.trim() === token) {
        return false;
      }
      if (this.ordinalDot && word.length <= 2 && /\p{L}/u.test(next)) {
        return false;
      }
    }
    return true;
  }

  /** No sentence end in sight: cut early for the first unit, or when too long. */
  private softCut(): {end: number} | null {
    const buf = this.buf;
    const wantClause =
      this.firstClause &&
      this.index === 0 &&
      buf.length >= this.firstClauseChars;
    if (!wantClause && buf.length < this.maxChars) {
      return null;
    }
    const limit = Math.min(buf.length, this.maxChars);
    const min = wantClause ? Math.min(24, limit) : Math.floor(limit / 3);
    let inCode = false;
    let clause = -1;
    let space = -1;
    for (let i = 0; i < limit - 1; i++) {
      const c = buf[i]!;
      if (c === '`') {
        inCode = !inCode;
      }
      if (inCode || i < min) {
        continue;
      }
      if (isSpace(buf[i + 1]) && ',;:—–'.includes(c)) {
        clause = i + 1;
      } else if (isSpace(c)) {
        space = i;
      }
    }
    if (clause > 0) {
      return {end: clause};
    }
    if (buf.length >= this.maxChars && space > 0) {
      return {end: space};
    }
    return null;
  }
}

export function splitSentences(
  text: string,
  options?: SplitterOptions,
): SpeechUnit[] {
  const splitter = new SentenceSplitter(options);
  return [...splitter.push(text), ...splitter.flush()];
}
