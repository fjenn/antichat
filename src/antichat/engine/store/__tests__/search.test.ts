import {
  buildFtsQuery,
  buildSnippet,
  parseMarked,
  searchConversations,
} from '../search';
import {createHarness, Harness} from './support/harness';

const plain = (segments: {text: string; match: boolean}[]) =>
  segments
    .map(segment => (segment.match ? `[${segment.text}]` : segment.text))
    .join('');

describe('search', () => {
  let h: Harness;
  beforeEach(async () => {
    h = await createHarness();
  });
  afterEach(() => h.close());

  async function chat(title: string, turns: [string, string][]) {
    const s = h.up.addSession(title);
    for (const [question, reply] of turns) {
      h.up.say(s, question);
      h.up.answer(s, reply);
    }
    await h.store.syncSession(s);
    return s;
  }

  it('builds prefix queries and ignores punctuation', () => {
    expect(buildFtsQuery('banana bre')).toBe('"banana"* "bre"*');
    expect(buildFtsQuery('  "quoted" AND (x_y) ')).toBe(
      '"quoted"* "AND"* "x"* "y"*',
    );
    const mark = (text: string, query: string) =>
      plain(buildSnippet(text, query));
    expect(mark('Où est le café Zoë?', 'CAFE zo')).toBe(
      'Où est le [café] [Zoë]?',
    );
    expect(
      mark(
        'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen',
        'eight',
      ),
    ).toBe(
      '…three four five six seven [eight] nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen',
    );
    expect(
      mark('a b c d e f g h i j needle k l m n o p q r s t u v w', 'needle'),
    ).toBe('…f g h i j [needle] k l m n o p q r s…');
    expect(mark('', 'x')).toBe('');
    expect(buildFtsQuery('***')).toBeNull();
    expect(parseMarked('a \u0001b\u0002 c')).toEqual([
      {text: 'a ', match: false},
      {text: 'b', match: true},
      {text: ' c', match: false},
    ]);
  });

  it('finds message text with a highlighted snippet', async () => {
    const s = await chat('Baking', [
      [
        'How do I make banana bread?',
        'Mash three ripe bananas, fold in flour, sugar and an egg, then bake the banana bread for fifty minutes at 175 degrees until a skewer comes out clean. Let it cool in the tin before slicing so it does not crumble.',
      ],
    ]);
    await chat('Cars', [['Best tyres?', 'All-season tyres are a compromise.']]);

    const hits = await searchConversations(h.db, 'skewer');
    expect(hits).toHaveLength(1);
    const hit = hits[0];
    expect(hit.sessionId).toBe(s);
    expect(hit.title).toBe('Baking');
    expect(hit.titleMatched).toBe(false);
    expect(hit.snippet!.role).toBe('assistant');
    expect(hit.snippet!.onActivePath).toBe(true);
    expect(hit.snippet!.messageId).toBe(h.up.messages.get(s)![1].id);
    expect(plain(hit.snippet!.segments)).toContain(
      'until a [skewer] comes out',
    );
    // A snippet, not the whole message.
    expect(plain(hit.snippet!.segments).length).toBeLessThan(140);
  });

  it('matches prefixes, several words, case and accents', async () => {
    const s = await chat('Paris', [
      ['Où est le café Zoë?', 'Près de la gare.'],
    ]);
    for (const query of ['caf', 'CAFE', 'café zoe', 'zoë cafe', 'gar près']) {
      const hits = await searchConversations(h.db, query);
      expect(hits.map(hit => hit.sessionId)).toEqual([s]);
    }
    expect(await searchConversations(h.db, 'café berlin')).toEqual([]);
    expect(await searchConversations(h.db, '')).toEqual([]);
    expect(await searchConversations(h.db, '"')).toEqual([]);
  });

  it('ranks title matches first and returns one hit per chat', async () => {
    const body = await chat('Weekend', [
      ['Plan', 'We could visit the aquarium.'],
      ['More', 'The aquarium opens at nine. The aquarium has sharks.'],
    ]);
    const title = await chat('Aquarium visit', [['Tickets?', 'Buy online.']]);
    const both = await chat('Aquarium notes', [
      ['x', 'aquarium aquarium aquarium'],
    ]);

    const hits = await searchConversations(h.db, 'aquarium');
    expect(hits).toHaveLength(3);
    expect(hits[0].sessionId).toBe(both);
    expect(hits[1].sessionId).toBe(title);
    expect(hits[2].sessionId).toBe(body);
    expect(plain(hits[1].titleSegments)).toBe('[Aquarium] visit');
    expect(hits[1].snippet).toBeNull();
    expect(hits[2].messageMatches).toBe(2);
    expect(hits[2].titleSegments).toEqual([{text: 'Weekend', match: false}]);
    expect(
      await searchConversations(h.db, 'aquarium', {limit: 2}),
    ).toHaveLength(2);
  });

  it('keeps parked versions out unless asked, and reindexes on streaming', async () => {
    const s = await chat('Versions', [
      ['Tell me a fact', 'Octopuses have three hearts.'],
    ]);
    const [q, a] = h.up.messages.get(s)!;
    await h.truncate(s, q.id);
    h.up.say(s, 'Tell me a fact');
    const a2 = h.up.answer(s, 'Honey never');
    await h.store.syncSession(s);

    expect(await searchConversations(h.db, 'octopuses')).toEqual([]);
    const parked = await searchConversations(h.db, 'octopuses', {
      includeParked: true,
    });
    expect(parked[0].snippet).toMatchObject({
      nodeId: a.id,
      onActivePath: false,
      messageId: null,
    });

    expect(await searchConversations(h.db, 'spoils')).toEqual([]);
    h.up.rewrite(s, a2.id, 'Honey never spoils.');
    await h.store.syncSession(s);
    expect((await searchConversations(h.db, 'spoils'))[0].sessionId).toBe(s);
    expect(await searchConversations(h.db, 'never spoils octopuses')).toEqual(
      [],
    );

    // Showing the parked version flips which one search sees.
    await h.store.showNode(s, a.id);
    expect(
      (await searchConversations(h.db, 'octopuses'))[0].snippet!.onActivePath,
    ).toBe(true);
    expect(await searchConversations(h.db, 'spoils')).toEqual([]);
  });

  it('finds text in scripts written without spaces', async () => {
    const s = await chat('正規表現のヘルプ', [
      [
        'メールアドレスを検証する正規表現を教えてください。',
        '確認メールを送るのが確実です。',
      ],
    ]);
    const hits = await searchConversations(h.db, '検証');
    expect(hits[0].sessionId).toBe(s);
    expect(plain(hits[0].snippet!.segments)).toContain('[検証]');
    const byTitle = await searchConversations(h.db, '正規表現');
    expect(byTitle[0].titleMatched).toBe(true);
    expect(plain(byTitle[0].titleSegments)).toBe('[正規表現]のヘルプ');
    expect(await searchConversations(h.db, '存在しない')).toEqual([]);
    expect(await searchConversations(h.db, '100%')).toEqual([]);
  });

  it('answers in well under 100 ms over 5,000 messages', async () => {
    const words =
      'river mountain invoice kettle saxophone garden tensor holiday budget lantern recipe compiler harbour violin meadow passport quantum sandwich telescope umbrella'.split(
        ' ',
      );
    let seed = 7;
    const next = (n: number) => {
      seed = (seed * 48271) % 2147483647;
      return seed % n;
    };
    const sentence = (length: number) =>
      Array.from({length}, () => words[next(words.length)]).join(' ');
    for (let c = 0; c < 100; c++) {
      const s = h.up.addSession(`Chat ${c} ${sentence(3)}`);
      for (let m = 0; m < 25; m++) {
        h.up.say(s, sentence(12));
        h.up.answer(s, sentence(120));
      }
    }
    const needle = h.up.addSession('Needle');
    h.up.say(needle, 'where is the xylophone hidden');
    await h.store.syncAll();
    expect((await h.store.stats()).nodes).toBe(5001);

    const queries = [
      'xylophone',
      'saxophone garden',
      'quant',
      'holiday budget recipe',
      'tele umb',
    ];
    const times: number[] = [];
    for (let round = 0; round < 10; round++) {
      for (const query of queries) {
        const start = performance.now();
        const hits = await searchConversations(h.db, query);
        times.push(performance.now() - start);
        expect([query, hits.length > 0]).toEqual([query, true]);
      }
    }
    times.sort((a, b) => a - b);
    const median = times[Math.floor(times.length / 2)];
    const worst = times[times.length - 1];
    console.info(
      `search over 5,001 messages (Node SQLite): median ${median.toFixed(2)} ms, worst ${worst.toFixed(2)} ms`,
    );
    expect((await searchConversations(h.db, 'xylophone'))[0].sessionId).toBe(
      needle,
    );
    expect(worst).toBeLessThan(100);
  }, 60_000);
});
