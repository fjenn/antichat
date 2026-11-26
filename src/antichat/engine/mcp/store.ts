/**
 * The connectors state the UI observes: the app directory, what is
 * connected, custom MCP servers, the connect flow in progress, pending
 * write approvals and the in-chat Connect card. All platform access is
 * injected (`ConnectorsDeps`), so the store runs under Jest.
 */
import {action, computed, makeObservable, observable, runInAction} from 'mobx';

import {FEATURED_SLUGS, appTitle, resolveApp, type AppRef} from './apps';
import {McpClient, McpError, type FetchLike, type McpToolInfo} from './client';
import {
  OAuthError,
  OAuthSession,
  type OAuthPlatform,
  type SecureStore,
} from './oauth';
import {
  Permissions,
  type ApprovalAnswer,
  type ApprovalRequest,
  type KeyValueStore,
} from './permissions';
import {
  CONNECT_CALLBACK_URL,
  RelayClient,
  RelayError,
  isActive,
  type Connection,
  type Toolkit,
} from './relay';

export interface CustomServer {
  id: string;
  url: string;
  name: string;
  state: 'connected' | 'needs_signin' | 'error';
  /** Tools as last listed; registered at start-up without a request. */
  tools: McpToolInfo[];
  error?: string;
}

export interface ConnectCard {
  id: string;
  /** null = not an app the directory has: the card links to the screen. */
  slug: string | null;
  name: string;
  /** Answers a plain "connect X" message: nothing to run again afterwards. */
  direct: boolean;
}

export interface ConnectorsDeps {
  relay: RelayClient;
  storage: KeyValueStore;
  secure: SecureStore;
  fetch: FetchLike;
  randomBytes(length: number): Uint8Array;
  /** Open a page in the browser. */
  openUrl(url: string): Promise<void>;
  /**
   * Open a hosted sign-in in an in-app sheet that closes when the page
   * redirects to `callbackPrefix`. Resolves 'returned' (the redirect came
   * back) or 'cancelled' (the person closed the sheet). Without it the page
   * opens in the browser (`openUrl`).
   */
  openSheet?(
    url: string,
    callbackPrefix: string,
  ): Promise<'returned' | 'cancelled'>;
  /** Open a sign-in page and resolve with the redirect the app receives. */
  openAuth(url: string, redirectUri: string): Promise<string>;
  isOnline(): boolean;
  permissions?: Permissions;
  /** Milliseconds between connection checks while a sign-in is open. */
  pollIntervalMs?: number;
  pollTimeoutMs?: number;
  clientInfo?: {name: string; version: string};
}

const TOOLKITS_KEY = 'antichat.connectors.toolkits.v1';
const CONNECTIONS_KEY = 'antichat.connectors.connections.v1';
const SERVERS_KEY = 'antichat.connectors.servers.v1';
const MAX_SERVER_TOOLS = 60;

const BUSY = 'Connections are busy, try again later.';

/** Words for a failure, never a relay code. */
export function describeError(error: unknown): string {
  if (error instanceof RelayError) {
    switch (error.code) {
      case 'network':
        return 'No connection to the connections service.';
      case 'relay.rateLimited':
        return 'Too many requests. Try again in a little while.';
      case 'relay.overCapacity':
        return BUSY;
      case 'relay.updateRequired':
        return 'Update AntiChat to use connections.';
      case 'relay.disabled':
      case 'relay.notConfigured':
        return 'Connections are switched off right now.';
      default:
        return 'The connections service did not answer. Try again.';
    }
  }
  // The relay's MCP pass-through out of capacity (its JSON code, or the host's own quota page).
  if (
    error instanceof McpError &&
    error.code === 'http' &&
    ((error.body as {code?: unknown} | undefined)?.code ===
      'relay.overCapacity' ||
      (error.body === undefined &&
        (error.status === 429 || error.status === 503)))
  ) {
    return BUSY;
  }
  if (error instanceof McpError || error instanceof OAuthError) {
    return error.message;
  }
  return 'Something went wrong. Try again.';
}

/** `https://mcp.notion.com/mcp` → "notion". */
export function serverNameFromUrl(url: string): string {
  const host = /^https?:\/\/([^/:?#]+)/i.exec(url)?.[1] ?? 'server';
  const labels = host.split('.').filter(Boolean);
  if (/^\d+$/.test(labels[labels.length - 1] ?? '') || labels.length < 2) {
    return host;
  }
  return labels[labels.length - 2];
}

let localHttpAllowed = true;

/**
 * Plain `http` to a server on this phone or the local network. Debug builds
 * only: release builds have no ATS local-networking exception and take
 * `https` servers alone (`createPlatformDeps`).
 */
export function setLocalHttpAllowed(on: boolean): void {
  localHttpAllowed = on;
}

/**
 * A typed address as a server URL, or null. `http` only for local hosts, and
 * only while `setLocalHttpAllowed` is on.
 */
export function normalizeServerUrl(input: string): string | null {
  let text = input.trim();
  if (!text) {
    return null;
  }
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) {
    text = `https://${text}`;
  }
  const match = /^(https?):\/\/([^/:?#\s]+)(:\d+)?([^\s]*)$/i.exec(text);
  if (!match) {
    return null;
  }
  const host = match[2].toLowerCase();
  const local =
    host === 'localhost' ||
    host === '10.0.2.2' ||
    /^127\./.test(host) ||
    /^192\.168\./.test(host);
  if (match[1].toLowerCase() === 'http' && !(local && localHttpAllowed)) {
    return null;
  }
  if (!local && !host.includes('.')) {
    return null;
  }
  return `${match[1].toLowerCase()}://${host}${match[3] ?? ''}${match[4] ?? ''}`;
}

export class ConnectorsStore {
  toolkits: Toolkit[] = [];
  toolkitsState: 'idle' | 'loading' | 'ready' | 'error' = 'idle';
  connections: Connection[] = [];
  servers: CustomServer[] = [];
  /** Slug whose hosted sign-in is open. */
  connecting: string | null = null;
  /** Last failure, in words, for the screen's inline error. */
  error: string | null = null;
  approvals: ApprovalRequest[] = [];
  card: ConnectCard | null = null;
  /** Bumps whenever the set of registered tools may have changed. */
  revision = 0;

  readonly permissions: Permissions;
  private toolkitsEtag: string | null = null;
  private loaded: Promise<void> | null = null;
  private wake: (() => void) | null = null;
  private cancelConnect: (() => void) | null = null;
  private readonly clients = new Map<string, McpClient>();
  private readonly sessions = new Map<string, OAuthSession>();
  private relayMcpClient: McpClient | null = null;
  private counter = 0;

  constructor(readonly deps: ConnectorsDeps) {
    this.permissions = deps.permissions ?? new Permissions(deps.storage);
    makeObservable(this, {
      toolkits: observable.ref,
      toolkitsState: observable,
      connections: observable.ref,
      servers: observable.ref,
      connecting: observable,
      error: observable,
      approvals: observable.ref,
      card: observable.ref,
      revision: observable,
      connectedSlugs: computed,
      dismissCard: action,
      showCard: action,
      clearError: action,
    });
    this.permissions.subscribe(() =>
      runInAction(() => {
        this.approvals = this.permissions.requests();
      }),
    );
  }

  get online(): boolean {
    return this.deps.isOnline();
  }

  get connectedSlugs(): string[] {
    return [
      ...new Set(this.connections.filter(isActive).map(item => item.toolkit)),
    ];
  }

  isConnected(slug: string): boolean {
    return this.connectedSlugs.includes(slug.toLowerCase());
  }

  get directory(): AppRef[] {
    return this.toolkits;
  }

  title(slug: string): string {
    return appTitle(slug, this.toolkits);
  }

  clearError(): void {
    this.error = null;
  }

  /** Cached state from the last run; no request. */
  load(): Promise<void> {
    this.loaded ??= (async () => {
      const read = async <T>(key: string): Promise<T | null> => {
        try {
          const raw = await this.deps.storage.getItem(key);
          return raw ? (JSON.parse(raw) as T) : null;
        } catch {
          return null;
        }
      };
      const [toolkits, connections, servers] = await Promise.all([
        read<{etag: string | null; toolkits: Toolkit[]}>(TOOLKITS_KEY),
        read<Connection[]>(CONNECTIONS_KEY),
        read<CustomServer[]>(SERVERS_KEY),
        this.permissions.load(),
      ]);
      runInAction(() => {
        if (toolkits?.toolkits?.length) {
          this.toolkits = toolkits.toolkits;
          this.toolkitsEtag = toolkits.etag;
          this.toolkitsState = 'ready';
        }
        this.connections = connections ?? [];
        this.servers = servers ?? [];
        this.revision++;
      });
    })();
    return this.loaded;
  }

  private persist(key: string, value: unknown): void {
    this.deps.storage.setItem(key, JSON.stringify(value)).catch(() => {});
  }

  // MARK: directory and connections

  /** Refresh the directory and the connections (two read calls). */
  async refresh(): Promise<void> {
    await this.load();
    if (!this.online) {
      return;
    }
    runInAction(() => {
      this.error = null;
      if (this.toolkitsState !== 'ready') {
        this.toolkitsState = 'loading';
      }
    });
    const [toolkits, connections] = await Promise.allSettled([
      this.deps.relay.toolkits(this.toolkits.length ? this.toolkitsEtag : null),
      this.deps.relay.connections(),
    ]);
    runInAction(() => {
      if (toolkits.status === 'fulfilled') {
        if (toolkits.value) {
          this.toolkits = toolkits.value.toolkits;
          this.toolkitsEtag = toolkits.value.etag;
          this.persist(TOOLKITS_KEY, {
            etag: this.toolkitsEtag,
            toolkits: this.toolkits,
          });
        }
        this.toolkitsState = 'ready';
      } else if (this.toolkitsState !== 'ready') {
        this.toolkitsState = 'error';
        this.error = describeError(toolkits.reason);
      }
      if (connections.status === 'fulfilled') {
        this.applyConnections(connections.value.connections);
      } else if (toolkits.status === 'fulfilled') {
        this.error = describeError(connections.reason);
      }
    });
  }

  private applyConnections(next: Connection[]): void {
    const before = this.connectedSlugs.join(',');
    this.connections = next;
    this.persist(CONNECTIONS_KEY, next);
    if (this.connectedSlugs.join(',') !== before) {
      this.revision++;
    }
  }

  async refreshConnections(): Promise<void> {
    const {connections} = await this.deps.relay.connections();
    runInAction(() => this.applyConnections(connections));
  }

  /** The directory, featured apps first, filtered by a search text. */
  search(query: string): Toolkit[] {
    const wanted = query.trim().toLowerCase();
    const rank = (toolkit: Toolkit) => {
      const featured = FEATURED_SLUGS.indexOf(toolkit.slug);
      return featured === -1 ? FEATURED_SLUGS.length : featured;
    };
    const list = wanted
      ? this.toolkits.filter(
          toolkit =>
            toolkit.name.toLowerCase().includes(wanted) ||
            toolkit.slug.includes(wanted) ||
            toolkit.categories.some(category => category.includes(wanted)),
        )
      : this.toolkits.filter(toolkit => toolkit.auth !== 'none');
    return [...list].sort((a, b) => {
      if (wanted) {
        const starts =
          Number(b.name.toLowerCase().startsWith(wanted)) -
          Number(a.name.toLowerCase().startsWith(wanted));
        if (starts) {
          return starts;
        }
      }
      return rank(a) - rank(b) || a.name.localeCompare(b.name);
    });
  }

  /**
   * Connect an app: relay session → hosted sign-in in an in-app sheet (or
   * the browser) → back through the `antichat:` redirect, with a connection
   * check every few seconds as the fallback. Closing the sheet ends the wait
   * after one last check. Resolves true once the app is connected.
   */
  async connect(slug: string): Promise<boolean> {
    const toolkit = slug.toLowerCase();
    if (!this.online || this.connecting) {
      return false;
    }
    runInAction(() => {
      this.connecting = toolkit;
      this.error = null;
    });
    let cancelled = false;
    // The in-app sheet was closed: one last check, then stop waiting.
    let closed = false;
    this.cancelConnect = () => {
      cancelled = true;
      this.wake?.();
    };
    try {
      await this.deps.relay.session();
      const link = await this.deps.relay.link(
        toolkit,
        `${CONNECT_CALLBACK_URL}?toolkit=${encodeURIComponent(toolkit)}`,
      );
      if (this.deps.openSheet) {
        // The sheet runs beside the checks; closing it ends the wait.
        this.deps.openSheet(link.url, CONNECT_CALLBACK_URL).then(
          outcome => {
            if (outcome === 'cancelled') {
              closed = true;
            }
            this.wake?.();
          },
          () => {
            closed = true;
            this.wake?.();
          },
        );
      } else {
        await this.deps.openUrl(link.url);
      }
      const interval = this.deps.pollIntervalMs ?? 2500;
      const deadline = Date.now() + (this.deps.pollTimeoutMs ?? 5 * 60_000);
      while (!cancelled && Date.now() < deadline) {
        await new Promise<void>(resolve => {
          const timer = setTimeout(resolve, interval);
          this.wake = () => {
            clearTimeout(timer);
            resolve();
          };
        });
        if (cancelled) {
          break;
        }
        try {
          await this.refreshConnections();
        } catch {
          // A failed check is retried at the next tick.
        }
        if (this.isConnected(toolkit)) {
          return true;
        }
        if (closed) {
          break;
        }
        const failed = this.connections.some(
          item => item.toolkit === toolkit && item.status === 'failed',
        );
        if (failed && link.id) {
          break;
        }
      }
      return this.isConnected(toolkit);
    } catch (error) {
      runInAction(() => {
        this.error = describeError(error);
      });
      return false;
    } finally {
      this.wake = null;
      this.cancelConnect = null;
      runInAction(() => {
        this.connecting = null;
      });
    }
  }

  cancelConnecting(): void {
    this.cancelConnect?.();
  }

  /** The app came back (deep link or foreground): check right away. */
  connectionMayHaveChanged(): void {
    if (this.wake) {
      this.wake();
    } else if (this.online && this.connections.length + this.toolkits.length) {
      this.refreshConnections().catch(() => {});
    }
  }

  async disconnect(slug: string): Promise<void> {
    const toolkit = slug.toLowerCase();
    try {
      for (const connection of this.connections.filter(
        item => item.toolkit === toolkit,
      )) {
        await this.deps.relay.disconnect(connection.id);
      }
      await this.permissions.forget(`composio:${toolkit.toUpperCase()}_`);
      await this.refreshConnections();
    } catch (error) {
      runInAction(() => {
        this.error = describeError(error);
      });
    }
  }

  /** The relay's MCP endpoint (Composio's meta-tools). */
  relayMcp(): McpClient {
    this.relayMcpClient ??= new McpClient({
      url: this.deps.relay.mcpUrl,
      fetch: this.deps.fetch,
      headers: () => this.deps.relay.headers(),
      clientInfo: this.deps.clientInfo,
      timeoutMs: 120_000,
    });
    return this.relayMcpClient;
  }

  // MARK: custom MCP servers

  private oauthPlatform(): OAuthPlatform {
    return {
      fetch: this.deps.fetch,
      store: this.deps.secure,
      randomBytes: this.deps.randomBytes,
      openAuth: this.deps.openAuth,
    };
  }

  private sessionFor(server: {id: string; url: string}): OAuthSession {
    let session = this.sessions.get(server.id);
    if (!session) {
      session = new OAuthSession(this.oauthPlatform(), {
        serverUrl: server.url,
        storageKey: `ai.antichat.mcp.${server.id}`,
      });
      this.sessions.set(server.id, session);
    }
    return session;
  }

  clientFor(server: {id: string; url: string}): McpClient {
    let client = this.clients.get(server.id);
    if (!client) {
      client = new McpClient({
        url: server.url,
        fetch: this.deps.fetch,
        auth: this.sessionFor(server),
        clientInfo: this.deps.clientInfo,
      });
      this.clients.set(server.id, client);
    }
    return client;
  }

  private setServers(next: CustomServer[]): void {
    this.servers = next;
    this.persist(SERVERS_KEY, next);
    this.revision++;
  }

  /**
   * Add a server by URL (or sign in again to one that needs it): handshake,
   * browser sign-in when the server answers 401, then its tool list.
   */
  async addServer(input: string): Promise<CustomServer | null> {
    const url = normalizeServerUrl(input);
    if (!url) {
      runInAction(() => {
        this.error = 'Enter the web address of an MCP server (https://…).';
      });
      return null;
    }
    if (!this.online) {
      return null;
    }
    runInAction(() => {
      this.error = null;
    });
    const existing = this.servers.find(server => server.url === url);
    const id =
      existing?.id ??
      `${
        serverNameFromUrl(url)
          .replace(/[^a-z0-9]/gi, '')
          .toLowerCase() || 'server'
      }${this.servers.length ? `-${Date.now().toString(36)}` : ''}`;
    const ref = {id, url};
    const session = this.sessionFor(ref);
    const client = this.clientFor(ref);
    session.interactive = true;
    try {
      client.reset();
      await client.initialize();
      const tools = (await client.listTools()).slice(0, MAX_SERVER_TOOLS);
      const server: CustomServer = {
        id,
        url,
        name:
          existing?.name ??
          prettyName(client.serverInfo.name, serverNameFromUrl(url)),
        state: 'connected',
        tools: tools.map(tool => ({
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
          annotations: tool.annotations,
        })),
      };
      runInAction(() =>
        this.setServers([
          ...this.servers.filter(item => item.id !== id),
          server,
        ]),
      );
      return server;
    } catch (error) {
      runInAction(() => {
        this.error = describeError(error);
        if (existing) {
          this.setServers(
            this.servers.map(item =>
              item.id === id
                ? {
                    ...item,
                    state:
                      error instanceof McpError && error.code === 'unauthorized'
                        ? 'needs_signin'
                        : 'error',
                    error: this.error ?? undefined,
                  }
                : item,
            ),
          );
        }
      });
      return null;
    } finally {
      session.interactive = false;
    }
  }

  markServerSignedOut(id: string): void {
    runInAction(() =>
      this.setServers(
        this.servers.map(item =>
          item.id === id ? {...item, state: 'needs_signin'} : item,
        ),
      ),
    );
  }

  async removeServer(id: string): Promise<void> {
    const server = this.servers.find(item => item.id === id);
    if (!server) {
      return;
    }
    await this.sessionFor(server)
      .signOut()
      .catch(() => {});
    this.sessions.delete(id);
    this.clients.delete(id);
    await this.permissions.forget(`mcp:${id}:`);
    runInAction(() =>
      this.setServers(this.servers.filter(item => item.id !== id)),
    );
  }

  // MARK: approvals and the Connect card

  answerApproval(id: string, answer: ApprovalAnswer): void {
    this.permissions.answer(id, answer);
  }

  /**
   * Show the Connect card for an app the model (or the user) named. Returns
   * the card, or null when the app is already connected.
   */
  showCard(name: string, direct = false): ConnectCard | null {
    const app = resolveApp(name, this.toolkits);
    if (app && this.isConnected(app.slug)) {
      return null;
    }
    this.card = {
      id: `card-${Date.now().toString(36)}-${this.counter++}`,
      slug: app?.slug ?? null,
      name: app?.name ?? name.trim(),
      direct,
    };
    return this.card;
  }

  dismissCard(): void {
    this.card = null;
  }
}

function prettyName(reported: string | undefined, fallback: string): string {
  const name = (reported ?? '').trim();
  const text =
    name && name.length <= 40 && !/server/i.test(name) ? name : fallback;
  return text.charAt(0).toUpperCase() + text.slice(1);
}
