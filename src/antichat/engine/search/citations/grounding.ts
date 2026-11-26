/**
 * Deterministic citation check. Port of AntiChat Mac `CitationGrounding`
 * (stage 1 of its three; the entailment model and the verifier pass are too
 * heavy for a phone).
 *
 * After the answer, every cited sentence is checked against the text the
 * model saw for the sources it cites (page chunks, or the snippet):
 *
 *   numbers    every number of the sentence ("1,000" = "1000"; 0–20 also as
 *              words) appears in that text
 *   months     every month name
 *   names      every capitalised word that is not the sentence's first word
 *              or a common word (or its stem)
 *   words      at least `MIN_COVERAGE` of the content words (≥ 4 letters, not
 *              a function word) occur there, whole or by their 5-letter stem
 *   recency    "latest / most recent / current / next / upcoming" needs a
 *              recency word near one of the sentence's anchors in that text
 *   qualifier  a scope or strength word ("main", "only", "first", "largest",
 *              "often" …) must occur near one of the anchors
 *   stage      alpha / beta / preview / RC must be the stage the text names
 *
 * A sentence that fails keeps its words and loses its marker: a pill only
 * stands for what its passage says. No meaning judgement and no change to
 * what the model said. When the sentence is clearly in another language than
 * its sources (a German answer over English pages) only the numbers are
 * checked: the two share figures, not words or noun forms.
 */
import {scoreLanguage} from '../query';
import {codeSpans} from './markers';

export interface GroundingResult {
  text: string;
  /** Cited sentences checked. */
  checked: number;
  /** Sentences that lost their marker. */
  uncited: number;
  /** Per uncited sentence, what its passage lacked. */
  missing: string[][];
  removedClaims: string[];
}

export const MIN_COVERAGE = 0.6;
const WINDOW = 150;

const MARKER_RUN = /(?:[ \t]*\[\d{1,3}(?:\s*,\s*\d{1,3})*\])+/g;
const NUMBER = /\d+(?:[.,]\d+)*/g;

const MONTHS = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];
const NUMBER_WORDS = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
  'twenty',
];
const COMMON = new Set([
  'the',
  'a',
  'an',
  'this',
  'that',
  'these',
  'those',
  'it',
  'its',
  'in',
  'on',
  'at',
  'for',
  'of',
  'and',
  'or',
  'but',
  'as',
  'by',
  'to',
  'from',
  'with',
  'however',
  'also',
  'according',
  'both',
  'each',
  'while',
  'although',
  'since',
  'after',
  'before',
  'during',
  'there',
  'their',
  'they',
  'he',
  'she',
  'his',
  'her',
  'we',
  'you',
  'i',
  'if',
  'when',
  'where',
  'which',
  'who',
  'what',
  'how',
  'why',
  'yes',
  'no',
  'not',
  'note',
  'overall',
  'today',
  'currently',
  'additionally',
  'furthermore',
  'meanwhile',
  'instead',
  'finally',
  'first',
  'second',
  'third',
  'some',
  'many',
  'most',
  'all',
  'other',
  'another',
  'such',
  'here',
  'so',
  'then',
  'thus',
  'key',
  'summary',
  'source',
  'sources',
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
]);
const FUNCTION_WORDS = new Set([
  'this',
  'that',
  'these',
  'those',
  'with',
  'from',
  'into',
  'over',
  'under',
  'between',
  'through',
  'within',
  'without',
  'about',
  'after',
  'before',
  'during',
  'while',
  'although',
  'since',
  'however',
  'also',
  'according',
  'both',
  'each',
  'there',
  'their',
  'they',
  'them',
  'then',
  'than',
  'when',
  'where',
  'which',
  'what',
  'whose',
  'have',
  'has',
  'had',
  'were',
  'been',
  'being',
  'will',
  'would',
  'could',
  'should',
  'might',
  'must',
  'does',
  'more',
  'less',
  'very',
  'some',
  'many',
  'most',
  'other',
  'another',
  'such',
  'here',
  'thus',
  'only',
  'just',
  'note',
  'overall',
  'today',
  'currently',
  'additionally',
  'furthermore',
  'meanwhile',
  'instead',
  'finally',
  'first',
  'second',
  'third',
  'summary',
  'source',
  'sources',
  'based',
  'search',
  'results',
  'result',
  'official',
  'officially',
  'latest',
  'current',
  'recent',
  'recently',
  'well',
  'known',
  'used',
  'uses',
  'using',
  'include',
  'includes',
  'including',
  'like',
  'often',
  'generally',
  'typically',
  'around',
  'approximately',
  'nearly',
  'roughly',
  'important',
  'notably',
  'specifically',
  'particularly',
  'even',
  'still',
  'make',
  'makes',
]);
const RECENCY_CLAIMS = [
  'latest',
  'most recent',
  'newest',
  'current',
  'currently',
  'next',
  'upcoming',
];
const RECENCY = [
  'latest',
  'most recent',
  'newest',
  'recent',
  'recently',
  'current',
  'currently',
  'next',
  'upcoming',
  'new',
  'now',
  'today',
];
const STAGES: Array<[string, string[]]> = [
  ['alpha', ['alpha']],
  ['beta', ['beta']],
  ['preview', ['preview']],
  ['release candidate', ['release candidate', 'rc', 'rc1', 'rc2', 'rc3']],
  ['rc', ['release candidate', 'rc', 'rc1', 'rc2', 'rc3']],
];
const QUALIFIERS = [
  'main',
  'mainly',
  'primarily',
  'primary',
  'sole',
  'solely',
  'only',
  'first',
  'largest',
  'biggest',
  'smallest',
  'best',
  'steadily',
  'always',
  'never',
  'widely',
  'often',
  'commonly',
  'usually',
  'decades',
  'entirely',
  'completely',
  'fully',
  'exclusively',
  'leading',
  'dominant',
  'prevalent',
  'decisive',
  'thinnest',
  'strongest',
  'fastest',
  'oldest',
  'newest',
  'highest',
  'lowest',
];
const STRENGTHENINGS: Array<[string, string[]]> = [
  ['essential', ['essential']],
  [
    'must',
    [
      'must',
      'required',
      'requires',
      'require',
      'mandatory',
      'obliged',
      'have to',
      'has to',
    ],
  ],
  ['mandatory', ['mandatory', 'must', 'required', 'compulsory']],
  ['crucial', ['crucial']],
  ['vital', ['vital']],
  ['critical', ['critical']],
  ['headquartered', ['headquarters', 'headquartered', 'hq', 'head office']],
];

const escape = (text: string): string =>
  text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export const normalizeText = (text: string): string =>
  text
    .toLowerCase()
    .replace(/(?<=\d),(?=\d{3})/g, '')
    .replace(/(?<=\d)[   ](?=\d{3}\b)/g, '');

const containsWord = (word: string, text: string): boolean =>
  new RegExp(`(?<![\\p{L}\\p{N}])${escape(word)}(?![\\p{L}\\p{N}])`, 'iu').test(
    text,
  );

const numberPattern = (value: string): string =>
  `(?<![\\d.,])${escape(value)}(?!\\d|[.,]\\d)`;

const containsNumber = (value: string, passage: string): boolean =>
  new RegExp(numberPattern(value)).test(passage);

const wordTokens = (text: string): string[] =>
  text.split(/[^\p{L}\p{N}'-]+/u).filter(Boolean);

const SCALES: Array<[RegExp, number]> = [
  [/^\s*(?:thousand|k\b)/i, 1e3],
  [/^\s*(?:million|mio\b|m\b)/i, 1e6],
  [/^\s*(?:billion|bn\b|b\b)/i, 1e9],
  [/^\s*(?:trillion|tn\b)/i, 1e12],
];

/** Every number of a text with its scale word applied ("5.5 million" → 5500000). */
function scaledNumbers(text: string): number[] {
  const out: number[] = [];
  for (const match of text.matchAll(/\d+(?:[.,]\d+)*/g)) {
    const raw = match[0].replace(/[.,]+$/, '');
    // 1,234,567 or 1.234.567 are grouped thousands; 5.5 or 5,5 a decimal.
    const grouped = /^\d{1,3}(?:[.,]\d{3})+$/.test(raw);
    const value = Number(
      grouped ? raw.replace(/[.,]/g, '') : raw.replace(',', '.'),
    );
    if (!Number.isFinite(value)) {
      continue;
    }
    const rest = text.slice(
      match.index! + match[0].length,
      match.index! + match[0].length + 12,
    );
    const scale = SCALES.find(([pattern]) => pattern.test(rest))?.[1] ?? 1;
    out.push(value * scale);
  }
  return out;
}

/**
 * A rounded figure is backed by the exact one: "about 5.5 million" by
 * "5,541,000", "102,000 acres" by "102,347". Only for a scaled or large
 * round number, within 2 %, so years, versions and small counts never match
 * by accident.
 */
function roundedFrom(value: string, claim: string, passage: string): boolean {
  const at = claim.indexOf(value);
  const scaled = scaledNumbers(
    claim.slice(Math.max(0, at), at + value.length + 12),
  )[0];
  if (scaled === undefined || scaled < 1000) {
    return false;
  }
  const hasScaleWord = SCALES.some(([pattern]) =>
    pattern.test(claim.slice(at + value.length)),
  );
  const round = hasScaleWord || /000$/.test(String(Math.round(scaled)));
  if (!round) {
    return false;
  }
  return scaledNumbers(passage).some(
    candidate =>
      candidate >= 1000 && Math.abs(candidate - scaled) / candidate <= 0.02,
  );
}

const BOUNDARY = /[.!?。！？](?:\s+|$)|\n/g;

/** The sentence a marker closes: text after the previous sentence end. */
export function lastSentence(before: string): string {
  let text = before.replace(/[\s.!?;:。！？]+$/u, '');
  const matches = [...text.matchAll(BOUNDARY)];
  for (let i = matches.length - 1; i >= 0; i--) {
    const match = matches[i];
    const at = match.index!;
    if (
      match[0][0] !== '\n' &&
      /(?:\b[A-Z]\.){2,}$/.test(text.slice(0, at + 1))
    ) {
      continue; // "U.S." is not a sentence end
    }
    if (
      match[0][0] === '.' &&
      /\d$/.test(text.slice(0, at)) &&
      /^\.\s+\d/.test(text.slice(at))
    ) {
      continue;
    }
    text = text.slice(at + match[0].length);
    break;
  }
  return cleanClaim(text);
}

export function cleanClaim(text: string): string {
  return text
    .replace(/^(?:\s*(?:[-*+#>]+|\d{1,3}[.)])(?:\s+|$))+/, '')
    .replace(/\*\*|__|`/g, '')
    .trim();
}

/** A list item's lead-in label ("Price: …") is a heading, not a name. */
function withoutLabel(claim: string): string {
  const match = /^[^:\n]{1,40}:\s+/.exec(claim);
  if (!match) {
    return claim;
  }
  const labelWords = wordTokens(match[0]).length;
  const rest = claim.slice(match[0].length);
  return labelWords <= 4 && wordTokens(rest).length >= 4 ? rest : claim;
}

function anchorsOf(claim: string, long: boolean): string[] {
  const normalized = normalizeText(claim);
  const anchors = (normalized.match(NUMBER) ?? []).map(value =>
    numberPattern(value.replace(/[.,]+$/, '')),
  );
  wordTokens(claim).forEach((token, index) => {
    const isName = index > 0 && /^\p{Lu}/u.test(token) && token.length >= 3;
    const isLong =
      long &&
      token.length >= 6 &&
      !FUNCTION_WORDS.has(token.toLowerCase()) &&
      !QUALIFIERS.includes(token.toLowerCase());
    if (isName || isLong) {
      anchors.push(`(?<![\\p{L}\\p{N}])${escape(token.toLowerCase())}`);
    }
  });
  return anchors;
}

/** Any of `forms` within `WINDOW` characters of one of the claim's anchors. */
function nearAnchor(
  forms: string[],
  claim: string,
  passage: string,
  long = true,
): boolean {
  const anchors = anchorsOf(claim, long);
  if (anchors.length === 0) {
    return forms.some(form => containsWord(form, passage));
  }
  for (const anchor of anchors) {
    let pattern: RegExp;
    try {
      pattern = new RegExp(anchor, 'giu');
    } catch {
      continue;
    }
    for (const match of passage.matchAll(pattern)) {
      const from = Math.max(0, match.index! - WINDOW);
      const to = Math.min(
        passage.length,
        match.index! + match[0].length + WINDOW,
      );
      const segment = passage.slice(from, to);
      if (forms.some(form => containsWord(form, segment))) {
        return true;
      }
    }
  }
  return false;
}

export function coverage(
  claim: string,
  passage: string,
): {share: number; absent: string[]} {
  const words = claim
    .toLowerCase()
    .split(/[^\p{L}'-]+/u)
    .filter(word => word.length >= 4 && !FUNCTION_WORDS.has(word));
  if (words.length === 0) {
    return {share: 1, absent: []};
  }
  const absent = words.filter(
    word => !passage.includes(word) && !passage.includes(word.slice(0, 5)),
  );
  return {share: 1 - absent.length / words.length, absent};
}

/**
 * What the passage lacks for the claim (empty = supported as far as this
 * check can tell). `passage` must already be normalised (`normalizeText`).
 */
export function unsupported(
  claim: string,
  passage: string,
  options: {checkCoverage?: boolean; checkNames?: boolean} = {},
): string[] {
  const lack: string[] = [];
  const normalized = normalizeText(claim);
  for (const raw of normalized.match(NUMBER) ?? []) {
    const value = raw.replace(/[.,]+$/, '');
    if (containsNumber(value, passage)) {
      continue;
    }
    const asInt = Number(value);
    if (
      Number.isInteger(asInt) &&
      asInt >= 0 &&
      asInt < NUMBER_WORDS.length &&
      containsWord(NUMBER_WORDS[asInt], passage)
    ) {
      continue;
    }
    // 44,990 in the claim against 44.990 in the passage (decimal comma).
    const swapped = value.includes('.')
      ? value.replace(/\./g, ',')
      : value.replace(/,/g, '.');
    if (swapped !== value && containsNumber(swapped, passage)) {
      continue;
    }
    if (
      containsNumber(
        value.replace(/[.,]/g, ''),
        passage.replace(/(?<=\d)[.,](?=\d{3}\b)/g, ''),
      )
    ) {
      continue;
    }
    if (roundedFrom(value, normalized, passage)) {
      continue;
    }
    lack.push(value);
  }
  for (const month of options.checkNames === false ? [] : MONTHS) {
    if (
      !containsWord(month, normalized) ||
      containsWord(month, passage) ||
      containsWord(month.slice(0, 3), passage)
    ) {
      continue;
    }
    if (month === 'may' && !claim.includes('May')) {
      continue;
    }
    // A numeric date in the source backs the month name: 2026-10-16, 16.10.2026.
    const number = MONTHS.indexOf(month) + 1;
    const numeric = new RegExp(
      `(?:\\b\\d{4}[-/.]0?${number}[-/.]\\d{1,2}\\b)|(?:\\b\\d{1,2}[-/.]0?${number}[-/.]\\d{2,4}\\b)`,
    );
    if (numeric.test(passage)) {
      continue;
    }
    lack.push(month);
  }
  const labelled = withoutLabel(claim);
  const skip =
    labelled === claim
      ? 1
      : Math.max(
          1,
          wordTokens(claim.slice(0, claim.length - labelled.length)).length,
        );
  wordTokens(claim).forEach((token, index) => {
    if (options.checkNames === false) {
      return;
    }
    if (index < skip || !/^\p{Lu}/u.test(token) || token.length < 3) {
      return;
    }
    const word = token.toLowerCase().replace(/'s$/, '');
    if (
      COMMON.has(word) ||
      MONTHS.includes(word) ||
      containsWord(word, passage)
    ) {
      return;
    }
    const stem = word.split('-')[0];
    if (stem.length >= 3 && passage.includes(stem)) {
      return;
    }
    lack.push(token);
  });
  if (
    RECENCY_CLAIMS.some(term => containsWord(term, normalized)) &&
    !nearAnchor(RECENCY, claim, passage, false)
  ) {
    lack.push('recency');
  }
  for (const [term, forms] of STAGES) {
    if (
      containsWord(term, normalized) &&
      !forms.some(form => containsWord(form, passage))
    ) {
      lack.push(term);
    }
  }
  for (const qualifier of QUALIFIERS) {
    if (
      containsWord(qualifier, normalized) &&
      !nearAnchor([qualifier], claim, passage)
    ) {
      lack.push(`qualifier ${qualifier}`);
    }
  }
  for (const [term, forms] of STRENGTHENINGS) {
    if (containsWord(term, normalized) && !nearAnchor(forms, claim, passage)) {
      lack.push(`qualifier ${term}`);
    }
  }
  if (options.checkCoverage !== false) {
    const {share, absent} = coverage(claim, passage);
    if (share < MIN_COVERAGE) {
      lack.push(`coverage ${Math.round(share * 100)}%: ${absent.join(' ')}`);
    }
  }
  return lack;
}

interface MarkerMatch {
  start: number;
  end: number;
  raw: string;
}

function markerRuns(text: string): MarkerMatch[] {
  const spans = codeSpans(text);
  return [...text.matchAll(MARKER_RUN)]
    .map(match => ({
      start: match.index!,
      end: match.index! + match[0].length,
      raw: match[0],
    }))
    .filter(
      match =>
        !spans.some(([from, to]) => match.start < to && match.end > from),
    );
}

export const ATTACH_COVERAGE = 0.8;

const hasAnchor = (claim: string): boolean =>
  /\d/.test(claim) ||
  wordTokens(claim)
    .slice(1)
    .some(
      token =>
        /^\p{Lu}/u.test(token) &&
        token.length >= 3 &&
        !COMMON.has(token.toLowerCase()),
    );

export interface Attachment {
  claim: string;
  source: number;
}

/**
 * Citations for an answer that used the sources but wrote no markers (the
 * Mac's "attach", simplified). An uncited factual sentence — at least four
 * words, with a number or a name to check, not a heading, a table row or
 * code — gets the one source that passes the full deterministic check on
 * its own with at least `ATTACH_COVERAGE` of its content words. Never a
 * source for a sentence no source supports; the words never change.
 */
export function attachCitations(
  text: string,
  evidence: Record<number, string>,
): {text: string; attached: Attachment[]} {
  const passages = Object.entries(evidence).map(
    ([key, value]) => [Number(key), normalizeText(value)] as const,
  );
  const attached: Attachment[] = [];
  if (passages.length === 0) {
    return {text, attached};
  }
  let inFence = false;
  const lines = text.split('\n').map(line => {
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      return line;
    }
    if (inFence || /^\s*(?:#|\||>)/.test(line) || !line.trim()) {
      return line;
    }
    return line
      .split(/(?<=[.!?。])\s+(?=\S)/u)
      .map(sentence => {
        if (
          /\[\d{1,3}(?:\s*,\s*\d{1,3})*\]/.test(sentence) ||
          sentence.includes('`')
        ) {
          return sentence;
        }
        const claim = cleanClaim(sentence.replace(/[\s.!?。:;]+$/u, ''));
        if (
          wordTokens(claim).length < 4 ||
          !hasAnchor(claim) ||
          /\?\s*$/.test(sentence)
        ) {
          return sentence;
        }
        let best: {source: number; share: number} | null = null;
        for (const [source, passage] of passages) {
          if (unsupported(claim, passage).length > 0) {
            continue;
          }
          const share = coverage(withoutLabel(claim), passage).share;
          if (share >= ATTACH_COVERAGE && share > (best?.share ?? -1)) {
            best = {source, share};
          }
        }
        if (!best) {
          return sentence;
        }
        attached.push({claim, source: best.source});
        const end = /[\s.!?。:;]+$/u.exec(sentence);
        return end
          ? `${sentence.slice(0, end.index)} [${best.source}]${end[0]}`
          : `${sentence} [${best.source}]`;
      })
      .join(' ');
  });
  return {text: attached.length ? lines.join('\n') : text, attached};
}

/** Every cited sentence of `text` with the source numbers it cites. */
export function citedClaims(
  text: string,
): Array<{claim: string; sources: number[]}> {
  const out: Array<{claim: string; sources: number[]}> = [];
  let lastEnd = 0;
  for (const match of markerRuns(text)) {
    const claim = lastSentence(text.slice(lastEnd, match.start));
    lastEnd = match.end;
    if (claim) {
      out.push({
        claim,
        sources: (match.raw.match(/\d{1,3}/g) ?? []).map(Number),
      });
    }
  }
  return out;
}

/**
 * Check every cited sentence; remove the marker of each one its sources do
 * not back. `evidence[n]` = what the model saw for source `n`.
 */
export function applyGrounding(
  text: string,
  evidence: Record<number, string>,
): GroundingResult {
  const matches = markerRuns(text);
  if (matches.length === 0) {
    return {text, checked: 0, uncited: 0, missing: [], removedClaims: []};
  }
  const lowered: Record<number, string> = {};
  const language: Record<number, string> = {};
  for (const [key, value] of Object.entries(evidence)) {
    lowered[Number(key)] = normalizeText(value);
    language[Number(key)] = scoreLanguage(value).language;
  }
  let out = '';
  let cursor = 0;
  let lastEnd = 0;
  let checked = 0;
  let uncited = 0;
  const missing: string[][] = [];
  const removedClaims: string[] = [];
  for (const match of matches) {
    const claim = lastSentence(text.slice(lastEnd, match.start));
    const numbers = (match.raw.match(/\d{1,3}/g) ?? []).map(Number);
    const passages = numbers.map(number => lowered[number]).filter(Boolean);
    out += text.slice(cursor, match.start);
    cursor = match.end;
    lastEnd = match.end;
    if (passages.length === 0 || !claim) {
      out += match.raw;
      continue;
    }
    checked += 1;
    // A claim clearly in another language than its sources (a German answer
    // over English pages) shares numbers with them, not words or noun forms.
    const claimLanguage = scoreLanguage(claim);
    const crossLanguage =
      claimLanguage.score >= 2 &&
      !numbers.some(number => language[number] === claimLanguage.language);
    const lack = unsupported(claim, passages.join('\n'), {
      checkCoverage: !crossLanguage,
      checkNames: !crossLanguage,
    });
    if (lack.length === 0) {
      out += match.raw;
    } else {
      uncited += 1;
      missing.push(lack);
      removedClaims.push(claim);
    }
  }
  out += text.slice(cursor);
  return {text: out, checked, uncited, missing, removedClaims};
}
