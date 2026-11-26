import {createEstimatingCounter} from '../../context/tokenCounter';
import {
  MEMORY_BLOCK_HEADER,
  attributeMemories,
  memoryBudgetFor,
  renderMemoryBlock,
  renderRetrievedLine,
  retrieveMemories,
  selectAlways,
  sharesTopic,
} from '../retrieval';
import {stemSet} from '../text';
import type {MemoryItem} from '../types';
import {MemoryWriter} from '../writer';
import {createFakeEmbedder} from './support/fakeEmbedder';
import {createMemoryHarness, type MemoryHarness} from './support/memoryHarness';

const counter = createEstimatingCounter();
const DAY = 86_400_000;

describe('memory budget', () => {
  it('grows with the context window and stays a small share of it', () => {
    const small = memoryBudgetFor(4096);
    const medium = memoryBudgetFor(8192);
    const large = memoryBudgetFor(16384);
    expect(small).toMatchObject({
      alwaysTokens: 220,
      digestChats: 0,
      searchChats: false,
    });
    expect(medium).toMatchObject({digestChats: 5, searchChats: true});
    expect(large.digestChats).toBe(10);
    for (const [nCtx, budget] of [
      [4096, small],
      [8192, medium],
      [16384, large],
    ] as const) {
      const total =
        budget.alwaysTokens + budget.retrievedTokens + budget.digestTokens;
      expect(total / nCtx).toBeLessThan(0.1);
    }
  });
});

describe('selectAlways', () => {
  let h: MemoryHarness;
  beforeEach(async () => {
    h = await createMemoryHarness();
  });
  afterEach(() => h.close());

  it('takes everything when it fits, in creation order', async () => {
    await h.store.add({
      text: 'User lives in Lyon',
      origin: 'user',
      kind: 'profile',
    });
    h.clock.now += 1000;
    await h.store.add({
      text: 'User is planning a trip to Japan',
      origin: 'user',
      kind: 'context',
    });
    h.clock.now += 1000;
    await h.store.add({
      text: 'User wants short answers',
      origin: 'user',
      kind: 'preference',
    });
    const picked = await selectAlways(
      await h.store.visible(),
      220,
      counter,
      h.clock.now,
    );
    expect(picked.selected.map(item => item.text)).toEqual([
      'User lives in Lyon',
      'User is planning a trip to Japan',
      'User wants short answers',
    ]);
    expect(picked.rest).toEqual([]);
    expect(picked.tokens).toBeGreaterThan(0);
    expect(picked.tokens).toBeLessThanOrEqual(220);
    expect(renderMemoryBlock(picked.selected)).toBe(
      `${MEMORY_BLOCK_HEADER}\n- User lives in Lyon\n- User is planning a trip to Japan\n- User wants short answers`,
    );
  });

  it('under pressure keeps pinned, then profile and preferences, then context', async () => {
    const add = (text: string, extra: object) =>
      h.store.add({text, origin: 'user', ...extra});
    await add('User is planning a trip to Japan in the spring', {
      kind: 'context',
    });
    await add('User is renovating the kitchen this year', {kind: 'context'});
    await add('User lives in Lyon with two children', {kind: 'profile'});
    await add('User wants short answers without preamble', {
      kind: 'preference',
    });
    await add('User once mentioned liking a blue bicycle', {
      kind: 'context',
      pinned: true,
      importance: 0.1,
    });
    const header = await counter.countText(MEMORY_BLOCK_HEADER);
    // Room for the header and about three lines.
    const picked = await selectAlways(
      await h.store.visible(),
      header + 45,
      counter,
      h.clock.now,
    );
    expect(picked.selected.map(item => item.text)).toEqual([
      'User lives in Lyon with two children',
      'User wants short answers without preamble',
      'User once mentioned liking a blue bicycle',
    ]);
    expect(picked.rest.map(item => item.kind)).toEqual(['context', 'context']);
    expect(picked.tokens).toBeLessThanOrEqual(header + 45);
  });

  it('prefers recent and used context over stale context', async () => {
    const old = await h.store.add({
      text: 'User was preparing for a driving test',
      origin: 'extraction',
      kind: 'context',
    });
    h.clock.now += 200 * DAY;
    const fresh = await h.store.add({
      text: 'User is preparing for a job interview',
      origin: 'extraction',
      kind: 'context',
    });
    const header = await counter.countText(MEMORY_BLOCK_HEADER);
    const picked = await selectAlways(
      await h.store.visible(),
      header + 16,
      counter,
      h.clock.now,
    );
    expect(picked.selected.map(item => item.id)).toEqual([fresh!.id]);
    expect(picked.rest.map(item => item.id)).toEqual([old!.id]);
  });

  it('returns nothing for an empty list', async () => {
    expect(await selectAlways([], 220, counter, 0)).toEqual({
      selected: [],
      rest: [],
      tokens: 0,
    });
    expect(renderMemoryBlock([])).toBe('');
    expect(renderRetrievedLine([])).toBe('');
  });
});

describe('retrieveMemories', () => {
  let h: MemoryHarness;
  beforeEach(async () => {
    h = await createMemoryHarness();
    for (const text of [
      'User is training for a marathon in October',
      'User has a beagle called Biscuit',
      'User is building a Flutter app for houseplants',
      'User likes cooking Persian food',
      'User works at a bank',
    ]) {
      await h.store.add({text, origin: 'extraction', kind: 'context'});
    }
  });
  afterEach(() => h.close());

  const texts = (items: MemoryItem[]) => items.map(item => item.text);

  it('finds memories that share something specific with the message', async () => {
    expect(
      texts(
        await retrieveMemories(h.store, 'Can you adjust my marathon plan?'),
      ),
    ).toEqual(['User is training for a marathon in October']);
    expect(
      texts(await retrieveMemories(h.store, 'What should I feed my beagle?')),
    ).toEqual(['User has a beagle called Biscuit']);
    // Nothing specific in common: nothing retrieved.
    expect(
      await retrieveMemories(h.store, 'What is the capital of Peru?'),
    ).toEqual([]);
    expect(await retrieveMemories(h.store, 'ok thanks')).toEqual([]);
  });

  it('skips what is already in the block and respects the limits', async () => {
    const all = await h.store.visible();
    const marathon = all.find(item => item.text.includes('marathon'))!;
    expect(
      await retrieveMemories(h.store, 'marathon plan', {
        exclude: new Set([marathon.id]),
      }),
    ).toEqual([]);
    const many = await retrieveMemories(
      h.store,
      'marathon beagle flutter persian bank',
      {limit: 2},
    );
    expect(many.length).toBeLessThanOrEqual(2);
    const tight = await retrieveMemories(
      h.store,
      'marathon beagle flutter persian bank',
      {limit: 5, tokens: 22, counter},
    );
    expect(tight).toHaveLength(1);
    expect(renderRetrievedLine(tight)).toMatch(
      /^Saved memory that may be relevant here: User /,
    );
  });

  it('stays inside the chat’s scope', async () => {
    await h.store.add({
      text: 'Marathon sponsor is Acme',
      origin: 'user',
      projectId: 'p1',
    });
    expect(
      texts(await retrieveMemories(h.store, 'marathon sponsor', {scope: {}})),
    ).toEqual(['User is training for a marathon in October']);
    expect(
      texts(
        await retrieveMemories(h.store, 'marathon sponsor', {
          scope: {projectId: 'p1', projectOnly: true},
        }),
      ),
    ).toEqual(['Marathon sponsor is Acme']);
  });

  it('with an embedding model also finds a paraphrase', async () => {
    const embedder = createFakeEmbedder();
    const writer = new MemoryWriter({
      store: h.store,
      vectors: h.vectors,
      embedder: async () => embedder,
    });
    expect(await writer.indexMissing()).toBe(5);
    const query = 'Any tips for walking a puppy in the rain?';
    // Keywords alone: nothing ("puppy" is not "beagle").
    expect(await retrieveMemories(h.store, query)).toEqual([]);
    const hybrid = await retrieveMemories(h.store, query, {
      embedder,
      vectors: h.vectors,
      minSimilarity: 0.3,
    });
    expect(texts(hybrid)).toEqual(['User has a beagle called Biscuit']);
    // A memory both retrievers agree on comes first.
    await h.store.add({text: 'User owns a puppy', origin: 'user'});
    await writer.indexMissing();
    const both = await retrieveMemories(h.store, query, {
      embedder,
      vectors: h.vectors,
      minSimilarity: 0.3,
      limit: 3,
    });
    expect(texts(both)[0]).toBe('User owns a puppy');
  });
});

describe('attributeMemories', () => {
  const memories = [
    {id: 'diet', text: 'User is vegetarian'},
    {id: 'home', text: 'User lives in Lyon'},
    {id: 'dog', text: 'User has a beagle called Biscuit'},
  ];

  it('marks the memories the answer drew on', () => {
    expect(
      attributeMemories(
        memories,
        'Give me a dinner idea',
        'How about a vegetarian chickpea curry with rice?',
      ),
    ).toEqual(['diet']);
    expect(
      attributeMemories(
        memories,
        'Where can I walk Biscuit?',
        'The Parc de la Tête d’Or in Lyon is ideal.',
      ),
    ).toEqual(['home', 'dog']);
    expect(attributeMemories(memories, 'What is 2 + 2?', 'It is 4.')).toEqual(
      [],
    );
  });

  it('needs something specific in common', () => {
    expect(
      sharesTopic(stemSet('User lives in Lyon'), stemSet('I live here')),
    ).toBe(false);
    expect(
      sharesTopic(stemSet('User lives in Lyon'), stemSet('Lyon is lovely')),
    ).toBe(true);
    expect(
      sharesTopic(
        stemSet('User works new day shifts'),
        stemSet('a new work day'),
      ),
    ).toBe(true);
  });
});
