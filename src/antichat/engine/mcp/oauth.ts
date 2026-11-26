/**
 * OAuth 2.1 for remote MCP servers: protected-resource discovery (RFC 9728),
 * authorization-server metadata (RFC 8414 / OIDC), client registration by
 * Client ID Metadata Document when the server supports it and one is
 * configured, else dynamic registration (RFC 7591), authorization code with
 * PKCE S256 in the browser, refresh. Tokens are kept in the secure store,
 * one entry per server.
 *
 * Everything that touches the platform (browser, keychain, randomness) is
 * injected, so the flow runs under Jest.
 */
import type {FetchLike, McpAuth} from './client';
import {base64url, pkceChallenge} from './sha256';

export const OAUTH_REDIRECT_URI = 'antichat://oauth/callback';

/**
 * URL of AntiChat Mobile's Client ID Metadata Document. Not hosted yet
 * (owner-owned: it must sit on the project's domain and list
 * `OAUTH_REDIRECT_URI`). While null, servers are asked for dynamic
 * registration instead.
 */
export const CLIENT_METADATA_URL: string | null = null;

export interface SecureStore {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}

export interface OAuthPlatform {
  fetch: FetchLike;
  store: SecureStore;
  randomBytes(length: number): Uint8Array;
  /** Open the sign-in page; resolve with the redirect URL the app receives. */
  openAuth(url: string, redirectUri: string): Promise<string>;
  now?: () => number;
}

export interface OAuthOptions {
  serverUrl: string;
  /** Key of this server's entry in the secure store. */
  storageKey: string;
  redirectUri?: string;
  clientMetadataUrl?: string | null;
  clientName?: string;
}

interface StoredAuth {
  clientId?: string;
  clientSecret?: string;
  tokenEndpoint?: string;
  resource?: string;
  accessToken?: string;
  refreshToken?: string;
  /** Epoch ms. */
  expiresAt?: number;
  scope?: string;
}

export class OAuthError extends Error {
  constructor(
    readonly code:
      | 'discovery'
      | 'registration'
      | 'cancelled'
      | 'state'
      | 'denied'
      | 'token',
    message: string,
  ) {
    super(message);
    this.name = 'OAuthError';
  }
}

/** `key="value"` parameters of a `WWW-Authenticate: Bearer …` header. */
export function parseWwwAuthenticate(
  header: string | null | undefined,
): Record<string, string> {
  const out: Record<string, string> = {};
  if (!header) {
    return out;
  }
  const pattern = /([a-z_]+)\s*=\s*(?:"([^"]*)"|([^\s,]+))/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(header))) {
    out[match[1].toLowerCase()] = match[2] ?? match[3];
  }
  return out;
}

/** Query parameters of any URL, custom schemes included. */
export function queryOf(url: string): Record<string, string> {
  const out: Record<string, string> = {};
  const query = url.split('#')[0].split('?')[1] ?? '';
  for (const pair of query.split('&')) {
    if (!pair) {
      continue;
    }
    const [key, value = ''] = pair.split('=');
    try {
      out[decodeURIComponent(key)] = decodeURIComponent(
        value.replace(/\+/g, ' '),
      );
    } catch {
      out[key] = value;
    }
  }
  return out;
}

const form = (params: Record<string, string | undefined>): string =>
  Object.entries(params)
    .filter(([, value]) => value !== undefined && value !== '')
    .map(
      ([key, value]) =>
        `${encodeURIComponent(key)}=${encodeURIComponent(value as string)}`,
    )
    .join('&');

function splitUrl(url: string): {origin: string; path: string} {
  const match = /^(https?:\/\/[^/?#]+)([^?#]*)/i.exec(url);
  if (!match) {
    throw new OAuthError('discovery', 'Not a web address.');
  }
  return {origin: match[1], path: match[2].replace(/\/+$/, '')};
}

async function getJson(fetcher: FetchLike, url: string): Promise<any | null> {
  try {
    const response = await fetcher(url, {
      method: 'GET',
      headers: {Accept: 'application/json'},
    });
    if (!response.ok) {
      return null;
    }
    return JSON.parse(await response.text());
  } catch {
    return null;
  }
}

export interface ServerMetadata {
  resource: string;
  issuer: string;
  authorizationEndpoint: string;
  tokenEndpoint: string;
  registrationEndpoint?: string;
  supportsClientMetadata: boolean;
  scopes?: string[];
}

/** Where to sign in for a server, from its 401 answer and well-known files. */
export async function discover(
  fetcher: FetchLike,
  serverUrl: string,
  wwwAuthenticate?: string | null,
): Promise<ServerMetadata> {
  const challenge = parseWwwAuthenticate(wwwAuthenticate);
  const server = splitUrl(serverUrl);
  const resourceCandidates = [
    challenge.resource_metadata,
    `${server.origin}/.well-known/oauth-protected-resource${server.path}`,
    `${server.origin}/.well-known/oauth-protected-resource`,
  ].filter((value): value is string => !!value);
  let resourceMeta: any = null;
  for (const candidate of resourceCandidates) {
    resourceMeta = await getJson(fetcher, candidate);
    if (resourceMeta) {
      break;
    }
  }
  const issuer: string =
    resourceMeta?.authorization_servers?.[0] ?? server.origin;
  const as = splitUrl(issuer);
  const metaCandidates = [
    `${as.origin}/.well-known/oauth-authorization-server${as.path}`,
    `${as.origin}/.well-known/openid-configuration${as.path}`,
    `${as.origin}${as.path}/.well-known/openid-configuration`,
  ];
  let meta: any = null;
  for (const candidate of metaCandidates) {
    meta = await getJson(fetcher, candidate);
    if (meta?.authorization_endpoint && meta?.token_endpoint) {
      break;
    }
    meta = null;
  }
  if (!meta && !resourceMeta) {
    throw new OAuthError(
      'discovery',
      'This server does not say how to sign in.',
    );
  }
  return {
    resource: resourceMeta?.resource ?? serverUrl.split('#')[0],
    issuer,
    authorizationEndpoint:
      meta?.authorization_endpoint ?? `${as.origin}/authorize`,
    tokenEndpoint: meta?.token_endpoint ?? `${as.origin}/token`,
    registrationEndpoint:
      meta?.registration_endpoint ??
      (meta ? undefined : `${as.origin}/register`),
    supportsClientMetadata:
      meta?.client_id_metadata_document_supported === true,
    scopes:
      (challenge.scope ? challenge.scope.split(' ') : undefined) ??
      resourceMeta?.scopes_supported,
  };
}

/** One server's sign-in state; plugs into `McpClient` as its `auth`. */
export class OAuthSession implements McpAuth {
  private cached: StoredAuth | null = null;
  private signingIn: Promise<boolean> | null = null;
  /** Interactive sign-in on 401 only when the user asked to connect. */
  interactive = false;

  constructor(
    private readonly platform: OAuthPlatform,
    private readonly options: OAuthOptions,
  ) {}

  private now(): number {
    return this.platform.now?.() ?? Date.now();
  }

  private async load(): Promise<StoredAuth> {
    if (!this.cached) {
      try {
        const raw = await this.platform.store.get(this.options.storageKey);
        this.cached = raw ? (JSON.parse(raw) as StoredAuth) : {};
      } catch {
        this.cached = {};
      }
    }
    return this.cached;
  }

  private async save(next: StoredAuth): Promise<void> {
    this.cached = next;
    await this.platform.store.set(
      this.options.storageKey,
      JSON.stringify(next),
    );
  }

  async hasToken(): Promise<boolean> {
    return !!(await this.load()).accessToken;
  }

  async token(): Promise<string | undefined> {
    const state = await this.load();
    if (
      state.accessToken &&
      state.expiresAt &&
      state.expiresAt - 30_000 < this.now() &&
      state.refreshToken
    ) {
      await this.refresh().catch(() => false);
      return (await this.load()).accessToken;
    }
    return state.accessToken;
  }

  async onUnauthorized(wwwAuthenticate: string | null): Promise<boolean> {
    if (await this.refresh().catch(() => false)) {
      return true;
    }
    if (!this.interactive) {
      return false;
    }
    this.signingIn ??= this.signIn(wwwAuthenticate).finally(() => {
      this.signingIn = null;
    });
    return this.signingIn;
  }

  async signOut(): Promise<void> {
    this.cached = {};
    await this.platform.store.remove(this.options.storageKey);
  }

  private async refresh(): Promise<boolean> {
    const state = await this.load();
    if (!state.refreshToken || !state.tokenEndpoint || !state.clientId) {
      return false;
    }
    const refreshToken = state.refreshToken;
    const granted = await this.tokenRequest(state.tokenEndpoint, {
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: state.clientId,
      client_secret: state.clientSecret,
      resource: state.resource,
    }).catch(() => null);
    if (!granted) {
      // The refresh token is spent: forget the tokens, keep the client.
      await this.save({
        ...state,
        accessToken: undefined,
        refreshToken: undefined,
        expiresAt: undefined,
      });
      return false;
    }
    await this.save({
      ...state,
      ...granted,
      refreshToken: granted.refreshToken ?? refreshToken,
    });
    return true;
  }

  /** The whole browser flow. Resolves true when a token was stored. */
  async signIn(wwwAuthenticate?: string | null): Promise<boolean> {
    const {platform, options} = this;
    const redirectUri = options.redirectUri ?? OAUTH_REDIRECT_URI;
    const meta = await discover(
      platform.fetch,
      options.serverUrl,
      wwwAuthenticate,
    );
    const state = await this.load();
    let clientId = state.clientId;
    let clientSecret = state.clientSecret;
    const metadataUrl =
      options.clientMetadataUrl === undefined
        ? CLIENT_METADATA_URL
        : options.clientMetadataUrl;
    if (!clientId || state.tokenEndpoint !== meta.tokenEndpoint) {
      if (meta.supportsClientMetadata && metadataUrl) {
        clientId = metadataUrl;
        clientSecret = undefined;
      } else if (meta.registrationEndpoint) {
        const response = await platform.fetch(meta.registrationEndpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Accept: 'application/json',
          },
          body: JSON.stringify({
            client_name: options.clientName ?? 'AntiChat',
            redirect_uris: [redirectUri],
            grant_types: ['authorization_code', 'refresh_token'],
            response_types: ['code'],
            token_endpoint_auth_method: 'none',
            application_type: 'native',
          }),
        });
        let registered: any = null;
        try {
          registered = JSON.parse(await response.text());
        } catch {}
        if (!response.ok || !registered?.client_id) {
          throw new OAuthError(
            'registration',
            'This server does not accept new apps.',
          );
        }
        clientId = String(registered.client_id);
        clientSecret = registered.client_secret
          ? String(registered.client_secret)
          : undefined;
      } else {
        throw new OAuthError(
          'registration',
          'This server needs an app registered in advance.',
        );
      }
    }

    const verifier = base64url(platform.randomBytes(32));
    const stateParam = base64url(platform.randomBytes(16));
    const authorizeUrl =
      meta.authorizationEndpoint +
      (meta.authorizationEndpoint.includes('?') ? '&' : '?') +
      form({
        response_type: 'code',
        client_id: clientId,
        redirect_uri: redirectUri,
        code_challenge: pkceChallenge(verifier),
        code_challenge_method: 'S256',
        state: stateParam,
        resource: meta.resource,
        scope: meta.scopes?.join(' '),
      });
    const returned = queryOf(
      await platform.openAuth(authorizeUrl, redirectUri),
    );
    if (returned.error) {
      throw new OAuthError(
        'denied',
        returned.error_description || 'Sign-in was not completed.',
      );
    }
    if (!returned.code || returned.state !== stateParam) {
      throw new OAuthError('state', 'The sign-in answer did not match.');
    }
    const granted = await this.tokenRequest(meta.tokenEndpoint, {
      grant_type: 'authorization_code',
      code: returned.code,
      redirect_uri: redirectUri,
      client_id: clientId,
      client_secret: clientSecret,
      code_verifier: verifier,
      resource: meta.resource,
    });
    await this.save({
      clientId,
      clientSecret,
      tokenEndpoint: meta.tokenEndpoint,
      resource: meta.resource,
      ...granted,
    });
    return true;
  }

  private async tokenRequest(
    endpoint: string,
    params: Record<string, string | undefined>,
  ): Promise<
    Pick<StoredAuth, 'accessToken' | 'refreshToken' | 'expiresAt' | 'scope'>
  > {
    const response = await this.platform.fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body: form(params),
    });
    let parsed: any = null;
    try {
      parsed = JSON.parse(await response.text());
    } catch {}
    if (!response.ok || !parsed?.access_token) {
      throw new OAuthError(
        'token',
        parsed?.error_description || 'The server did not issue a token.',
      );
    }
    return {
      accessToken: String(parsed.access_token),
      refreshToken: parsed.refresh_token
        ? String(parsed.refresh_token)
        : undefined,
      expiresAt:
        typeof parsed.expires_in === 'number'
          ? this.now() + parsed.expires_in * 1000
          : undefined,
      scope: parsed.scope ? String(parsed.scope) : undefined,
    };
  }
}
