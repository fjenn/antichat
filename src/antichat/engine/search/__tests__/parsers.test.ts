import fixtures from '../__fixtures__/serp.json';
import {
  buildEngineUrl,
  DEFAULT_ENGINES,
  applyEngineOverrides,
} from '../engines/config';
import {
  derefBing,
  derefDuckDuckGo,
  looksBlocked,
  parseMojeek,
  parseResults,
  parseStartpage,
  urlFromBreadcrumb,
} from '../engines/parsers';

const engine = (id: string) =>
  DEFAULT_ENGINES.find(candidate => candidate.id === id)!;

describe('result-page parsers (markup captured 2026-11-24)', () => {
  it('reads DuckDuckGo html results', () => {
    const hits = parseResults(
      'duckduckgo',
      fixtures.duckduckgo,
      engine('duckduckgo'),
    );
    expect(hits.length).toBe(3);
    expect(hits[0].url).toMatch(/^https:\/\//);
    expect(hits[0].title.length).toBeGreaterThan(5);
    expect(hits[0].snippet.length).toBeGreaterThan(20);
    expect(hits[0].snippet).not.toMatch(/<b>/);
    expect(hits[0].engine).toBe('duckduckgo');
  });

  it('reads DuckDuckGo lite results', () => {
    const hits = parseResults(
      'duckduckgo-lite',
      fixtures.duckduckgoLite,
      engine('duckduckgo'),
    );
    expect(hits.length).toBeGreaterThanOrEqual(2);
    expect(hits[0].snippet.length).toBeGreaterThan(20);
  });

  it('unwraps DuckDuckGo redirect links', () => {
    expect(
      derefDuckDuckGo(
        '//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fa%3Fb%3D1&rut=x',
      ),
    ).toBe('https://example.org/a?b=1');
    expect(derefDuckDuckGo('https://example.org/')).toBe(
      'https://example.org/',
    );
  });

  it('reads Brave results and rebuilds URLs from the breadcrumb', () => {
    const hits = parseResults('brave', fixtures.brave, engine('brave'));
    expect(hits.length).toBeGreaterThanOrEqual(2);
    for (const hit of hits) {
      expect(hit.url).toMatch(/^https:\/\/[a-z0-9.-]+\//);
      expect(hit.url).not.toContain('brave.com');
      expect(hit.title.length).toBeGreaterThan(3);
    }
    expect(hits.some(hit => hit.approximateUrl)).toBe(true);
  });

  it('reads Bing results with their dates', () => {
    const hits = parseResults('bing', fixtures.bing, engine('bing'));
    expect(hits).toHaveLength(3);
    expect(hits[0]).toMatchObject({
      url: 'https://www.wikihow.com/Fold-a-Fitted-Sheet',
      engine: 'bing',
      publishedAt: 'Aug 4, 2026',
    });
    expect(hits[0].title).toContain('How to Fold a Fitted Sheet');
    expect(hits[0].snippet).not.toMatch(/^Aug 4|&nbsp;|&#/);
    expect(
      derefBing(
        'https://www.bing.com/ck/a?!&&p=abc&u=a1aHR0cHM6Ly9leGFtcGxlLm9yZy9hP2I9MQ&ntb=1',
      ),
    ).toBe('https://example.org/a?b=1');
    expect(derefBing('https://example.org/x')).toBe('https://example.org/x');
  });

  it('rebuilds breadcrumbs', () => {
    expect(urlFromBreadcrumb('https://bbc.co.uk › sport  › tennis')).toEqual({
      url: 'https://bbc.co.uk/sport/tennis',
      approximate: true,
    });
    expect(urlFromBreadcrumb('https://example.org')).toEqual({
      url: 'https://example.org/',
      approximate: false,
    });
    expect(urlFromBreadcrumb('newsnow.com › sports › us open')?.url).toBe(
      'https://newsnow.com/sports',
    );
    expect(urlFromBreadcrumb('not a host')).toBeNull();
  });

  it('reads Mojeek and Startpage markup', () => {
    const mojeek = parseMojeek(
      '<ul class="results-standard"><li class="r1"><h2><a class="title" href="https://a.example/x">A &amp; B</a></h2><p class="s">Snippet <b>one</b></p></li><li><h2><a href="https://b.example/">B</a></h2><p class="s">Two</p></li></ul>',
    );
    expect(mojeek).toEqual([
      {title: 'A & B', url: 'https://a.example/x', snippet: 'Snippet one'},
      {title: 'B', url: 'https://b.example/', snippet: 'Two'},
    ]);
    const startpage = parseStartpage(
      '<div class="result css-1"><a class="result-title result-link" href="https://c.example/p"><h2>C page</h2></a><p class="description">About C</p></div>',
    );
    expect(startpage).toEqual([
      {title: 'C page', url: 'https://c.example/p', snippet: 'About C'},
    ]);
  });

  it('drops engine-internal links and duplicates', () => {
    const html =
      '<div class="result results_links web-result"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Ad</a></div>' +
      '<div class="result results_links web-result"><a class="result__a" href="https://x.example/">X</a><a class="result__snippet">s</a></div>' +
      '<div class="result results_links web-result"><a class="result__a" href="https://x.example/">X again</a></div>' +
      '<div class="result results_links web-result"><a class="result__a" href="javascript:alert(1)">bad</a></div>';
    const hits = parseResults('duckduckgo', html, engine('duckduckgo'));
    expect(hits.map(hit => hit.url)).toEqual(['https://x.example/']);
  });

  it('tells a bot wall from a result page', () => {
    expect(looksBlocked(403, fixtures.mojeekBlocked)).toBe(true);
    expect(looksBlocked(200, fixtures.mojeekBlocked)).toBe(true);
    expect(looksBlocked(200, fixtures.startpageChallenge)).toBe(true);
    expect(looksBlocked(200, fixtures.duckduckgo)).toBe(false);
  });
});

describe('engine configuration', () => {
  it('builds URLs with recency, region and safe-search parameters', () => {
    const url = buildEngineUrl(
      engine('duckduckgo').urlTemplate,
      engine('duckduckgo'),
      {
        query: 'tesla model y preis',
        recencyDays: 7,
        language: 'de',
        safeSearch: true,
      },
    );
    expect(url).toBe(
      'https://html.duckduckgo.com/html/?q=tesla%20model%20y%20preis&kp=1&df=w&kl=de-de',
    );
    expect(
      buildEngineUrl(engine('brave').urlTemplate, engine('brave'), {
        query: 'a b',
      }),
    ).toBe('https://search.brave.com/search?q=a%20b&source=web');
    expect(
      buildEngineUrl(engine('bing').urlTemplate, engine('bing'), {
        query: 'wetter',
        language: 'de',
        recencyDays: 1,
      }),
    ).toBe(
      'https://www.bing.com/search?q=wetter&form=QBLH&filters=ex1%3a%22ez1%22&setlang=de&cc=DE',
    );
  });

  it('lets the catalogue disable or re-point an engine, never move it off-site', () => {
    const next = applyEngineOverrides(DEFAULT_ENGINES, [
      {id: 'brave', enabled: false},
      {id: 'duckduckgo', urlTemplate: 'https://duckduckgo.com/html/?q={q}'},
      {id: 'mojeek', urlTemplate: 'https://evil.example/?q={q}'},
      {id: 'google', enabled: true},
    ]);
    expect(next.find(e => e.id === 'brave')!.enabled).toBe(false);
    expect(next.find(e => e.id === 'duckduckgo')!.urlTemplate).toBe(
      'https://duckduckgo.com/html/?q={q}',
    );
    expect(next.find(e => e.id === 'mojeek')!.urlTemplate).toBe(
      engine('mojeek').urlTemplate,
    );
    expect(next).toHaveLength(DEFAULT_ENGINES.length);
  });
});
