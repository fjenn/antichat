/**
 * Scoring primitives for hybrid (keyword + vector) retrieval: plain
 * arithmetic, no model and no I/O.
 *
 * Ported from Private Mind (Software Mansion, MIT), `utils/rankFusion.ts`;
 * constants from its `constants/retrieval.ts`. Changes: vectors are
 * `Float32Array`, and MMR takes the similarity function as an argument.
 */

/** RRF constant in `weight / (k + rank)`; 60 is the paper default. */
export const RRF_K = 60;
/** MMR trade-off: higher = relevance, lower = diversity. */
export const MMR_LAMBDA = 0.7;
/** Adaptive-k: stop once relevance falls below this share of the previous. */
export const ADAPTIVE_K_DROP_RATIO = 0.45;
/** Coverage boost: `relevance *= 1 + COVERAGE_ALPHA * coverage`. */
export const COVERAGE_ALPHA = 0.5;

export interface RankedList {
  /** Ids, best first. */
  ids: string[];
  weight?: number;
}

/**
 * Fuses rank-ordered lists with `Σ weight / (k + rank)`. It uses positions,
 * not raw scores, so it can mix scales that cannot be compared (cosine and
 * bm25).
 */
export function reciprocalRankFusion(
  lists: RankedList[],
  k: number = RRF_K,
): Map<string, number> {
  const scores = new Map<string, number>();
  for (const {ids, weight = 1} of lists) {
    ids.forEach((id, index) => {
      scores.set(id, (scores.get(id) ?? 0) + weight / (k + index + 1));
    });
  }
  return scores;
}

type Vector = ArrayLike<number>;

/** Cosine similarity; 0 for empty, zero-length or mismatched vectors. */
export function cosineSimilarity(a: Vector, b: Vector): number {
  const length = a.length;
  if (length === 0 || b.length !== length) {
    return 0;
  }
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA === 0 || normB === 0) {
    return 0;
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

/** Share (0–1) of `terms` found as substrings of `text`. */
export function termCoverage(text: string, terms: Set<string>): number {
  if (terms.size === 0) {
    return 0;
  }
  const lower = text.toLowerCase();
  let hits = 0;
  for (const term of terms) {
    if (lower.includes(term)) {
      hits++;
    }
  }
  return hits / terms.size;
}

export interface MmrCandidate {
  id: string;
  relevance: number;
  embedding?: Vector;
}

/**
 * Maximal Marginal Relevance: greedily picks `count` candidates, each
 * maximising `λ·relevance − (1−λ)·(similarity to what is already picked)`.
 * Candidates without an embedding count as unlike everything.
 */
export function maximalMarginalRelevance<T extends MmrCandidate>(
  candidates: T[],
  count: number,
  lambda: number = MMR_LAMBDA,
): T[] {
  const remaining = [...candidates];
  const selected: T[] = [];
  while (selected.length < count && remaining.length > 0) {
    let bestIndex = -1;
    let bestScore = -Infinity;
    for (let i = 0; i < remaining.length; i++) {
      const candidate = remaining[i];
      let maxSimilarity = 0;
      if (candidate.embedding) {
        for (const picked of selected) {
          if (picked.embedding) {
            maxSimilarity = Math.max(
              maxSimilarity,
              cosineSimilarity(candidate.embedding, picked.embedding),
            );
          }
        }
      }
      const score = lambda * candidate.relevance - (1 - lambda) * maxSimilarity;
      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }
    if (bestIndex === -1) {
      break;
    }
    selected.push(remaining.splice(bestIndex, 1)[0]);
  }
  return selected;
}

/** Keep leading items until relevance drops below `dropRatio × previous`. */
export function adaptiveKeepCount(
  sortedScoresDesc: number[],
  minKeep: number = 1,
  dropRatio: number = ADAPTIVE_K_DROP_RATIO,
): number {
  const total = sortedScoresDesc.length;
  if (total <= minKeep) {
    return total;
  }
  for (let i = Math.max(1, minKeep); i < total; i++) {
    const previous = sortedScoresDesc[i - 1];
    if (previous > 0 && sortedScoresDesc[i] < dropRatio * previous) {
      return i;
    }
  }
  return total;
}
