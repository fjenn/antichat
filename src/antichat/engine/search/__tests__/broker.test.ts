import {
  EngineStats,
  SearchBroker,
  mergeResults,
  relevantShare,
} from '../broker';
import {DEFAULT_ENGINES} from '../engines/config';
import {
  ScrapeEngineProvider,
  type WebViewScraper,
} from '../engines/scrapeProvider';
import {WikipediaProvider} from '../engines/wikipedia';
import fixtures from '../__fixtures__/serp.json';
import {HttpError} from '../http';
import {normalizeUrl} from '../html';
import {
  SearchProviderError,
  type HttpGet,
  type SearchRequest,
  type SearchResult,
  type WebSearchProvider,
} from '../types';
import {fromUpstreamProvider} from '../upstreamProvider';
import {
  WebViewScrapeController,
  isAllowedScrapeNavigation,
  parseSerpMessage,
} from '../webview/scraper';
import {buildSerpParserJs} from '../webview/serpScript';

const hit = (
  engine: string,
  url: string,
  title = 'T',
  snippet = 'snippet text',
): SearchResult => ({
  engine,
  url,
  title,
  snippet,
});

const provider = (
  id: string,
  behaviour: (request: SearchRequest) => Promise<SearchResult[]>,
  tier: 'race' | 'fallback' = 'race',
  available = true,
): WebSearchProvider & {calls: SearchRequest[]} => {
  const calls: SearchRequest[] = [];
  return {
    id,
    name: id,
    tier,
    calls,
    isAvailable: () => available,
    search: request => {
      calls.push(request);
      return behaviour(request);
    },
  };
};

const later = <T>(ms: number, value: T): Promise<T> =>
  new Promise(resolve => setTimeout(() => resolve(value), ms));

describe('mergeResults', () => {
  it('dedupes by normalised URL and ranks agreement first', () => {
    const merged = mergeResults(
      [
        [
          hit('a', 'https://www.one.example/page/'),
          hit('a', 'https://two.example/x?utm_source=q'),
        ],
        [
          hit('b', 'https://two.example/x'),
          hit('b', 'http://one.example/page'),
          hit('b', 'https://three.example/'),
        ],
      ],
      {query: 'anything'},
    );
    expect(merged.map(result => normalizeUrl(result.url))).toEqual([
      'one.example/page',
      'two.example/x',
      'three.example',
    ]);
    expect(merged[0].engines).toEqual(['a', 'b']);
    expect(merged[2].engines).toEqual(['b']);
  });

  it('prefers an exact URL over a rebuilt one and keeps the longer snippet', () => {
    const merged = mergeResults([
      [
        {
          ...hit('brave', 'https://bbc.co.uk/sport/tennis', 'Tennis', 'short'),
          approximateUrl: true,
        },
      ],
      [
        hit(
          'duckduckgo',
          'https://www.bbc.co.uk/sport/tennis',
          'Tennis',
          'a much longer snippet here',
        ),
      ],
    ]);
    expect(merged).toHaveLength(1);
    expect(merged[0]).toMatchObject({
      url: 'https://www.bbc.co.uk/sport/tennis',
      snippet: 'a much longer snippet here',
    });
    expect(merged[0].approximateUrl).toBeUndefined();
  });

  it('caps results per host and demotes low-value hosts', () => {
    const merged = mergeResults(
      [
        [
          hit('a', 'https://site.example/1'),
          hit('a', 'https://site.example/2'),
          hit('a', 'https://site.example/3'),
          hit('a', 'https://www.pinterest.com/pin/1'),
          hit('a', 'https://other.example/'),
        ],
      ],
      {limit: 4},
    );
    expect(merged.map(result => result.url)).toEqual([
      'https://site.example/1',
      'https://site.example/2',
      'https://other.example/',
      'https://www.pinterest.com/pin/1',
    ]);
  });
});

describe('SearchBroker', () => {
  it('races the engines and merges what came back', async () => {
    const a = provider('a', async () => [
      hit('a', 'https://one.example/'),
      hit('a', 'https://two.example/'),
    ]);
    const b = provider('b', async () => [
      hit('b', 'https://two.example/'),
      hit('b', 'https://three.example/'),
    ]);
    const fallback = provider(
      'wikipedia',
      async () => [hit('wikipedia', 'https://wiki.example/')],
      'fallback',
    );
    const broker = new SearchBroker({
      providers: [a, b, fallback],
      minResults: 3,
    });
    const outcome = await broker.search({
      queries: ['q'],
      maxResults: 5,
      language: 'de',
      recencyDays: 7,
    });
    expect(outcome.results.map(result => result.url)).toEqual([
      'https://two.example/',
      'https://one.example/',
      'https://three.example/',
    ]);
    expect(
      outcome.attempts.map(attempt => [
        attempt.engine,
        attempt.ok,
        attempt.count,
      ]),
    ).toEqual([
      ['a', true, 2],
      ['b', true, 2],
    ]);
    expect(fallback.calls).toHaveLength(0);
    expect(a.calls[0]).toMatchObject({
      query: 'q',
      language: 'de',
      recencyDays: 7,
      maxResults: 5,
    });
  });

  it('answers at the grace period instead of waiting for a slow engine', async () => {
    const fast = provider('fast', async () => [
      hit('fast', 'https://one.example/'),
      hit('fast', 'https://two.example/'),
      hit('fast', 'https://three.example/'),
    ]);
    const slow = provider('slow', () =>
      later(400, [hit('slow', 'https://late.example/')]),
    );
    const broker = new SearchBroker({
      providers: [fast, slow],
      raceBudgetMs: 1000,
      graceMs: 30,
    });
    const started = Date.now();
    const outcome = await broker.search({queries: ['q'], maxResults: 5});
    expect(Date.now() - started).toBeLessThan(300);
    expect(outcome.results).toHaveLength(3);
    expect(
      outcome.attempts.find(attempt => attempt.engine === 'slow'),
    ).toMatchObject({
      ok: false,
      kind: 'timeout',
    });
  });

  it('falls back in order when the race comes back empty', async () => {
    const blocked = provider('duckduckgo', async () => {
      throw new SearchProviderError('blocked', 'blocked (202)');
    });
    const empty = provider('mojeek', async () => []);
    const you = provider(
      'you',
      async () => [hit('you', 'https://one.example/')],
      'fallback',
    );
    const wiki = provider(
      'wikipedia',
      async () => [hit('wikipedia', 'https://en.wikipedia.org/wiki/X')],
      'fallback',
    );
    const broker = new SearchBroker({
      providers: [blocked, empty, you, wiki],
      minResults: 2,
    });
    const outcome = await broker.search({queries: ['q'], maxResults: 5});
    expect(outcome.results.map(result => result.engine)).toEqual([
      'you',
      'wikipedia',
    ]);
    expect(
      outcome.attempts.map(
        attempt => `${attempt.engine}:${attempt.kind ?? 'ok'}`,
      ),
    ).toEqual(['duckduckgo:blocked', 'mojeek:empty', 'you:ok', 'wikipedia:ok']);
    expect(outcome.failure).toBeUndefined();
  });

  it('promotes the first fallback into the race when only one engine is healthy', async () => {
    const only = provider('duckduckgo', async () => [
      hit('duckduckgo', 'https://one.example/'),
      hit('duckduckgo', 'https://two.example/'),
    ]);
    const down = provider('brave', async () => [], 'race', false);
    const you = provider(
      'you',
      async () => [
        hit('you', 'https://two.example/'),
        hit('you', 'https://three.example/'),
      ],
      'fallback',
    );
    const wiki = provider('wikipedia', async () => [], 'fallback');
    const broker = new SearchBroker({providers: [only, down, you, wiki]});
    const outcome = await broker.search({queries: ['q'], maxResults: 5});
    expect(down.calls).toHaveLength(0);
    expect(you.calls).toHaveLength(1);
    expect(wiki.calls).toHaveLength(0);
    expect(outcome.results[0]).toMatchObject({
      url: 'https://two.example/',
      engines: ['duckduckgo', 'you'],
    });
  });

  it('runs several queries in parallel and reports a total failure', async () => {
    const a = provider('a', async request => [
      hit('a', `https://${request.query}.example/`),
    ]);
    const b = provider('b', async request => [
      hit('b', `https://${request.query}.example/b`),
    ]);
    const broker = new SearchBroker({providers: [a, b], minResults: 1});
    const outcome = await broker.search({
      queries: ['x', 'y', 'x', ' '],
      maxResults: 5,
    });
    expect(outcome.queries).toEqual(['x', 'y']);
    expect(outcome.results).toHaveLength(4);

    const dead = new SearchBroker({
      providers: [
        provider('a', async () => {
          throw new SearchProviderError('timeout', 't');
        }),
      ],
    });
    const failed = await dead.search({queries: ['q'], maxResults: 5});
    expect(failed).toMatchObject({results: [], failure: 'timeout'});
    expect((await dead.search({queries: [], maxResults: 5})).failure).toBe(
      'no query',
    );
  });

  it('discards a result page that has nothing to do with the query', async () => {
    const junk = provider('bing', async () => [
      hit(
        'bing',
        'https://shop.example/wine-fridge',
        'Cava de vinos para 12 botellas',
        'Estantes de madera',
      ),
      hit(
        'bing',
        'https://shop.example/12-botellas',
        '12 Botellas',
        'Coleccion',
      ),
      hit(
        'bing',
        'https://market.example/cava',
        'Cava Vondom 12 Botellas',
        'Envio gratis',
      ),
    ]);
    const wiki = provider(
      'wikipedia',
      async () => [
        hit(
          'wikipedia',
          'https://en.wikipedia.org/wiki/Node.js',
          'Node.js',
          'Node.js release history',
        ),
      ],
      'fallback',
    );
    const broker = new SearchBroker({providers: [junk, wiki], minResults: 1});
    const outcome = await broker.search({
      queries: ['When was the most recent release of Node.js published 2026'],
      maxResults: 5,
    });
    expect(outcome.attempts[0]).toMatchObject({
      engine: 'bing',
      ok: false,
      kind: 'irrelevant',
    });
    expect(outcome.results.map(result => result.engine)).toEqual(['wikipedia']);
    expect(
      relevantShare(
        [
          hit(
            'a',
            'https://nodejs.org/en/blog/release',
            'Node.js 26 released',
            '',
          ),
        ],
        'most recent release of Node.js',
      ),
    ).toBe(1);
  });

  it('feeds per-engine statistics', async () => {
    const stats = new EngineStats();
    const broker = new SearchBroker({
      providers: [
        provider('a', async () => [hit('a', 'https://one.example/')]),
        provider('b', async () => {
          throw new SearchProviderError('blocked', 'x');
        }),
      ],
      minResults: 1,
      onAttempt: stats.record,
    });
    await broker.search({queries: ['q1'], maxResults: 3});
    await broker.search({queries: ['q2'], maxResults: 3});
    expect(stats.summary()).toMatchObject({
      a: {calls: 2, hitRate: 1},
      b: {calls: 2, hitRate: 0, failures: {blocked: 2}},
    });
  });
});

describe('ScrapeEngineProvider', () => {
  const engine = (id: string) =>
    DEFAULT_ENGINES.find(candidate => candidate.id === id)!;
  const page = (text: string, status = 200): ReturnType<HttpGet> =>
    Promise.resolve({status, text});

  it('parses a fetched result page', async () => {
    const urls: string[] = [];
    const scraper = new ScrapeEngineProvider(engine('duckduckgo'), {
      httpGet: url => {
        urls.push(url);
        return page(fixtures.duckduckgo);
      },
    });
    const results = await scraper.search({
      query: 'tennis news',
      maxResults: 2,
      language: 'en',
    });
    expect(results).toHaveLength(2);
    expect(results[0].engine).toBe('duckduckgo');
    expect(urls).toEqual([
      'https://html.duckduckgo.com/html/?q=tennis%20news&kl=wt-wt',
    ]);
  });

  it('tries the second endpoint when the first is blocked', async () => {
    const urls: string[] = [];
    const scraper = new ScrapeEngineProvider(engine('duckduckgo'), {
      httpGet: url => {
        urls.push(url);
        return url.includes('html.duckduckgo')
          ? page('<html>anomaly captcha</html>', 202)
          : page(fixtures.duckduckgoLite);
      },
    });
    const results = await scraper.search({query: 'q', maxResults: 5});
    expect(results.length).toBeGreaterThan(0);
    expect(urls[1]).toContain('lite.duckduckgo.com');
  });

  it('reports blocked, then uses the WebView when one is attached', async () => {
    let ready = false;
    const scraped: string[] = [];
    const webView: WebViewScraper = {
      isReady: () => ready,
      scrape: async url => {
        scraped.push(url);
        return [hit('x', 'https://one.example/')];
      },
    };
    let fetches = 0;
    const scraper = new ScrapeEngineProvider(engine('mojeek'), {
      httpGet: () => {
        fetches += 1;
        return page(fixtures.mojeekBlocked, 403);
      },
      webView: () => webView,
    });
    await expect(
      scraper.search({query: 'q', maxResults: 5}),
    ).rejects.toMatchObject({kind: 'blocked'});
    expect(scraper.plainFetchBlocked).toBe(true);
    expect(scraper.isAvailable()).toBe(false);
    ready = true;
    expect(scraper.isAvailable()).toBe(true);
    const results = await scraper.search({query: 'q', maxResults: 5});
    expect(results).toEqual([{...hit('mojeek', 'https://one.example/')}]);
    expect(scraped[0]).toBe('https://www.mojeek.com/search?q=q');
    expect(fetches).toBe(1); // no second plain request during the cool-down
  });

  it('is unavailable without a WebView when the engine needs one', () => {
    const scraper = new ScrapeEngineProvider(engine('startpage'), {
      webView: () => null,
    });
    expect(scraper.isAvailable()).toBe(false);
  });

  it('distinguishes timeouts, HTTP errors and changed markup', async () => {
    const make = (httpGet: HttpGet) =>
      new ScrapeEngineProvider(engine('brave'), {httpGet});
    await expect(
      make(() => Promise.reject(new HttpError('timeout', 'timed out'))).search({
        query: 'q',
        maxResults: 5,
      }),
    ).rejects.toMatchObject({kind: 'timeout'});
    await expect(
      make(() => page('<html>oops</html>', 500)).search({
        query: 'q',
        maxResults: 5,
      }),
    ).rejects.toMatchObject({kind: 'network'});
    await expect(
      make(() =>
        page(
          `<html><body>${'<div class="new-markup">result</div>'.repeat(2000)}</body></html>`,
        ),
      ).search({query: 'q', maxResults: 5}),
    ).rejects.toMatchObject({kind: 'parse'});
  });
});

describe('Wikipedia and upstream providers', () => {
  it('maps the Wikipedia API to results in the query language', async () => {
    const urls: string[] = [];
    const wikipedia = new WikipediaProvider(url => {
      urls.push(url);
      return Promise.resolve({
        status: 200,
        text: JSON.stringify({
          query: {
            search: [
              {
                title: 'Plate tectonics',
                snippet:
                  'The <span class="searchmatch">theory</span> of&nbsp;plates',
                timestamp: '2026-11-01T10:00:00Z',
              },
            ],
          },
        }),
      });
    });
    const results = await wikipedia.search({
      query: 'Plattentektonik',
      maxResults: 3,
      language: 'de',
    });
    expect(urls[0]).toContain('https://de.wikipedia.org/w/api.php');
    expect(results).toEqual([
      {
        title: 'Plate tectonics',
        url: 'https://de.wikipedia.org/wiki/Plate_tectonics',
        snippet: 'The theory of plates',
        publishedAt: '2026-11-01',
        engine: 'wikipedia',
      },
    ]);
    const limited = new WikipediaProvider(() =>
      Promise.resolve({status: 429, text: ''}),
    );
    await expect(
      limited.search({query: 'q', maxResults: 3}),
    ).rejects.toMatchObject({kind: 'quota'});
  });

  it("puts PocketPal's providers behind the same interface", async () => {
    const upstream = {
      id: 'you' as const,
      search: jest.fn(async () => [
        {
          title: 'A',
          url: 'https://a.example/',
          snippet: 's',
          publishedAt: '2026-11-20',
        },
        {title: 'no url', url: '', snippet: ''},
      ]),
    };
    const adapted = fromUpstreamProvider(upstream);
    expect(adapted).toMatchObject({
      id: 'you',
      name: 'You.com',
      tier: 'fallback',
    });
    expect(await adapted.search({query: 'q', maxResults: 4})).toEqual([
      {
        title: 'A',
        url: 'https://a.example/',
        snippet: 's',
        publishedAt: '2026-11-20',
        engine: 'you',
      },
    ]);
    expect(upstream.search).toHaveBeenCalledWith(
      'q',
      {maxResults: 4},
      undefined,
    );
    const limited = fromUpstreamProvider({
      id: 'tavily',
      search: async () => {
        throw new Error('Tavily key not set');
      },
    });
    await expect(
      limited.search({query: 'q', maxResults: 1}),
    ).rejects.toMatchObject({kind: 'unavailable'});
  });
});

describe('WebView scraper', () => {
  const timing = {minDelayMs: 0, pageLoadTimeoutMs: 80, challengeTimeoutMs: 60};
  const message = (nonce: number, results: unknown[]) =>
    JSON.stringify({type: 'serp-results', nonce, results});

  it('navigates, takes the matching message and ignores a stale one', async () => {
    const controller = new WebViewScrapeController(timing);
    const navigations: Array<{url: string; nonce: number}> = [];
    controller.attachHost({
      navigate: (url, nonce) => navigations.push({url, nonce}),
    });
    const pending = controller.scrape('https://www.mojeek.com/search?q=x', {
      engineId: 'mojeek',
    });
    await later(5, null);
    controller.handleMessage(
      message(99, [
        {title: 'stale', url: 'https://stale.example/', snippet: ''},
      ]),
    );
    controller.handleMessage(
      message(navigations[0].nonce, [
        {title: 'Fresh', url: 'https://fresh.example/', snippet: 'ok'},
      ]),
    );
    expect(await pending).toEqual([
      {
        title: 'Fresh',
        url: 'https://fresh.example/',
        snippet: 'ok',
        engine: 'mojeek',
      },
    ]);
  });

  it('times out, and waits longer once a challenge shows', async () => {
    const controller = new WebViewScrapeController(timing);
    let challenged = 0;
    let nonce = 0;
    controller.attachHost({
      navigate: (_url, n) => (nonce = n),
      onChallenge: () => challenged++,
    });
    await expect(
      controller.scrape('https://www.startpage.com/sp/search?query=x', {
        engineId: 'startpage',
      }),
    ).rejects.toThrow('timed out');
    const pending = controller.scrape(
      'https://www.startpage.com/sp/search?query=y',
      {engineId: 'startpage'},
    );
    await later(5, null);
    controller.handleMessage(JSON.stringify({type: 'serp-challenge', nonce}));
    expect(controller.isChallengeActive()).toBe(true);
    expect(await pending).toEqual([]);
    expect(challenged).toBe(1);
  });

  it('is not ready without a host', async () => {
    const controller = new WebViewScrapeController(timing);
    expect(controller.isReady()).toBe(false);
    await expect(
      controller.scrape('https://www.mojeek.com/', {engineId: 'mojeek'}),
    ).rejects.toThrow('not attached');
  });

  it('validates page messages field by field', () => {
    expect(parseSerpMessage('not json')).toBeNull();
    expect(parseSerpMessage(JSON.stringify({type: 'other'}))).toBeNull();
    const parsed = parseSerpMessage(
      JSON.stringify({
        type: 'serp-results',
        nonce: 3,
        results: [
          {title: 'Ok​ title', url: 'https://ok.example/', snippet: 5},
          // eslint-disable-next-line no-script-url
          {title: 'bad scheme', url: 'javascript:alert(1)'},
          {title: '', url: 'https://empty.example/'},
          'junk',
        ],
      }),
    );
    expect(parsed).toEqual({
      type: 'serp-results',
      nonce: 3,
      results: [{title: 'Ok title', url: 'https://ok.example/', snippet: ''}],
    });
  });

  it('locks navigation to the engines and their challenge hosts', () => {
    expect(isAllowedScrapeNavigation('https://www.mojeek.com/search?q=x')).toBe(
      true,
    );
    expect(
      isAllowedScrapeNavigation('https://challenges.cloudflare.com/x'),
    ).toBe(true);
    expect(isAllowedScrapeNavigation('about:blank')).toBe(true);
    expect(isAllowedScrapeNavigation('https://evil.example/')).toBe(false);
    expect(isAllowedScrapeNavigation('http://www.mojeek.com/')).toBe(false);
    expect(isAllowedScrapeNavigation('https://mojeek.com.evil.example/')).toBe(
      false,
    );
  });

  it('builds an injectable parser script', () => {
    const script = buildSerpParserJs(true, 7);
    expect(script).toContain('msg.nonce = 7;');
    expect(script).toContain("post({ type: 'serp-results', results: [] });");
    // eslint-disable-next-line no-new-func
    expect(() => new Function(script)).not.toThrow();
  });
});
