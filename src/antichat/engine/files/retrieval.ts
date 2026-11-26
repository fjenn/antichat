/**
 * Hybrid retrieval over a chat's file chunks: FTS5 keywords and, where the
 * embedding model may run, cosine over chunk vectors (sqlite-vec), fused by
 * reciprocal rank. Neighbouring hits of one file are kept apart so the few
 * excerpts cover more of the document.
 */
import type {EmbedderProvider} from '../memory/embeddings/types';
import type {ChunkRow, FilesStore} from './FilesStore';

export interface RetrievedChunk extends ChunkRow {
  score: number;
  how: 'keyword' | 'semantic' | 'both';
}

const STOP = new Set(
  (
    'the a an and or of to in on for with is are was were be been it this that ' +
    'what which who whom whose when where why how does do did can could should ' +
    'would about from at by as tell me please give show find document file pdf ' +
    'der die das und oder ist sind ein eine was wie wo wer el la los las y o es un una que'
  ).split(' '),
);

/** FTS5 query: any content word may match; bm25 ranks fuller matches up. */
export function keywordQuery(
  text: string,
  maxTerms: number = 12,
): string | null {
  const seen = new Set<string>();
  const terms: string[] = [];
  for (const word of text
    .normalize('NFKC')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)) {
    if (word.length < 2 || STOP.has(word) || seen.has(word)) {
      continue;
    }
    seen.add(word);
    // Prefix match for longer words: "allowance" finds "allowances".
    terms.push(word.length >= 5 ? `"${word}"*` : `"${word}"`);
    if (terms.length >= maxTerms) {
      break;
    }
  }
  return terms.length ? terms.join(' OR ') : null;
}

const RRF_K = 60;

export interface RetrieveOptions {
  limit: number;
  /** Null provider or a provider that returns null: keywords only. */
  embedder?: EmbedderProvider;
  /** Hits considered per list before fusion. */
  poolSize?: number;
}

export interface RetrieveResult {
  chunks: RetrievedChunk[];
  semantic: boolean;
}

export async function retrieveChunks(
  store: FilesStore,
  query: string,
  fileIds: string[],
  options: RetrieveOptions,
): Promise<RetrieveResult> {
  const pool = options.poolSize ?? Math.max(24, options.limit * 6);
  const scores = new Map<number, {score: number; lists: number; kw: boolean}>();
  const add = (id: number, rank: number, kw: boolean) => {
    const entry = scores.get(id) ?? {score: 0, lists: 0, kw: false};
    entry.score += 1 / (RRF_K + rank + 1);
    entry.lists++;
    entry.kw = entry.kw || kw;
    scores.set(id, entry);
  };

  const match = keywordQuery(query);
  if (match) {
    const hits = await store.keywordSearch(match, fileIds, pool);
    hits.forEach((hit, rank) => add(hit.id, rank, true));
  }

  let semantic = false;
  const embedder = await options.embedder?.().catch(() => null);
  if (embedder) {
    try {
      const among = (await store.chunkIds(fileIds)).map(String);
      const [vector] = await embedder.embed([query], 'query');
      const hits = await store.vectors.nearest('chunk', vector, embedder.id, {
        limit: pool,
        among,
      });
      hits.forEach((hit, rank) => add(Number(hit.ownerId), rank, false));
      semantic = hits.length > 0;
    } catch {
      // The model was refused (memory, chat busy): keywords carry the turn.
    }
  }

  const ranked = [...scores.entries()].sort((a, b) => b[1].score - a[1].score);
  const rows = await store.chunksById(ranked.map(([id]) => id));
  const picked: RetrievedChunk[] = [];
  for (const [id, entry] of ranked) {
    const row = rows.get(id);
    if (!row) {
      continue;
    }
    // Overlapping neighbours say the same thing twice.
    const neighbour = picked.some(
      other =>
        other.fileId === row.fileId &&
        Math.abs(other.position - row.position) === 1 &&
        picked.length >= 2,
    );
    if (neighbour) {
      continue;
    }
    picked.push({
      ...row,
      score: entry.score,
      how: entry.lists > 1 ? 'both' : entry.kw ? 'keyword' : 'semantic',
    });
    if (picked.length >= options.limit) {
      break;
    }
  }
  return {chunks: picked, semantic};
}
