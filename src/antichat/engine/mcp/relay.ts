/**
 * Client of the AntiChat relay (the Mac app's, unchanged): the only
 * AntiChat-run server. It holds the Composio key; the phone sends an install
 * id it generated itself and nothing about the user.
 *
 * Contract: `relay/README.md` in the Mac repository.
 */
import type {FetchLike} from './client';

export const RELAY_BASE_URL = 'https://antichat-relay.finn-jennen.workers.dev';
export const RELAY_CLIENT_VERSION = '0.1.0';
/** Where the hosted sign-in returns to. The relay accepts `antichat:` only. */
export const CONNECT_CALLBACK_URL = 'antichat://connectors/callback';

export interface Toolkit {
  slug: string;
  name: string;
  description: string;
  categories: string[];
  auth: 'oauth' | 'apikey' | 'none' | 'other';
  logo: string;
}

export interface Connection {
  id: string;
  toolkit: string;
  /** Lower-case: `active`, `initiated`, `failed`, … */
  status: string;
}

export type RelayErrorCode =
  | 'relay.notConfigured'
  | 'relay.rateLimited'
  | 'relay.overCapacity'
  | 'relay.disabled'
  | 'relay.updateRequired'
  | 'relay.badRequest'
  | 'relay.notFound'
  | 'relay.upstream'
  | 'relay.misconfigured'
  | 'network'
  | 'unknown';

export class RelayError extends Error {
  constructor(
    readonly code: RelayErrorCode,
    readonly status = 0,
    readonly retryAfterSeconds?: number,
  ) {
    super(code);
    this.name = 'RelayError';
  }
}

export interface RelayOptions {
  baseUrl?: string;
  fetch?: FetchLike;
  /** The install id (UUIDv4), created on first use and kept in the keychain. */
  installId: () => Promise<string>;
  version?: string;
  platform?: string;
  timeoutMs?: number;
  /**
   * Debug builds: resolves to a relay URL that replaces `baseUrl` (a relay
   * on the Mac, `tools/antichat/relay-local.sh`), or null. Every call waits
   * for it first.
   */
  baseUrlOverride?: Promise<string | null>;
}

/**
 * True when an answer without a relay code means the host is out of capacity: Cloudflare's own pages when the
 * Workers Free daily quota is used up (error 1027) or a request ran out of CPU (1102), or a bare 429/503.
 * The app then says "busy, try again later" instead of showing an error.
 */
export function relayBusy(status: number, body: string): boolean {
  return (
    status === 429 ||
    status === 503 ||
    /error(?:\s+code)?:?\s*(1027|1102)\b/i.test(body)
  );
}

export const isActive = (connection: Connection): boolean =>
  connection.status === 'active';

const trimUrl = (url: string) => url.replace(/\/+$/, '');

export class RelayClient {
  baseUrl: string;
  private readonly ready: Promise<void>;

  constructor(private readonly options: RelayOptions) {
    this.baseUrl = trimUrl(options.baseUrl ?? RELAY_BASE_URL);
    this.ready = (options.baseUrlOverride ?? Promise.resolve(null)).then(
      url => {
        if (url) {
          this.baseUrl = trimUrl(url);
        }
      },
      () => {},
    );
  }

  get mcpUrl(): string {
    return `${this.baseUrl}/v1/mcp`;
  }

  /** The headers every route but `/v1/health` needs. */
  async headers(): Promise<Record<string, string>> {
    const version = this.options.version ?? RELAY_CLIENT_VERSION;
    return {
      'X-AntiChat-Install': await this.options.installId(),
      'X-AntiChat-Version': version,
      // Ignored by today's relay; lets it tell the apps apart later.
      'X-AntiChat-Platform': this.options.platform ?? 'mobile',
      'User-Agent': `AntiChat/${version}`,
    };
  }

  private async call(
    method: string,
    path: string,
    body?: unknown,
    extraHeaders: Record<string, string> = {},
    identified = true,
  ): Promise<{status: number; json: any; etag: string | null}> {
    await this.ready;
    const doFetch = this.options.fetch ?? (fetch as unknown as FetchLike);
    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(),
      this.options.timeoutMs ?? 30_000,
    );
    let status = 0;
    let text = '';
    let etag: string | null = null;
    let retryAfter: string | null = null;
    try {
      const response = await doFetch(`${this.baseUrl}${path}`, {
        method,
        headers: {
          Accept: 'application/json',
          ...(body === undefined ? {} : {'Content-Type': 'application/json'}),
          ...(identified ? await this.headers() : {}),
          ...extraHeaders,
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      });
      status = response.status;
      etag = response.headers.get('etag');
      retryAfter = response.headers.get('retry-after');
      text = await response.text();
    } catch {
      throw new RelayError('network');
    } finally {
      clearTimeout(timer);
    }
    let json: any = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {}
    if (status === 304) {
      return {status, json: null, etag};
    }
    if (status < 200 || status >= 300) {
      const code =
        typeof json?.code === 'string' && json.code.startsWith('relay.')
          ? (json.code as RelayErrorCode)
          : relayBusy(status, text)
            ? 'relay.overCapacity'
            : 'unknown';
      throw new RelayError(
        code,
        status,
        retryAfter ? Number(retryAfter) || undefined : undefined,
      );
    }
    return {status, json, etag};
  }

  async health(): Promise<{ok: boolean; version?: string}> {
    return (await this.call('GET', '/v1/health', undefined, {}, false)).json;
  }

  /** Creates or reuses the tool session. */
  async session(): Promise<void> {
    await this.call('POST', '/v1/session');
  }

  /** The app directory. `null` = unchanged since `etag`. */
  async toolkits(
    etag?: string | null,
  ): Promise<{toolkits: Toolkit[]; etag: string | null} | null> {
    const answer = await this.call(
      'GET',
      '/v1/toolkits',
      undefined,
      etag ? {'If-None-Match': etag} : {},
    );
    if (answer.status === 304 || !Array.isArray(answer.json?.toolkits)) {
      return null;
    }
    return {
      toolkits: (answer.json.toolkits as any[])
        .filter(item => item && typeof item.slug === 'string')
        .map(item => ({
          slug: String(item.slug),
          name: String(item.name ?? item.slug),
          description: String(item.description ?? ''),
          categories: Array.isArray(item.categories)
            ? item.categories.map(String)
            : [],
          auth: item.auth ?? 'other',
          logo: typeof item.logo === 'string' ? item.logo : '',
        })),
      etag: answer.etag,
    };
  }

  async connections(): Promise<{
    featured: string[];
    connections: Connection[];
  }> {
    const {json} = await this.call('GET', '/v1/connections');
    return {
      featured: Array.isArray(json?.toolkits) ? json.toolkits.map(String) : [],
      connections: (Array.isArray(json?.connections) ? json.connections : [])
        .filter((item: any) => item && item.id && item.toolkit)
        .map((item: any) => ({
          id: String(item.id),
          toolkit: String(item.toolkit).toLowerCase(),
          status: String(item.status ?? '').toLowerCase(),
        })),
    };
  }

  /** The hosted sign-in page for an app. */
  async link(
    toolkit: string,
    callbackUrl: string | null = CONNECT_CALLBACK_URL,
  ): Promise<{url: string; id: string}> {
    const {json} = await this.call('POST', '/v1/connections/link', {
      toolkit,
      ...(callbackUrl ? {callback_url: callbackUrl} : {}),
    });
    if (typeof json?.url !== 'string' || !/^https:\/\//i.test(json.url)) {
      throw new RelayError('relay.upstream', 502);
    }
    return {url: json.url, id: String(json.id ?? '')};
  }

  async disconnect(connectionId: string): Promise<void> {
    await this.call(
      'DELETE',
      `/v1/connections/${encodeURIComponent(connectionId)}`,
    );
  }

  /** Disconnects everything and deletes the relay's session for this install. */
  async forget(): Promise<void> {
    await this.call('POST', '/v1/forget');
  }
}
