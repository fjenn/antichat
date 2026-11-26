import {formatChatSearch, searchChats, shortDate} from '../chatSearch';
import {
  DigestStore,
  renderRecentChats,
  ruleDigest,
  writeModelDigest,
} from '../digest';
import {createEstimatingCounter} from '../../context/tokenCounter';
import {createChatHarness, type ChatHarness} from './support/memoryHarness';
import {createScriptedEngine} from './support/scriptedEngine';

describe('searchChats', () => {
  let h: ChatHarness;
  let lisbon: string;
  let bread: string;

  beforeEach(async () => {
    h = await createChatHarness();
    lisbon = await h.addChat('Trip to Lisbon', [
      [
        'Plan a 3 day trip to Lisbon in March for two people on a budget',
        'Day 1: Alfama and the castle. Day 2: Belém. Stay near Baixa.',
      ],
    ]);
    bread = await h.addChat('Baking', [
      [
        'Why is my sourdough starter flat?',
        'Feed it twice a day at 24 degrees.',
      ],
      [
        'And how long should the bread proof?',
        'About four hours at room temperature.',
      ],
    ]);
  });
  afterEach(() => h.close());

  const ids = async (query: string, options = {}) =>
    (await searchChats(h.db, query, options)).map(chat => chat.sessionId);

  it('matches any of the words and ranks the chat that covers most', async () => {
    expect(await ids('lisbon budget trip')).toEqual([lisbon]);
    expect(await ids('sourdough bread proof')).toEqual([bread]);
    // A model's query usually has a word that is in no chat.
    expect(await ids('lisbon itinerary recommendations')).toEqual([lisbon]);
    expect(await ids('')).toEqual([]);
    expect(await ids('the and of')).toEqual([]);
    expect(await ids('volcano')).toEqual([]);
  });

  it('finds a chat by its title', async () => {
    expect(await ids('baking')).toEqual([bread]);
  });

  it('returns one excerpt per side of the chat, best first', async () => {
    const [chat] = await searchChats(h.db, 'sourdough starter');
    expect(chat.title).toBe('Baking');
    expect(chat.snippets[0]).toMatchObject({
      role: 'user',
      text: 'Why is my sourdough starter flat?',
    });
    expect(chat.snippets[0].messageId).toBeTruthy();
    const [trip] = await searchChats(h.db, 'alfama castle');
    expect(trip.snippets[0].role).toBe('assistant');
    expect(trip.snippets[0].text).toContain('Alfama and the castle');
  });

  it('leaves out weak hits when a strong one exists', async () => {
    await h.addChat('Other', [['How long is a marathon?', '42.195 km.']]);
    // "long" is in the marathon chat, but it covers one word of three.
    expect(await ids('how long bread proof')).toEqual([bread]);
  });

  it('never returns locked, temporary or the current chat', async () => {
    await h.chats.store.setLocked(lisbon, true);
    expect(await ids('lisbon')).toEqual([]);
    await h.chats.store.setLocked(lisbon, false);
    expect(await ids('lisbon', {excludeSessionId: lisbon})).toEqual([]);
    const temp = h.chats.up.addSession('Temp');
    await h.chats.store.markTemporary(temp);
    h.chats.up.say(temp, 'Secret trip to Lisbon');
    await h.chats.store.syncSession(temp);
    expect(await ids('secret lisbon')).toEqual([lisbon]);
    await h.chats.store.setArchived(lisbon, true);
    expect(await ids('lisbon')).toEqual([]);
    expect(await ids('lisbon', {includeArchived: true})).toEqual([lisbon]);
  });

  it('respects project walls', async () => {
    await h.chats.store.setProject(lisbon, 'p1');
    expect(await ids('lisbon', {isolatedProjectIds: ['p1']})).toEqual([]);
    expect(await ids('lisbon', {isolatedProjectIds: ['p2']})).toEqual([lisbon]);
    expect(await ids('lisbon sourdough', {onlyProjectId: 'p1'})).toEqual([
      lisbon,
    ]);
  });

  it('searches text written without spaces by substring', async () => {
    const tokyo = await h.addChat('ラーメン', [
      ['東京でおすすめのラーメン屋を教えてください', '一蘭がおすすめです。'],
    ]);
    expect(await ids('ラーメン屋')).toEqual([tokyo]);
  });

  it('formats results for a small context', async () => {
    const results = await searchChats(h.db, 'lisbon sourdough');
    const text = formatChatSearch(results, 2000);
    expect(text.split('\n')[0]).toBe(
      'Excerpts from earlier chats with the user:',
    );
    expect(text).toMatch(/1\. ".+" \(\d+ \w{3} \d{4}\)/);
    expect(formatChatSearch(results, 80).match(/^\d\. /gm)).toHaveLength(1);
    expect(formatChatSearch([])).toContain('do not guess');
    expect(shortDate(new Date(2026, 10, 3).getTime())).toBe('3 Nov 2026');
  });

  it('attaches the chat digest when there is one', async () => {
    await new DigestStore(h.db).set(
      lisbon,
      'Budget trip to Lisbon in March',
      9,
      'model',
    );
    const [chat] = await searchChats(h.db, 'lisbon');
    expect(chat.digest).toBe('Budget trip to Lisbon in March');
  });
});

describe('chat digests', () => {
  let h: ChatHarness;
  const counter = createEstimatingCounter();
  beforeEach(async () => {
    h = await createChatHarness();
  });
  afterEach(() => h.close());

  it('builds a digest from the first and the latest user message', () => {
    expect(ruleDigest([])).toBe('');
    expect(ruleDigest(['Plan a trip to Lisbon'])).toBe('Plan a trip to Lisbon');
    expect(
      ruleDigest(['Plan a trip to Lisbon', 'ok', 'Which hotel area is quiet?']),
    ).toBe('Plan a trip to Lisbon … Which hotel area is quiet?');
    expect(ruleDigest([`${'long '.repeat(80)}`]).length).toBeLessThanOrEqual(
      151,
    );
  });

  it('lists recent chats newest first, with a line even before the idle pass', async () => {
    const a = await h.addChat('Trip to Lisbon', [
      ['Plan a trip to Lisbon', 'Sure.'],
    ]);
    const b = await h.addChat('Baking', [
      ['Why is my starter flat?', 'Feed it.'],
    ]);
    await h.digests.set(a, 'Lisbon trip on a budget, three days', 5, 'model');
    const recent = await h.digests.recent({limit: 5});
    expect(recent.map(chat => [chat.sessionId, chat.digest])).toEqual([
      [b, 'Why is my starter flat?'],
      [a, 'Lisbon trip on a budget, three days'],
    ]);
    expect(
      await h.digests.recent({limit: 5, excludeSessionId: b}),
    ).toHaveLength(1);
    expect(await h.digests.recent({limit: 1})).toHaveLength(1);
    expect(await h.digests.recent({limit: 0})).toEqual([]);
    expect(await h.digests.get(a)).toMatchObject({
      source: 'model',
      throughSeq: 5,
    });
    await h.digests.delete(a);
    expect(await h.digests.get(a)).toBeNull();
  });

  it('never lists locked, archived or temporary chats, and respects projects', async () => {
    const a = await h.addChat('Locked', [['secret plan', 'ok']]);
    const b = await h.addChat('Archived', [['old plan', 'ok']]);
    const c = await h.addChat('Project', [['thesis outline', 'ok']]);
    const d = await h.addChat('Plain', [['hello there', 'hi']]);
    await h.chats.store.setLocked(a, true);
    await h.chats.store.setArchived(b, true);
    await h.chats.store.setProject(c, 'p1');
    const temp = h.chats.up.addSession('Temp');
    await h.chats.store.markTemporary(temp);
    const list = async (options = {}) =>
      (await h.digests.recent({limit: 9, ...options})).map(
        chat => chat.sessionId,
      );
    expect(await list()).toEqual([d, c]);
    expect(await list({isolatedProjectIds: ['p1']})).toEqual([d]);
    expect(await list({onlyProjectId: 'p1'})).toEqual([c]);
  });

  it('leaves memory requests out of digests', () => {
    expect(ruleDigest(["Remember that I'm vegetarian"])).toBe('');
    expect(
      ruleDigest([
        "Remember that I'm vegetarian",
        'Now plan my week of dinners',
      ]),
    ).toBe('Now plan my week of dinners');
  });

  it('takes chats that touch on a deleted memory off the recent list', async () => {
    const asked = await h.addChat('New chat', [
      ["I'm vegetarian. Dinner ideas for this week?", 'Chickpea curry…'],
    ]);
    const other = await h.addChat('Baking', [
      ['Why is my starter flat?', 'Feed it.'],
    ]);
    const noted = await h.addChat('Lunch', [
      ['What goes in a banh mi?', 'Pork…'],
    ]);
    await h.digests.set(noted, 'Vegetarian banh mi filling ideas', 3, 'model');
    const memory = await h.store.add({
      text: 'User is vegetarian',
      origin: 'extraction',
      sourceSessionId: asked,
    });
    expect(await h.digests.recent({limit: 9})).toHaveLength(3);
    await h.store.delete([memory!.id], 'user');
    const recent = await h.digests.recent({limit: 9});
    expect(recent.map(chat => chat.sessionId)).toEqual([other]);
    expect(JSON.stringify(recent)).not.toMatch(/vegetarian/i);
    expect(await h.digests.get(asked)).toMatchObject({source: 'suppressed'});
    // Still in the history: an explicit search finds it.
    expect(
      (await searchChats(h.db, 'vegetarian dinner')).map(c => c.sessionId),
    ).toEqual([asked]);
    // Eviction is not a deletion by the user: digests stay.
    const kept = await h.store.add({
      text: 'User bakes sourdough starter bread',
      origin: 'user',
    });
    await h.store.delete([kept!.id], 'evicted');
    expect((await h.digests.recent({limit: 9})).map(c => c.sessionId)).toEqual([
      other,
    ]);
  });

  it('renders the block inside its token budget', async () => {
    const chats = Array.from({length: 10}, (_, i) => ({
      sessionId: `s${i}`,
      title: `Chat number ${i}`,
      updatedAt: new Date(2026, 10, 20 - i).getTime(),
      digest: `The user asked about topic ${i} in some detail and wanted examples`,
    }));
    const full = await renderRecentChats(chats, 400, counter, true);
    expect(full.count).toBe(10);
    expect(full.text.split('\n')[1]).toBe(
      '- 20 Nov, Chat number 0: The user asked about topic 0 in some detail and wanted examples',
    );
    expect(full.text).toContain('Call search_chats');
    const tight = await renderRecentChats(chats, 120, counter, false);
    expect(tight.count).toBeLessThan(10);
    expect(tight.count).toBeGreaterThan(0);
    expect(tight.tokens).toBeLessThanOrEqual(120);
    expect(tight.text).not.toContain('search_chats');
    expect(await renderRecentChats(chats, 10, counter, true)).toEqual({
      text: '',
      count: 0,
      tokens: 0,
    });
    expect((await renderRecentChats([], 400, counter, true)).text).toBe('');
  });

  it('lets the model rewrite a digest from the previous one and the new turns', async () => {
    const engine = createScriptedEngine(
      () =>
        'Note: Budget trip to Lisbon in March; chose Campo de Ourique.\n\nextra',
    );
    const note = await writeModelDigest({
      engine,
      family: 'gemma4',
      previous: 'Budget trip to Lisbon in March',
      turns: ['Which hotel area is quiet?'],
    });
    expect(note).toBe(
      'Budget trip to Lisbon in March; chose Campo de Ourique.',
    );
    expect(engine.calls[0].last).toContain(
      'Previous note: Budget trip to Lisbon in March',
    );
    expect(engine.calls[0].last).toContain('1. Which hotel area is quiet?');
    expect(
      await writeModelDigest({
        engine: createScriptedEngine(() => 'ok'),
        turns: ['x'],
      }),
    ).toBeNull();
    expect(await writeModelDigest({engine, turns: []})).toBeNull();
  });
});
