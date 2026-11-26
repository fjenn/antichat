import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import type {ToolDefinition} from '../../prompt/types';
import {SourceRegistry} from '../../search/citations/registry';
import {ToolCatalog, createSearchToolsTool} from '../catalog';
import {
  activateTools,
  activatedTools,
  activeChips,
  consumeOneShotChips,
  resetChipState,
  setChip,
} from '../chips';
import {
  createConnectivityFlag,
  isOnline,
  setConnectivity,
  OFFLINE_NOTE,
} from '../connectivity';
import {
  createToolSelectionProvider,
  namesOtherTool,
  selectTools,
  type ToolsMeta,
} from '../selection';
import {DEFAULT_CAPS, setToolCaps, toolCapsFor} from '../toolCaps';
import type {AntichatTool} from '../types';

const tool = (
  name: string,
  extra: Partial<AntichatTool> = {},
): AntichatTool => ({
  name,
  description: `${name} tool.`,
  parameters: {type: 'object', properties: {q: {type: 'string'}}},
  kind: 'local',
  tier: 'always',
  execute: async () => ({text: 'ok'}),
  ...extra,
});

const CATALOG: AntichatTool[] = [
  tool('web_search', {kind: 'online', chip: 'search'}),
  tool('read_url', {kind: 'online'}),
  tool('calculator'),
  tool('date_time'),
  tool('weather', {kind: 'online', triggers: ['forecast']}),
  tool('image_search', {
    kind: 'online',
    tier: 'deferred',
    keywords: ['picture', 'photo'],
  }),
  tool('email_send', {
    tier: 'deferred',
    description: 'Send an email from the user account.',
  }),
  tool('study_quiz', {tier: 'chip', chip: 'study'}),
  tool('search_tools'),
];

const caps = {...DEFAULT_CAPS, maxTools: 8, schemaTokens: 5000};
const names = (selection: {names: string[]}) => selection.names;

describe('selectTools', () => {
  it('offers the always-on set plus search_tools, in catalogue order', () => {
    const selection = selectTools({catalog: CATALOG, online: true, caps});
    expect(names(selection)).toEqual([
      'web_search',
      'read_url',
      'calculator',
      'date_time',
      'weather',
      'search_tools',
    ]);
    expect(selection.offline).toEqual([]);
  });

  it('removes every online tool when the device is offline', () => {
    const selection = selectTools({catalog: CATALOG, online: false, caps});
    expect(names(selection)).toEqual([
      'calculator',
      'date_time',
      'search_tools',
    ]);
    expect(selection.offline).toEqual(['web_search', 'read_url', 'weather']);
  });

  it('adds chip tools and tools switched on through search_tools', () => {
    const selection = selectTools({
      catalog: CATALOG,
      online: true,
      caps,
      chips: ['study'],
      activated: ['email_send'],
    });
    expect(names(selection)).toEqual([
      'web_search',
      'read_url',
      'calculator',
      'date_time',
      'weather',
      'email_send',
      'study_quiz',
      'search_tools',
    ]);
  });

  it('keeps chip and activated tools when the cap bites, and reports what fell out', () => {
    const selection = selectTools({
      catalog: CATALOG,
      online: true,
      caps: {...caps, maxTools: 4},
      chips: ['study'],
      activated: ['email_send'],
    });
    expect(names(selection)).toEqual([
      'web_search',
      'email_send',
      'study_quiz',
      'search_tools',
    ]);
    expect(selection.overCap).toEqual([
      'read_url',
      'calculator',
      'date_time',
      'weather',
    ]);
  });

  it('honours the schema-token cap', () => {
    const selection = selectTools({
      catalog: CATALOG,
      online: true,
      caps: {...caps, schemaTokens: 110},
    });
    expect(selection.names.length).toBeLessThan(6);
    expect(selection.names).toContain('search_tools');
  });

  it('keeps a pal tool, replaces superseded ones and same-named ones', () => {
    const base: ToolDefinition[] = [
      {
        type: 'function',
        function: {name: 'calculate', description: 'old', parameters: {}},
      },
      {
        type: 'function',
        function: {name: 'render_html', description: 'html', parameters: {}},
      },
      {
        type: 'function',
        function: {name: 'web_search', description: 'upstream', parameters: {}},
      },
    ];
    const selection = selectTools({
      catalog: CATALOG,
      baseTools: base,
      online: true,
      caps,
    });
    expect(selection.superseded).toEqual(['calculate']);
    expect(selection.names).toContain('render_html');
    expect(selection.names).not.toContain('calculate');
    expect(
      selection.tools.find(item => item.function.name === 'web_search')!
        .function.description,
    ).toBe('web_search tool.');
  });

  it('offers nothing to a chat-only model', () => {
    expect(
      selectTools({
        catalog: CATALOG,
        online: true,
        caps: {...caps, maxTools: 0},
      }).tools,
    ).toEqual([]);
  });

  it('drops search_tools when no deferred tool is left to find', () => {
    const selection = selectTools({
      catalog: CATALOG,
      online: false,
      caps,
      activated: ['email_send'],
    });
    expect(selection.names).not.toContain('search_tools');
  });
});

describe('tool caps', () => {
  afterEach(() => setToolCaps(null));

  it('are data, matched on the model name', () => {
    expect(
      toolCapsFor('gemma-4-E2B-it-qat-UD-Q4_K_XL', 'gemma4', 8192).maxTools,
    ).toBe(8);
    expect(toolCapsFor('LFM3-1.7B-Q4_K_M', 'lfm3', 8192)).toMatchObject({
      maxTools: 6,
      parallelCalls: 1,
    });
    expect(toolCapsFor('Qwen3.5-4B-Q4_K_M', 'qwen35', 8192).maxTools).toBe(8);
    expect(toolCapsFor('Qwen3.5-0.8B-Q4_K_M', 'qwen35', 8192)).toMatchObject({
      maxTools: 3,
      toolSearch: false,
    });
    expect(toolCapsFor('Qwen3.5-9B-Q4_K_M', 'qwen35', 32768).directSearch).toBe(
      false,
    );
    expect(toolCapsFor('mystery-model', 'generic').maxTools).toBe(
      DEFAULT_CAPS.maxTools,
    );
  });

  it('shrink for a 4k window and can be replaced by the catalogue', () => {
    expect(toolCapsFor('Qwen3.5-4B-Q4_K_M', 'qwen35', 4096)).toMatchObject({
      maxTools: 4,
      resultChars: 1200,
    });
    setToolCaps([{match: 'mystery', maxTools: 2}]);
    expect(toolCapsFor('mystery-model', 'generic').maxTools).toBe(2);
  });
});

describe('chips and activations', () => {
  beforeEach(() => resetChipState());

  it('are kept per chat and one-shot chips switch themselves off', () => {
    setChip('a', 'search', true);
    setChip('a', 'study', true);
    setChip('b', 'think', true);
    expect(activeChips('a')).toEqual(['search', 'study']);
    expect(activeChips('b')).toEqual(['think']);
    expect(consumeOneShotChips('a')).toEqual(['search']);
    expect(activeChips('a')).toEqual(['study']);
  });

  it('keep the most recent activations', () => {
    activateTools('a', ['t1', 't2', 't3'], 3);
    activateTools('a', ['t4', 't1'], 3);
    expect(activatedTools('a')).toEqual(['t3', 't4', 't1']);
    expect(activatedTools('b')).toEqual([]);
  });
});

describe('search_tools', () => {
  beforeEach(() => resetChipState());

  it('finds deferred tools by what they do and switches them on', async () => {
    const catalog = new ToolCatalog();
    CATALOG.filter(item => item.name !== 'search_tools').forEach(item =>
      catalog.register(item),
    );
    const meta = createSearchToolsTool({catalog, chatId: () => 'chat-1'});
    catalog.register(meta);
    const out = await meta.execute(
      {query: 'send an email'},
      {now: new Date(), turnId: 't'},
    );
    expect(out.text).toContain(
      '- email_send: Send an email from the user account.',
    );
    expect(out.text).toContain('They are now available');
    expect(activatedTools('chat-1')).toEqual(['email_send']);
    const pictures = catalog.search('photos of a red panda', {
      filter: item => item.tier === 'deferred',
    });
    expect(pictures[0].tool.name).toBe('image_search');
    const nothing = await meta.execute(
      {query: 'launch a rocket'},
      {now: new Date()},
    );
    expect(nothing.text).toContain('No tool found');
  });

  it('never returns a tool that cannot run now', async () => {
    const catalog = new ToolCatalog();
    CATALOG.forEach(item => catalog.register(item));
    const meta = createSearchToolsTool({
      catalog,
      usable: item => item.kind !== 'online',
    });
    const out = await meta.execute({query: 'picture photo'}, {now: new Date()});
    expect(out.text).toContain('No tool found');
  });
});

describe('the selection provider at the D2 seam', () => {
  const flag = createConnectivityFlag(true);
  const catalog = new ToolCatalog();
  CATALOG.forEach(item => catalog.register(item));
  const now = new Date(2026, 10, 24, 10, 0);
  const runtime = {
    nCtx: 8192,
    family: 'gemma4' as const,
    modelName: 'gemma-4-E2B-it',
    now,
  };

  beforeEach(() => {
    resetChipState();
    flag.set(true);
    clearRequestProviders();
    registerRequestProvider(
      createToolSelectionProvider({
        catalog,
        online: flag.isOnline,
        directSearch: false,
      }),
    );
  });
  afterAll(() => clearRequestProviders());

  const prepare = (text: string, id = 'chat') =>
    prepareRequest({
      messages: [
        {role: 'system', content: 'You are a test.'},
        {role: 'user', content: text},
      ],
      session: {id},
      runtime,
    });

  it('offers no online tool and no location in an offline chat', async () => {
    const local = new ToolCatalog();
    [...CATALOG, tool('get_location', {tier: 'always'})].forEach(item =>
      local.register(item),
    );
    clearRequestProviders();
    registerRequestProvider(
      createToolSelectionProvider({
        catalog: local,
        online: flag.isOnline,
        directSearch: false,
      }),
    );
    setChip('offline-chat', 'search', true);
    const prepared = await prepareRequest({
      messages: [{role: 'user', content: 'Search the web for news near me'}],
      session: {id: 'offline-chat', offline: true},
      runtime,
    });
    const offered = prepared.tools.map(item => item.function.name);
    expect(offered).not.toContain('web_search');
    expect(offered).not.toContain('read_url');
    expect(offered).not.toContain('get_location');
    expect(offered).toContain('calculator');
    // Online, the same chip offers the web.
    const online = await prepareRequest({
      messages: [{role: 'user', content: 'Search the web for news near me'}],
      session: {id: 'online-chat'},
      runtime,
    });
    expect(online.tools.map(item => item.function.name)).toContain(
      'get_location',
    );
  });

  it('never sends a request to remember something to the web', async () => {
    const prepared = await prepare('Please remember that I live in Lisbon');
    const meta = prepared.meta.tools as ToolsMeta;
    expect(meta.verdict.decision).toBe('none');
  });

  it('adds the tools, the tool-use clause and nothing else for a plain question', async () => {
    const prepared = await prepare('What is the capital of Australia?');
    expect(prepared.tools.map(item => item.function.name)).toEqual([
      'web_search',
      'read_url',
      'calculator',
      'date_time',
      'weather',
      'search_tools',
    ]);
    expect(String(prepared.messages[0].content)).toContain(
      'Call a tool only when the request needs',
    );
    expect(prepared.messages[1].content).toBe(
      'What is the capital of Australia?',
    );
    expect(prepared.params.tool_choice).toBeUndefined();
    expect((prepared.meta.tools as ToolsMeta).verdict.decision).toBe('auto');
  });

  it('keeps the tool list byte-stable across turns and sets tool_choice none for small talk', async () => {
    const first = await prepare('What is the capital of Australia?');
    const second = await prepare('hey, how are you?');
    expect(JSON.stringify(second.tools)).toBe(JSON.stringify(first.tools));
    expect(second.params.tool_choice).toBe('none');
    expect((second.meta.tools as ToolsMeta).verdict).toMatchObject({
      decision: 'none',
      abstainAll: true,
    });
  });

  it('leaves the tools out for a model that ignores tool_choice none', async () => {
    const prepared = await prepareRequest({
      messages: [{role: 'user', content: 'What is 17 times 23?'}],
      session: {id: 'lfm'},
      runtime: {...runtime, family: 'lfm3', modelName: 'LFM3-1.7B-Q4_K_M'},
    });
    expect(prepared.tools).toEqual([]);
    expect(prepared.params.tool_choice).toBeUndefined();
    const asks = await prepareRequest({
      messages: [{role: 'user', content: 'What is the capital of Australia?'}],
      session: {id: 'lfm'},
      runtime: {...runtime, family: 'lfm3', modelName: 'LFM3-1.7B-Q4_K_M'},
    });
    expect(asks.tools.length).toBeGreaterThan(0);
  });

  it('withholds online tools and tells the model when the device is offline', async () => {
    flag.set(false);
    const prepared = await prepare('What is the weather in Lisbon today?');
    expect(prepared.tools.map(item => item.function.name)).toEqual([
      'calculator',
      'date_time',
      'search_tools',
    ]);
    const meta = prepared.meta.tools as ToolsMeta;
    expect(meta.offline).toEqual(['web_search', 'read_url', 'weather']);
    expect(meta.offlineBlocked).toBe(true);
    expect(String(prepared.messages[1].content)).toContain(OFFLINE_NOTE);
    const plain = await prepare('What is 17 times 23?');
    expect((plain.meta.tools as ToolsMeta).offlineBlocked).toBe(false);
    expect(String(plain.messages[1].content)).not.toContain('offline');
  });

  it('adds the date table when the message uses a relative date', async () => {
    const prepared = await prepare(
      'Put lunch with Maria on Friday in my calendar',
    );
    expect(String(prepared.messages[1].content)).toContain('Fri 2026-11-27');
    const plain = await prepare('Explain photosynthesis');
    expect(String(plain.messages[1].content)).not.toContain('Dates:');
  });

  it('forces a search for the Search chip and consumes the chip', async () => {
    setChip('chip-chat', 'search', true);
    const prepared = await prepare('tell me about photosynthesis', 'chip-chat');
    expect((prepared.meta.tools as ToolsMeta).verdict).toEqual({
      decision: 'force',
      reason: 'chip',
    });
    expect(activeChips('chip-chat')).toEqual([]);
  });

  it('reads the injected connectivity flag by default', () => {
    setConnectivity(flag);
    flag.set(false);
    expect(isOnline()).toBe(false);
    setConnectivity(null);
    expect(isOnline()).toBe(true);
  });
});

describe('namesOtherTool', () => {
  it('spots a message that names a non-web tool', () => {
    const offered = [
      tool('web_search'),
      tool('calendar_list_events'),
      tool('email_send'),
      tool('set_timer', {triggers: ['alarm']}),
      tool('date_time'),
    ];
    expect(namesOtherTool('email anna that I am late today', offered)).toBe(
      true,
    );
    expect(namesOtherTool("What's on my calendar tomorrow?", offered)).toBe(
      true,
    );
    expect(namesOtherTool('set an alarm for 7', offered)).toBe(true);
    expect(
      namesOtherTool('Any news on the EU AI Act this week?', offered),
    ).toBe(false);
    expect(namesOtherTool('what time is the match today', offered)).toBe(false);
  });
});

// Keeps the import used: the registry is what a turn's sources hang off.
test('source registry starts empty', () =>
  expect(new SourceRegistry().size).toBe(0));
