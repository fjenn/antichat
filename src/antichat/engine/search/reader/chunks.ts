/**
 * Chunk selection for small context windows: split the readable text into
 * ~250-token chunks, rank them with BM25 (minisearch) against the query and
 * the user's question, keep the best few, and put them back in page order.
 *
 * `rerank` is the hook for embeddings: when the embedding model is loaded it
 * returns one score per chunk and the two rankings are fused by reciprocal
 * rank (k = 60), as on the Mac. Without it the selection is BM25 only.
 */
import MiniSearch from 'minisearch';

import {approxTokens} from '../budget';

export interface Chunk {
  /** Index of the source (page) the chunk came from. */
  source: number;
  /** Position within its source. */
  index: number;
  text: string;
  score?: number;
}

export type ChunkReranker = (
  query: string,
  chunks: Chunk[],
) => Promise<number[]>;

const SENTENCE_END = /(?<=[.!?。！？])\s+(?=[\p{Lu}\p{N}"'“([])/u;

/** Split text into chunks of about `targetTokens`, on paragraph and sentence ends. */
export function chunkText(
  text: string,
  targetTokens = 250,
  source = 0,
): Chunk[] {
  const maxChars = Math.floor(targetTokens * 3.6);
  const pieces: string[] = [];
  for (const paragraph of text.split(/\n+/)) {
    const trimmed = paragraph.trim();
    if (!trimmed) {
      continue;
    }
    if (trimmed.length <= maxChars) {
      pieces.push(trimmed);
      continue;
    }
    let current = '';
    for (const sentence of trimmed.split(SENTENCE_END)) {
      if (current && current.length + sentence.length + 1 > maxChars) {
        pieces.push(current);
        current = '';
      }
      if (sentence.length > maxChars) {
        for (let at = 0; at < sentence.length; at += maxChars) {
          pieces.push(sentence.slice(at, at + maxChars));
        }
        continue;
      }
      current = current ? `${current} ${sentence}` : sentence;
    }
    if (current) {
      pieces.push(current);
    }
  }
  // Pack short paragraphs (headings, list items) together up to the target.
  const chunks: Chunk[] = [];
  let buffer = '';
  const flush = () => {
    if (buffer.trim()) {
      chunks.push({source, index: chunks.length, text: buffer.trim()});
    }
    buffer = '';
  };
  for (const piece of pieces) {
    if (buffer && buffer.length + piece.length + 1 > maxChars) {
      flush();
    }
    buffer = buffer ? `${buffer}\n${piece}` : piece;
  }
  flush();
  return chunks;
}

const tokenize = (text: string): string[] =>
  text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(token => token.length > 1);

const STOP = new Set([
  'the',
  'and',
  'for',
  'are',
  'was',
  'what',
  'who',
  'how',
  'when',
  'where',
  'which',
  'with',
  'that',
  'this',
  'from',
  'does',
  'did',
  'has',
  'have',
  'is',
  'of',
  'in',
  'on',
  'to',
  'a',
  'an',
  'der',
  'die',
  'das',
  'und',
  'ist',
  'wie',
  'was',
  'ein',
  'eine',
  'el',
  'la',
  'los',
  'las',
  'de',
  'le',
  'les',
  'des',
  'est',
  'het',
  'een',
]);

/** BM25 scores of `chunks` for `query` (0 for a chunk that matches nothing). */
export function bm25Scores(query: string, chunks: Chunk[]): number[] {
  if (chunks.length === 0) {
    return [];
  }
  const index = new MiniSearch<{id: number; text: string}>({
    fields: ['text'],
    tokenize,
    processTerm: term => (STOP.has(term) ? null : term),
    searchOptions: {
      prefix: term => term.length > 4,
      fuzzy: false,
      combineWith: 'OR',
    },
  });
  index.addAll(chunks.map((chunk, id) => ({id, text: chunk.text})));
  const scores = new Array<number>(chunks.length).fill(0);
  const terms = tokenize(query).filter(term => !STOP.has(term));
  if (terms.length === 0) {
    return scores;
  }
  for (const hit of index.search(terms.join(' '))) {
    scores[hit.id as number] = hit.score;
  }
  return scores;
}

const ranks = (scores: number[]): number[] => {
  const order = scores
    .map((score, index) => ({score, index}))
    .sort((a, b) => b.score - a.score);
  const out = new Array<number>(scores.length).fill(0);
  order.forEach((entry, rank) => {
    out[entry.index] = rank;
  });
  return out;
};

export interface SelectOptions {
  /** Query sent to the engines plus the user's own question. */
  query: string;
  /** Token ceiling for everything returned. */
  maxTokens: number;
  /** Chunks kept per source (Mac: 2). */
  perSource?: number;
  /** Total chunks kept. */
  maxChunks?: number;
  rerank?: ChunkReranker;
}

/**
 * Pick the chunks that answer the query within the budget. Guarantees: at
 * most `perSource` per source, every source that has any matching chunk gets
 * one before any source gets a second, output in source-then-page order.
 */
export async function selectChunks(
  chunks: Chunk[],
  options: SelectOptions,
): Promise<Chunk[]> {
  if (chunks.length === 0) {
    return [];
  }
  const lexical = bm25Scores(options.query, chunks);
  let fused = lexical.slice();
  if (options.rerank) {
    try {
      const semantic = await options.rerank(options.query, chunks);
      if (semantic.length === chunks.length) {
        const a = ranks(lexical);
        const b = ranks(semantic);
        fused = chunks.map(
          (_, index) => 1 / (60 + a[index] + 1) + 1 / (60 + b[index] + 1),
        );
      }
    } catch {
      // the hook is optional: BM25 stands
    }
  }
  const scored = chunks.map((chunk, index) => ({
    ...chunk,
    score: fused[index],
  }));
  const anyMatch = scored.some(chunk => (chunk.score ?? 0) > 0);
  // Nothing matches (query in another language than the page): lead chunks.
  const ordered = anyMatch
    ? [...scored].sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
    : [...scored].sort((a, b) => a.index - b.index || a.source - b.source);
  const perSource = options.perSource ?? 2;
  const maxChunks = options.maxChunks ?? 8;
  const taken: Chunk[] = [];
  const counts = new Map<number, number>();
  let tokens = 0;
  const tryTake = (chunk: Chunk, limit: number): void => {
    if (taken.length >= maxChunks || taken.includes(chunk)) {
      return;
    }
    if (anyMatch && (chunk.score ?? 0) <= 0) {
      return;
    }
    const count = counts.get(chunk.source) ?? 0;
    if (count >= limit) {
      return;
    }
    const cost = approxTokens(chunk.text);
    if (tokens + cost > options.maxTokens) {
      return;
    }
    counts.set(chunk.source, count + 1);
    tokens += cost;
    taken.push(chunk);
  };
  // First pass: one per source; second pass: fill up to perSource.
  ordered.forEach(chunk => tryTake(chunk, 1));
  ordered.forEach(chunk => tryTake(chunk, perSource));
  return taken.sort((a, b) => a.source - b.source || a.index - b.index);
}
