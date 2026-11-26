/**
 * Splits an extracted document into retrieval chunks of about 450 tokens
 * with a 15% overlap, and keeps the page(s) each chunk came from, so an
 * answer can cite them.
 *
 * Splitting prefers paragraph, then line, then sentence, then word
 * boundaries. Pages are joined into one stream first, so a paragraph that
 * runs over a page break stays in one chunk (which then reports both pages).
 */
import type {ExtractedDocument} from './extract/types';

export interface Chunk {
  position: number;
  text: string;
  /** First and last page the chunk covers, 1-based. */
  pageStart: number;
  pageEnd: number;
  title?: string;
}

export interface ChunkOptions {
  targetTokens?: number;
  overlapRatio?: number;
  charsPerToken?: number;
}

export function estimateTokens(
  text: string,
  charsPerToken: number = 3.6,
): number {
  return Math.ceil(text.length / charsPerToken);
}

const SEPARATORS = ['\n\n', '\n', '. ', ' '];

/** Pieces no longer than `max`, cut at the best separator available. */
function split(text: string, max: number, level: number = 0): string[] {
  if (text.length <= max) {
    return [text];
  }
  if (level >= SEPARATORS.length) {
    const out: string[] = [];
    for (let i = 0; i < text.length; i += max) {
      out.push(text.slice(i, i + max));
    }
    return out;
  }
  const separator = SEPARATORS[level];
  const out: string[] = [];
  let start = 0;
  for (;;) {
    const at = text.indexOf(separator, start);
    const end = at < 0 ? text.length : at + separator.length;
    const piece = text.slice(start, end);
    if (piece) {
      out.push(...split(piece, max, level + 1));
    }
    if (at < 0) {
      break;
    }
    start = end;
  }
  return out;
}

export function chunkDocument(
  doc: ExtractedDocument,
  options: ChunkOptions = {},
): Chunk[] {
  const charsPerToken = options.charsPerToken ?? 3.6;
  const max = Math.floor((options.targetTokens ?? 450) * charsPerToken);
  const overlap = Math.floor(max * (options.overlapRatio ?? 0.15));

  // One stream, with the offset where every page starts.
  let stream = '';
  const starts: Array<{offset: number; page: number; title?: string}> = [];
  for (const page of doc.pages) {
    const text = page.text.trim();
    if (!text) {
      continue;
    }
    starts.push({offset: stream.length, page: page.page, title: page.title});
    stream += text + '\n\n';
  }
  const pageAt = (offset: number) => {
    let found = starts[0];
    for (const start of starts) {
      if (start.offset > offset) {
        break;
      }
      found = start;
    }
    return found;
  };

  const chunks: Chunk[] = [];
  const pieces = split(stream, max - overlap);
  let offset = 0;
  let current = '';
  let currentStart = 0;
  const emit = (end: number) => {
    const text = current.trim();
    if (!text) {
      return;
    }
    const lead = current.length - current.trimStart().length;
    const first = pageAt(currentStart + lead);
    const last = pageAt(
      Math.max(
        currentStart,
        end - 1 - (current.length - current.trimEnd().length),
      ),
    );
    chunks.push({
      position: chunks.length,
      text,
      pageStart: first.page,
      pageEnd: Math.max(first.page, last.page),
      title: first.title,
    });
  };
  for (const piece of pieces) {
    if (current && current.length + piece.length > max - overlap) {
      emit(offset);
      // Overlap: the tail of the chunk just closed, from a sentence start.
      let tail = current.slice(-overlap);
      const sentence = tail.search(/(?<=[.!?\n])\s+\S/);
      tail = sentence >= 0 ? tail.slice(sentence).trimStart() : tail;
      current = tail;
      currentStart = offset - tail.length;
    }
    if (!current) {
      currentStart = offset;
    }
    current += piece;
    offset += piece.length;
  }
  emit(offset);
  return chunks;
}
