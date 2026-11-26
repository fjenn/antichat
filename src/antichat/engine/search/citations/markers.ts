/**
 * Citation markers. The model is asked for `[n]` after the sentence — the
 * one format every 1–5 GB model tested reproduces. What they actually write
 * varies, so `normalizeMarkers` first folds the variants seen in the M8 runs
 * into the canonical form:
 *
 *   [1, 2]  [1][2]  [1,2]      → [1,2]
 *   【1】 ［1］ (1) at a sentence end, [^1], [S1], [Source 1], [source: 2]
 *   [1†source]  ¹ ²            → [n]
 *
 * `validateMarkers` (port of the Mac `CitationValidator`) then keeps only
 * numbers that name a registered source; the rest are removed from the text
 * and counted. Markers inside code are code and are never touched.
 */

export interface Citation {
  /** Cited source numbers, each valid. */
  sources: number[];
  /** Offset of the marker in the cleaned text. */
  location: number;
}

export interface MarkerValidation {
  text: string;
  citations: Citation[];
  /** Numbers that named no source and were removed. */
  dropped: number;
}

export const MARKER = /\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]/g;
const CODE = /```[\s\S]*?(?:```|$)|`[^`\n]+`/g;

const SUPERSCRIPTS = '⁰¹²³⁴⁵⁶⁷⁸⁹';

/** Ranges of fenced and inline code. */
export function codeSpans(text: string): Array<[number, number]> {
  if (!text.includes('`')) {
    return [];
  }
  return [...text.matchAll(CODE)].map(match => [
    match.index!,
    match.index! + match[0].length,
  ]);
}

const inside = (
  spans: Array<[number, number]>,
  start: number,
  end: number,
): boolean => spans.some(([from, to]) => start < to && end > from);

/** Apply `replace` to the parts of `text` outside code. */
function outsideCode(text: string, replace: (part: string) => string): string {
  const spans = codeSpans(text);
  if (spans.length === 0) {
    return replace(text);
  }
  let out = '';
  let cursor = 0;
  for (const [from, to] of spans) {
    out += replace(text.slice(cursor, from)) + text.slice(from, to);
    cursor = to;
  }
  return out + replace(text.slice(cursor));
}

/** Fold the marker variants small models write into `[n]` / `[n,m]`. */
export function normalizeMarkers(text: string): string {
  return outsideCode(text, part => {
    let out = part
      // spaces inside the brackets
      .replace(/\[\s+(\d{1,3}(?:\s*,\s*\d{1,3})*)\s*\]/g, '[$1]')
      .replace(/\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\s+\]/g, '[$1]')
      // full-width and CJK brackets
      .replace(
        /[【［]\s*(\d{1,3}(?:\s*[,、]\s*\d{1,3})*)\s*(?:†[^】］]*)?[】］]/g,
        '[$1]',
      )
      // [^1], [S1], [Source 1], [source: 2], [ref 3], [1†source]
      .replace(/\[\^(\d{1,3})\]/g, '[$1]')
      .replace(
        /\[(?:s|src|source|sources|ref|quelle|fuente)[\s:#.]*(\d{1,3}(?:\s*(?:,|and|&)\s*(?:s|source)?\s*\d{1,3})*)\]/gi,
        (_, list: string) => `[${(list.match(/\d{1,3}/g) ?? []).join(',')}]`,
      )
      .replace(/\[(\d{1,3})\s*†[^\]]*\]/g, '[$1]')
      // ranges: [1-3] → [1,2,3]
      .replace(
        /\[(\d{1,2})\s*[-–]\s*(\d{1,2})\]/g,
        (whole, a: string, b: string) => {
          const from = Number(a);
          const to = Number(b);
          if (to <= from || to - from > 6) {
            return whole;
          }
          return `[${Array.from({length: to - from + 1}, (_, i) => from + i).join(',')}]`;
        },
      )
      // superscript digits after a word
      .replace(
        new RegExp(`(?<=[\\p{L}\\p{N}.!?"”)])([${SUPERSCRIPTS}]{1,3})`, 'gu'),
        (_, digits: string) =>
          `[${[...digits].map(digit => SUPERSCRIPTS.indexOf(digit)).join('')}]`,
      )
      // (1) or (1, 2) right before sentence punctuation or a line end
      .replace(
        /\s?\((\d{1,2}(?:\s*,\s*\d{1,2})*)\)(?=\s*(?:[.!?;:]|$|\n))/gm,
        ' [$1]',
      );
    // [1][2] and [1], [2] → [1,2]
    let previous: string;
    do {
      previous = out;
      out = out.replace(
        /\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?:\s*,?\s*)\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]/g,
        '[$1,$2]',
      );
    } while (out !== previous);
    return out.replace(
      MARKER,
      (_, list: string) =>
        `[${list
          .split(',')
          .map(item => item.trim())
          .join(',')}]`,
    );
  });
}

/** Keep markers that name a known source; drop the rest. */
export function validateMarkers(
  answer: string,
  valid: Iterable<number>,
): MarkerValidation {
  const known = new Set(valid);
  const spans = codeSpans(answer);
  let out = '';
  let cursor = 0;
  let dropped = 0;
  const citations: Citation[] = [];
  for (const match of answer.matchAll(MARKER)) {
    const start = match.index!;
    const end = start + match[0].length;
    if (inside(spans, start, end)) {
      continue;
    }
    const numbers = [
      ...new Set(match[1].split(',').map(item => Number(item.trim()))),
    ];
    const ok = numbers.filter(number => known.has(number));
    dropped += numbers.length - ok.length;
    let before = answer.slice(cursor, start);
    cursor = end;
    if (ok.length === 0) {
      // Remove the marker and the space that led to it.
      before = before.replace(/[ \t]+$/, '');
      out += before;
      continue;
    }
    out += before;
    citations.push({sources: ok, location: out.length});
    out += `[${ok.join(',')}]`;
  }
  out += answer.slice(cursor);
  return {text: out, citations, dropped};
}

/** The text without any citation markers (outside code). */
export function stripMarkers(text: string): string {
  const spans = codeSpans(text);
  let out = '';
  let cursor = 0;
  for (const match of text.matchAll(/[ \t]*\[\d{1,3}(?:\s*,\s*\d{1,3})*\]/g)) {
    const start = match.index!;
    const end = start + match[0].length;
    if (inside(spans, start, end)) {
      continue;
    }
    out += text.slice(cursor, start);
    cursor = end;
  }
  return out + text.slice(cursor);
}

/** Raw URLs and markdown links the model wrote although told not to. */
export function linkifyKnownUrls(
  text: string,
  sources: Array<{n: number; url: string}>,
  normalize: (url: string) => string,
): string {
  const byKey = new Map(
    sources.map(source => [normalize(source.url), source.n]),
  );
  return outsideCode(text, part =>
    part
      .replace(
        /\[([^\]\n]{1,120})\]\((https?:\/\/[^)\s]+)\)/g,
        (whole, label: string, url: string) => {
          const n = byKey.get(normalize(url));
          return n ? `${label} [${n}]` : whole;
        },
      )
      .replace(/\(?<?(https?:\/\/[^\s)>\]]+)>?\)?/g, (whole, url: string) => {
        const n = byKey.get(normalize(url.replace(/[.,;:!?]+$/, '')));
        return n ? `[${n}]` : whole;
      }),
  );
}
