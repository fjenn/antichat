/**
 * Which memories go into the prompt (H3).
 *
 * Two tiers, both inside a small token budget that scales with the context
 * window:
 *  - **always**: pinned memories, then profile facts and answer preferences,
 *    then passing context while there is room. This is ChatGPT's own design
 *    (the whole saved list rides in every chat); on a phone the list is cut
 *    by value when it outgrows the budget.
 *  - **retrieved**: memories that did not fit, found for the current message
 *    by keyword search (FTS5 bm25 with stemming) and, when an embedding
 *    model is loaded, vector search; fused by reciprocal rank.
 */
import type {TokenCounter} from '../context/tokenCounter';
import type {Embedder} from './embeddings/types';
import type {VectorStore} from './embeddings/vectorStore';
import {memoryValue, type MemoryStore} from './MemoryStore';
import {
  COVERAGE_ALPHA,
  adaptiveKeepCount,
  reciprocalRankFusion,
} from './rankFusion';
import {coverage, normalizeFact, sharesTopic, stemSet} from './text';

export {sharesTopic};
import type {MemoryItem, MemoryScope} from './types';

export interface MemoryBudget {
  /** Tokens for the block of always-included memories. */
  alwaysTokens: number;
  /** Tokens for memories retrieved for the current message. */
  retrievedTokens: number;
  maxRetrieved: number;
  /** Past chats listed in the digest block (0 = no block). */
  digestChats: number;
  digestTokens: number;
  /** Offer `search_chats`. */
  searchChats: boolean;
}

/**
 * Memory's share of the window: about 7% on a 4k context (class A, where
 * the gap analysis caps memory near 300 tokens), about 8% from 8k up, where
 * the recent-chat digest joins.
 */
export function memoryBudgetFor(nCtx: number): MemoryBudget {
  if (nCtx < 6000) {
    return {
      alwaysTokens: 220,
      retrievedTokens: 80,
      maxRetrieved: 2,
      digestChats: 0,
      digestTokens: 0,
      searchChats: false,
    };
  }
  if (nCtx < 12000) {
    return {
      alwaysTokens: 350,
      retrievedTokens: 120,
      maxRetrieved: 3,
      digestChats: 5,
      digestTokens: 200,
      searchChats: true,
    };
  }
  return {
    alwaysTokens: 600,
    retrievedTokens: 200,
    maxRetrieved: 4,
    digestChats: 10,
    digestTokens: 400,
    searchChats: true,
  };
}

/**
 * Wording measured on both models (m9-eval.md §6): with a softer header
 * ("take them into account whenever they affect the answer") LFM3 1.7B
 * suggested a chicken dinner to a vegetarian in 5 of 16 answers; with the
 * heading and the examples in brackets, 1 of 16 (Gemma 4 E2B: 2 → 0).
 */
export const MEMORY_BLOCK_HEADER =
  '## About the user\nYou already know the following about the user. Always respect it in your answer (for example diet, allergies, where they live), without mentioning this list.';

export const RETRIEVED_PREFIX = 'Saved memory that may be relevant here: ';

const line = (item: MemoryItem): string => `- ${item.text}`;

export function renderMemoryBlock(items: MemoryItem[]): string {
  if (items.length === 0) {
    return '';
  }
  return `${MEMORY_BLOCK_HEADER}\n${items.map(line).join('\n')}`;
}

export function renderRetrievedLine(items: MemoryItem[]): string {
  if (items.length === 0) {
    return '';
  }
  return RETRIEVED_PREFIX + items.map(item => item.text).join(' | ');
}

/** Order in which memories claim room in the always-included block. */
function tier(item: MemoryItem): number {
  if (item.pinned) {
    return 0;
  }
  return item.kind === 'context' ? 2 : 1;
}

/**
 * Picks the always-included memories within `tokens`. The result is in
 * creation order, so the block's bytes do not move when ranks change.
 */
export async function selectAlways(
  items: MemoryItem[],
  tokens: number,
  counter: TokenCounter,
  now: number,
): Promise<{selected: MemoryItem[]; rest: MemoryItem[]; tokens: number}> {
  const ranked = [...items].sort(
    (a, b) =>
      tier(a) - tier(b) ||
      memoryValue(b, now) - memoryValue(a, now) ||
      a.createdAt - b.createdAt,
  );
  let used = items.length ? await counter.countText(MEMORY_BLOCK_HEADER) : 0;
  const selected: MemoryItem[] = [];
  const rest: MemoryItem[] = [];
  for (const item of ranked) {
    const cost = (await counter.countText(line(item))) + 1;
    if (used + cost <= tokens) {
      selected.push(item);
      used += cost;
    } else {
      rest.push(item);
    }
  }
  selected.sort(
    (a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id),
  );
  return {selected, rest, tokens: selected.length ? used : 0};
}

export interface RetrieveOptions {
  scope?: MemoryScope;
  /** Ids already in the always-included block. */
  exclude?: Set<string>;
  limit?: number;
  tokens?: number;
  counter?: TokenCounter;
  embedder?: Embedder | null;
  vectors?: VectorStore | null;
  /** Cosine below which a vector-only hit is ignored. */
  minSimilarity?: number;
}

const VECTOR_ONLY_FLOOR = 0.45;

/**
 * Memories relevant to `query`, best first. Keyword hits must share a
 * specific word with the query; vector hits must clear a similarity floor.
 */
export async function retrieveMemories(
  store: MemoryStore,
  query: string,
  options: RetrieveOptions = {},
): Promise<MemoryItem[]> {
  const limit = options.limit ?? 3;
  const exclude = options.exclude ?? new Set<string>();
  const wanted = stemSet(query);
  if (wanted.size === 0 || limit <= 0) {
    return [];
  }
  const scope = options.scope ?? {};
  const byId = new Map<string, MemoryItem>();

  const keyword = (await store.searchText(query, scope, 12))
    .map(hit => hit.item)
    .filter(
      item =>
        !exclude.has(item.id) &&
        sharesTopic(stemSet(normalizeFact(item.text)), wanted),
    );
  keyword.forEach(item => byId.set(item.id, item));

  let semantic: string[] = [];
  if (options.embedder && options.vectors) {
    try {
      const candidates = (await store.visible(scope)).filter(
        item => !exclude.has(item.id),
      );
      const [vector] = await options.embedder.embed([query], 'query');
      const hits = await options.vectors.nearest(
        'memory',
        vector,
        options.embedder.id,
        {
          limit: 12,
          among: candidates.map(item => item.id),
          minSimilarity: options.minSimilarity ?? VECTOR_ONLY_FLOOR,
        },
      );
      const lookup = new Map(candidates.map(item => [item.id, item]));
      semantic = hits.map(hit => hit.ownerId);
      for (const id of semantic) {
        byId.set(id, lookup.get(id)!);
      }
    } catch {
      semantic = [];
    }
  }

  const fused = reciprocalRankFusion([
    {ids: keyword.map(item => item.id)},
    {ids: semantic},
  ]);
  const ranked = [...fused.entries()]
    .map(([id, score]) => {
      const item = byId.get(id)!;
      const covered = coverage(wanted, stemSet(normalizeFact(item.text)));
      return {item, score: score * (1 + COVERAGE_ALPHA * covered)};
    })
    .sort((a, b) => b.score - a.score);
  const keep = adaptiveKeepCount(
    ranked.map(entry => entry.score),
    1,
  );
  const picked: MemoryItem[] = [];
  let used = options.counter
    ? await options.counter.countText(RETRIEVED_PREFIX)
    : 0;
  for (const {item} of ranked.slice(0, Math.min(keep, limit))) {
    if (options.counter && options.tokens !== undefined) {
      const cost = (await options.counter.countText(item.text)) + 2;
      if (used + cost > options.tokens) {
        continue;
      }
      used += cost;
    }
    picked.push(item);
  }
  return picked;
}

/**
 * Which of the memories in a prompt the answer drew on: a memory counts
 * when the reply, or the question, shares something specific with it.
 * Lexical on purpose (no model call); see the report for its limits.
 */
export function attributeMemories(
  items: Array<{id: string; text: string}>,
  userText: string,
  reply: string,
): string[] {
  const said = stemSet(`${userText}\n${reply}`);
  return items
    .filter(item => sharesTopic(stemSet(normalizeFact(item.text)), said))
    .map(item => item.id);
}
