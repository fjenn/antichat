import {
  DEFAULT_EMBEDDING_MODEL,
  EMBEDDING_GEMMA_300M,
  MINILM_L6,
} from '../embeddings/catalog';
import {
  createLlamaEmbedder,
  withPrefix,
  type EmbeddingContext,
} from '../embeddings/llamaEmbedder';
import {
  EmbeddingService,
  embeddingPolicyFor,
  type EmbeddingDeviceClass,
} from '../embeddings/service';
import {normalizeVector, truncateVector} from '../embeddings/types';
import {VectorStore, fromBlob, toBlob} from '../embeddings/vectorStore';
import {
  adaptiveKeepCount,
  cosineSimilarity,
  maximalMarginalRelevance,
  reciprocalRankFusion,
  termCoverage,
} from '../rankFusion';
import {createFakeEmbedder} from './support/fakeEmbedder';
import {createMemoryHarness, type MemoryHarness} from './support/memoryHarness';

const MB = 1024 * 1024;

/** A llama.rn embedding context that returns a fixed-shape vector. */
function scriptedContext(dims: number = 768) {
  const context = {
    texts: [] as string[],
    released: 0,
    async embedding(text: string) {
      context.texts.push(text);
      const embedding = Array.from({length: dims}, (_, i) =>
        Math.sin(i + text.length),
      );
      return {embedding};
    },
    async release() {
      context.released++;
    },
  };
  return context as typeof context & EmbeddingContext;
}

describe('vector helpers', () => {
  it('normalises and truncates (Matryoshka)', () => {
    const v = normalizeVector(new Float32Array([3, 4]));
    expect(Array.from(v)).toEqual([expect.closeTo(0.6), expect.closeTo(0.8)]);
    const cut = truncateVector([3, 4, 12, 99], 2);
    expect(cut).toHaveLength(2);
    expect(Math.hypot(...cut)).toBeCloseTo(1);
    expect(Array.from(normalizeVector(new Float32Array(3)))).toEqual([0, 0, 0]);
  });

  it('round-trips a vector through a BLOB', () => {
    const v = new Float32Array([0.25, -1.5, 3]);
    const blob = toBlob(v) as unknown as Uint8Array;
    expect(blob.byteLength).toBe(12);
    expect(Array.from(fromBlob(blob))).toEqual([0.25, -1.5, 3]);
    expect(Array.from(fromBlob(blob.buffer.slice(0)))).toEqual([0.25, -1.5, 3]);
    expect(fromBlob(null)).toHaveLength(0);
  });
});

describe('rank fusion (ported from Private Mind)', () => {
  it('fuses ranked lists by position', () => {
    const scores = reciprocalRankFusion([
      {ids: ['a', 'b', 'c']},
      {ids: ['b', 'd'], weight: 2},
    ]);
    const order = [...scores.entries()]
      .sort((x, y) => y[1] - x[1])
      .map(e => e[0]);
    expect(order).toEqual(['b', 'd', 'a', 'c']);
    expect(scores.get('a')).toBeCloseTo(1 / 61);
    expect(scores.get('b')).toBeCloseTo(1 / 62 + 2 / 61);
  });

  it('computes cosine similarity safely', () => {
    expect(cosineSimilarity([1, 0], [1, 0])).toBe(1);
    expect(cosineSimilarity([1, 0], [0, 1])).toBe(0);
    expect(cosineSimilarity([1, 0], [-1, 0])).toBe(-1);
    expect(cosineSimilarity([], [])).toBe(0);
    expect(cosineSimilarity([1, 2], [1, 2, 3])).toBe(0);
    expect(cosineSimilarity([0, 0], [1, 2])).toBe(0);
  });

  it('measures term coverage and the adaptive cut', () => {
    expect(termCoverage('Trip to Lisbon', new Set(['lisbon', 'hotel']))).toBe(
      0.5,
    );
    expect(termCoverage('x', new Set())).toBe(0);
    expect(adaptiveKeepCount([1, 0.9, 0.3, 0.29])).toBe(2);
    expect(adaptiveKeepCount([1, 0.9, 0.8])).toBe(3);
    expect(adaptiveKeepCount([1])).toBe(1);
    expect(adaptiveKeepCount([1, 0.1], 2)).toBe(2);
  });

  it('picks relevant but different candidates (MMR)', () => {
    const picked = maximalMarginalRelevance(
      [
        {id: 'a', relevance: 1, embedding: [1, 0]},
        {id: 'a2', relevance: 0.95, embedding: [1, 0.01]},
        {id: 'b', relevance: 0.7, embedding: [0, 1]},
        {id: 'c', relevance: 0.1},
      ],
      2,
    );
    expect(picked.map(candidate => candidate.id)).toEqual(['a', 'b']);
    expect(maximalMarginalRelevance([], 3)).toEqual([]);
  });
});

describe('VectorStore', () => {
  let h: MemoryHarness;
  const embedder = createFakeEmbedder();
  beforeEach(async () => {
    h = await createMemoryHarness();
  });
  afterEach(() => h.close());

  const put = async (id: string, text: string, model = embedder.id) => {
    const [vector] = await embedder.embed([text], 'document');
    await h.vectors.save('memory', id, model, vector);
  };

  it('uses the JavaScript scan where sqlite-vec is not loaded', async () => {
    expect(await h.vectors.hasSqliteVec()).toBe(false);
    expect(await new VectorStore(h.db, {forceJs: true}).hasSqliteVec()).toBe(
      false,
    );
  });

  it('stores one vector per owner and model, and finds the nearest', async () => {
    await put('dog', 'User owns a dog');
    await put('car', 'User drives an old car');
    await put('home', 'User lives in a flat in Lyon');
    await put('dog', 'User owns a dog called Rex');
    const rows = await h.db.all("SELECT * FROM vectors WHERE owner_id = 'dog'");
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({model: embedder.id, dims: embedder.dims});

    const [query] = await embedder.embed(['a puppy'], 'query');
    const hits = await h.vectors.nearest('memory', query, embedder.id);
    expect(hits[0].ownerId).toBe('dog');
    expect(hits[0].similarity).toBeGreaterThan(hits[1].similarity);
    expect(
      await h.vectors.nearest('memory', query, embedder.id, {
        among: ['car', 'home'],
        limit: 1,
      }),
    ).toHaveLength(1);
    expect(
      await h.vectors.nearest('memory', query, embedder.id, {among: []}),
    ).toEqual([]);
    expect(
      (
        await h.vectors.nearest('memory', query, embedder.id, {
          minSimilarity: 0.3,
        })
      ).map(hit => hit.ownerId),
    ).toEqual(['dog']);
  });

  it('never compares vectors of different models or sizes', async () => {
    await put('dog', 'User owns a dog');
    await put('dog', 'User owns a dog', 'other-model');
    const [query] = await embedder.embed(['a puppy'], 'query');
    expect(await h.vectors.nearest('memory', query, 'missing-model')).toEqual(
      [],
    );
    expect(
      await h.vectors.nearest('memory', query.slice(0, 16), embedder.id),
    ).toEqual([]);
    expect(
      await h.vectors.missing('memory', ['dog', 'cat'], embedder.id),
    ).toEqual(['cat']);
    await h.vectors.deleteOtherModels('memory', embedder.id);
    expect(await h.db.all('SELECT model FROM vectors')).toEqual([
      {model: embedder.id},
    ]);
    await h.vectors.delete('memory', ['dog']);
    expect((await h.vectors.load('memory', ['dog'], embedder.id)).size).toBe(0);
  });
});

describe('createLlamaEmbedder', () => {
  it('adds the model’s task prefixes and cuts to 256 dimensions', async () => {
    const context = scriptedContext();
    const embedder = createLlamaEmbedder(EMBEDDING_GEMMA_300M, context);
    expect(embedder).toMatchObject({
      id: 'embeddinggemma-300m-q8@256',
      dims: 256,
    });
    const [query] = await embedder.embed(['dinner  idea\n'], 'query');
    const [doc] = await embedder.embed(['User is vegetarian'], 'document');
    expect(context.texts).toEqual([
      'task: search result | query: dinner idea',
      'title: none | text: User is vegetarian',
    ]);
    expect(query).toHaveLength(256);
    expect(Math.hypot(...query)).toBeCloseTo(1);
    expect(doc).toHaveLength(256);
  });

  it('clips long text to the model’s window and rejects short vectors', async () => {
    const long = 'word '.repeat(5000);
    expect(withPrefix(MINILM_L6, long, 'document').length).toBeLessThanOrEqual(
      MINILM_L6.nCtx * 3,
    );
    const embedder = createLlamaEmbedder(
      EMBEDDING_GEMMA_300M,
      scriptedContext(64),
    );
    await expect(embedder.embed(['x'], 'query')).rejects.toThrow(
      '64 dimensions',
    );
  });
});

describe('EmbeddingService', () => {
  const make = (
    deviceClass: EmbeddingDeviceClass,
    extra: Partial<ConstructorParameters<typeof EmbeddingService>[0]> = {},
  ) => {
    const contexts: Array<ReturnType<typeof scriptedContext>> = [];
    const timers: Array<{fn: () => void; ms: number}> = [];
    const service = new EmbeddingService({
      modelPath: () => '/models/embeddinggemma-300M-Q8_0.gguf',
      deviceClass: () => deviceClass,
      loader: async () => {
        const context = scriptedContext();
        contexts.push(context);
        return context;
      },
      setTimer: (fn, ms) => {
        timers.push({fn, ms});
        return timers.length;
      },
      clearTimer: handle => {
        timers[(handle as number) - 1] = {fn: () => {}, ms: -1};
      },
      ...extra,
    });
    return {service, contexts, timers};
  };

  it('names the model file to add and nothing is verified yet', () => {
    expect(DEFAULT_EMBEDDING_MODEL.filename).toBe(
      'embeddinggemma-300M-Q8_0.gguf',
    );
    expect(DEFAULT_EMBEDDING_MODEL.dims).toBe(256);
    expect(DEFAULT_EMBEDDING_MODEL.verified).toBe(false);
  });

  it('follows the per-class policy', () => {
    expect(embeddingPolicyFor('A')).toMatchObject({allowed: false});
    expect(embeddingPolicyFor('B')).toMatchObject({
      allowed: true,
      queryTime: false,
      idleReleaseMs: 0,
    });
    expect(embeddingPolicyFor('C')).toMatchObject({
      queryTime: true,
      idleReleaseMs: 60_000,
    });
    expect(embeddingPolicyFor('E').idleReleaseMs).toBe(300_000);
  });

  it('loads on first use, once, and releases after the idle period', async () => {
    const {service, contexts, timers} = make('C');
    expect(service.loaded).toBe(false);
    const results = await Promise.all([
      service.use('query', e => e.embed(['a'], 'query')),
      service.use('index', e => e.embed(['b', 'c'], 'document')),
    ]);
    expect(results[0]).toHaveLength(1);
    expect(results[1]).toHaveLength(2);
    expect(contexts).toHaveLength(1);
    expect(service.loads).toBe(1);
    expect(service.loaded).toBe(true);
    const timer = timers[timers.length - 1];
    expect(timer.ms).toBe(60_000);
    // Used again before the timer fires: the old timer is void.
    await service.use('query', e => e.embed(['d'], 'query'));
    expect(contexts[0].released).toBe(0);
    timers[timers.length - 1].fn();
    await Promise.resolve();
    expect(contexts[0].released).toBe(1);
    expect(service.loaded).toBe(false);
    // The next use loads it again.
    await service.use('query', e => e.embed(['e'], 'query'));
    expect(service.loads).toBe(2);
  });

  it('on a 6 GB phone indexes and lets go at once; never loads for a send', async () => {
    const {service, contexts} = make('B');
    expect(await service.use('query', async () => 1)).toBeNull();
    expect(service.lastUnavailable).toBe('not-for-queries');
    expect(await service.use('index', async () => 'done')).toBe('done');
    await Promise.resolve();
    expect(contexts[0].released).toBe(1);
    expect(await service.provider('query')()).toBeNull();
    expect(await service.provider('index')()).not.toBeNull();
  });

  it('refuses on class A, without the file, on low memory and while chat is busy', async () => {
    const a = make('A');
    expect(await a.service.use('index', async () => 1)).toBeNull();
    expect(a.service.lastUnavailable).toBe('device-class');
    const noFile = make('D', {modelPath: () => null});
    expect(await noFile.service.use('query', async () => 1)).toBeNull();
    expect(noFile.service.lastUnavailable).toBe('no-model-file');
    const low = make('C', {availableMemory: () => 500 * MB});
    expect(await low.service.use('query', async () => 1)).toBeNull();
    expect(low.service.lastUnavailable).toBe('low-memory');
    const enough = make('C', {availableMemory: () => 900 * MB});
    expect(await enough.service.use('query', async () => 1)).toBe(1);
    const busy = make('D', {isChatBusy: () => true});
    expect(await busy.service.use('index', async () => 1)).toBeNull();
    expect(busy.service.lastUnavailable).toBe('chat-busy');
    // A send-time lookup may still load: the user is waiting for it.
    expect(await busy.service.use('query', async () => 1)).toBe(1);
    expect(a.contexts).toHaveLength(0);
    expect(low.contexts).toHaveLength(0);
  });

  it('survives a failed load and can be released by hand', async () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const failing = make('D', {
      loader: async () => {
        throw new Error('out of memory');
      },
    });
    expect(await failing.service.use('query', async () => 1)).toBeNull();
    expect(failing.service.lastUnavailable).toBe('load-failed');
    warn.mockRestore();
    const {service, contexts} = make('D');
    await service.use('query', async () => 1);
    await service.release();
    expect(contexts[0].released).toBe(1);
    await service.release();
    expect(contexts[0].released).toBe(1);
  });

  it('hands memory code an embedder that goes through the lifecycle', async () => {
    const {service, contexts} = make('D');
    const embedder = (await service.provider('query')())!;
    expect(embedder).toMatchObject({id: service.spec.id, dims: 256});
    expect(contexts).toHaveLength(0);
    const [vector] = await embedder.embed(['dinner idea'], 'query');
    expect(vector).toHaveLength(256);
    expect(contexts).toHaveLength(1);
  });
});
