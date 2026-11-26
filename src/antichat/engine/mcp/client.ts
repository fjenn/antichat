/**
 * A small MCP client for React Native / Hermes: Streamable HTTP with
 * buffered responses.
 *
 * RN's `fetch` is XHR-based and cannot stream a body, so every request is a
 * POST whose answer is read whole (`await res.text()`) and then parsed as
 * JSON or as a finished SSE body. The long-lived `GET` stream is never
 * opened. That is all the relay and ordinary remote servers need for
 * `initialize`, `tools/list` and `tools/call`.
 *
 * Hand-written (05b §2 option 2) instead of `@modelcontextprotocol/client`:
 * no package, no Metro remap and no native module, so it runs in the debug
 * apps already built. OAuth lives in `oauth.ts`.
 */
export type FetchLike = (
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    signal?: AbortSignal;
  },
) => Promise<{
  status: number;
  ok: boolean;
  headers: {get(name: string): string | null};
  text(): Promise<string>;
}>;

export const MCP_PROTOCOL_VERSION = '2025-06-18';
const MAX_BODY = 1_000_000;

export type McpErrorCode =
  | 'unauthorized'
  | 'http'
  | 'rpc'
  | 'network'
  | 'protocol'
  | 'cancelled';

export class McpError extends Error {
  constructor(
    readonly code: McpErrorCode,
    message: string,
    readonly status?: number,
    /** `WWW-Authenticate` of a 401, for OAuth discovery. */
    readonly wwwAuthenticate?: string | null,
    /** Parsed JSON body of an HTTP error, when there was one. */
    readonly body?: unknown,
  ) {
    super(message);
    this.name = 'McpError';
  }
}

export interface McpToolInfo {
  name: string;
  description?: string;
  inputSchema?: Record<string, any>;
  annotations?: Record<string, unknown>;
}

export interface McpCallResult {
  /** Text parts joined with blank lines. */
  text: string;
  isError: boolean;
  structured?: unknown;
}

export interface McpAuth {
  /** A bearer token to send, if there is one. */
  token(): Promise<string | undefined>;
  /**
   * Called on 401. Return true once a new token is available (refreshed, or
   * the user signed in) and the request should be sent again.
   */
  onUnauthorized?(wwwAuthenticate: string | null): Promise<boolean>;
}

export interface McpClientOptions {
  url: string;
  fetch?: FetchLike;
  /** Extra headers for every request (the relay's install headers). */
  headers?: () => Promise<Record<string, string>> | Record<string, string>;
  auth?: McpAuth;
  clientInfo?: {name: string; version: string};
  timeoutMs?: number;
}

interface RpcResponse {
  id?: number | string | null;
  result?: any;
  error?: {code: number; message: string};
}

/** The JSON-RPC messages of a finished SSE body. */
export function parseSse(body: string): RpcResponse[] {
  const messages: RpcResponse[] = [];
  for (const block of body.split(/\r?\n\r?\n/)) {
    const data = block
      .split(/\r?\n/)
      .filter(line => line.startsWith('data:'))
      .map(line => line.slice(5).replace(/^ /, ''))
      .join('\n');
    if (!data) {
      continue;
    }
    try {
      const parsed = JSON.parse(data);
      (Array.isArray(parsed) ? parsed : [parsed]).forEach(item =>
        messages.push(item),
      );
    } catch {
      // Not JSON (a comment or keep-alive): skip.
    }
  }
  return messages;
}

export class McpClient {
  private sessionId: string | null = null;
  private protocolVersion: string | null = null;
  private initializing: Promise<void> | null = null;
  private nextId = 1;
  serverInfo: {name?: string; version?: string} = {};

  constructor(private readonly options: McpClientOptions) {}

  get url(): string {
    return this.options.url;
  }

  /** Handshake; safe to call again (runs once until `reset`). */
  initialize(signal?: AbortSignal): Promise<void> {
    this.initializing ??= this.handshake(signal).catch(error => {
      this.initializing = null;
      throw error;
    });
    return this.initializing;
  }

  reset(): void {
    this.sessionId = null;
    this.protocolVersion = null;
    this.initializing = null;
  }

  private async handshake(signal?: AbortSignal): Promise<void> {
    const result = await this.send(
      'initialize',
      {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: this.options.clientInfo ?? {
          name: 'AntiChat Mobile',
          version: '0.1.0',
        },
      },
      signal,
    );
    this.protocolVersion =
      typeof result?.protocolVersion === 'string'
        ? result.protocolVersion
        : MCP_PROTOCOL_VERSION;
    this.serverInfo = result?.serverInfo ?? {};
    await this.send('notifications/initialized', undefined, signal, true);
  }

  async listTools(signal?: AbortSignal): Promise<McpToolInfo[]> {
    const tools: McpToolInfo[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 20; page++) {
      const result = await this.request(
        'tools/list',
        cursor ? {cursor} : {},
        signal,
      );
      tools.push(...((result?.tools as McpToolInfo[]) ?? []));
      cursor = result?.nextCursor;
      if (!cursor) {
        break;
      }
    }
    return tools;
  }

  async callTool(
    name: string,
    args: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<McpCallResult> {
    const result = await this.request(
      'tools/call',
      {name, arguments: args},
      signal,
    );
    const parts: string[] = [];
    for (const item of (result?.content as any[]) ?? []) {
      if (item?.type === 'text' && typeof item.text === 'string') {
        parts.push(item.text);
      } else if (item?.type === 'resource' && item.resource?.text) {
        parts.push(String(item.resource.text));
      } else if (item?.type) {
        parts.push(`[${item.type} content not shown]`);
      }
    }
    if (parts.length === 0 && result?.structuredContent !== undefined) {
      parts.push(JSON.stringify(result.structuredContent));
    }
    return {
      text: parts.join('\n\n'),
      isError: result?.isError === true,
      structured: result?.structuredContent,
    };
  }

  /** A request after the handshake; re-initializes once on a stale session. */
  private async request(
    method: string,
    params: unknown,
    signal?: AbortSignal,
  ): Promise<any> {
    await this.initialize(signal);
    try {
      return await this.send(method, params, signal);
    } catch (error) {
      if (error instanceof McpError && error.status === 404 && this.sessionId) {
        this.reset();
        await this.initialize(signal);
        return this.send(method, params, signal);
      }
      throw error;
    }
  }

  private async send(
    method: string,
    params: unknown,
    signal?: AbortSignal,
    notification = false,
    retried = false,
  ): Promise<any> {
    const id = notification ? undefined : this.nextId++;
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
      ...((await this.options.headers?.()) ?? {}),
    };
    if (this.protocolVersion) {
      headers['MCP-Protocol-Version'] = this.protocolVersion;
    }
    if (this.sessionId) {
      headers['Mcp-Session-Id'] = this.sessionId;
    }
    const token = await this.options.auth?.token();
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }

    const controller = new AbortController();
    const onAbort = () => controller.abort();
    signal?.addEventListener('abort', onAbort);
    const timer = setTimeout(onAbort, this.options.timeoutMs ?? 60_000);
    let status = 0;
    let body = '';
    let contentType = '';
    let wwwAuthenticate: string | null = null;
    try {
      const doFetch = this.options.fetch ?? (fetch as unknown as FetchLike);
      const response = await doFetch(this.options.url, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          jsonrpc: '2.0',
          ...(id === undefined ? {} : {id}),
          method,
          ...(params === undefined ? {} : {params}),
        }),
        signal: controller.signal,
      });
      status = response.status;
      contentType = response.headers.get('content-type') ?? '';
      wwwAuthenticate = response.headers.get('www-authenticate');
      const session = response.headers.get('mcp-session-id');
      if (session) {
        this.sessionId = session;
      }
      body = (await response.text()).slice(0, MAX_BODY);
    } catch (error) {
      if (signal?.aborted) {
        throw new McpError('cancelled', 'cancelled');
      }
      throw new McpError(
        'network',
        controller.signal.aborted
          ? 'The server did not answer in time.'
          : `Could not reach the server (${(error as Error)?.message ?? 'network error'}).`,
      );
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
    }

    if (status === 401) {
      if (
        !retried &&
        (await this.options.auth?.onUnauthorized?.(wwwAuthenticate))
      ) {
        return this.send(method, params, signal, notification, true);
      }
      throw new McpError(
        'unauthorized',
        'This server needs a sign-in.',
        401,
        wwwAuthenticate,
      );
    }
    if (status < 200 || status >= 300) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch {}
      throw new McpError(
        'http',
        `The server answered ${status}.`,
        status,
        null,
        parsed,
      );
    }
    if (notification || status === 202) {
      return undefined;
    }
    let messages: RpcResponse[];
    if (contentType.includes('text/event-stream')) {
      messages = parseSse(body);
    } else {
      try {
        const parsed = JSON.parse(body);
        messages = Array.isArray(parsed) ? parsed : [parsed];
      } catch {
        throw new McpError('protocol', 'The server sent an unreadable answer.');
      }
    }
    const answer = messages.find(message => message?.id === id);
    if (!answer) {
      throw new McpError('protocol', 'The server sent no answer.');
    }
    if (answer.error) {
      throw new McpError(
        'rpc',
        answer.error.message || 'The tool call failed.',
      );
    }
    return answer.result;
  }
}
