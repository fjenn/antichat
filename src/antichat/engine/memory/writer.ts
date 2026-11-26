/**
 * The one way a fact becomes a saved memory, whoever found it: the
 * `save_memory` tool, the background pass over a finished chat, or the
 * manage screen. Checks the switches, asks `reconcile` what to do, writes.
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import type {ModelFamily} from '../prompt/modelFamily';
import type {EmbedderProvider} from './embeddings/types';
import type {VectorStore} from './embeddings/vectorStore';
import {extractFacts, type ExtractedFact} from './extraction';
import type {MemoryStore} from './MemoryStore';
import {
  reconcile,
  type ReconcileOutcome,
  type ReconcileThresholds,
} from './reconcile';
import {normalizeFact, slotOf} from './text';
import type {
  MemoryItem,
  MemoryKind,
  MemoryOrigin,
  MemoryScope,
  SensitiveCategory,
} from './types';

export interface ModelAccess {
  engine: CompletionEngine;
  family?: ModelFamily;
  signal?: AbortSignal;
}

export interface SaveRequest {
  text: string;
  kind?: MemoryKind;
  origin: MemoryOrigin;
  /** The user asked for this to be remembered. */
  explicit?: boolean;
  /**
   * The request is being made now (the tool, the manage screen, the capture
   * right after the user's message). Only a fresh request brings back a
   * fact the user deleted; a "remember that…" found later in an old chat
   * does not.
   */
  fresh?: boolean;
  sensitive?: SensitiveCategory | null;
  scope?: MemoryScope;
  sessionId?: string | null;
  nodeId?: string | null;
}

export type SaveStatus =
  /** A new memory was written. */
  | 'added'
  /** An existing memory was rewritten (correction or more detail). */
  | 'updated'
  /** Already known; nothing changed. */
  | 'duplicate'
  /** The user deleted this fact before; the background pass leaves it. */
  | 'blocked'
  /** Memory is off or paused. */
  | 'paused'
  | 'empty';

export interface SaveResult {
  status: SaveStatus;
  memory?: MemoryItem;
  previousText?: string;
  usedModel?: boolean;
}

export interface MemoryWriterOptions {
  store: MemoryStore;
  /** Resolves the embedding model when one may run; absent = keyword only. */
  embedder?: EmbedderProvider;
  vectors?: VectorStore;
  thresholds?: Partial<ReconcileThresholds>;
}

const PREFERENCE =
  /\b(?:answer|answers|reply|replies|respond|responses?|explain|explanations?|tone|bullet|format|concise|short|brief|detailed|formal|informal|emoji|emojis|metric|imperial|call (?:him|her|them|me))\b/;
const PROFILE =
  /\b(?:name|lives?|based|moved|born|from|works?|job|engineer|developer|teacher|student|stud(?:y|ies)|married|wife|husband|partner|girlfriend|boyfriend|son|daughter|kids?|child|children|mother|father|sister|brother|dog|cat|pet|years old|birthday|vegetarian|vegan|allerg\w*|speaks?|pronouns)\b/;

/** A kind for facts that arrive without one (the tool, the manage screen). */
export function inferKind(text: string): MemoryKind {
  const norm = normalizeFact(text);
  if (
    PREFERENCE.test(norm) &&
    /\b(?:prefer|want|like|always|never|should)/.test(norm)
  ) {
    return 'preference';
  }
  if (slotOf(text) || PROFILE.test(norm)) {
    return 'profile';
  }
  return 'context';
}

/**
 * Saved memories that share words with what the user wrote: shown to the
 * extraction prompt, so it does not repeat them and notices when one of
 * them has changed.
 */
export async function relatedMemories(
  store: MemoryStore,
  turns: string[],
  scope: MemoryScope = {},
  limit: number = 6,
): Promise<string[]> {
  const found = new Map<string, string>();
  for (const turn of turns) {
    for (const hit of await store.searchText(turn, scope, 3)) {
      if (found.size < limit) {
        found.set(hit.item.id, hit.item.text);
      }
    }
  }
  return [...found.values()];
}

/** Where a new memory is written for a chat in `scope`. */
export function writeProjectId(scope: MemoryScope = {}): string | null {
  return scope.projectId && scope.projectOnly ? scope.projectId : null;
}

function importanceFor(request: SaveRequest, kind: MemoryKind): number {
  if (request.explicit || request.origin === 'user') {
    return 0.9;
  }
  if (request.origin === 'tool') {
    return 0.8;
  }
  return kind === 'context' ? 0.45 : 0.7;
}

export class MemoryWriter {
  readonly store: MemoryStore;
  private readonly options: MemoryWriterOptions;

  constructor(options: MemoryWriterOptions) {
    this.store = options.store;
    this.options = options;
  }

  private async embedder() {
    if (!this.options.embedder || !this.options.vectors) {
      return null;
    }
    try {
      return await this.options.embedder();
    } catch {
      return null;
    }
  }

  /**
   * Saves one fact. With `model`, an unclear case (related but not the
   * same) is decided by one short generation; without it, by rules.
   */
  async save(request: SaveRequest, model?: ModelAccess): Promise<SaveResult> {
    const text = request.text.replace(/\s+/g, ' ').trim();
    if (!text) {
      return {status: 'empty'};
    }
    const {store} = this;
    if (!store.canWrite) {
      return {status: 'paused'};
    }
    const explicit = !!request.explicit || request.origin === 'user';
    const fresh =
      explicit && (request.origin !== 'extraction' || !!request.fresh);
    if (fresh) {
      await store.clearTombstone(text);
    } else if (await store.isTombstoned(text)) {
      return {status: 'blocked'};
    }
    const projectId = writeProjectId(request.scope);
    const embedder = await this.embedder();
    const outcome: ReconcileOutcome = await reconcile(text, projectId, {
      store,
      engine: model?.engine,
      family: model?.family,
      signal: model?.signal,
      embedder,
      vectors: this.options.vectors,
      thresholds: this.options.thresholds,
    });
    if (model?.signal?.aborted) {
      return {status: 'empty'};
    }
    const kind = request.kind ?? inferKind(text);
    const {decision} = outcome;
    const saveVector = async (id: string, value: string) => {
      if (!embedder || !this.options.vectors) {
        return;
      }
      try {
        const vector =
          value === text && outcome.vector
            ? outcome.vector
            : (await embedder.embed([value], 'document'))[0];
        await this.options.vectors.save('memory', id, embedder.id, vector);
      } catch {
        // The idle pass indexes what is missing.
      }
    };

    switch (decision.action) {
      case 'none': {
        if (decision.id) {
          await store.touch(decision.id);
        }
        const memory = decision.id ? await store.get(decision.id) : null;
        return {
          status: 'duplicate',
          memory: memory ?? undefined,
          usedModel: outcome.usedModel,
        };
      }
      case 'update': {
        const before = await store.get(decision.id);
        const memory = await store.update(
          decision.id,
          {
            text: decision.text,
            importance: Math.max(
              before?.importance ?? 0,
              importanceFor(request, kind),
            ),
          },
          {sessionId: request.sessionId},
        );
        if (!memory) {
          break;
        }
        await saveVector(memory.id, memory.text);
        return {
          status: 'updated',
          memory,
          previousText: before?.text,
          usedModel: outcome.usedModel,
        };
      }
      default:
        break;
    }
    const memory = await store.add(
      {
        text,
        kind,
        origin: request.origin,
        projectId,
        importance: importanceFor(request, kind),
        sensitive: request.sensitive ?? null,
        sourceSessionId: request.sessionId ?? null,
        sourceNodeId: request.nodeId ?? null,
      },
      {review: decision.action === 'add' && decision.review},
    );
    if (!memory) {
      return {status: 'paused'};
    }
    await saveVector(memory.id, memory.text);
    return {status: 'added', memory, usedModel: outcome.usedModel};
  }

  /**
   * The background pass for one chat: one extraction call over the user's
   * messages, then `save` for each fact that survives screening.
   */
  async extractAndSave(input: {
    turns: string[];
    scope?: MemoryScope;
    sessionId?: string | null;
    model: ModelAccess;
    timeoutMs?: number;
    /** The messages were written just now (see `SaveRequest.fresh`). */
    fresh?: boolean;
  }): Promise<{ok: boolean; facts: ExtractedFact[]; results: SaveResult[]}> {
    const settings = this.store.getSettings();
    if (!this.store.canWrite) {
      return {ok: true, facts: [], results: []};
    }
    const extraction = await extractFacts({
      engine: input.model.engine,
      family: input.model.family,
      signal: input.model.signal,
      turns: input.turns,
      known: await relatedMemories(this.store, input.turns, input.scope),
      includeSensitive: settings.includeSensitive,
      timeoutMs: input.timeoutMs,
    });
    const results: SaveResult[] = [];
    if (!extraction.ok) {
      return {ok: false, facts: [], results};
    }
    for (const fact of extraction.facts) {
      if (input.model.signal?.aborted) {
        return {ok: false, facts: extraction.facts, results};
      }
      results.push(
        await this.save(
          {
            text: fact.text,
            // Small models label kinds loosely ("works as a barista" as a
            // preference); where the wording is clear, the rules decide.
            kind:
              inferKind(fact.text) === 'context'
                ? fact.kind
                : inferKind(fact.text),
            origin: 'extraction',
            explicit: fact.explicit,
            fresh: input.fresh,
            sensitive: fact.sensitive,
            scope: input.scope,
            sessionId: input.sessionId,
          },
          input.model,
        ),
      );
    }
    return {ok: true, facts: extraction.facts, results};
  }

  /**
   * Memories the tool saved next to similar ones while the model was busy:
   * now that it is free, let it merge or drop them.
   */
  async reviewPending(model: ModelAccess): Promise<number> {
    let changed = 0;
    for (const item of await this.store.needingReview()) {
      if (model.signal?.aborted) {
        break;
      }
      const outcome = await reconcile(
        item.text,
        item.projectId,
        {
          store: this.store,
          engine: model.engine,
          family: model.family,
          signal: model.signal,
          thresholds: this.options.thresholds,
        },
        item.id,
      );
      if (outcome.modelFailed || model.signal?.aborted) {
        continue;
      }
      const {decision} = outcome;
      if (decision.action === 'update') {
        // The older memory takes the merged text; the newer one goes.
        await this.store.update(decision.id, {
          text: decision.text,
          importance: item.importance,
        });
        await this.store.delete([item.id], 'replaced');
        changed++;
      } else if (decision.action === 'none' && decision.id) {
        await this.store.delete([item.id], 'replaced');
        changed++;
      } else {
        await this.store.clearReview(item.id);
      }
    }
    return changed;
  }

  /** Embeds memories that have no vector for the current model yet. */
  async indexMissing(limit: number = 64): Promise<number> {
    const embedder = await this.embedder();
    const vectors = this.options.vectors;
    if (!embedder || !vectors) {
      return 0;
    }
    const all = await this.store.list();
    const missing = (
      await vectors.missing(
        'memory',
        all.map(item => item.id),
        embedder.id,
      )
    ).slice(0, limit);
    if (missing.length === 0) {
      return 0;
    }
    const byId = new Map(all.map(item => [item.id, item]));
    const embedded = await embedder.embed(
      missing.map(id => byId.get(id)!.text),
      'document',
    );
    for (let i = 0; i < missing.length; i++) {
      await vectors.save('memory', missing[i], embedder.id, embedded[i]);
    }
    return missing.length;
  }
}
