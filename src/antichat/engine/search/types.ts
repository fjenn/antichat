/**
 * Contracts of the web-search layer. One provider interface covers scraped
 * result pages, the hidden-WebView scraper, keyless APIs and PocketPal's
 * keyed providers.
 */

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
  /** Provider that returned it first. */
  engine: string;
  /** Every provider that returned this URL. */
  engines?: string[];
  /** ISO date or the engine's own wording ("2 weeks ago"). */
  publishedAt?: string;
  /** The URL was rebuilt from a breadcrumb and may not resolve exactly. */
  approximateUrl?: boolean;
  /** Ranking score after the merge (higher is better). */
  score?: number;
}

export interface SearchRequest {
  query: string;
  maxResults: number;
  /** Two-letter language of the query, when known. */
  language?: string;
  safeSearch?: boolean;
  /** Only results newer than this many days, where the engine supports it. */
  recencyDays?: number;
  signal?: AbortSignal;
  timeoutMs?: number;
}

export type FailureKind =
  | 'timeout'
  | 'blocked'
  | 'network'
  | 'parse'
  | 'empty'
  | 'unavailable'
  | 'quota'
  /** Results came back, but they have nothing to do with the query. */
  | 'irrelevant';

export class SearchProviderError extends Error {
  constructor(
    readonly kind: FailureKind,
    message: string,
  ) {
    super(message);
    this.name = 'SearchProviderError';
  }
}

export interface WebSearchProvider {
  readonly id: string;
  readonly name: string;
  /**
   * `race`: fired in parallel for every query. `fallback`: tried in order
   * when the race came back thin (rate-limited APIs, Wikipedia).
   */
  readonly tier: 'race' | 'fallback';
  /** False while the provider cannot run (no WebView host, no key). */
  isAvailable?(): boolean;
  /** Throws `SearchProviderError`; never resolves empty for a failure. */
  search(request: SearchRequest): Promise<SearchResult[]>;
}

export interface SearchAttempt {
  engine: string;
  query: string;
  ok: boolean;
  count: number;
  ms: number;
  kind?: FailureKind;
  error?: string;
}

export interface SearchOutcome {
  results: SearchResult[];
  attempts: SearchAttempt[];
  elapsedMs: number;
  queries: string[];
  /** Set when nothing came back. */
  failure?: string;
}

/** Minimal HTTP surface, injectable for tests and for Node evaluation. */
export interface HttpResponse {
  status: number;
  text: string;
  /** Final URL after redirects, when the transport knows it. */
  url?: string;
  contentType?: string;
}

export type HttpGet = (
  url: string,
  options?: {
    headers?: Record<string, string>;
    signal?: AbortSignal;
    timeoutMs?: number;
    maxBytes?: number;
  },
) => Promise<HttpResponse>;
