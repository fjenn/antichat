import {attachCitations} from '../citations/grounding';
import {buildCitedAnswer} from '../citations/output';
import {
  SourceRegistry,
  peekRegistry,
  resetRegistries,
} from '../citations/registry';
import {WANTS_IMAGES, searchImages} from '../images';
import {PageCache, sharedPageCache} from '../reader/fetchPage';
import {
  createImageSearchTool,
  createReadUrlTool,
  createWebSearchTool,
} from '../searchTools';
import {SearchService} from '../service';
import type {HttpGet, SearchResult, WebSearchProvider} from '../types';

const now = new Date(2026, 10, 24, 10, 0);

const page = (title: string, body: string) =>
  `<html><head><title>${title}</title></head><body><article><h1>${title}</h1>${body}</article></body></html>`;

const PAGES: Record<string, string> = {
  'https://f1.example/vegas': page(
    'Las Vegas GP result',
    `<p>Lando Norris won the Las Vegas Grand Prix on 22 November 2026 ahead of Charles Leclerc.</p>${'<p>The race ran over 50 laps under floodlights and the pit lane was busy from the start.</p>'.repeat(6)}`,
  ),
  'https://news.example/f1': page(
    'F1 championship standings',
    `<p>Norris now leads the championship by 12 points with two races left.</p>${'<p>Teams arrive in Qatar next week for the sprint weekend.</p>'.repeat(6)}`,
  ),
};

const httpGet: HttpGet = jest.fn(async url => {
  if (url.includes('commons.wikimedia.org')) {
    return {
      status: 200,
      text: JSON.stringify({
        query: {
          pages: {
            1: {
              index: 1,
              title: 'File:Red panda.jpg',
              imageinfo: [
                {
                  url: 'https://upload.example/red-panda.jpg',
                  thumburl: 'https://upload.example/thumb.jpg',
                  width: 1200,
                  height: 800,
                  descriptionurl:
                    'https://commons.wikimedia.org/wiki/File:Red_panda.jpg',
                  extmetadata: {LicenseShortName: {value: 'CC BY-SA 4.0'}},
                },
              ],
            },
            2: {
              index: 2,
              title: 'File:Diagram.svg',
              imageinfo: [
                {url: 'https://upload.example/diagram.svg', width: 500},
              ],
            },
          },
        },
      }),
    };
  }
  const html = PAGES[url];
  return html
    ? {status: 200, text: html, contentType: 'text/html', url}
    : {status: 404, text: 'not found', contentType: 'text/html', url};
});

const results: SearchResult[] = [
  {
    engine: 'a',
    url: 'https://f1.example/vegas',
    title: 'Las Vegas GP result',
    snippet: 'Lando Norris won the Las Vegas Grand Prix.',
  },
  {
    engine: 'a',
    url: 'https://news.example/f1',
    title: 'F1 standings',
    snippet: 'Norris leads the championship.',
  },
  {
    engine: 'a',
    url: 'https://gone.example/404',
    title: 'Gone page about the race',
    snippet: 'A page about the race that no longer exists.',
  },
];

const provider = (
  list: SearchResult[] = results,
): WebSearchProvider & {queries: string[]} => {
  const queries: string[] = [];
  return {
    id: 'a',
    name: 'a',
    tier: 'race',
    queries,
    search: async request => {
      queries.push(request.query);
      return list;
    },
  };
};

beforeEach(() => {
  resetRegistries();
  sharedPageCache.clear();
});

describe('SearchService.webSearch', () => {
  it('searches, reads pages, numbers the sources and renders the block', async () => {
    const engine = provider();
    const service = new SearchService({providers: [engine], httpGet});
    const run = await service.webSearch({
      queries: ['"formula 1 race winner 2024"'],
      userText: 'Who won the Formula 1 race last weekend?',
      now,
      nCtx: 8192,
      turnId: 'turn-1',
    });
    expect(engine.queries).toEqual(['formula 1 race winner 2026']); // cleaned, stale year fixed
    expect(run.pagesRead).toBe(2);
    expect(run.pagesFailed).toBe(1);
    expect(
      run.output.sources!.map(source => [source.url, source.fetched]),
    ).toEqual([
      ['https://f1.example/vegas', true],
      ['https://news.example/f1', true],
      ['https://gone.example/404', false],
    ]);
    const text = run.output.text;
    expect(text).toContain('<web_results untrusted="true" date="2026-11-24">');
    expect(text).toContain('[1] Las Vegas GP result — f1.example');
    expect(text).toContain(
      'Lando Norris won the Las Vegas Grand Prix on 22 November 2026',
    );
    expect(text).toContain('[3] Gone page about the race — gone.example');
    expect(text).not.toContain('https://');
    expect(run.output.card).toEqual({
      type: 'sources',
      query: 'formula 1 race winner 2026',
      count: 3,
    });
    expect(peekRegistry('turn-1')!.size).toBe(3);
    expect(text.length / 3.6).toBeLessThan(run.budget.evidenceTokens + 250);
  });

  it('keeps numbering across two searches of one turn and builds pills from the answer', async () => {
    const service = new SearchService({providers: [provider()], httpGet});
    await service.webSearch({
      queries: ['f1 winner'],
      now,
      turnId: 'turn-2',
      nCtx: 8192,
    });
    const second = new SearchService({
      providers: [
        provider([
          results[1],
          {
            engine: 'a',
            url: 'https://new.example/x',
            title: 'New',
            snippet: 'Something new about Qatar.',
          },
        ]),
      ],
      httpGet,
    });
    const run = await second.webSearch({
      queries: ['f1 standings'],
      now,
      turnId: 'turn-2',
      nCtx: 8192,
    });
    const registry = peekRegistry('turn-2')!;
    const numberOf = (url: string) =>
      registry.sources.find(source => source.url === url)!.n;
    const vegas = numberOf('https://f1.example/vegas');
    const news = numberOf('https://news.example/f1');
    expect(run.output.sources!.map(source => source.n)).toEqual([news, 4]);
    expect(registry.size).toBe(4);
    const answer = buildCitedAnswer(
      `Lando Norris won the Las Vegas Grand Prix [${vegas}]. He leads the championship by 12 points [${news}].`,
      registry,
    );
    expect(answer.stats).toMatchObject({
      written: 2,
      ungrounded: 0,
      distinctSources: 2,
    });
    expect(
      answer.sources.filter(source => source.cited).map(source => source.site),
    ).toEqual(['f1.example', 'news.example']);
  });

  it('respects the small-window budget: fewer sources, at most one page', async () => {
    const service = new SearchService({providers: [provider()], httpGet});
    const run = await service.webSearch({
      queries: ['f1 winner'],
      now,
      nCtx: 4096,
    });
    expect(run.output.sources).toHaveLength(3);
    expect(run.pagesRead).toBeLessThanOrEqual(1);
    expect(run.output.text.length / 3.6).toBeLessThan(900);
  });

  it('returns a failure block, not an exception, when nothing comes back', async () => {
    const dead: WebSearchProvider = {
      id: 'dead',
      name: 'dead',
      tier: 'race',
      search: async () => {
        throw new Error('offline');
      },
    };
    const run = await new SearchService({providers: [dead], httpGet}).webSearch(
      {queries: ['x'], now},
    );
    expect(run.output.isError).toBe(true);
    expect(run.output.text).toContain('Search failed: answer without the web');
  });

  it('adds free images when the question asks to see something', async () => {
    const service = new SearchService({
      providers: [
        provider([
          {
            engine: 'a',
            url: 'https://zoo.example/red-panda',
            title: 'Red panda',
            snippet: 'The red panda lives in the eastern Himalayas.',
          },
        ]),
      ],
      httpGet,
    });
    const run = await service.webSearch({
      queries: ['red panda'],
      userText: 'What does a red panda look like?',
      now,
      turnId: 'turn-img',
    });
    expect(run.output.images).toEqual([
      {
        url: 'https://upload.example/red-panda.jpg',
        thumbnailUrl: 'https://upload.example/thumb.jpg',
        title: 'Red panda',
        sourceUrl: 'https://commons.wikimedia.org/wiki/File:Red_panda.jpg',
        width: 1200,
        height: 800,
        license: 'CC BY-SA 4.0',
      },
    ]);
    expect(peekRegistry('turn-img')!.images).toHaveLength(1);
    expect(WANTS_IMAGES.test('Who won the race?')).toBe(false);
    expect(
      await searchImages('x', {httpGet: async () => ({status: 500, text: ''})}),
    ).toEqual([]);
  });

  it('writes the direct queries for a turn from the user message', () => {
    const service = new SearchService({providers: [provider()]});
    expect(
      service.directQueries({
        userText: 'Any news on the EU AI Act this week?',
        now,
        nCtx: 8192,
      }),
    ).toEqual(['Any news on the EU AI Act this week November 2026']);
    expect(
      service.directQueries({
        userText: 'Compare the populations of Lyon and Marseille',
        now,
        nCtx: 32768,
        deviceClass: 'C',
      }),
    ).toHaveLength(3);
  });
});

describe('read_url and the tool wrappers', () => {
  it('reads one page into a numbered block within the page budget', async () => {
    const long = page(
      'Long read',
      `<p>Intro paragraph about the museum.</p>${Array.from({length: 120}, (_, i) => `<p>Paragraph ${i} talks about gallery ${i} and its paintings in some detail for visitors.</p>`).join('')}<p>Opening hours are 11:30 to 22:00 every day.</p>`,
    );
    const get: HttpGet = async url => ({
      status: 200,
      text: long,
      contentType: 'text/html',
      url,
    });
    const service = new SearchService({providers: [provider()], httpGet: get});
    const tool = createReadUrlTool(() => service);
    expect(tool.normalize!({link: 'museum.example/visit'}, {now})).toEqual({
      url: 'https://museum.example/visit',
    });
    const out = await tool.execute(
      {url: 'https://museum.example/visit'},
      {
        now,
        nCtx: 4096,
        turnId: 'turn-r',
        userText: 'What are the opening hours?',
      },
    );
    expect(out.text).toContain('[1] Long read — museum.example');
    expect(out.text).toContain('Intro paragraph about the museum.');
    expect(out.text).toContain('Opening hours are 11:30 to 22:00');
    expect(out.text.length / 3.6).toBeLessThan(950);
    expect(out.sources![0]).toMatchObject({n: 1, fetched: true});
  });

  it('explains a page that cannot be read and refuses private addresses', async () => {
    const service = new SearchService({providers: [provider()], httpGet});
    const tool = createReadUrlTool(() => service);
    const missing = await tool.execute(
      {url: 'https://gone.example/404'},
      {now},
    );
    expect(missing).toMatchObject({isError: true});
    expect(missing.text).toContain('HTTP 404');
    const local = await tool.execute({url: 'http://192.168.1.1/'}, {now});
    expect(local.text).toContain('private-range');
  });

  it('fills in the query a small model left out', () => {
    const tool = createWebSearchTool();
    const context = {
      now,
      userText: 'look up the latest stable version of React Native',
    };
    expect(tool.normalize!({}, context)).toEqual({
      query: 'the latest stable version of React Native 2026',
    });
    expect(tool.normalize!({queries: ['a', 'b']}, context)).toEqual({
      query: 'a',
    });
    expect(tool.normalize!({q: 'x', recency: 7}, context)).toEqual({
      query: 'x',
      recency_days: 7,
    });
    expect(tool.kind).toBe('online');
    expect(createImageSearchTool().tier).toBe('deferred');
  });
});

describe('attached citations', () => {
  const evidence = {
    1: 'Django releases\nDjango 6.1.3 was released on 3 November 2026. It is the latest stable version of Django.',
    2: 'Other\nSomething unrelated about gardening.',
  };

  it('cites a fully supported sentence the model left without a marker', () => {
    const result = attachCitations(
      'The latest stable version of Django is 6.1.3, released on 3 November 2026.\nIt is a great framework that many people love deeply.',
      evidence,
    );
    expect(result.text).toBe(
      'The latest stable version of Django is 6.1.3, released on 3 November 2026 [1].\nIt is a great framework that many people love deeply.',
    );
    expect(result.attached).toEqual([
      {
        claim:
          'The latest stable version of Django is 6.1.3, released on 3 November 2026',
        source: 1,
      },
    ]);
  });

  it('attaches nothing to a wrong number, a question, a heading or code', () => {
    const text =
      '## Django 6.1.3 release\nThe latest stable version of Django is 7.0.\nIs Django 6.1.3 the latest version?\n```\nDjango 6.1.3 released 3 November 2026\n```';
    expect(attachCitations(text, evidence)).toEqual({text, attached: []});
  });

  it('is applied by buildCitedAnswer only when the answer has no pill of its own', () => {
    const registry = new SourceRegistry();
    registry.add([
      {
        url: 'https://django.example/',
        title: 'Django releases',
        site: 'django.example',
        evidence: evidence[1],
      },
    ]);
    const bare = buildCitedAnswer(
      'The latest stable version of Django is 6.1.3, released on 3 November 2026.',
      registry,
    );
    expect(bare.stats).toMatchObject({
      written: 0,
      attached: 1,
      distinctSources: 1,
    });
    expect(bare.text).toContain('2026 [1].');
    const off = buildCitedAnswer(
      'The latest stable version of Django is 6.1.3.',
      registry,
      {attach: false},
    );
    expect(off.stats.distinctSources).toBe(0);
    const cache = new PageCache();
    expect(cache.get('x')).toBeUndefined();
  });
});
