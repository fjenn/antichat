import type {TalentEngine} from '../../../../services/talents/types';
import {
  FORGET_MEMORY_DEFINITION,
  SAVE_MEMORY_DEFINITION,
  SEARCH_CHATS_DEFINITION,
  createForgetMemoryTool,
  createSaveMemoryTool,
  createSearchChatsTool,
  matchForForget,
  type ToolChatContext,
} from '../tools';
import {createChatHarness, type ChatHarness} from './support/memoryHarness';

describe('memory tools', () => {
  let h: ChatHarness;
  let context: ToolChatContext;
  let save: TalentEngine;
  let forget: TalentEngine;
  let search: TalentEngine;

  beforeEach(async () => {
    h = await createChatHarness();
    context = {sessionId: 'chat-1', scope: {}};
    const options = {
      store: h.store,
      writer: h.writer,
      context: () => context,
    };
    save = createSaveMemoryTool(options);
    forget = createForgetMemoryTool(options);
    search = createSearchChatsTool({
      db: h.db,
      store: h.store,
      context: () => context,
    });
  });
  afterEach(() => h.close());

  const run = async (tool: TalentEngine, args: Record<string, unknown>) =>
    (await tool.execute(args)).summary;
  const all = async () =>
    (await h.store.list()).map(memory => memory.text).sort();

  it('describes themselves in a form small models can call', () => {
    for (const definition of [
      SAVE_MEMORY_DEFINITION,
      FORGET_MEMORY_DEFINITION,
      SEARCH_CHATS_DEFINITION,
    ]) {
      expect(definition.type).toBe('function');
      expect(definition.function.parameters.required).toHaveLength(1);
      expect(definition.function.description.length).toBeLessThan(420);
    }
    expect(save.toToolDefinition()).toBe(SAVE_MEMORY_DEFINITION);
    expect([save.name, forget.name, search.name]).toEqual([
      'save_memory',
      'forget_memory',
      'search_chats',
    ]);
  });

  it('saves a fact and says so', async () => {
    const saved = await run(save, {fact: 'User is vegetarian.'});
    expect(saved.split('\n')[0]).toBe('Saved to memory: User is vegetarian.');
    // The result asks for a reply: Gemma 4 E2B says nothing otherwise.
    expect(saved.split('\n')[1]).toMatch(
      /^Tell the user in one short sentence/,
    );
    const [memory] = await h.store.list();
    expect(memory).toMatchObject({
      origin: 'tool',
      kind: 'profile',
      sourceSessionId: 'chat-1',
      importance: 0.9,
    });
    expect(await run(save, {fact: 'The user is vegetarian'})).toContain(
      'This is already in memory',
    );
    expect(await run(save, {text: 'User lives in Lyon'})).toContain('Saved');
    expect(await run(save, {fact: 'User moved to Nantes'})).toContain(
      'Memory updated: User moved to Nantes',
    );
    expect(await run(save, {})).toContain('empty');
    expect(await all()).toEqual([
      'User is vegetarian.',
      'User moved to Nantes',
    ]);
  });

  it('refuses in a temporary chat, when paused and when switched off', async () => {
    context = {sessionId: 't1', temporary: true};
    expect(await run(save, {fact: 'User is vegetarian'})).toContain(
      'temporary chat',
    );
    expect(await run(forget, {fact: 'vegetarian'})).toContain('temporary chat');
    context = {sessionId: 'chat-1'};
    await h.store.setPaused(true);
    expect(await run(save, {fact: 'User is vegetarian'})).toContain('paused');
    await h.store.updateSettings({paused: false, enabled: false});
    expect(await run(save, {fact: 'User is vegetarian'})).toContain(
      'switched off',
    );
    expect(await all()).toEqual([]);
  });

  it('screens what the model wants to save against what the user wrote', async () => {
    context = {
      sessionId: 'chat-1',
      userText: 'I was diagnosed with diabetes last month. What does A1C mean?',
    };
    expect(await run(save, {fact: 'User has type 2 diabetes.'})).toContain(
      'private detail',
    );
    expect(await run(save, {fact: 'User asked what A1C means.'})).toContain(
      'not a lasting fact',
    );
    expect(await all()).toEqual([]);
    // The same private fact is saved when the user asks for it.
    context = {
      sessionId: 'chat-1',
      userText: 'Please remember that I have diabetes.',
    };
    expect(await run(save, {fact: 'User has diabetes.'})).toContain(
      'Saved to memory: User has diabetes.',
    );
    expect((await h.store.list())[0]).toMatchObject({
      sensitive: 'health',
      importance: 0.9,
    });
    // An ordinary fact the model saves on its own gets less weight.
    context = {sessionId: 'chat-1', userText: 'My dog Rex is a beagle.'};
    await run(save, {fact: 'User has a beagle called Rex.'});
    const dog = (await h.store.list()).find(m => m.text.includes('Rex'))!;
    expect(dog.importance).toBe(0.8);
  });

  it('does not re-save what the user deleted unless they ask again', async () => {
    await run(save, {fact: 'User is vegetarian'});
    await h.store.delete(
      (await h.store.list()).map(memory => memory.id),
      'user',
    );
    context = {sessionId: 'chat-1', userText: 'Vegetarian dinner idea please'};
    expect(await run(save, {fact: 'User is vegetarian'})).toContain(
      'deleted this memory before',
    );
    context = {sessionId: 'chat-1', userText: "Remember that I'm vegetarian"};
    expect(await run(save, {fact: 'User is vegetarian'})).toContain('Saved');
  });

  it('forgets the memory the user means, and only that', async () => {
    await run(save, {fact: 'User is vegetarian'});
    await run(save, {fact: 'User lives in Lyon'});
    await run(save, {fact: 'User has a beagle called Biscuit'});
    expect(await run(forget, {fact: 'is vegetarian'})).toContain(
      'Deleted from memory: User is vegetarian\n',
    );
    expect(await run(forget, {fact: 'my dog Biscuit'})).toContain('Biscuit');
    expect(await run(forget, {fact: 'my job'})).toBe(
      'No saved memory matches that. Nothing was deleted.',
    );
    expect(await run(forget, {})).toContain('say what to forget');
    expect(await all()).toEqual(['User lives in Lyon']);
    // Forgotten on request: the background pass will not bring it back.
    expect(await h.store.isTombstoned('User is a vegetarian')).toBe(true);
  });

  it('matches for forgetting by how well the words cover each other', async () => {
    await run(save, {fact: 'User is training for a marathon in October'});
    await run(save, {fact: 'User plays the cello'});
    const match = async (query: string) =>
      (await matchForForget(h.store, query)).map(memory => memory.text);
    expect(await match('marathon training')).toEqual([
      'User is training for a marathon in October',
    ]);
    expect(await match('User plays the cello')).toEqual([
      'User plays the cello',
    ]);
    expect(await match('favourite marathon runners of the 1990s')).toEqual([]);
    expect(await match('the')).toEqual([]);
  });

  it('keeps tool memory inside a project that keeps to itself', async () => {
    context = {sessionId: 'c', scope: {projectId: 'p1', projectOnly: true}};
    await run(save, {fact: 'Thesis deadline is 1 March'});
    expect((await h.store.list())[0].projectId).toBe('p1');
    context = {sessionId: 'other', scope: {}};
    expect(await run(forget, {fact: 'thesis deadline'})).toContain(
      'No saved memory matches',
    );
  });

  describe('search_chats', () => {
    let lisbon: string;
    beforeEach(async () => {
      lisbon = await h.addChat('Trip to Lisbon', [
        [
          'Plan a 3 day trip to Lisbon in March for two people on a budget',
          'Day 1: Alfama and the castle. Day 2: Belém and pastéis de nata. Stay near Baixa in a guesthouse.',
        ],
        [
          'Which hotel area is quiet?',
          'Campo de Ourique is quiet and well connected by tram 28.',
        ],
      ]);
      await h.addChat('Sourdough', [
        [
          'Why is my sourdough starter flat?',
          'Feed it twice a day and keep it at 24 degrees.',
        ],
      ]);
    });

    it('returns short dated excerpts from the matching chat', async () => {
      const result = await run(search, {query: 'lisbon hotel area'});
      expect(result).toMatch(
        /^Excerpts from earlier chats with the user:\n1\. "Trip to Lisbon" \(\d+ \w+ \d{4}\)\n {3}User: /,
      );
      expect(result).toContain('Assistant: ');
      expect(result).not.toContain('Sourdough');
      expect(result.length).toBeLessThan(700);
    });

    it('says so when nothing matches, and never searches the current chat', async () => {
      expect(await run(search, {query: 'quantum chromodynamics'})).toContain(
        'No earlier chat matches',
      );
      context = {sessionId: lisbon, scope: {}};
      expect(await run(search, {query: 'lisbon hotel'})).toContain(
        'No earlier chat matches',
      );
      expect(await run(search, {})).toBe('No query given.');
    });

    it('is off with chat reference off', async () => {
      await h.store.updateSettings({referenceChats: false});
      expect(await run(search, {query: 'lisbon'})).toContain('switched off');
    });

    it('fits the result to a small context', async () => {
      context = {sessionId: 'chat-1', scope: {}, resultChars: 150};
      const result = await run(search, {query: 'starter lisbon trip'});
      // One chat only: the second would not fit.
      expect(result.match(/^\d\. /gm)).toHaveLength(1);
    });
  });
});
