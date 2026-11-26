/**
 * Page reader: fetch a page on the device and extract its readable text.
 * No reader service sees the URL (upstream's `r.jina.ai` path stays as the
 * last fallback only, behind `allowReaderService`).
 *
 * Guards (Mac `PageFetcher` / `SSRFGuard`, Private Mind `outboundFetch`):
 * http(s) only, public hosts only (also after redirects), a time limit, a
 * size limit, text content types only, a small in-memory cache.
 */
import {HttpError, defaultHttpGet} from '../http';
import type {HttpGet} from '../types';
import {
  extractFromHtml,
  hostname,
  type ExtractedArticle,
} from './extractArticle';
import {assertPublicHttpUrl} from './ssrf';

export interface ReadPage extends ExtractedArticle {
  /** Where the text came from. */
  via: 'fetch' | 'reader-service' | 'cache';
  ms: number;
}

export class PageReadError extends Error {
  constructor(
    readonly kind:
      | 'refused'
      | 'timeout'
      | 'network'
      | 'blocked'
      | 'not_text'
      | 'empty'
      | 'http',
    message: string,
  ) {
    super(message);
    this.name = 'PageReadError';
  }
}

export interface ReadOptions {
  httpGet?: HttpGet;
  signal?: AbortSignal;
  timeoutMs?: number;
  maxBytes?: number;
  /**
   * Last-resort reader for pages that need JavaScript or block plain
   * requests. Sends the URL to a third party, so it is off unless the user
   * allowed it in settings.
   */
  readerService?: (
    url: string,
    signal?: AbortSignal,
  ) => Promise<{text: string; title?: string}>;
  cache?: PageCache;
}

const TEXT_TYPES = /text\/|\+xml|\/xml|\/json/i;
const MIN_TEXT = 200;

/** Add the scheme people leave out; reject anything that is not a web URL. */
export function normalizeUrlInput(input: string): string {
  let url = input
    .trim()
    .replace(/[)\].,;!?]+$/, '')
    .replace(/^<|>$/g, '')
    .replace(/[)\].,;!?]+$/, '');
  if (/^\/\//.test(url)) {
    url = `https:${url}`;
  } else if (
    !/^[a-z][a-z0-9+.-]*:/i.test(url) &&
    /^[\w-]+(\.[\w-]+)+(?:[/:?#]|$)/.test(url)
  ) {
    url = `https://${url}`;
  }
  return url;
}

export class PageCache {
  private readonly entries = new Map<string, {page: ReadPage; at: number}>();

  constructor(
    private readonly maxEntries = 24,
    private readonly ttlMs = 30 * 60 * 1000,
  ) {}

  get(url: string): ReadPage | undefined {
    const hit = this.entries.get(url);
    if (!hit) {
      return undefined;
    }
    if (Date.now() - hit.at > this.ttlMs) {
      this.entries.delete(url);
      return undefined;
    }
    return {...hit.page, via: 'cache', ms: 0};
  }

  set(url: string, page: ReadPage): void {
    this.entries.delete(url);
    this.entries.set(url, {page, at: Date.now()});
    while (this.entries.size > this.maxEntries) {
      this.entries.delete(this.entries.keys().next().value as string);
    }
  }

  clear(): void {
    this.entries.clear();
  }
}

export const sharedPageCache = new PageCache();

/** Fetch and extract one page. Throws `PageReadError`. */
export async function readPage(
  input: string,
  options: ReadOptions = {},
): Promise<ReadPage> {
  const url = normalizeUrlInput(input);
  try {
    assertPublicHttpUrl(url);
  } catch (error) {
    throw new PageReadError('refused', (error as Error).message);
  }
  const cache = options.cache ?? sharedPageCache;
  const cached = cache.get(url);
  if (cached) {
    return cached;
  }
  const started = Date.now();
  const httpGet = options.httpGet ?? defaultHttpGet;
  let failure: PageReadError | null = null;
  let page: ReadPage | null = null;
  try {
    const response = await httpGet(url, {
      signal: options.signal,
      timeoutMs: options.timeoutMs ?? 8000,
      maxBytes: options.maxBytes ?? 2_000_000,
      headers: {Accept: 'text/html,application/xhtml+xml,text/plain;q=0.8'},
    });
    if (response.url && response.url !== url) {
      // A redirect must not lead into the local network.
      try {
        assertPublicHttpUrl(response.url);
      } catch (error) {
        throw new PageReadError('refused', (error as Error).message);
      }
    }
    if (
      response.status === 403 ||
      response.status === 429 ||
      response.status === 503
    ) {
      throw new PageReadError(
        'blocked',
        `the site refused the request (${response.status})`,
      );
    }
    if (response.status >= 400) {
      throw new PageReadError(
        'http',
        `the page returned HTTP ${response.status}`,
      );
    }
    if (response.contentType && !TEXT_TYPES.test(response.contentType)) {
      throw new PageReadError(
        'not_text',
        `not a text page (${response.contentType.split(';')[0]})`,
      );
    }
    const finalUrl = response.url || url;
    const isHtml =
      !response.contentType ||
      /html|xml/i.test(response.contentType) ||
      /^\s*</.test(response.text);
    const article: ExtractedArticle = isHtml
      ? extractFromHtml(response.text, finalUrl)
      : {
          url: finalUrl,
          title: hostname(finalUrl),
          text: response.text.trim(),
          siteName: hostname(finalUrl),
        };
    if (article.blocked) {
      throw new PageReadError(
        'blocked',
        'the site showed a bot check instead of the page',
      );
    }
    if (article.text.length < MIN_TEXT && options.readerService) {
      throw new PageReadError(
        'empty',
        'the page has no readable text without JavaScript',
      );
    }
    if (!article.text) {
      throw new PageReadError('empty', 'the page has no readable text');
    }
    page = {...article, via: 'fetch', ms: Date.now() - started};
  } catch (error) {
    if (error instanceof PageReadError) {
      failure = error;
    } else if (error instanceof HttpError) {
      failure = new PageReadError(
        error.kind === 'timeout' ? 'timeout' : 'network',
        error.kind === 'timeout'
          ? 'the page took too long to load'
          : `could not reach the site (${error.message})`,
      );
    } else {
      failure = new PageReadError(
        'network',
        (error as Error)?.message ?? 'failed',
      );
    }
  }
  if (
    !page &&
    options.readerService &&
    failure &&
    failure.kind !== 'refused' &&
    failure.kind !== 'not_text' &&
    !options.signal?.aborted
  ) {
    try {
      const read = await options.readerService(url, options.signal);
      if (read.text && read.text.trim().length >= MIN_TEXT) {
        page = {
          url,
          title: read.title ?? hostname(url),
          text: read.text.trim(),
          siteName: hostname(url),
          via: 'reader-service',
          ms: Date.now() - started,
        };
      }
    } catch {
      // keep the first failure
    }
  }
  if (!page) {
    throw (
      failure ?? new PageReadError('empty', 'the page has no readable text')
    );
  }
  cache.set(url, page);
  return page;
}
