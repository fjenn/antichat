import {createSearchToolsTool, ToolCatalog} from '../../tools/catalog';
import {directConnectRequest, resolveApp} from '../apps';
import {
  COMPOSIO_EXECUTE,
  COMPOSIO_SEARCH,
  HintCache,
  UNAVAILABLE_RESULT,
  condenseSearchResult,
  displaySlug,
  executeArguments,
  innerCalls,
  isRemoteExecution,
  isWriteSlug,
} from '../composio';
import {DENIED_RESULT, Permissions} from '../permissions';
import {
  normalizeServerUrl,
  serverNameFromUrl,
  setLocalHttpAllowed,
} from '../store';
import {
  CONNECT_APP,
  connectorToolLabel,
  registerConnectorTools,
} from '../tools';
import {classifyVerb} from '../verbs';
import {RELAY, makeStore, mcpRoute, memoryStorage, type Route} from './support';

const SEARCH_RESULT = {
  results: [{primaryToolSlugs: ['GMAIL_SEND_EMAIL'], relatedToolSlugs: []}],
  toolSchemas: {
    GMAIL_SEND_EMAIL: {
      toolSlug: 'GMAIL_SEND_EMAIL',
      description: 'Send an email message.',
      tags: ['createHint'],
      inputSchema: {
        type: 'object',
        properties: {
          body: {type: 'string'},
          recipient_email: {type: 'string'},
        },
        required: ['recipient_email'],
      },
    },
    COMPOSIO_REMOTE_WORKBENCH: {description: 'x'},
  },
  toolkitConnectionStatuses: [{toolkit: 'gmail', hasActiveConnection: true}],
};

const ctx = {now: new Date(), turnId: 'chat-1'};

describe('apps and verbs', () => {
  it('classifies names by verb', () => {
    expect(classifyVerb('GMAIL_SEND_EMAIL')).toBe('write');
    expect(classifyVerb('listIssues')).toBe('read');
    expect(classifyVerb('ask_wiki_question')).toBe('read');
    expect(classifyVerb('search_and_delete')).toBe('write');
    expect(classifyVerb('notion.frobnicate')).toBe('unknown');
    expect(isWriteSlug('NOTION_FROBNICATE')).toBe(true);
  });

  it('finds the app of a plain connect request', () => {
    expect(directConnectRequest('Let me log into GitHub')?.slug).toBe('github');
    expect(
      directConnectRequest('can you connect my gmail account please')?.slug,
    ).toBe('gmail');
    expect(
      directConnectRequest('connect airtable', [
        {slug: 'airtable', name: 'Airtable'},
      ])?.slug,
    ).toBe('airtable');
    expect(
      directConnectRequest('connect the dots for me in this essay'),
    ).toBeNull();
    expect(directConnectRequest('summarise my inbox')).toBeNull();
    expect(resolveApp('email')?.slug).toBe('gmail');
    expect(resolveApp('Google Calendar')?.slug).toBe('googlecalendar');
  });
});

describe('Composio meta-tool handling', () => {
  it('cuts an execute call to its inner calls, results inline', () => {
    const calls = innerCalls({
      tools: [{tool_slug: 'gmail_send_email', arguments: {to: 'a'}}],
      thought: 'noise',
      sync_response_to_workbench: true,
    })!;
    expect(executeArguments(calls)).toEqual({
      tools: [{tool_slug: 'GMAIL_SEND_EMAIL', arguments: {to: 'a'}}],
      sync_response_to_workbench: false,
    });
    expect(innerCalls({tools: [{arguments: {}}]})).toBeNull();
    expect(isRemoteExecution('COMPOSIO_REMOTE_BASH_TOOL')).toBe(true);
    expect(isRemoteExecution('GMAIL_FETCH_EMAILS')).toBe(false);
    expect(displaySlug('GOOGLECALENDAR_CREATE_EVENT')).toMatchObject({
      app: 'Google Calendar',
      action: 'Create event',
    });
  });

  it('learns write hints and condenses a search result', () => {
    const hints = new HintCache();
    hints.learn({
      toolSchemas: {X: {toolSlug: 'FOO_FETCH_ROWS', tags: ['destructiveHint']}},
    });
    expect(isWriteSlug('FOO_FETCH_ROWS', hints)).toBe(true);
    expect(isWriteSlug('FOO_FETCH_ROWS')).toBe(false);

    const condensed = condenseSearchResult(JSON.stringify(SEARCH_RESULT));
    expect(condensed.text).toContain(
      '- GMAIL_SEND_EMAIL: Send an email message. Arguments (* required): recipient_email*: string, body: string.',
    );
    expect(condensed.text).not.toContain('WORKBENCH');
    expect(condensed.text).toContain(COMPOSIO_EXECUTE);
    const missing = condenseSearchResult(
      JSON.stringify({
        ...SEARCH_RESULT,
        toolkitConnectionStatuses: [
          {toolkit: 'gmail', hasActiveConnection: false},
        ],
      }),
    );
    expect(missing.missing).toEqual(['gmail']);
    expect(missing.text).toContain('Not connected: Gmail. Call connect_app');
    expect(condenseSearchResult('plain text').text).toBe('plain text');
  });

  // The shape Composio's tool router answers with today (snake_case): a
  // Gmail search that also returns a Drive action of an unconnected app.
  it('reads the snake_case search result and keeps a connected app runnable', () => {
    const live = {
      successful: true,
      data: {
        results: [
          {
            use_case: 'get my gmail profile',
            primary_tool_slugs: ['GMAIL_GET_PROFILE'],
            related_tool_slugs: [
              'GMAIL_FETCH_EMAILS',
              'GOOGLEDRIVE_ADD_FILE_SHARING_PREFERENCE',
            ],
            toolkits: ['gmail', 'googledrive'],
          },
        ],
        tool_schemas: {
          GMAIL_GET_PROFILE: {
            toolkit: 'GMAIL',
            tool_slug: 'GMAIL_GET_PROFILE',
            description: 'Get the profile of the account.',
            input_schema: {
              type: 'object',
              properties: {user_id: {type: 'string'}},
            },
          },
          GMAIL_FETCH_EMAILS: {
            toolkit: 'GMAIL',
            tool_slug: 'GMAIL_FETCH_EMAILS',
            description: 'Fetch emails.',
          },
          GOOGLEDRIVE_ADD_FILE_SHARING_PREFERENCE: {
            toolkit: 'GOOGLEDRIVE',
            tool_slug: 'GOOGLEDRIVE_ADD_FILE_SHARING_PREFERENCE',
            description: 'Share a file.',
          },
        },
        toolkit_connection_statuses: [
          {toolkit: 'gmail', has_active_connection: true},
          {toolkit: 'googledrive', has_active_connection: false},
        ],
      },
    };
    const condensed = condenseSearchResult(JSON.stringify(live));
    expect(condensed.missing).toEqual([]);
    expect(condensed.text).toContain(
      '- GMAIL_GET_PROFILE: Get the profile of the account. Arguments (* required): user_id: string.',
    );
    expect(condensed.text).toContain('GMAIL_FETCH_EMAILS');
    expect(condensed.text).not.toContain('GOOGLEDRIVE');
    expect(condensed.text).not.toContain('No action found');
    expect(condensed.text).toContain(COMPOSIO_EXECUTE);

    const driveOnly = condenseSearchResult(
      JSON.stringify({
        data: {
          ...live.data,
          results: [
            {primary_tool_slugs: ['GOOGLEDRIVE_ADD_FILE_SHARING_PREFERENCE']},
          ],
          tool_schemas: {},
        },
      }),
    );
    expect(driveOnly.missing).toEqual(['googledrive']);
    expect(driveOnly.text).toContain('Call connect_app');
  });
});

describe('Permissions', () => {
  it('runs reads, asks for writes and remembers "always"', async () => {
    const storage = memoryStorage();
    const permissions = new Permissions(storage);
    const action = {
      key: 'composio:X_SEND',
      app: 'X',
      action: 'Send',
      arguments: {},
    };
    expect(await permissions.allow({...action, write: false})).toBe(true);
    expect(permissions.requests()).toHaveLength(0);

    const denied = permissions.allow({...action, write: true});
    await Promise.resolve();
    await Promise.resolve();
    expect(permissions.requests()).toHaveLength(1);
    permissions.answer(permissions.requests()[0].id, 'deny');
    expect(await denied).toBe(false);

    const always = permissions.allow({...action, write: true});
    await Promise.resolve();
    await Promise.resolve();
    permissions.answer(permissions.requests()[0].id, 'always');
    expect(await always).toBe(true);
    expect(await permissions.allow({...action, write: true})).toBe(true);
    expect(await new Permissions(storage).allow({...action, write: true})).toBe(
      true,
    );

    await permissions.setPolicy(action.key, 'block');
    expect(await permissions.allow({...action, write: false})).toBe(false);
  });

  it('denies when the turn is cancelled', async () => {
    const permissions = new Permissions();
    const controller = new AbortController();
    const waiting = permissions.allow(
      {key: 'k', app: 'A', action: 'Send', arguments: {}, write: true},
      controller.signal,
    );
    await Promise.resolve();
    await Promise.resolve();
    controller.abort();
    expect(await waiting).toBe(false);
    expect(permissions.requests()).toHaveLength(0);
  });
});

describe('ConnectorsStore', () => {
  const relayRoutes = (state: {connected: boolean; calls: any[]}): Route[] => [
    request =>
      request.url === `${RELAY}/v1/toolkits`
        ? {
            headers: {etag: '"1"'},
            json: {
              toolkits: [
                {
                  slug: 'zoom',
                  name: 'Zoom',
                  auth: 'oauth',
                  categories: ['video'],
                },
                {
                  slug: 'gmail',
                  name: 'Gmail',
                  auth: 'oauth',
                  categories: ['email'],
                },
                {slug: 'util', name: 'Utility', auth: 'none', categories: []},
              ],
            },
          }
        : null,
    request =>
      request.url === `${RELAY}/v1/connections` && request.method === 'GET'
        ? {
            json: {
              connections: state.connected
                ? [{id: 'c1', toolkit: 'gmail', status: 'ACTIVE'}]
                : [],
            },
          }
        : null,
    request =>
      request.url === `${RELAY}/v1/session` ? {json: {ok: true}} : null,
    request => {
      if (request.url !== `${RELAY}/v1/connections/link`) {
        return null;
      }
      state.connected = true;
      return {json: {url: 'https://connect.test/link/1', id: 'l1'}};
    },
    request => {
      if (request.url !== `${RELAY}/v1/connections/c1`) {
        return null;
      }
      state.connected = false;
      return {json: {ok: true}};
    },
    mcpRoute(`${RELAY}/v1/mcp`, (method, params) => {
      if (method !== 'tools/call') {
        return {};
      }
      state.calls.push(params);
      return {
        content: [
          {
            type: 'text',
            text:
              params.name === COMPOSIO_SEARCH
                ? JSON.stringify(SEARCH_RESULT)
                : JSON.stringify({
                    data: {
                      results: [
                        {
                          tool_slug: 'GMAIL_SEND_EMAIL',
                          response: {data: {id: 'm1'}, logId: 'x'},
                        },
                      ],
                    },
                  }),
          },
        ],
      };
    }),
  ];

  it('lists the directory, featured first, and searches it', async () => {
    const {store, storage} = makeStore(
      relayRoutes({connected: false, calls: []}),
    );
    await store.refresh();
    expect(store.toolkitsState).toBe('ready');
    expect(store.search('').map(item => item.slug)).toEqual(['gmail', 'zoom']);
    expect(store.search('zo').map(item => item.slug)).toEqual(['zoom']);
    expect(store.search('email').map(item => item.slug)).toEqual(['gmail']);
    expect(storage.data.has('antichat.connectors.toolkits.v1')).toBe(true);
  });

  it('connects through the hosted page, registers tools, disconnects', async () => {
    const state = {connected: false, calls: [] as any[]};
    const {store, opened, doFetch} = makeStore(relayRoutes(state));
    const catalog = new ToolCatalog();
    const stop = registerConnectorTools(store, catalog);
    await store.refresh();
    expect(catalog.all().map(tool => tool.name)).toEqual([CONNECT_APP]);

    expect(await store.connect('gmail')).toBe(true);
    expect(opened).toEqual(['https://connect.test/link/1']);
    const link = doFetch.calls.find(call => call.url.endsWith('/link'))!;
    expect(link.body.callback_url).toBe(
      'antichat://connectors/callback?toolkit=gmail',
    );
    expect(store.connectedSlugs).toEqual(['gmail']);
    expect(store.connecting).toBeNull();
    expect(catalog.has(COMPOSIO_SEARCH) && catalog.has(COMPOSIO_EXECUTE)).toBe(
      true,
    );
    expect(
      catalog
        .all()
        .every(tool => tool.tier === 'deferred' && tool.kind === 'online'),
    ).toBe(true);

    // The model reaches them through search_tools only.
    const finder = createSearchToolsTool({catalog});
    const found = await finder.execute({query: 'gmail email'}, ctx);
    expect(found.text).toContain(COMPOSIO_SEARCH);

    const search = await catalog
      .get(COMPOSIO_SEARCH)!
      .execute({query: 'send an email with gmail'}, ctx);
    expect(state.calls[0]).toEqual({
      name: COMPOSIO_SEARCH,
      arguments: {queries: [{use_case: 'send an email with gmail'}]},
    });
    expect(search.text).toContain('GMAIL_SEND_EMAIL');

    // A write waits for the user; the hint came from the search result.
    const execute = catalog.get(COMPOSIO_EXECUTE)!;
    const args = {
      tools: [
        {tool_slug: 'GMAIL_SEND_EMAIL', arguments: {recipient_email: 'a@b.c'}},
      ],
    };
    const run = execute.execute(args, ctx);
    await new Promise(resolve => setTimeout(resolve, 5));
    expect(store.approvals).toHaveLength(1);
    expect(store.approvals[0]).toMatchObject({
      app: 'Gmail',
      action: 'Send email',
    });
    expect(state.calls).toHaveLength(1);
    store.answerApproval(store.approvals[0].id, 'once');
    const result = await run;
    expect(result.untrusted).toBe(true);
    expect(JSON.parse(result.text)).toEqual([
      {action: 'GMAIL_SEND_EMAIL', result: {id: 'm1'}},
    ]);
    expect(state.calls[1].arguments.sync_response_to_workbench).toBe(false);

    const refused = execute.execute(args, ctx);
    await new Promise(resolve => setTimeout(resolve, 5));
    store.answerApproval(store.approvals[0].id, 'deny');
    expect((await refused).text).toBe(DENIED_RESULT);
    expect(state.calls).toHaveLength(2);

    expect(
      (
        await execute.execute(
          {tools: [{tool_slug: 'COMPOSIO_REMOTE_BASH_TOOL', arguments: {}}]},
          ctx,
        )
      ).text,
    ).toBe(UNAVAILABLE_RESULT);

    expect(connectorToolLabel(COMPOSIO_EXECUTE, args, store)).toBe(
      'Using Gmail',
    );
    expect(
      connectorToolLabel(
        COMPOSIO_EXECUTE,
        {tools: [{tool_slug: 'GMAIL_FETCH_EMAILS', arguments: {}}]},
        store,
      ),
    ).toBe('Checking Gmail');

    await store.disconnect('gmail');
    expect(store.connectedSlugs).toEqual([]);
    expect(catalog.has(COMPOSIO_SEARCH)).toBe(false);
    stop();
    expect(catalog.all()).toHaveLength(0);
  });

  it('connect_app shows the card unless the app is connected', async () => {
    const state = {connected: false, calls: []};
    const {store} = makeStore(relayRoutes(state));
    const catalog = new ToolCatalog();
    registerConnectorTools(store, catalog);
    await store.refresh();
    const tool = catalog.get(CONNECT_APP)!;
    const shown = await tool.execute({app: 'email'}, ctx);
    expect(store.card).toMatchObject({slug: 'gmail', name: 'Gmail'});
    expect(shown.card).toMatchObject({type: 'connect_app', slug: 'gmail'});
    expect(shown.text).toContain('Connect button for Gmail');

    await tool.execute({app: 'Frobnicator'}, ctx);
    expect(store.card).toMatchObject({slug: null, name: 'Frobnicator'});

    state.connected = true;
    await store.refreshConnections();
    expect((await tool.execute({app: 'Gmail'}, ctx)).text).toContain(
      'already connected',
    );
  });

  it('opens the sign-in in the in-app sheet; closing it stops the wait', async () => {
    const state = {connected: false, calls: [] as any[]};
    const sheets: string[][] = [];
    const {store, opened} = makeStore(relayRoutes(state), {
      pollTimeoutMs: 60_000,
      openSheet: async (url, prefix) => {
        sheets.push([url, prefix]);
        state.connected = false; // the person closed the sheet unfinished
        return 'cancelled';
      },
    });
    await store.refresh();
    expect(await store.connect('gmail')).toBe(false);
    expect(sheets).toEqual([
      ['https://connect.test/link/1', 'antichat://connectors/callback'],
    ]);
    expect(opened).toEqual([]);
    expect(store.connecting).toBeNull();
    expect(store.error).toBeNull();
  });

  it('finishes the connect when the sheet comes back', async () => {
    const state = {connected: false, calls: [] as any[]};
    const {store} = makeStore(relayRoutes(state), {
      pollTimeoutMs: 60_000,
      openSheet: async () => {
        state.connected = true;
        return 'returned';
      },
    });
    await store.refresh();
    expect(await store.connect('gmail')).toBe(true);
    expect(store.connectedSlugs).toEqual(['gmail']);
  });

  it('does nothing while offline', async () => {
    const {store, doFetch} = makeStore([], {isOnline: () => false});
    await store.refresh();
    expect(await store.connect('gmail')).toBe(false);
    expect(await store.addServer('https://mcp.test/mcp')).toBeNull();
    expect(doFetch.calls).toHaveLength(0);
  });

  it('adds a custom server by URL and registers its tools', async () => {
    const {store, storage} = makeStore([
      mcpRoute('https://mcp.demo.test/mcp', (method, params) => {
        if (method === 'initialize') {
          return {serverInfo: {name: 'Demo Notes'}};
        }
        if (method === 'tools/list') {
          return {
            tools: [
              {
                name: 'search_notes',
                description: 'Search the notes.',
                inputSchema: {
                  type: 'object',
                  properties: {q: {type: 'string'}},
                },
                annotations: {readOnlyHint: true},
              },
              {
                name: 'delete_note',
                inputSchema: {type: 'object', properties: {}},
              },
            ],
          };
        }
        return {content: [{type: 'text', text: `ok ${params.name}`}]};
      }),
    ]);
    const catalog = new ToolCatalog();
    registerConnectorTools(store, catalog);

    expect(await store.addServer('not a url')).toBeNull();
    expect(store.error).toContain('web address');
    expect(await store.addServer('http://example.com/mcp')).toBeNull();

    const server = await store.addServer('mcp.demo.test/mcp');
    expect(server).toMatchObject({
      id: 'demo',
      name: 'Demo Notes',
      state: 'connected',
    });
    expect(catalog.has('demo_search_notes')).toBe(true);
    expect(
      (await catalog.get('demo_search_notes')!.execute({q: 'x'}, ctx)).text,
    ).toBe('ok search_notes');
    expect(store.approvals).toHaveLength(0);

    const removal = catalog.get('demo_delete_note')!.execute({}, ctx);
    await new Promise(resolve => setTimeout(resolve, 5));
    expect(store.approvals[0]).toMatchObject({
      app: 'Demo Notes',
      action: 'Delete note',
    });
    store.answerApproval(store.approvals[0].id, 'deny');
    expect((await removal).text).toBe(DENIED_RESULT);

    expect(
      JSON.parse(storage.data.get('antichat.connectors.servers.v1')!),
    ).toHaveLength(1);
    await store.removeServer('demo');
    expect(catalog.has('demo_search_notes')).toBe(false);
  });

  it('normalizes server addresses', () => {
    expect(normalizeServerUrl(' mcp.notion.com/mcp ')).toBe(
      'https://mcp.notion.com/mcp',
    );
    expect(normalizeServerUrl('http://localhost:8123/mcp')).toBe(
      'http://localhost:8123/mcp',
    );
    expect(normalizeServerUrl('http://evil.example/mcp')).toBeNull();
    setLocalHttpAllowed(false); // release builds
    expect(normalizeServerUrl('http://localhost:8123/mcp')).toBeNull();
    expect(normalizeServerUrl('https://192.168.1.2/mcp')).toBe(
      'https://192.168.1.2/mcp',
    );
    setLocalHttpAllowed(true);
    expect(normalizeServerUrl('ftp://x.y')).toBeNull();
    expect(serverNameFromUrl('https://mcp.notion.com/mcp')).toBe('notion');
    expect(serverNameFromUrl('http://127.0.0.1:9000')).toBe('127.0.0.1');
  });
});
