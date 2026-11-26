import {approxTokens, clipToTokens, searchBudgetFor} from '../budget';
import {HttpError} from '../http';
import {
  bm25Scores,
  chunkText,
  selectChunks,
  type Chunk,
} from '../reader/chunks';
import {extractFromHtml} from '../reader/extractArticle';
import {
  PageCache,
  PageReadError,
  normalizeUrlInput,
  readPage,
} from '../reader/fetchPage';
import {assertPublicHttpUrl, isPrivateHost} from '../reader/ssrf';
import type {HttpGet} from '../types';

const ARTICLE = `<!doctype html><html><head><title>On-device LLMs in 2026 | Example Blog</title>
<meta property="og:description" content="What limits local models on phones.">
<meta property="article:published_time" content="2026-11-02T08:00:00Z">
<script>var tracking = "ignore me";</script><style>.x{color:red}</style></head>
<body><header><nav><a href="/">Home</a><a href="/blog">Blog</a></nav></header>
<article><h1>On-device LLMs in 2026</h1>
<p>Phones now run 2&ndash;4 billion parameter models at about 20 tokens per second.</p>
<p>Memory is the first limit: a 4&nbsp;GB phone can hold a 1.7B model and little else.</p>
<p>Thermal throttling is the second limit, cutting speed by half after ten minutes of use.</p>
<ul><li>Use quantised weights.</li><li>Keep the context small.</li></ul>
</article><aside>Related: ten other posts</aside><footer>Copyright Example</footer></body></html>`;

describe('article extraction', () => {
  it('keeps the article and drops navigation, scripts and footers', () => {
    const article = extractFromHtml(
      ARTICLE,
      'https://www.example.org/blog/on-device-llms',
    );
    expect(article.title).toContain('On-device LLMs in 2026');
    expect(article.siteName).toBe('example.org');
    expect(article.publishedAt).toBe('2026-11-02');
    expect(article.description).toBe('What limits local models on phones.');
    expect(article.text).toContain(
      'Phones now run 2–4 billion parameter models at about 20 tokens per second.',
    );
    expect(article.text).toContain('Thermal throttling is the second limit');
    expect(article.text).toContain('Use quantised weights.');
    expect(article.text).not.toMatch(
      /ignore me|color:red|Copyright Example|Related: ten|Home/,
    );
  });

  it('falls back to structured data for a script-rendered page', () => {
    const html = `<html><head><title>Shop</title><script type="application/ld+json">{"@type":"Article","headline":"Return policy","articleBody":"${'Items can be returned within 45 days of delivery. '.repeat(4)}"}</script></head><body><div id="root"></div></body></html>`;
    const article = extractFromHtml(
      html,
      'https://shop.example.com/help/returns',
    );
    expect(article.text).toContain('returned within 45 days');
  });

  it('flags a bot wall instead of returning its text', () => {
    const wall =
      '<html><head><title>Just a moment...</title></head><body><div id="challenge-form">Checking your browser before accessing the site.</div></body></html>';
    expect(extractFromHtml(wall, 'https://x.example/')).toMatchObject({
      blocked: true,
      text: '',
    });
  });
});

describe('outbound request guard', () => {
  it('refuses private, local and malformed targets', () => {
    for (const host of [
      'localhost',
      '127.0.0.1',
      '10.1.2.3',
      '192.168.0.10',
      '172.20.1.1',
      '169.254.169.254',
      '[::1]',
      '0x7f.1',
      '2130706433',
      'printer.localhost',
    ]) {
      expect(isPrivateHost(host)).toBe(true);
    }
    for (const host of ['example.org', '8.8.8.8', '172.32.0.1']) {
      expect(isPrivateHost(host)).toBe(false);
    }
    expect(() => assertPublicHttpUrl('http://192.168.1.1/admin')).toThrow(
      'private-range',
    );
    expect(() => assertPublicHttpUrl('file:///etc/passwd')).toThrow('non-http');
    expect(() => assertPublicHttpUrl('ftp://example.org/')).toThrow();
    expect(assertPublicHttpUrl('https://example.org/a')).toBe('example.org');
  });

  it('adds the scheme people leave out', () => {
    expect(normalizeUrlInput('example.net/paper.html')).toBe(
      'https://example.net/paper.html',
    );
    expect(normalizeUrlInput('<https://a.example/x>.')).toBe(
      'https://a.example/x',
    );
    expect(
      normalizeUrlInput('https://shop.example.com/help/returns?lang=en'),
    ).toBe('https://shop.example.com/help/returns?lang=en');
    expect(normalizeUrlInput('//cdn.example.org/a')).toBe(
      'https://cdn.example.org/a',
    );
  });
});

describe('readPage', () => {
  const http = (
    status: number,
    text: string,
    extra: Partial<Awaited<ReturnType<HttpGet>>> = {},
  ): HttpGet =>
    jest.fn(async () => ({
      status,
      text,
      contentType: 'text/html; charset=utf-8',
      ...extra,
    }));

  it('fetches, extracts and caches', async () => {
    const httpGet = http(200, ARTICLE);
    const cache = new PageCache();
    const page = await readPage('example.org/blog/on-device-llms', {
      httpGet,
      cache,
    });
    expect(page).toMatchObject({via: 'fetch', siteName: 'example.org'});
    expect(page.text).toContain('20 tokens per second');
    const again = await readPage('https://example.org/blog/on-device-llms', {
      httpGet,
      cache,
    });
    expect(again.via).toBe('cache');
    expect(httpGet).toHaveBeenCalledTimes(1);
  });

  it('refuses private targets before any request, and redirects into them', async () => {
    const httpGet = http(200, ARTICLE);
    await expect(
      readPage('http://192.168.0.1/', {httpGet}),
    ).rejects.toMatchObject({kind: 'refused'});
    expect(httpGet).not.toHaveBeenCalled();
    const redirected = http(200, ARTICLE, {
      url: 'http://127.0.0.1:8080/secret',
    });
    await expect(
      readPage('https://redirect.example/', {
        httpGet: redirected,
        cache: new PageCache(),
      }),
    ).rejects.toMatchObject({kind: 'refused'});
  });

  it('names the failure: blocked, HTTP error, binary, timeout, empty', async () => {
    const cache = () => new PageCache();
    await expect(
      readPage('https://a.example/', {
        httpGet: http(403, 'no'),
        cache: cache(),
      }),
    ).rejects.toMatchObject({kind: 'blocked'});
    await expect(
      readPage('https://a.example/', {
        httpGet: http(404, 'no'),
        cache: cache(),
      }),
    ).rejects.toMatchObject({kind: 'http'});
    await expect(
      readPage('https://a.example/x.pdf', {
        httpGet: http(200, '%PDF-1.7', {contentType: 'application/pdf'}),
        cache: cache(),
      }),
    ).rejects.toMatchObject({kind: 'not_text'});
    const slow: HttpGet = async () => {
      throw new HttpError('timeout', 'timed out');
    };
    await expect(
      readPage('https://a.example/', {httpGet: slow, cache: cache()}),
    ).rejects.toMatchObject({
      kind: 'timeout',
      message: 'the page took too long to load',
    });
    await expect(
      readPage('https://a.example/', {
        httpGet: http(200, '<html><body></body></html>'),
        cache: cache(),
      }),
    ).rejects.toBeInstanceOf(PageReadError);
  });

  it('uses the reader service only when allowed, and only as a fallback', async () => {
    const readerService = jest.fn(async () => ({
      text: 'Rendered text of the page. '.repeat(20),
      title: 'Rendered',
    }));
    const page = await readPage('https://spa.example/', {
      httpGet: http(200, '<html><body><div id="app"></div></body></html>'),
      readerService,
      cache: new PageCache(),
    });
    expect(page).toMatchObject({via: 'reader-service', title: 'Rendered'});
    await expect(
      readPage('http://10.0.0.1/', {httpGet: http(200, ''), readerService}),
    ).rejects.toMatchObject({kind: 'refused'});
    expect(readerService).toHaveBeenCalledTimes(1);
  });
});

describe('chunk selection', () => {
  const text = [
    'The museum opened in 1902 and holds paintings from the nineteenth century.',
    'Tickets cost 12 euros for adults and 6 euros for students.',
    'Opening hours are 11:30 to 22:00 from Tuesday to Sunday; the museum is closed on Mondays.',
    'The cafe on the ground floor serves lunch and cakes.',
    'Parking is available behind the building for a small fee.',
  ].join('\n');

  it('splits long text on sentence ends near the target size', () => {
    const long = Array.from(
      {length: 40},
      (_, i) =>
        `Sentence ${i} explains one more detail of the subject at hand.`,
    ).join(' ');
    const chunks = chunkText(long, 100);
    expect(chunks.length).toBeGreaterThan(4);
    for (const chunk of chunks) {
      expect(approxTokens(chunk.text)).toBeLessThanOrEqual(105);
      expect(chunk.text.endsWith('.')).toBe(true);
    }
    expect(chunks.map(chunk => chunk.index)).toEqual(chunks.map((_, i) => i));
  });

  it('ranks chunks by BM25 and keeps the ones that answer the question', async () => {
    const chunks = chunkText(text, 25);
    const scores = bm25Scores('opening hours', chunks);
    const best = scores.indexOf(Math.max(...scores));
    expect(chunks[best].text).toContain('11:30 to 22:00');
    const picked = await selectChunks(chunks, {
      query: 'what are the opening hours',
      maxTokens: 40,
      maxChunks: 1,
    });
    expect(picked).toHaveLength(1);
    expect(picked[0].text).toContain('Opening hours');
  });

  it('gives every source a chunk before any source gets a second, within the budget', async () => {
    const chunks: Chunk[] = [
      ...chunkText(
        'Tesla Model Y price in Germany is 44,990 euros.\nTesla Model Y range is 600 km.\nTesla Model Y price changed in May.',
        15,
        0,
      ),
      ...chunkText(
        'The Model Y price starts at 44,990 euros according to the configurator.',
        15,
        1,
      ),
      ...chunkText('Unrelated page about gardening and tomatoes.', 15, 2),
    ];
    const picked = await selectChunks(chunks, {
      query: 'Tesla Model Y price Germany',
      maxTokens: 60,
      perSource: 2,
    });
    expect(new Set(picked.map(chunk => chunk.source))).toEqual(new Set([0, 1]));
    expect(
      picked.reduce((sum, chunk) => sum + approxTokens(chunk.text), 0),
    ).toBeLessThanOrEqual(60);
    expect(
      picked.filter(chunk => chunk.source === 0).length,
    ).toBeLessThanOrEqual(2);
    // page order within a source
    const first = picked
      .filter(chunk => chunk.source === 0)
      .map(chunk => chunk.index);
    expect(first).toEqual([...first].sort((a, b) => a - b));
  });

  it('fuses an embedding ranking when the hook is given, and survives a failing hook', async () => {
    const chunks = chunkText(text, 25);
    const target = chunks.findIndex(chunk => chunk.text.includes('cafe'));
    const rerank = jest.fn(async (_query: string, list: Chunk[]) =>
      list.map((_, index) => (index === target ? 1 : 0)),
    );
    const picked = await selectChunks(chunks, {
      query: 'where can I eat cake lunch',
      maxTokens: 30,
      maxChunks: 1,
      rerank,
    });
    expect(rerank).toHaveBeenCalled();
    expect(picked[0].text).toContain('cafe');
    const broken = await selectChunks(chunks, {
      query: 'opening hours',
      maxTokens: 40,
      maxChunks: 1,
      rerank: async () => {
        throw new Error('no embedding model');
      },
    });
    expect(broken[0].text).toContain('Opening hours');
  });

  it('returns the lead of the page when nothing matches', async () => {
    const chunks = chunkText(text, 25);
    const picked = await selectChunks(chunks, {
      query: 'zzz qqq',
      maxTokens: 30,
      maxChunks: 1,
    });
    expect(picked[0].index).toBe(0);
  });
});

describe('search budgets', () => {
  it('grow with the context window and never exceed about a quarter of it', () => {
    const sizes = [4096, 8192, 16384, 32768];
    const budgets = sizes.map(size => searchBudgetFor(size));
    budgets.forEach((budget, index) => {
      expect(budget.evidenceTokens).toBeLessThanOrEqual(sizes[index] * 0.25);
      expect(budget.pageTokens).toBeLessThanOrEqual(sizes[index] * 0.25);
    });
    expect(budgets.map(budget => budget.queries)).toEqual([1, 1, 2, 3]);
    expect(budgets.map(budget => budget.results)).toEqual([3, 5, 6, 8]);
    expect(searchBudgetFor(16384, 'A')).toMatchObject({
      queries: 1,
      pages: 1,
      results: 3,
    });
  });

  it('clips text at a sentence end', () => {
    const clipped = clipToTokens(
      'First sentence here. Second sentence here. Third sentence here.',
      8,
    );
    expect(clipped).toBe('First sentence here. …');
    expect(clipToTokens('short', 10)).toBe('short');
  });
});
