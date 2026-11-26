import type {FetchLike} from '../client';
import type {SecureStore} from '../oauth';
import type {KeyValueStore} from '../permissions';
import {RelayClient} from '../relay';
import {ConnectorsStore, type ConnectorsDeps} from '../store';

export interface Recorded {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: any;
}

export type Route = (request: Recorded) => {
  status?: number;
  headers?: Record<string, string>;
  json?: unknown;
  sse?: unknown;
  text?: string;
} | null;

/** A fetch that answers from a list of routes and records every request. */
export function fakeFetch(routes: Route[]): FetchLike & {calls: Recorded[]} {
  const calls: Recorded[] = [];
  const doFetch = (async (url: string, init: any = {}) => {
    let body: any = init.body;
    try {
      body = JSON.parse(init.body);
    } catch {}
    const request: Recorded = {
      url,
      method: init.method ?? 'GET',
      headers: init.headers ?? {},
      body,
    };
    calls.push(request);
    for (const route of routes) {
      const answer = route(request);
      if (answer) {
        const headers: Record<string, string> = {
          'content-type': answer.sse ? 'text/event-stream' : 'application/json',
          ...(answer.headers ?? {}),
        };
        const text = answer.sse
          ? `event: message\ndata: ${JSON.stringify(answer.sse)}\n\n`
          : (answer.text ?? JSON.stringify(answer.json ?? {}));
        const status = answer.status ?? 200;
        return {
          status,
          ok: status >= 200 && status < 300,
          headers: {get: (name: string) => headers[name.toLowerCase()] ?? null},
          text: async () => text,
        };
      }
    }
    return {
      status: 404,
      ok: false,
      headers: {get: () => null},
      text: async () => '{}',
    };
  }) as FetchLike & {calls: Recorded[]};
  doFetch.calls = calls;
  return doFetch;
}

export function memoryStorage(): KeyValueStore &
  SecureStore & {data: Map<string, string>} {
  const data = new Map<string, string>();
  return {
    data,
    getItem: async key => data.get(key) ?? null,
    setItem: async (key, value) => {
      data.set(key, value);
    },
    removeItem: async key => {
      data.delete(key);
    },
    get: async key => data.get(key) ?? null,
    set: async (key, value) => {
      data.set(key, value);
    },
    remove: async key => {
      data.delete(key);
    },
  };
}

/** An MCP server route: JSON-RPC answered by `handler`, as SSE. */
export function mcpRoute(
  url: string,
  handler: (method: string, params: any, request: Recorded) => any,
  options: {token?: string; wwwAuthenticate?: string} = {},
): Route {
  return request => {
    if (request.url !== url || request.method !== 'POST') {
      return null;
    }
    if (
      options.token &&
      request.headers.Authorization !== `Bearer ${options.token}`
    ) {
      return {
        status: 401,
        headers: {'www-authenticate': options.wwwAuthenticate ?? 'Bearer'},
        json: {},
      };
    }
    if (request.body.id === undefined) {
      return {status: 202, text: ''};
    }
    const result = handler(request.body.method, request.body.params, request);
    return {
      sse: {jsonrpc: '2.0', id: request.body.id, result},
    };
  };
}

export const RELAY = 'https://relay.test';

export function makeStore(
  routes: Route[],
  overrides: Partial<ConnectorsDeps> = {},
) {
  const doFetch = fakeFetch(routes);
  const storage = memoryStorage();
  const opened: string[] = [];
  const store = new ConnectorsStore({
    relay: new RelayClient({
      baseUrl: RELAY,
      fetch: doFetch,
      installId: async () => '11111111-2222-4333-8444-555555555555',
    }),
    storage,
    secure: storage,
    fetch: doFetch,
    randomBytes: length => new Uint8Array(length).fill(7),
    openUrl: async url => {
      opened.push(url);
    },
    openAuth: async () => 'antichat://oauth/callback',
    isOnline: () => true,
    pollIntervalMs: 1,
    pollTimeoutMs: 500,
    ...overrides,
  });
  return {store, doFetch, storage, opened};
}
