/**
 * One keyless engine as a `WebSearchProvider`: plain fetch of the result
 * page, the engine's parser, a second URL when the first is blocked, and the
 * hidden WebView when plain fetch does not get through at all.
 */
import {HttpError, defaultHttpGet} from '../http';
import {
  SearchProviderError,
  type HttpGet,
  type SearchRequest,
  type SearchResult,
  type WebSearchProvider,
} from '../types';
import {buildEngineUrl, type EngineConfig} from './config';
import {looksBlocked, parseResults} from './parsers';

/** The WebView side: navigates a hidden page and returns its HTML or hits. */
export interface WebViewScraper {
  isReady(): boolean;
  scrape(
    url: string,
    options: {signal?: AbortSignal; timeoutMs?: number; engineId: string},
  ): Promise<SearchResult[]>;
}

export interface ScrapeProviderOptions {
  httpGet?: HttpGet;
  webView?: () => WebViewScraper | null;
  /** How long a blocked engine is left alone before the next plain request. */
  blockCooldownMs?: number;
}

/** Engines blocked for plain fetch are skipped for a while, then retried. */
const BLOCK_COOLDOWN_MS = 10 * 60 * 1000;

export class ScrapeEngineProvider implements WebSearchProvider {
  readonly tier = 'race' as const;
  private blockedUntil = 0;

  constructor(
    readonly config: EngineConfig,
    private readonly options: ScrapeProviderOptions = {},
  ) {}

  get id(): string {
    return this.config.id;
  }

  get name(): string {
    return this.config.name;
  }

  private get webView(): WebViewScraper | null {
    const scraper = this.options.webView?.() ?? null;
    return scraper && scraper.isReady() ? scraper : null;
  }

  isAvailable(): boolean {
    if (!this.config.enabled) {
      return false;
    }
    if (this.config.transport === 'webview') {
      return this.webView !== null;
    }
    // Blocked for plain requests and no WebView to fall back on: sit out
    // until the cool-down ends, so the broker can promote a fallback.
    if (Date.now() < this.blockedUntil) {
      return (
        this.config.transport === 'fetch_then_webview' && this.webView !== null
      );
    }
    return true;
  }

  /** For tests and the settings screen ("blocked, retrying in …"). */
  get plainFetchBlocked(): boolean {
    return Date.now() < this.blockedUntil;
  }

  async search(request: SearchRequest): Promise<SearchResult[]> {
    const {config} = this;
    const viaWebView = async (): Promise<SearchResult[]> => {
      const scraper = this.webView;
      if (!scraper) {
        throw new SearchProviderError(
          'blocked',
          `${config.name} blocks plain requests`,
        );
      }
      const hits = await scraper.scrape(
        buildEngineUrl(config.urlTemplate, config, request),
        {
          signal: request.signal,
          timeoutMs: request.timeoutMs,
          engineId: config.id,
        },
      );
      if (hits.length === 0) {
        throw new SearchProviderError('empty', 'no results');
      }
      return hits
        .slice(0, request.maxResults)
        .map(hit => ({...hit, engine: config.id}));
    };

    if (config.transport === 'webview') {
      return viaWebView();
    }
    if (
      Date.now() < this.blockedUntil &&
      config.transport === 'fetch_then_webview'
    ) {
      return viaWebView();
    }

    const attempts: Array<[string, EngineConfig['parser']]> = [
      [config.urlTemplate, config.parser],
    ];
    if (config.fallbackUrlTemplate) {
      attempts.push([
        config.fallbackUrlTemplate,
        config.fallbackParser ?? config.parser,
      ]);
    }
    let failure: SearchProviderError | null = null;
    for (const [template, parser] of attempts) {
      try {
        const hits = await this.fetchOnce(template, parser, request);
        this.blockedUntil = 0;
        return hits;
      } catch (error) {
        failure = error as SearchProviderError;
        if (failure.kind === 'timeout' || request.signal?.aborted) {
          break;
        }
      }
    }
    if (failure?.kind === 'blocked') {
      this.blockedUntil =
        Date.now() + (this.options.blockCooldownMs ?? BLOCK_COOLDOWN_MS);
      if (config.transport === 'fetch_then_webview' && this.webView) {
        return viaWebView();
      }
    }
    throw failure ?? new SearchProviderError('empty', 'no results');
  }

  private async fetchOnce(
    template: string,
    parser: EngineConfig['parser'],
    request: SearchRequest,
  ): Promise<SearchResult[]> {
    const httpGet = this.options.httpGet ?? defaultHttpGet;
    let response;
    try {
      response = await httpGet(buildEngineUrl(template, this.config, request), {
        signal: request.signal,
        timeoutMs: request.timeoutMs,
        maxBytes: 1_500_000,
      });
    } catch (error) {
      const kind =
        error instanceof HttpError && error.kind === 'timeout'
          ? 'timeout'
          : 'network';
      throw new SearchProviderError(kind, (error as Error).message);
    }
    const hits = parseResults(parser, response.text, this.config);
    if (hits.length > 0) {
      return hits.slice(0, request.maxResults);
    }
    if (looksBlocked(response.status, response.text)) {
      throw new SearchProviderError('blocked', `blocked (${response.status})`);
    }
    if (response.status >= 400) {
      throw new SearchProviderError('network', `HTTP ${response.status}`);
    }
    // A 200 page of some size without a single recognised result usually
    // means the markup changed: report it as a parse failure, not as "empty".
    throw new SearchProviderError(
      /no results|keine ergebnisse|no more results|did not match/i.test(
        response.text,
      )
        ? 'empty'
        : 'parse',
      'no results recognised',
    );
  }
}
