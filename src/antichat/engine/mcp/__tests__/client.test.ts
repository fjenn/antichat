import {McpClient, McpError, parseSse} from '../client';
import {OAuthSession, parseWwwAuthenticate, queryOf} from '../oauth';
import {RelayClient, RelayError} from '../relay';
import {base64url, pkceChallenge, sha256} from '../sha256';
import {RELAY, fakeFetch, mcpRoute, memoryStorage} from './support';

const hex = (bytes: Uint8Array) =>
  [...bytes].map(byte => byte.toString(16).padStart(2, '0')).join('');

describe('sha256 / PKCE', () => {
  it('matches the standard vectors', () => {
    expect(hex(sha256('abc'))).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(hex(sha256(''))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(hex(sha256('a'.repeat(200)))).toBe(
      'c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5',
    );
  });

  it('computes the RFC 7636 example challenge', () => {
    expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')).toBe(
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    expect(base64url(Uint8Array.from([251, 255, 254]))).toBe('-__-');
  });
});

describe('McpClient', () => {
  it('reads a finished SSE body', () => {
    expect(
      parseSse(
        ': ping\n\nevent: message\ndata: {"id":1,"result":{"a":1}}\n\ndata: nope\n\n',
      ),
    ).toEqual([{id: 1, result: {a: 1}}]);
  });

  it('initializes once, lists and calls tools over SSE and JSON', async () => {
    const doFetch = fakeFetch([
      mcpRoute('https://mcp.test/mcp', (method, params) => {
        if (method === 'initialize') {
          return {protocolVersion: '2025-06-18', serverInfo: {name: 'Demo'}};
        }
        if (method === 'tools/list') {
          return params.cursor
            ? {tools: [{name: 'b'}]}
            : {tools: [{name: 'a'}], nextCursor: 'next'};
        }
        return {content: [{type: 'text', text: `ran ${params.name}`}]};
      }),
    ]);
    const client = new McpClient({
      url: 'https://mcp.test/mcp',
      fetch: doFetch,
      headers: () => ({'X-Extra': '1'}),
    });
    expect((await client.listTools()).map(tool => tool.name)).toEqual([
      'a',
      'b',
    ]);
    expect(await client.callTool('a', {x: 1})).toEqual({
      text: 'ran a',
      isError: false,
      structured: undefined,
    });
    const methods = doFetch.calls.map(call => call.body.method);
    expect(methods).toEqual([
      'initialize',
      'notifications/initialized',
      'tools/list',
      'tools/list',
      'tools/call',
    ]);
    expect(doFetch.calls[2].headers['MCP-Protocol-Version']).toBe('2025-06-18');
    expect(doFetch.calls[2].headers['X-Extra']).toBe('1');
    expect(doFetch.calls[2].headers.Accept).toContain('text/event-stream');
  });

  it('re-initializes once when the session id is stale', async () => {
    let valid = 's1';
    const doFetch = fakeFetch([
      request => {
        const {id, method} = request.body;
        if (method === 'initialize') {
          return {
            headers: {'mcp-session-id': valid},
            json: {jsonrpc: '2.0', id, result: {}},
          };
        }
        if (id === undefined) {
          return {status: 202, text: ''};
        }
        if (request.headers['Mcp-Session-Id'] !== valid) {
          return {status: 404, json: {code: 'relay.notFound'}};
        }
        return {json: {jsonrpc: '2.0', id, result: {tools: []}}};
      },
    ]);
    const client = new McpClient({url: 'https://mcp.test/mcp', fetch: doFetch});
    await client.listTools();
    valid = 's2';
    await expect(client.listTools()).resolves.toEqual([]);
    expect(
      doFetch.calls.filter(call => call.body.method === 'initialize'),
    ).toHaveLength(2);
  });

  it('reports HTTP and JSON-RPC errors', async () => {
    const client = new McpClient({
      url: 'https://mcp.test/mcp',
      fetch: fakeFetch([
        request =>
          request.body.method === 'tools/call'
            ? {
                json: {
                  jsonrpc: '2.0',
                  id: request.body.id,
                  error: {code: -32602, message: 'bad'},
                },
              }
            : request.body.id === undefined
              ? {status: 202, text: ''}
              : {json: {jsonrpc: '2.0', id: request.body.id, result: {}}},
      ]),
    });
    await expect(client.callTool('x', {})).rejects.toMatchObject({
      code: 'rpc',
      message: 'bad',
    });
    const down = new McpClient({
      url: 'https://mcp.test/mcp',
      fetch: fakeFetch([() => ({status: 500, json: {}})]),
    });
    await expect(down.initialize()).rejects.toBeInstanceOf(McpError);
  });
});

describe('OAuth with PKCE', () => {
  const SERVER = 'https://mcp.test/mcp';

  function setup(options: {cimd?: boolean} = {}) {
    let issued = 0;
    const doFetch = fakeFetch([
      request =>
        request.url ===
        'https://mcp.test/.well-known/oauth-protected-resource/mcp'
          ? {
              json: {
                resource: SERVER,
                authorization_servers: ['https://auth.test'],
              },
            }
          : null,
      request =>
        request.url ===
        'https://auth.test/.well-known/oauth-authorization-server'
          ? {
              json: {
                authorization_endpoint: 'https://auth.test/authorize',
                token_endpoint: 'https://auth.test/token',
                registration_endpoint: 'https://auth.test/register',
                client_id_metadata_document_supported: !!options.cimd,
              },
            }
          : null,
      request =>
        request.url === 'https://auth.test/register'
          ? {status: 201, json: {client_id: 'client-1'}}
          : null,
      request => {
        if (request.url !== 'https://auth.test/token') {
          return null;
        }
        issued += 1;
        return {
          json: {
            access_token: `token-${issued}`,
            refresh_token: 'refresh-1',
            expires_in: 3600,
          },
        };
      },
      mcpRoute(
        SERVER,
        method =>
          method === 'tools/list' ? {tools: [{name: 'list_pages'}]} : {},
        {
          token: 'token-1',
          wwwAuthenticate:
            'Bearer resource_metadata="https://mcp.test/.well-known/oauth-protected-resource/mcp"',
        },
      ),
    ]);
    const storage = memoryStorage();
    const authUrls: string[] = [];
    const session = new OAuthSession(
      {
        fetch: doFetch,
        store: storage,
        randomBytes: length => new Uint8Array(length).fill(9),
        openAuth: async (url, redirect) => {
          authUrls.push(url);
          return `${redirect}?code=the-code&state=${queryOf(url).state}`;
        },
        now: () => 1_000_000,
      },
      {
        serverUrl: SERVER,
        storageKey: 'k',
        clientMetadataUrl: options.cimd
          ? 'https://antichat.test/client.json'
          : null,
      },
    );
    return {doFetch, storage, authUrls, session};
  }

  it('parses a challenge header', () => {
    expect(
      parseWwwAuthenticate(
        'Bearer realm="x", resource_metadata="https://a/b", scope="read write"',
      ),
    ).toEqual({
      realm: 'x',
      resource_metadata: 'https://a/b',
      scope: 'read write',
    });
  });

  it('discovers, registers, signs in and retries the request', async () => {
    const {doFetch, storage, authUrls, session} = setup();
    session.interactive = true;
    const client = new McpClient({url: SERVER, fetch: doFetch, auth: session});
    expect((await client.listTools())[0].name).toBe('list_pages');

    const asked = queryOf(authUrls[0]);
    expect(asked.client_id).toBe('client-1');
    expect(asked.code_challenge_method).toBe('S256');
    expect(asked.redirect_uri).toBe('antichat://oauth/callback');
    expect(asked.resource).toBe(SERVER);
    const verifier = base64url(new Uint8Array(32).fill(9));
    expect(asked.code_challenge).toBe(pkceChallenge(verifier));

    const exchange = doFetch.calls.find(
      call => call.url === 'https://auth.test/token',
    )!;
    expect(String(exchange.body)).toContain(`code_verifier=${verifier}`);
    expect(String(exchange.body)).toContain('code=the-code');
    expect(JSON.parse(storage.data.get('k')!)).toMatchObject({
      clientId: 'client-1',
      accessToken: 'token-1',
      refreshToken: 'refresh-1',
      expiresAt: 1_000_000 + 3_600_000,
    });
  });

  it('uses the client metadata document when the server supports it', async () => {
    const {doFetch, authUrls, session} = setup({cimd: true});
    await session.signIn(null);
    expect(queryOf(authUrls[0]).client_id).toBe(
      'https://antichat.test/client.json',
    );
    expect(
      doFetch.calls.some(call => call.url === 'https://auth.test/register'),
    ).toBe(false);
  });

  it('does not open a browser unless the user asked to connect', async () => {
    const {doFetch, authUrls, session} = setup();
    const client = new McpClient({url: SERVER, fetch: doFetch, auth: session});
    await expect(client.listTools()).rejects.toMatchObject({
      code: 'unauthorized',
    });
    expect(authUrls).toHaveLength(0);
  });

  it('rejects an answer with the wrong state', async () => {
    const {session} = setup();
    (session as any).platform.openAuth = async (_: string, redirect: string) =>
      `${redirect}?code=x&state=other`;
    await expect(session.signIn(null)).rejects.toMatchObject({code: 'state'});
  });

  it('refreshes an expired token', async () => {
    const {storage, session, doFetch} = setup();
    await storage.set(
      'k',
      JSON.stringify({
        clientId: 'client-1',
        tokenEndpoint: 'https://auth.test/token',
        accessToken: 'old',
        refreshToken: 'refresh-1',
        expiresAt: 1,
      }),
    );
    expect(await session.token()).toBe('token-1');
    expect(String(doFetch.calls[0].body)).toContain('grant_type=refresh_token');
  });
});

describe('RelayClient', () => {
  it('sends the install headers and maps answers', async () => {
    const doFetch = fakeFetch([
      request =>
        request.url === `${RELAY}/v1/toolkits`
          ? request.headers['If-None-Match'] === '"e1"'
            ? {status: 304, text: ''}
            : {
                headers: {etag: '"e1"'},
                json: {
                  toolkits: [
                    {slug: 'gmail', name: 'Gmail', auth: 'oauth', logo: 'x'},
                  ],
                },
              }
          : null,
      request =>
        request.url === `${RELAY}/v1/connections`
          ? {
              json: {
                toolkits: ['gmail'],
                connections: [{id: 'c1', toolkit: 'GMAIL', status: 'ACTIVE'}],
              },
            }
          : null,
      request =>
        request.url === `${RELAY}/v1/connections/link`
          ? request.body.toolkit === 'gmail'
            ? {json: {url: 'https://connect.test/link/1', id: 'l1'}}
            : {
                status: 429,
                headers: {'retry-after': '60'},
                json: {code: 'relay.rateLimited'},
              }
          : null,
    ]);
    const relay = new RelayClient({
      baseUrl: RELAY,
      fetch: doFetch,
      installId: async () => 'install-1',
      version: '0.2.0',
      platform: 'ios',
    });
    const first = await relay.toolkits();
    expect(first?.toolkits[0]).toMatchObject({slug: 'gmail', categories: []});
    expect(await relay.toolkits(first?.etag)).toBeNull();
    expect((await relay.connections()).connections).toEqual([
      {id: 'c1', toolkit: 'gmail', status: 'active'},
    ]);
    expect(await relay.link('gmail')).toEqual({
      url: 'https://connect.test/link/1',
      id: 'l1',
    });
    expect(doFetch.calls[3].body).toEqual({
      toolkit: 'gmail',
      callback_url: 'antichat://connectors/callback',
    });
    expect(doFetch.calls[0].headers).toMatchObject({
      'X-AntiChat-Install': 'install-1',
      'X-AntiChat-Version': '0.2.0',
      'X-AntiChat-Platform': 'ios',
      'User-Agent': 'AntiChat/0.2.0',
    });
    const limited = await relay.link('slack').catch(error => error);
    expect(limited).toBeInstanceOf(RelayError);
    expect(limited).toMatchObject({
      code: 'relay.rateLimited',
      retryAfterSeconds: 60,
    });
  });
});

describe('relay out of capacity', () => {
  const answer = (status: number, body: string) => async () => ({
    status,
    ok: false,
    headers: {get: () => null},
    text: async () => body,
  });

  it('maps the host quota page (1027) and bare 429/503 to relay.overCapacity', async () => {
    const {describeError} = require('../store');
    for (const [status, body] of [
      [
        429,
        '<html><title>Worker exceeded free tier daily request limit</title>Error code: 1027</html>',
      ],
      [503, '<html>Error 1102 Worker exceeded resource limits</html>'],
      [503, ''],
    ] as const) {
      const relay = new RelayClient({
        baseUrl: 'https://relay.test',
        fetch: answer(status, body) as any,
        installId: async () => 'install-1',
      });
      const error = await relay.connections().catch(e => e);
      expect(error).toBeInstanceOf(RelayError);
      expect(error.code).toBe('relay.overCapacity');
      expect(describeError(error)).toBe(
        'Connections are busy, try again later.',
      );
    }
  });

  it('keeps other failures as they were', async () => {
    const relay = new RelayClient({
      baseUrl: 'https://relay.test',
      fetch: answer(500, '<html>oops</html>') as any,
      installId: async () => 'install-1',
    });
    expect((await relay.connections().catch(e => e)).code).toBe('unknown');
  });

  it('describes an MCP pass-through refusal as busy', () => {
    const {describeError} = require('../store');
    expect(
      describeError(
        new McpError('http', 'x', 503, null, {code: 'relay.overCapacity'}),
      ),
    ).toBe('Connections are busy, try again later.');
    expect(
      describeError(new McpError('http', 'The server answered 429.', 429)),
    ).toBe('Connections are busy, try again later.');
  });
});
