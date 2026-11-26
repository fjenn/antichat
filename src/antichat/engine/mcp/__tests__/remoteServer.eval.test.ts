/**
 * End to end: a real public MCP server added by URL, its tools in the tool
 * catalogue, and a real local model that calls one and answers from it.
 *
 * Skipped unless ANTICHAT_MCP_EVAL is set, e.g.
 *   llama-server -m models/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf --jinja \
 *     -c 16384 --port 18801 &
 *   ANTICHAT_MCP_EVAL=gemma4:18801 \
 *     yarn jest remoteServer.eval --coverage=false
 * Optional: ANTICHAT_MCP_EVAL_URL (default DeepWiki, no sign-in).
 *
 * The Composio part runs with ANTICHAT_RELAY_EVAL=<relay base URL> (the Mac
 * relay, tools/antichat/relay-local.sh): directory, the connect flow up to
 * the provider's sign-in page (nobody signs in), and one no-account action.
 */
import type {ModelFamily} from '../../prompt/modelFamily';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import {ToolCatalog} from '../../tools/catalog';
import {LOOP_POLICY} from '../../tools/loopGuard';
import {runToolTurn, type TurnOptions} from '../../tools/runner';
import {
  createToolSelectionProvider,
  type ToolsMeta,
} from '../../tools/selection';
import {toolCapsFor} from '../../tools/toolCaps';
import type {AntichatTool} from '../../tools/types';
import {
  MODEL_NAMES,
  SAMPLING,
  createEvalEngine,
} from '../../tools/__tests__/support/server';
import type {FetchLike} from '../client';
import {registerConnectorTools} from '../tools';
import {RelayClient} from '../relay';
import {makeStore} from './support';

const [family, port] = (process.env.ANTICHAT_MCP_EVAL ?? '').split(':') as [
  ModelFamily,
  string,
];
const SERVER =
  process.env.ANTICHAT_MCP_EVAL_URL ?? 'https://mcp.deepwiki.com/mcp';
const suite = port ? describe : describe.skip;

const realFetch: FetchLike = async (url, init = {}) => {
  const response = await fetch(url, init as RequestInit);
  return {
    status: response.status,
    ok: response.ok,
    headers: {get: name => response.headers.get(name)},
    text: () => response.text(),
  };
};

suite('custom MCP server with a real model', () => {
  afterAll(() => clearRequestProviders());

  it('adds the server, lists its tools, and the model answers with one', async () => {
    const {store} = makeStore([], {fetch: realFetch});
    const server = await store.addServer(SERVER);
    expect(store.error).toBeNull();
    expect(server?.state).toBe('connected');
    const names = server!.tools.map(tool => tool.name);
    console.log(`[mcp-eval] ${server!.name}: ${names.join(', ')}`);
    expect(names).toContain('ask_wiki_question');

    const catalog = new ToolCatalog();
    const stop = registerConnectorTools(store, catalog);
    const calls: {name: string; args: unknown; result: string}[] = [];
    // Record what the model really ran, through the store's real client.
    for (const tool of catalog.all()) {
      const execute = tool.execute.bind(tool);
      catalog.register({
        ...tool,
        async execute(args, context) {
          process.stderr.write(
            `[mcp-eval] run ${tool.name} ${JSON.stringify(args)}\n`,
          );
          const output = await execute(args, context);
          process.stderr.write(
            `[mcp-eval] done ${tool.name} ${output.text.length}\n`,
          );
          calls.push({name: tool.name, args, result: output.text});
          return output;
        },
      } as AntichatTool);
    }
    clearRequestProviders();
    registerRequestProvider(
      createToolSelectionProvider({
        catalog,
        online: () => true,
        directSearch: false,
      }),
    );

    const modelName = MODEL_NAMES[family] ?? family;
    const user =
      'Use DeepWiki to look up the GitHub repo modelcontextprotocol/typescript-sdk: which transports does it support?';
    const prepared = await prepareRequest({
      messages: [
        {role: 'system', content: 'You are AntiChat, a helpful assistant.'},
        {role: 'user', content: user},
      ],
      session: {id: 'mcp-eval'},
      tools: [],
      params: {},
      runtime: {nCtx: 16384, family, modelName, deviceClass: 'C'},
    });
    const meta = prepared.meta.tools as ToolsMeta;
    console.log(`[mcp-eval] offered: ${meta.selected.join(', ')}`);
    const caps = toolCapsFor(modelName, family, 16384);
    const result = await runToolTurn({
      engine: createEvalEngine(Number(port), {
        ...SAMPLING[family],
        seed: 1,
        n_predict: 1024,
      }),
      messages: prepared.messages,
      tools: meta.selected
        .map(name => catalog.get(name))
        .filter((tool): tool is AntichatTool => !!tool),
      params: {enable_thinking: false} as TurnOptions['params'],
      policy: {
        ...LOOP_POLICY.C,
        maxSteps: caps.maxSteps,
        maxCallsPerStep: caps.parallelCalls,
      },
      context: {now: new Date(), nCtx: 16384, userText: user},
      turnId: meta.turnId,
      resultChars: caps.resultChars,
      searchVerdict: meta.verdict,
      directSearch: false,
    });
    stop();
    console.log(
      `[mcp-eval] calls: ${JSON.stringify(
        calls.map(call => ({
          name: call.name,
          args: call.args,
          result: call.result.slice(0, 200),
        })),
      )}\n[mcp-eval] stop: ${result.stopReason}\n[mcp-eval] answer: ${result.text}`,
    );
    const used = calls.filter(call =>
      call.name.startsWith(`${server!.id.replace(/[^a-zA-Z0-9]+/g, '_')}_`),
    );
    expect(used.length).toBeGreaterThan(0);
    expect(used.some(call => call.result.length > 50)).toBe(true);
    expect(result.stopReason).not.toBe('error');
    expect(result.text.length).toBeGreaterThan(20);
  }, 600_000);
});

const RELAY = process.env.ANTICHAT_RELAY_EVAL;
(RELAY ? describe : describe.skip)('Composio through the relay', () => {
  it('lists apps, opens a sign-in page, runs a no-account action', async () => {
    const opened: string[] = [];
    const relay = new RelayClient({
      baseUrl: RELAY,
      fetch: realFetch,
      installId: async () => '7c1e2a4b-5d6f-4a8b-9c0d-1e2f3a4b5c6d',
    });
    const {store} = makeStore([], {
      relay,
      fetch: realFetch,
      openUrl: async url => {
        opened.push(url);
      },
      pollIntervalMs: 500,
      pollTimeoutMs: 3_000,
    });
    await store.refresh();
    expect(store.toolkits.length).toBeGreaterThan(100);

    // Connect Gmail: the app opens the hosted link; nobody signs in.
    await store.connect('gmail');
    expect(opened[0]).toMatch(/^https:\/\/connect\.composio\.dev\//);
    const page = await fetch(opened[0]!);
    console.log(
      `[relay-eval] sign-in link ${opened[0]} -> ${page.status} ${page.url}`,
    );
    expect(page.ok).toBe(true);
    expect(store.isConnected('gmail')).toBe(false);

    // Hacker News needs no account.
    const client = store.relayMcp();
    await client.initialize();
    const names = (await client.listTools()).map(tool => tool.name);
    expect(names).toContain('COMPOSIO_MULTI_EXECUTE_TOOL');
    const result = await client.callTool('COMPOSIO_MULTI_EXECUTE_TOOL', {
      tools: [{tool_slug: 'HACKERNEWS_GET_TOP_STORIES', arguments: {}}],
      sync_response_to_workbench: false,
    });
    console.log(`[relay-eval] ${result.text.slice(0, 160)}`);
    expect(result.isError).toBe(false);
    expect(result.text).toContain('story_ids');
  }, 120_000);
});
