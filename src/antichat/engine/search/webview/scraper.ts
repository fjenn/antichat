/**
 * Hidden-WebView scraping for engines that refuse plain requests (Mojeek's
 * 403, Startpage's JavaScript check). Ported from Software Mansion's Private
 * Mind (MIT), `utils/web/scrape/webViewScrapeProvider.ts`: one navigation at
 * a time, a minimum delay between navigations, a nonce per navigation so a
 * late message from the previous page is ignored, and a longer wait when the
 * page shows a challenge the user (or the WebView itself) can pass.
 *
 * The engine owns this controller; the UI half mounts `ScrapeWebViewHost`
 * (one zero-size WebView) and attaches it. Without a host the provider
 * reports itself unavailable and the broker simply races the other engines.
 */
import {isHttpUrl} from '../html';
import type {WebViewScraper} from '../engines/scrapeProvider';
import type {SearchResult} from '../types';

export interface ScraperHost {
  /** Load `url`; the host injects the parser script with this nonce. */
  navigate(url: string, nonce: number): void;
  reset?(): void;
  /** A challenge is showing; a visible host may bring the WebView forward. */
  onChallenge?(): void;
}

export const SCRAPE_MIN_DELAY_MS = 1500;
export const SCRAPE_PAGE_LOAD_TIMEOUT_MS = 12000;
export const SCRAPE_CHALLENGE_TIMEOUT_MS = 20000;

const MAX_TITLE = 200;
const MAX_SNIPPET = 500;
const MAX_URL = 2000;
const MAX_MESSAGE = 200_000;

export type SerpMessage = {nonce?: number} & (
  | {type: 'serp-results'; results: Array<Omit<SearchResult, 'engine'>>}
  | {type: 'serp-challenge'}
  | {type: 'serp-error'; message: string}
);

/** Messages come from a web page: validate every field, trust nothing. */
export function parseSerpMessage(raw: string): SerpMessage | null {
  if (typeof raw !== 'string' || raw.length > MAX_MESSAGE) {
    return null;
  }
  let data: any;
  try {
    data = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!data || typeof data !== 'object') {
    return null;
  }
  const nonce = typeof data.nonce === 'number' ? data.nonce : undefined;
  if (data.type === 'serp-challenge') {
    return {type: 'serp-challenge', nonce};
  }
  if (data.type === 'serp-error') {
    return {
      type: 'serp-error',
      message: String(data.message ?? '').slice(0, 200),
      nonce,
    };
  }
  if (data.type !== 'serp-results' || !Array.isArray(data.results)) {
    return null;
  }
  const clean = (value: unknown, max: number): string =>
    (typeof value === 'string' ? value : '')
      // eslint-disable-next-line no-control-regex
      .replace(/[\u0000-\u001F\u007F-\u009F​-‏‪-‮]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, max);
  const results = data.results
    .slice(0, 20)
    .filter(
      (row: any) => row && typeof row.url === 'string' && isHttpUrl(row.url),
    )
    .map((row: any) => ({
      title: clean(row.title, MAX_TITLE),
      url: String(row.url).slice(0, MAX_URL),
      snippet: clean(row.snippet, MAX_SNIPPET),
    }))
    .filter((row: {title: string}) => row.title.length > 0);
  return {type: 'serp-results', results, nonce};
}

interface Pending {
  resolve: (results: SearchResult[]) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
  nonce: number;
  engineId: string;
}

const delay = (ms: number): Promise<void> =>
  new Promise(resolve => setTimeout(resolve, ms));

export class WebViewScrapeController implements WebViewScraper {
  private host: ScraperHost | null = null;
  private pending: Pending | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private lastRunAt = 0;
  private navigations = 0;
  private challengeActive = false;

  constructor(
    private readonly timing: {
      minDelayMs?: number;
      pageLoadTimeoutMs?: number;
      challengeTimeoutMs?: number;
    } = {},
  ) {}

  attachHost(host: ScraperHost): void {
    this.host = host;
  }

  detachHost(): void {
    this.host = null;
    this.settle(null, new Error('WebView scraper host detached'));
  }

  isReady(): boolean {
    return this.host !== null;
  }

  isChallengeActive(): boolean {
    return this.challengeActive;
  }

  /** The host forwards every WebView message here. */
  handleMessage(raw: string): void {
    const message = parseSerpMessage(raw);
    const pending = this.pending;
    if (!message || !pending || message.nonce !== pending.nonce) {
      return;
    }
    if (message.type === 'serp-challenge') {
      if (!this.challengeActive) {
        clearTimeout(pending.timer);
        pending.timer = setTimeout(
          () => this.settle([], null),
          this.timing.challengeTimeoutMs ?? SCRAPE_CHALLENGE_TIMEOUT_MS,
        );
        this.challengeActive = true;
        this.host?.onChallenge?.();
      }
      return;
    }
    if (message.type === 'serp-error') {
      this.settle(null, new Error(message.message));
      return;
    }
    this.settle(
      message.results.map(result => ({...result, engine: pending.engineId})),
      null,
    );
  }

  scrape(
    url: string,
    options: {signal?: AbortSignal; timeoutMs?: number; engineId: string},
  ): Promise<SearchResult[]> {
    const run = this.queue.then(() => this.navigateAndWait(url, options));
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async navigateAndWait(
    url: string,
    options: {signal?: AbortSignal; timeoutMs?: number; engineId: string},
  ): Promise<SearchResult[]> {
    const minDelay = this.timing.minDelayMs ?? SCRAPE_MIN_DELAY_MS;
    const wait = minDelay - (Date.now() - this.lastRunAt);
    if (wait > 0 && this.lastRunAt > 0) {
      await delay(wait);
    }
    if (!this.host) {
      throw new Error('WebView scraper host not attached');
    }
    if (options.signal?.aborted) {
      return [];
    }
    this.lastRunAt = Date.now();
    const onAbort = () => {
      this.settle([], null);
      this.host?.reset?.();
    };
    options.signal?.addEventListener('abort', onAbort);
    try {
      return await new Promise<SearchResult[]>((resolve, reject) => {
        const timer = setTimeout(
          () => this.settle(null, new Error('result page timed out')),
          this.timing.pageLoadTimeoutMs ?? SCRAPE_PAGE_LOAD_TIMEOUT_MS,
        );
        const nonce = ++this.navigations;
        this.pending = {
          resolve,
          reject,
          timer,
          nonce,
          engineId: options.engineId,
        };
        this.host!.navigate(url, nonce);
      });
    } finally {
      options.signal?.removeEventListener('abort', onAbort);
    }
  }

  private settle(results: SearchResult[] | null, error: Error | null): void {
    const pending = this.pending;
    if (!pending) {
      return;
    }
    this.pending = null;
    this.challengeActive = false;
    clearTimeout(pending.timer);
    if (error) {
      pending.reject(error);
    } else {
      pending.resolve(results ?? []);
    }
  }
}

/** The app-wide controller the scrape providers and the host share. */
export const webViewScraper = new WebViewScrapeController();

const ALLOWED_NAVIGATION = [
  'duckduckgo.com',
  'bing.com',
  'mojeek.com',
  'brave.com',
  'startpage.com',
  'cloudflare.com',
  'hcaptcha.com',
  'recaptcha.net',
  'gstatic.com',
];

/** The hidden WebView may only ever load an engine or a challenge host. */
export function isAllowedScrapeNavigation(url: string): boolean {
  if (url.startsWith('about:')) {
    return true;
  }
  const host = /^https:\/\/([^/?#:]+)/i.exec(url)?.[1]?.toLowerCase();
  if (!host) {
    return false;
  }
  return ALLOWED_NAVIGATION.some(
    domain => host === domain || host.endsWith(`.${domain}`),
  );
}
