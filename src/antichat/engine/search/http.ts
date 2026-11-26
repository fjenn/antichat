/**
 * Default transport: `fetch` with a timeout, a size cap and no cookies.
 * Search engines and pages see a current mobile Safari user agent; nothing
 * about the device or the user is sent.
 */
import type {HttpGet, HttpResponse} from './types';

export const BROWSER_USER_AGENT =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1';

export const DEFAULT_HEADERS: Record<string, string> = {
  'User-Agent': BROWSER_USER_AGENT,
  Accept: 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.5',
  'Accept-Language': 'en-US,en;q=0.9',
};

const DEFAULT_TIMEOUT_MS = 8000;
const DEFAULT_MAX_BYTES = 2_000_000;

export class HttpError extends Error {
  constructor(
    readonly kind: 'timeout' | 'cancelled' | 'network' | 'too_large',
    message: string,
  ) {
    super(message);
    this.name = 'HttpError';
  }
}

export const defaultHttpGet: HttpGet = async (url, options = {}) => {
  const controller = new AbortController();
  const outer = options.signal;
  if (outer?.aborted) {
    throw new HttpError('cancelled', 'cancelled');
  }
  let firedBy: 'timer' | 'caller' | undefined;
  const onAbort = () => {
    firedBy ??= 'caller';
    controller.abort();
  };
  outer?.addEventListener('abort', onAbort);
  const timer = setTimeout(() => {
    firedBy ??= 'timer';
    controller.abort();
  }, options.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: {...DEFAULT_HEADERS, ...options.headers},
      credentials: 'omit',
      redirect: 'follow',
      signal: controller.signal,
    } as RequestInit);
    const maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;
    const declared = Number(response.headers?.get?.('content-length') ?? 0);
    if (declared > maxBytes * 4) {
      throw new HttpError('too_large', 'response too large');
    }
    let text = await response.text();
    if (text.length > maxBytes) {
      text = text.slice(0, maxBytes);
    }
    const result: HttpResponse = {
      status: response.status,
      text,
      url: response.url || url,
      contentType: response.headers?.get?.('content-type') ?? undefined,
    };
    return result;
  } catch (error) {
    if (error instanceof HttpError) {
      throw error;
    }
    if (firedBy === 'timer') {
      throw new HttpError('timeout', 'timed out');
    }
    if (firedBy === 'caller') {
      throw new HttpError('cancelled', 'cancelled');
    }
    throw new HttpError(
      'network',
      (error as Error)?.message ?? 'network error',
    );
  } finally {
    clearTimeout(timer);
    outer?.removeEventListener('abort', onAbort);
  }
};
