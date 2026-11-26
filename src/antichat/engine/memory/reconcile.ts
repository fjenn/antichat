/**
 * New fact against saved memories: add it, let it replace an existing one
 * (a correction or more detail), or drop it as a repeat.
 *
 * Order of evidence, cheapest first:
 *  1. same normalised text → repeat;
 *  2. word overlap (and cosine, when an embedding model is loaded) high
 *     enough → repeat, or an update when the new wording says more;
 *  3. a fact in the same single-valued slot (home, job, name, diet…)
 *     replaces the old one;
 *  4. something else related exists → one short model call that classifies
 *     the pair as same / replaces / different. This is mem0's ADD / UPDATE
 *     / NONE decision (Apache-2.0) reduced to a label: asking a 2B model
 *     to also write the merged text went wrong too often (m9-eval.md §4);
 *  5. no model free (the `save_memory` tool runs while the chat model is
 *     busy): the fact is added and flagged for the idle pass to review.
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import type {ModelFamily} from '../prompt/modelFamily';
import {runUtilityCompletion} from '../prompt/utility';
import type {Embedder} from './embeddings/types';
import {cosineSimilarity} from './rankFusion';
import type {VectorStore} from './embeddings/vectorStore';
import {parseJsonLoose} from './extraction';
import type {MemoryStore} from './MemoryStore';
import {coverage, jaccard, normalizeFact, slotOf, stemSet} from './text';
import type {MemoryItem} from './types';

export interface ReconcileThresholds {
  /** Word overlap at or above which two facts are the same fact. */
  sameJaccard: number;
  /** Word overlap at or above which the model is asked. */
  askJaccard: number;
  /** Cosine at or above which two facts are the same (Mac: 0.92). */
  sameCosine: number;
  /** Cosine at or above which the model is asked (Mac: 0.60). */
  askCosine: number;
  neighbours: number;
}

export const DEFAULT_THRESHOLDS: ReconcileThresholds = {
  sameJaccard: 0.8,
  askJaccard: 0.2,
  sameCosine: 0.92,
  askCosine: 0.6,
  neighbours: 5,
};

export type Decision =
  | {action: 'add'; review: boolean}
  | {action: 'update'; id: string; text: string}
  | {action: 'none'; id: string | null};

export interface Neighbour {
  item: MemoryItem;
  jaccard: number;
  cosine: number | null;
  sameSlot: boolean;
}

export interface ReconcileOutcome {
  decision: Decision;
  neighbours: Neighbour[];
  usedModel: boolean;
  /** The model was asked and gave nothing usable. */
  modelFailed: boolean;
  /** The new fact's vector, to store with it. */
  vector: Float32Array | null;
}

export interface ReconcileDeps {
  store: MemoryStore;
  engine?: CompletionEngine;
  family?: ModelFamily;
  embedder?: Embedder | null;
  vectors?: VectorStore | null;
  thresholds?: Partial<ReconcileThresholds>;
  signal?: AbortSignal;
}

export const DECISION_SYSTEM_PROMPT = `You compare one new fact about the user with facts that are already saved. Pick the saved fact closest to the new one and say how the new fact relates to it:
"same": the new fact says what the saved fact already says.
"replaces": same subject, but the new fact is newer, corrects it, or adds detail. The saved fact will be replaced by the new one.
"different": the new fact is about something else. Both are kept.

Examples
Saved: [{"id":"m1","text":"User lives in Oslo."}]
New: "User moved to Bergen."
{"id":"m1","relation":"replaces"}

Saved: [{"id":"m1","text":"User likes jazz."},{"id":"m2","text":"User has a dog."}]
New: "User's dog is called Rex."
{"id":"m2","relation":"replaces"}

Saved: [{"id":"m1","text":"User is vegan."}]
New: "User plays tennis."
{"id":"m1","relation":"different"}

Saved: [{"id":"m1","text":"User works as a chef."}]
New: "User is a chef."
{"id":"m1","relation":"same"}

Saved: [{"id":"m1","text":"User is learning the guitar."}]
New: "User has given up the guitar."
{"id":"m1","relation":"replaces"}`;

export const DECISION_SCHEMA = {
  type: 'object',
  properties: {
    id: {type: 'string'},
    relation: {type: 'string', enum: ['same', 'replaces', 'different']},
  },
  required: ['id', 'relation'],
  additionalProperties: false,
};

export function buildDecisionPrompt(
  fact: string,
  neighbours: MemoryItem[],
): string {
  // Short ids: a 2B model copies "m1" reliably, a 20-character id less so.
  const list = neighbours
    .map((item, index) =>
      JSON.stringify({id: `m${index + 1}`, text: item.text}),
    )
    .join(',');
  return `Saved: [${list}]\nNew: ${JSON.stringify(fact)}`;
}

/**
 * Reads the model's answer. The model only classifies; the text of an
 * update is always the new fact (small models merge two sentences badly:
 * "User lives in Chicago. User moved to Denver.").
 */
export function parseDecision(
  raw: string,
  neighbours: MemoryItem[],
  fact: string,
): Decision | null {
  const parsed = parseJsonLoose(raw) as Record<string, unknown> | null;
  if (!parsed || typeof parsed !== 'object') {
    return null;
  }
  const relation = String(parsed.relation ?? '').toLowerCase();
  const index = /^m?(\d+)$/.exec(String(parsed.id ?? '').trim());
  const target = index ? neighbours[Number(index[1]) - 1] : undefined;
  if (relation === 'different') {
    return {action: 'add', review: false};
  }
  if (!target) {
    return null;
  }
  if (relation === 'same') {
    return {action: 'none', id: target.id};
  }
  if (relation === 'replaces') {
    // "Replaces" with nothing new in it is a repeat.
    const next = stemSet(normalizeFact(fact));
    const old = stemSet(normalizeFact(target.text));
    return coverage(next, old) >= 0.99
      ? {action: 'none', id: target.id}
      : {action: 'update', id: target.id, text: fact};
  }
  return null;
}

const NEGATION =
  /\b(?:no longer|not|never|stopped|quit|gave up|given up|former|formerly|used to|anymore|any more|nicht mehr|ya no|ne plus)\b/;

/** The scope a fact is compared in: exactly where it would be written. */
const writeScope = (projectId: string | null) =>
  projectId ? {projectId, projectOnly: true} : {};

async function findNeighbours(
  fact: string,
  projectId: string | null,
  deps: ReconcileDeps,
  limits: ReconcileThresholds,
  exclude?: string,
): Promise<{neighbours: Neighbour[]; vector: Float32Array | null}> {
  const {store} = deps;
  const scope = writeScope(projectId);
  const stems = stemSet(normalizeFact(fact));
  const slot = slotOf(fact);
  const candidates = new Map<string, MemoryItem>();
  for (const hit of await store.searchText(fact, scope, limits.neighbours)) {
    candidates.set(hit.item.id, hit.item);
  }
  if (slot) {
    for (const item of await store.findBySlot(slot, scope)) {
      candidates.set(item.id, item);
    }
  }
  let vector: Float32Array | null = null;
  const cosines = new Map<string, number>();
  if (deps.embedder && deps.vectors) {
    try {
      [vector] = await deps.embedder.embed([fact], 'document');
      const all = await store.visible(scope);
      const stored = await deps.vectors.load(
        'memory',
        all.map(item => item.id),
        deps.embedder.id,
      );
      const scored = all
        .filter(item => stored.has(item.id))
        .map(item => ({
          item,
          cosine: cosineSimilarity(vector!, stored.get(item.id)!),
        }))
        .sort((a, b) => b.cosine - a.cosine);
      for (const entry of scored) {
        cosines.set(entry.item.id, entry.cosine);
      }
      for (const entry of scored.slice(0, limits.neighbours)) {
        if (entry.cosine >= limits.askCosine) {
          candidates.set(entry.item.id, entry.item);
        }
      }
    } catch {
      vector = null;
    }
  }
  if (exclude) {
    candidates.delete(exclude);
  }
  const neighbours = [...candidates.values()]
    .map(item => ({
      item,
      jaccard: jaccard(stems, stemSet(normalizeFact(item.text))),
      cosine: cosines.get(item.id) ?? null,
      sameSlot: !!slot && slotOf(item.text) === slot,
    }))
    .sort(
      (a, b) =>
        Math.max(b.jaccard, b.cosine ?? 0) - Math.max(a.jaccard, a.cosine ?? 0),
    );
  return {neighbours, vector};
}

/**
 * Decides what to do with `fact` in the scope `projectId` (null = global).
 * `exclude` is the fact's own id when a saved memory is being re-checked.
 */
export async function reconcile(
  fact: string,
  projectId: string | null,
  deps: ReconcileDeps,
  exclude?: string,
): Promise<ReconcileOutcome> {
  const limits = {...DEFAULT_THRESHOLDS, ...deps.thresholds};
  const outcome = (
    decision: Decision,
    neighbours: Neighbour[] = [],
    vector: Float32Array | null = null,
    usedModel = false,
    modelFailed = false,
  ): ReconcileOutcome => ({
    decision,
    neighbours,
    vector,
    usedModel,
    modelFailed,
  });

  const exact = await deps.store.findExact(fact, projectId);
  if (exact && exact.id !== exclude) {
    return outcome({action: 'none', id: exact.id});
  }

  const {neighbours, vector} = await findNeighbours(
    fact,
    projectId,
    deps,
    limits,
    exclude,
  );
  if (neighbours.length === 0) {
    return outcome({action: 'add', review: false}, [], vector);
  }

  // Clear repeats need no model.
  const stems = stemSet(normalizeFact(fact));
  const top = neighbours[0];
  if (
    top.jaccard >= limits.sameJaccard ||
    (top.cosine ?? 0) >= limits.sameCosine
  ) {
    const old = stemSet(normalizeFact(top.item.text));
    const saysMore = stems.size > old.size && coverage(old, stems) >= 0.99;
    return outcome(
      saysMore
        ? {action: 'update', id: top.item.id, text: fact}
        : {action: 'none', id: top.item.id},
      neighbours,
      vector,
    );
  }

  // Everything the fact says is already spread over saved memories
  // ("is a vegetarian living in Lyon" next to both halves): a repeat.
  const known = new Set<string>();
  for (const neighbour of neighbours) {
    stemSet(normalizeFact(neighbour.item.text)).forEach(s => known.add(s));
  }
  if (
    stems.size >= 2 &&
    coverage(stems, known) >= 0.99 &&
    !NEGATION.test(normalizeFact(fact))
  ) {
    return outcome(
      {action: 'none', id: neighbours[0].item.id},
      neighbours,
      vector,
    );
  }

  // One wording contains the other: more detail replaces less, less
  // detail is a repeat. Not when one of them negates ("no longer …").
  for (const neighbour of neighbours) {
    const old = stemSet(normalizeFact(neighbour.item.text));
    if (
      Math.min(old.size, stems.size) < 2 ||
      NEGATION.test(normalizeFact(fact)) !==
        NEGATION.test(normalizeFact(neighbour.item.text))
    ) {
      continue;
    }
    if (stems.size > old.size && coverage(old, stems) >= 0.99) {
      return outcome(
        {action: 'update', id: neighbour.item.id, text: fact},
        neighbours,
        vector,
      );
    }
    if (coverage(stems, old) >= 0.99) {
      return outcome(
        {action: 'none', id: neighbour.item.id},
        neighbours,
        vector,
      );
    }
  }

  const related = neighbours
    .filter(
      n =>
        n.sameSlot ||
        n.jaccard >= limits.askJaccard ||
        (n.cosine ?? 0) >= limits.askCosine,
    )
    .slice(0, limits.neighbours);
  if (related.length === 0) {
    return outcome({action: 'add', review: false}, neighbours, vector);
  }

  // A person has one home, one job, one name at a time: a new fact in
  // such a slot replaces the old one. Decided by rule even when a model is
  // free: Gemma 4 E2B called "barista" and "data analyst" different facts
  // and kept both.
  const slotMate = related.find(n => n.sameSlot);
  if (slotMate) {
    return outcome(
      {action: 'update', id: slotMate.item.id, text: fact},
      related,
      vector,
    );
  }

  let modelFailed = false;
  if (deps.engine && !deps.signal?.aborted) {
    const items = related.map(n => n.item);
    const result = await runUtilityCompletion({
      engine: deps.engine,
      family: deps.family,
      messages: [
        {role: 'system', content: DECISION_SYSTEM_PROMPT},
        {role: 'user', content: buildDecisionPrompt(fact, items)},
      ],
      maxTokens: 40,
      temperature: 0,
      jsonSchema: {name: 'memory_relation', schema: DECISION_SCHEMA},
      timeoutMs: 20000,
      signal: deps.signal,
    });
    const decision = result ? parseDecision(result.text, items, fact) : null;
    if (decision) {
      return outcome(decision, related, vector, true);
    }
    modelFailed = true;
  }

  // No model (or no usable answer): keep both and let the idle pass look.
  return outcome(
    {action: 'add', review: true},
    related,
    vector,
    modelFailed,
    modelFailed,
  );
}
