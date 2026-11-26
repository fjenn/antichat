import {
  DECISION_SYSTEM_PROMPT,
  buildDecisionPrompt,
  parseDecision,
  reconcile,
} from '../reconcile';
import type {MemoryItem} from '../types';
import {
  MemoryWriter,
  inferKind,
  relatedMemories,
  writeProjectId,
} from '../writer';
import {createFakeEmbedder} from './support/fakeEmbedder';
import {createMemoryHarness, type MemoryHarness} from './support/memoryHarness';
import {createScriptedEngine} from './support/scriptedEngine';

const item = (id: string, text: string) => ({id, text}) as MemoryItem;

describe('decision prompt', () => {
  const neighbours = [
    item('a', 'User lives in Oslo.'),
    item('b', 'User has a dog.'),
  ];

  it('shows neighbours under short ids', () => {
    expect(buildDecisionPrompt('User moved to Bergen.', neighbours)).toBe(
      'Saved: [{"id":"m1","text":"User lives in Oslo."},{"id":"m2","text":"User has a dog."}]\nNew: "User moved to Bergen."',
    );
  });

  it('maps the model’s label to an action', () => {
    const parse = (raw: string, fact = 'User moved to Bergen.') =>
      parseDecision(raw, neighbours, fact);
    expect(parse('{"id":"m1","relation":"replaces"}')).toEqual({
      action: 'update',
      id: 'a',
      text: 'User moved to Bergen.',
    });
    expect(parse('{"id":"m2","relation":"same"}')).toEqual({
      action: 'none',
      id: 'b',
    });
    expect(parse('{"id":"m1","relation":"different"}')).toEqual({
      action: 'add',
      review: false,
    });
    // "Replaces" that adds nothing is a repeat.
    expect(
      parse('{"id":"m2","relation":"replaces"}', 'User has a dog'),
    ).toEqual({action: 'none', id: 'b'});
    // An id that is not on the list, or rubbish, is no decision.
    expect(parse('{"id":"m9","relation":"replaces"}')).toBeNull();
    expect(parse('I think they are the same.')).toBeNull();
    expect(parse('{"id":"m1","relation":"merge"}')).toBeNull();
  });
});

describe('reconcile and MemoryWriter', () => {
  let h: MemoryHarness;
  beforeEach(async () => {
    h = await createMemoryHarness();
  });
  afterEach(() => h.close());

  const save = (text: string, extra: Record<string, unknown> = {}) =>
    h.writer.save({text, origin: 'extraction', ...extra});
  const all = async () =>
    (await h.store.list()).map(memory => memory.text).sort();

  it('adds a new fact with a kind and an importance', async () => {
    const result = await save('User is vegetarian');
    expect(result.status).toBe('added');
    expect(result.memory).toMatchObject({
      kind: 'profile',
      origin: 'extraction',
      importance: 0.7,
    });
    const asked = await save('User loves hiking in the Alps', {explicit: true});
    expect(asked.memory).toMatchObject({kind: 'context', importance: 0.9});
  });

  it('drops an exact repeat and a near repeat', async () => {
    const first = await save('User is vegetarian.');
    h.clock.now += 5000;
    expect(await save('The user is vegetarian')).toMatchObject({
      status: 'duplicate',
      memory: {id: first.memory!.id},
    });
    await save('User has two dogs called Rex and Bo');
    expect((await save('User has two dogs, Rex and Bo')).status).toBe(
      'duplicate',
    );
    expect(await all()).toHaveLength(2);
    // The repeat refreshes the memory instead.
    expect((await h.store.get(first.memory!.id))!.updatedAt).toBe(h.clock.now);
  });

  it('drops a fact that only combines what is already saved', async () => {
    await save('User is vegetarian');
    await save('User lives in Lyon');
    expect((await save('User is a vegetarian living in Lyon')).status).toBe(
      'duplicate',
    );
    expect(await all()).toEqual(['User is vegetarian', 'User lives in Lyon']);
  });

  it('lets a more detailed wording replace the shorter one', async () => {
    const first = await save('User has a dog called Rex');
    const result = await save('User has a beagle dog called Rex');
    expect(result).toMatchObject({
      status: 'updated',
      previousText: 'User has a dog called Rex',
      memory: {id: first.memory!.id, text: 'User has a beagle dog called Rex'},
    });
    expect(await all()).toEqual(['User has a beagle dog called Rex']);
  });

  it('replaces a single-valued fact without a model', async () => {
    await save('User lives in Munich');
    await save('User works as a barista');
    expect((await save('User moved to Berlin last month')).status).toBe(
      'updated',
    );
    expect((await save('User is a data analyst at an insurer')).status).toBe(
      'updated',
    );
    expect(await all()).toEqual([
      'User is a data analyst at an insurer',
      'User moved to Berlin last month',
    ]);
  });

  it('adds a related fact without a model and flags it for review', async () => {
    await save('User is training for a marathon');
    const result = await save('User stopped marathon training');
    expect(result.status).toBe('added');
    expect((await h.store.needingReview()).map(m => m.text)).toEqual([
      'User stopped marathon training',
    ]);
    // An unrelated fact is not flagged.
    await save('User plays the cello');
    expect(await h.store.needingReview()).toHaveLength(1);
  });

  it('asks the model about related facts and follows its label', async () => {
    await save('User is training for a marathon');
    const engine = createScriptedEngine(
      () => '{"id":"m1","relation":"replaces"}',
    );
    const result = await h.writer.save(
      {text: 'User stopped marathon training', origin: 'extraction'},
      {engine, family: 'gemma4'},
    );
    expect(result).toMatchObject({status: 'updated', usedModel: true});
    expect(await all()).toEqual(['User stopped marathon training']);
    expect(engine.calls).toHaveLength(1);
    expect(engine.calls[0].system).toBe(DECISION_SYSTEM_PROMPT);
    expect(engine.calls[0].last).toContain('"User is training for a marathon"');

    engine.calls.length = 0;
    // No related memory: no model call.
    await h.writer.save(
      {text: 'User plays the cello', origin: 'extraction'},
      {engine},
    );
    expect(engine.calls).toHaveLength(0);
  });

  it('keeps both when the model says they differ, one when they are the same', async () => {
    await save('User likes Italian food');
    const different = createScriptedEngine(
      () => '{"id":"m1","relation":"different"}',
    );
    expect(
      (
        await h.writer.save(
          {text: 'User is learning Italian', origin: 'extraction'},
          {engine: different},
        )
      ).status,
    ).toBe('added');
    const same = createScriptedEngine(() => '{"id":"m1","relation":"same"}');
    expect(
      (
        await h.writer.save(
          {text: 'User enjoys Italian cuisine', origin: 'extraction'},
          {engine: same},
        )
      ).status,
    ).toBe('duplicate');
    expect(await all()).toEqual([
      'User is learning Italian',
      'User likes Italian food',
    ]);
  });

  it('falls back to the rules when the model answers rubbish', async () => {
    await save('User lives in Munich');
    const engine = createScriptedEngine(() => 'no idea');
    const result = await h.writer.save(
      {text: 'User lives in Berlin now', origin: 'extraction'},
      {engine},
    );
    expect(result.status).toBe('updated');
    expect(await all()).toEqual(['User lives in Berlin now']);
  });

  it('does not bring back a fact the user deleted, unless they ask', async () => {
    const first = await save('User is vegetarian');
    await h.store.delete([first.memory!.id], 'user');
    expect((await save('The user is a vegetarian.')).status).toBe('blocked');
    expect(await all()).toEqual([]);
    const asked = await h.writer.save({
      text: 'User is vegetarian',
      origin: 'tool',
      explicit: true,
    });
    expect(asked.status).toBe('added');
    // The tombstone is gone: later passes may confirm it.
    expect((await save('User is a vegetarian')).status).toBe('duplicate');
  });

  it('writes nothing while paused or off', async () => {
    await h.store.setPaused(true);
    expect((await save('User is vegetarian')).status).toBe('paused');
    await h.store.updateSettings({paused: false, enabled: false});
    expect((await save('User is vegetarian')).status).toBe('paused');
    expect((await save('   ')).status).toBe('empty');
    expect(await all()).toEqual([]);
  });

  it('keeps project memory apart from global memory', async () => {
    await save('User prefers British spelling');
    const scope = {projectId: 'p1', projectOnly: true};
    expect(writeProjectId(scope)).toBe('p1');
    expect(writeProjectId({projectId: 'p1'})).toBeNull();
    const inProject = await save('User prefers British spelling', {scope});
    expect(inProject.status).toBe('added');
    expect(inProject.memory!.projectId).toBe('p1');
    // In a project that shares global memory, the fact is saved globally.
    const shared = await save('Client is called Acme', {
      scope: {projectId: 'p2'},
    });
    expect(shared.memory!.projectId).toBeNull();
  });

  it('guesses a kind when none is given', () => {
    expect(inferKind('User lives in Lyon')).toBe('profile');
    expect(inferKind("User's sister is called Mia")).toBe('profile');
    expect(inferKind('User prefers short answers with bullet points')).toBe(
      'preference',
    );
    expect(inferKind('User wants answers in British English')).toBe(
      'preference',
    );
    expect(inferKind('User is building a Flutter app for houseplants')).toBe(
      'context',
    );
  });

  it('finds the saved memories a chat touches on', async () => {
    await save('User is training for a marathon');
    await save('User lives in Lyon');
    await save('User plays the cello');
    expect(
      await relatedMemories(h.store, [
        'I decided to stop marathon training.',
        'Is Lyon nice in winter?',
      ]),
    ).toEqual(['User is training for a marathon', 'User lives in Lyon']);
  });

  describe('with an embedding model', () => {
    const embedder = createFakeEmbedder();
    let writer: MemoryWriter;
    beforeEach(() => {
      writer = new MemoryWriter({
        store: h.store,
        vectors: h.vectors,
        embedder: async () => embedder,
      });
    });

    it('stores a vector with each memory', async () => {
      const result = await writer.save({
        text: 'User owns a dog',
        origin: 'extraction',
      });
      const stored = await h.vectors.load(
        'memory',
        [result.memory!.id],
        embedder.id,
      );
      expect(stored.get(result.memory!.id)).toHaveLength(embedder.dims);
    });

    it('catches a paraphrase that shares no words', async () => {
      await writer.save({text: 'User owns a dog', origin: 'extraction'});
      // Keyword search finds nothing in common; the vectors are the same.
      expect(await h.store.searchText('User has a puppy')).toEqual([]);
      const outcome = await reconcile('User has a puppy', null, {
        store: h.store,
        embedder,
        vectors: h.vectors,
      });
      expect(outcome.decision.action).toBe('none');
      expect(outcome.neighbours[0].cosine).toBeGreaterThan(0.92);
      expect(
        (await writer.save({text: 'User has a puppy', origin: 'extraction'}))
          .status,
      ).toBe('duplicate');
    });

    it('re-embeds an updated memory and indexes what is missing', async () => {
      const first = await writer.save({
        text: 'User lives in Munich',
        origin: 'extraction',
      });
      const before = (
        await h.vectors.load('memory', [first.memory!.id], embedder.id)
      ).get(first.memory!.id)!;
      await writer.save({text: 'User moved to Berlin', origin: 'extraction'});
      const after = (
        await h.vectors.load('memory', [first.memory!.id], embedder.id)
      ).get(first.memory!.id)!;
      expect(Array.from(after)).not.toEqual(Array.from(before));

      // A memory saved without the model (the tool path) is indexed later.
      const plain = new MemoryWriter({store: h.store});
      const late = await plain.save({text: 'User plays chess', origin: 'tool'});
      expect(
        await h.vectors.missing('memory', [late.memory!.id], embedder.id),
      ).toEqual([late.memory!.id]);
      expect(await writer.indexMissing()).toBe(1);
      expect(await writer.indexMissing()).toBe(0);
    });

    it('carries on with keywords when the embedder fails', async () => {
      const broken = new MemoryWriter({
        store: h.store,
        vectors: h.vectors,
        embedder: async () => {
          throw new Error('no memory');
        },
      });
      expect(
        (await broken.save({text: 'User is vegan', origin: 'extraction'}))
          .status,
      ).toBe('added');
    });
  });

  it('extracts from a chat and saves what survives the screen', async () => {
    await save('User is training for a marathon');
    const engine = createScriptedEngine(call =>
      call.system.startsWith('You maintain the long-term memory')
        ? '{"memories": [{"text": "User is a nurse.", "type": "profile", "private": false}, {"text": "User has diabetes.", "type": "profile", "private": true}, {"text": "User no longer trains for a marathon.", "type": "context", "private": false}]}'
        : '{"id":"m1","relation":"replaces"}',
    );
    const out = await h.writer.extractAndSave({
      turns: ["I'm a nurse with diabetes. I gave up on the marathon."],
      sessionId: 's1',
      model: {engine, family: 'gemma4'},
    });
    expect(out.ok).toBe(true);
    expect(out.results.map(r => r.status)).toEqual(['added', 'updated']);
    expect(await all()).toEqual([
      'User is a nurse.',
      'User no longer trains for a marathon.',
    ]);
    // The prompt saw the related saved memory.
    expect(engine.calls[0].last).toContain(
      'Already saved:\n- User is training for a marathon',
    );
    expect((await h.store.list())[0].sourceSessionId).toBe('s1');
  });

  it('reports a failed extraction and stops when aborted', async () => {
    const failing = createScriptedEngine(() => {
      throw new Error('boom');
    });
    expect(
      await h.writer.extractAndSave({
        turns: ['I live in Rome.'],
        model: {engine: failing},
      }),
    ).toEqual({ok: false, facts: [], results: []});
    const controller = new AbortController();
    const engine = createScriptedEngine(() => {
      controller.abort();
      return '{"memories": [{"text": "User lives in Rome.", "type": "profile", "private": false}]}';
    });
    const out = await h.writer.extractAndSave({
      turns: ['I live in Rome.'],
      model: {engine, signal: controller.signal},
    });
    expect(out.ok).toBe(false);
    expect(await all()).toEqual([]);
  });

  it('lets the model tidy up memories the tool saved next to similar ones', async () => {
    await save('User is training for a marathon');
    await save('User stopped marathon training');
    await save('User likes Italian food');
    await save('User is learning Italian');
    expect(await h.store.needingReview()).toHaveLength(2);
    const engine = createScriptedEngine(call =>
      call.last.includes('stopped marathon')
        ? '{"id":"m1","relation":"replaces"}'
        : '{"id":"m1","relation":"different"}',
    );
    expect(await h.writer.reviewPending({engine})).toBe(1);
    expect(await all()).toEqual([
      'User is learning Italian',
      'User likes Italian food',
      'User stopped marathon training',
    ]);
    expect(await h.store.needingReview()).toEqual([]);
  });
});
