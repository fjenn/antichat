/**
 * The search pipeline behind `web_search`, `read_url` and the forced direct
 * search: queries → broker → page reads within a deadline → chunk selection
 * within the budget → numbered sources → the `<web_results>` block.
 */
import type {ToolImage, ToolOutput, ToolSource} from '../tools/types';
import {SearchBroker, EngineStats} from './broker';
import {searchBudgetFor, clipToTokens, type SearchBudget} from './budget';
import {
  registryForTurn,
  SourceRegistry,
  faviconUrl,
} from './citations/registry';
import {DEFAULT_ENGINES, type EngineConfig} from './engines/config';
import {
  ScrapeEngineProvider,
  type WebViewScraper,
} from './engines/scrapeProvider';
import {WikipediaProvider} from './engines/wikipedia';
import {hostOf} from './html';
import {searchImages, WANTS_IMAGES} from './images';
import {buildQueries, cleanModelQuery, detectLanguage} from './query';
import {
  chunkText,
  selectChunks,
  type Chunk,
  type ChunkReranker,
} from './reader/chunks';
import {
  PageReadError,
  readPage,
  type ReadOptions,
  type ReadPage,
} from './reader/fetchPage';
import {renderResultsBlock, type EvidenceItem} from './resultsBlock';
import type {
  HttpGet,
  SearchOutcome,
  SearchResult,
  WebSearchProvider,
} from './types';
import type {DeviceClass} from '../prompt/types';

export interface SearchServiceOptions {
  /** Replace the default provider chain. */
  providers?: WebSearchProvider[];
  /** Extra providers (a user's keyed provider, keyless You.com). */
  extraProviders?: WebSearchProvider[];
  engines?: EngineConfig[];
  httpGet?: HttpGet;
  webView?: () => WebViewScraper | null;
  readerService?: ReadOptions['readerService'];
  /** Embedding hook for chunk selection. */
  rerank?: ChunkReranker;
  /** Show favicons (sends the host to DuckDuckGo's icon service). */
  favicons?: boolean;
  raceBudgetMs?: number;
  /** Read result pages after a search (default true). */
  readPages?: boolean;
  /** Fetch a thumbnail strip when the question asks to see something. */
  images?: boolean;
}

export interface WebSearchInput {
  /** Queries as written by the model or the harness. */
  queries: string[];
  /** The user's own question (chunk ranking, empty-query fallback). */
  userText?: string;
  recencyDays?: number;
  nCtx?: number;
  deviceClass?: DeviceClass;
  turnId?: string;
  now: Date;
  signal?: AbortSignal;
  onProgress?: (note: string, fraction?: number) => void;
  /** `full` adds the long citation rules (C+ devices, ≥ 16k context). */
  rules?: 'compact' | 'full';
}

export interface WebSearchRun {
  output: ToolOutput;
  outcome: SearchOutcome;
  pagesRead: number;
  pagesFailed: number;
  budget: SearchBudget;
  ms: {search: number; read: number; total: number};
}

export class SearchService {
  readonly stats = new EngineStats();
  readonly broker: SearchBroker;
  private readonly options: SearchServiceOptions;

  constructor(options: SearchServiceOptions = {}) {
    this.options = options;
    const providers = options.providers ?? [
      ...(options.engines ?? DEFAULT_ENGINES).map(
        engine =>
          new ScrapeEngineProvider(engine, {
            httpGet: options.httpGet,
            webView: options.webView,
          }),
      ),
      ...(options.extraProviders ?? []),
      new WikipediaProvider(options.httpGet),
    ];
    this.broker = new SearchBroker({
      providers,
      raceBudgetMs: options.raceBudgetMs,
      onAttempt: this.stats.record,
    });
  }

  private registry(turnId?: string): SourceRegistry {
    return turnId ? registryForTurn(turnId) : new SourceRegistry();
  }

  /** Search, read, select, number, render. Never throws. */
  async webSearch(input: WebSearchInput): Promise<WebSearchRun> {
    const started = Date.now();
    const budget = searchBudgetFor(input.nCtx, input.deviceClass);
    const registry = this.registry(input.turnId);
    const queries = input.queries
      .map(query =>
        cleanModelQuery(query, {userText: input.userText, now: input.now}),
      )
      .filter(Boolean)
      .slice(0, budget.queries);
    const language = detectLanguage(input.userText || queries.join(' '));
    input.onProgress?.(queries[0] ?? '', 0.1);
    const outcome = await this.broker.search({
      queries,
      maxResults: budget.results + 3,
      language: language === 'other' ? undefined : language,
      recencyDays: input.recencyDays,
      signal: input.signal,
    });
    const searchMs = Date.now() - started;
    queries.forEach(query => registry.addQuery(query));
    const rules =
      input.rules ?? ((input.nCtx ?? 8192) >= 16384 ? 'full' : 'compact');

    if (outcome.results.length === 0) {
      return {
        output: {
          text: renderResultsBlock({
            sources: [],
            evidence: [],
            today: input.now,
            query: queries[0],
            failure: outcome.failure,
            rules,
          }),
          untrusted: true,
          isError: true,
        },
        outcome,
        pagesRead: 0,
        pagesFailed: 0,
        budget,
        ms: {search: searchMs, read: 0, total: Date.now() - started},
      };
    }

    const top = outcome.results.slice(0, budget.results);
    const readStarted = Date.now();
    const pages = new Map<string, ReadPage>();
    let pagesFailed = 0;
    if (
      this.options.readPages !== false &&
      budget.pages > 0 &&
      !input.signal?.aborted
    ) {
      input.onProgress?.(
        `Reading ${Math.min(budget.pages, top.length)} pages`,
        0.5,
      );
      // Exact URLs first; one extra candidate covers a page that fails.
      const candidates = [
        ...top.filter(result => !result.approximateUrl),
        ...top.filter(result => result.approximateUrl),
      ].slice(0, budget.pages + 1);
      const controller = new AbortController();
      const onAbort = () => controller.abort();
      input.signal?.addEventListener('abort', onAbort);
      const deadline = setTimeout(
        () => controller.abort(),
        budget.readDeadlineMs,
      );
      await Promise.all(
        candidates.map(async result => {
          try {
            const page = await readPage(result.url, {
              httpGet: this.options.httpGet,
              signal: controller.signal,
              timeoutMs: budget.readDeadlineMs,
              maxBytes: 1_500_000,
            });
            if (pages.size < budget.pages && page.text.length >= 200) {
              pages.set(result.url, page);
            }
          } catch {
            pagesFailed += 1;
          }
        }),
      );
      clearTimeout(deadline);
      input.signal?.removeEventListener('abort', onAbort);
    }
    const readMs = Date.now() - readStarted;

    // Chunks of the read pages, ranked against the query and the question.
    const chunks: Chunk[] = [];
    top.forEach((result, index) => {
      const page = pages.get(result.url);
      if (page) {
        chunks.push(...chunkText(page.text, budget.chunkTokens, index));
      }
    });
    const snippetTokens = top.reduce(
      (sum, result) =>
        sum +
        Math.ceil(Math.min(result.snippet.length, budget.snippetChars) / 3.6) +
        12,
      0,
    );
    const selected = await selectChunks(chunks, {
      query: [queries.join(' '), input.userText ?? ''].join(' '),
      maxTokens: Math.max(0, budget.evidenceTokens - snippetTokens),
      perSource: budget.chunksPerPage,
      maxChunks: budget.pages * budget.chunksPerPage,
      rerank: this.options.rerank,
    });

    const sources: ToolSource[] = top.map((result, index) => {
      const page = pages.get(result.url);
      const picked = selected
        .filter(chunk => chunk.source === index)
        .map(chunk => chunk.text);
      const snippet = result.snippet.slice(0, budget.snippetChars);
      const evidence = [snippet, ...picked].filter(Boolean).join('\n');
      return {
        url: result.url,
        title: (page?.title && page.title.length > 3
          ? page.title
          : result.title
        ).slice(0, 140),
        site: hostOf(result.url),
        snippet,
        evidence,
        publishedAt: page?.publishedAt ?? result.publishedAt,
        fetched: picked.length > 0,
        engine: result.engine,
      };
    });
    const registered = registry.add(sources);
    if (this.options.favicons) {
      registered.forEach(source => {
        source.favicon ??= faviconUrl(source.site);
      });
    }
    const evidence: EvidenceItem[] = registered
      .map((source, index) => ({
        n: source.n,
        text: sources[index].evidence ?? '',
      }))
      .filter(item => item.text);

    let images: ToolImage[] = [];
    if (
      this.options.images !== false &&
      input.userText &&
      WANTS_IMAGES.test(input.userText)
    ) {
      images = await searchImages(queries[0], {
        httpGet: this.options.httpGet,
        signal: input.signal,
      });
      registry.addImages(images);
    }

    const text = renderResultsBlock({
      sources: registered,
      evidence,
      today: input.now,
      query: queries[0],
      rules,
      maxTokens: budget.evidenceTokens,
    });
    return {
      output: {
        text,
        untrusted: true,
        sources: registered,
        images: images.length ? images : undefined,
        card: {type: 'sources', query: queries[0], count: registered.length},
      },
      outcome,
      pagesRead: pages.size,
      pagesFailed,
      budget,
      ms: {search: searchMs, read: readMs, total: Date.now() - started},
    };
  }

  /** Read one page for `read_url`: best chunks for the question, numbered. */
  async readUrl(input: {
    url: string;
    question?: string;
    nCtx?: number;
    deviceClass?: DeviceClass;
    turnId?: string;
    now: Date;
    signal?: AbortSignal;
  }): Promise<ToolOutput> {
    const budget = searchBudgetFor(input.nCtx, input.deviceClass);
    let page: ReadPage;
    try {
      page = await readPage(input.url, {
        httpGet: this.options.httpGet,
        signal: input.signal,
        readerService: this.options.readerService,
      });
    } catch (error) {
      const reason =
        error instanceof PageReadError
          ? error.message
          : 'the page could not be read';
      return {
        text: `read_url: ${reason}. Tell the user the page could not be opened; do not guess its content.`,
        isError: true,
      };
    }
    let body = page.text;
    if (Math.ceil(body.length / 3.6) > budget.pageTokens) {
      const chunks = chunkText(body, budget.chunkTokens, 0);
      // Lead of the page plus the chunks that match the question.
      const lead = chunks.slice(0, 2);
      const rest = await selectChunks(chunks.slice(2), {
        query: input.question ?? page.title,
        maxTokens:
          budget.pageTokens -
          lead.reduce(
            (sum, chunk) => sum + Math.ceil(chunk.text.length / 3.6),
            0,
          ),
        perSource: 99,
        maxChunks: 99,
        rerank: this.options.rerank,
      });
      const joined = [...lead, ...rest]
        .sort((a, b) => a.index - b.index)
        .map(chunk => chunk.text)
        .join('\n…\n');
      body = clipToTokens(joined, budget.pageTokens);
    }
    const registry = this.registry(input.turnId);
    const [source] = registry.add([
      {
        url: page.url,
        title: page.title,
        site: hostOf(page.url),
        snippet: page.description,
        evidence: body,
        publishedAt: page.publishedAt,
        fetched: true,
      },
    ]);
    if (this.options.favicons) {
      source.favicon ??= faviconUrl(source.site);
    }
    const text = renderResultsBlock({
      sources: [source],
      evidence: [{n: source.n, text: body}],
      today: input.now,
      rules: (input.nCtx ?? 8192) >= 16384 ? 'full' : 'compact',
      maxTokens: budget.pageTokens,
    });
    return {text, untrusted: true, sources: [source]};
  }

  /** The harness's own search for a turn the gate marked as fresh. */
  directQueries(input: {
    userText: string;
    previousUserTexts?: string[];
    now: Date;
    nCtx?: number;
    deviceClass?: DeviceClass;
  }): string[] {
    const budget = searchBudgetFor(input.nCtx, input.deviceClass);
    return buildQueries({
      userText: input.userText,
      previousUserTexts: input.previousUserTexts,
      now: input.now,
      maxQueries: budget.queries,
    }).queries;
  }
}

let service: SearchService | null = null;

export function configureSearch(options: SearchServiceOptions): SearchService {
  service = new SearchService(options);
  return service;
}

export function getSearchService(): SearchService {
  service ??= new SearchService();
  return service;
}

/** Test helper. */
export function resetSearchService(): void {
  service = null;
}

export type {SearchResult};
