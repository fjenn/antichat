import {
  deriveToolSchemas,
  registerDefaultTalents,
  resetRegisteredFlag,
  talentRegistry,
} from '../../../../services/talents';
import type {TalentEngine} from '../../../../services/talents/types';
import {
  clearRequestProviders,
  hasRequestProviders,
  prepareRequest,
} from '../../prompt/registry';
import {getSearchService, resetSearchService} from '../../search/service';
import {toolCatalog} from '../catalog';
import {resetChipState} from '../chips';
import {createConnectivityFlag, setConnectivity} from '../connectivity';
import {
  builtinTools,
  installToolEngine,
  registerAntichatTalents,
  resetToolInstall,
} from '../install';
import {currentTurn, endTurn} from '../turnState';

const UPSTREAM = [
  'render_html',
  'calculate',
  'datetime',
  'web_search',
  'read_url',
];

function reset() {
  resetToolInstall();
  clearRequestProviders();
  resetChipState();
  resetSearchService();
  setConnectivity(null);
  endTurn();
  talentRegistry.reset();
  resetRegisteredFlag();
}

describe('tool engine installation', () => {
  beforeEach(reset);
  afterAll(reset);

  it('leaves upstream untouched until the engine is installed', () => {
    registerDefaultTalents();
    expect(talentRegistry.getAll().map(engine => engine.name)).toEqual(
      UPSTREAM,
    );
    expect(deriveToolSchemas().map(tool => tool.function.name)).toEqual(
      UPSTREAM,
    );
    expect(hasRequestProviders()).toBe(false);
    expect(toolCatalog.all()).toEqual([]);
  });

  it('registers every tool as a talent on install, replacing web_search and read_url', () => {
    registerDefaultTalents();
    const upstreamSearch = talentRegistry.get('web_search');
    const remove = installToolEngine();
    const names = talentRegistry.getAll().map(engine => engine.name);
    expect(names).toEqual([
      ...UPSTREAM,
      'calculator',
      'convert_units',
      'date_time',
      'set_timer',
      'weather',
      'image_search',
      'get_location',
      'search_tools',
    ]);
    expect(talentRegistry.get('web_search')).not.toBe(upstreamSearch);
    expect(
      talentRegistry.get('web_search')!.toToolDefinition().function.description,
    ).toContain('Search the web for current or factual information');
    expect(hasRequestProviders()).toBe(true);
    // The user's provider from upstream settings is part of the chain.
    expect(
      getSearchService().broker.providers.map(provider => provider.id),
    ).toEqual([
      'duckduckgo',
      'bing',
      'brave',
      'mojeek',
      'startpage',
      'user-provider',
      'wikipedia',
    ]);
    remove();
    expect(talentRegistry.get('web_search')).toBe(upstreamSearch);
    expect(hasRequestProviders()).toBe(false);
  });

  it('works in either order: install first, registry later', () => {
    installToolEngine();
    const registered: string[] = [];
    registerAntichatTalents({
      register: (engine: TalentEngine) => registered.push(engine.name),
    });
    expect(registered).toEqual(
      builtinTools()
        .map(tool => tool.name)
        .concat('search_tools'),
    );
  });

  it('offers the selected tools through the seam and opens the turn for the adapter', async () => {
    registerDefaultTalents();
    const flag = createConnectivityFlag(true);
    installToolEngine({connectivity: flag, directSearch: false});
    const prepared = await prepareRequest({
      messages: [{role: 'user', content: 'What is the capital of Australia?'}],
      session: {id: 'chat-1'},
      runtime: {family: 'gemma4', modelName: 'gemma-4-E2B-it', nCtx: 8192},
    });
    expect(prepared.tools.map(tool => tool.function.name)).toEqual([
      'web_search',
      'read_url',
      'calculator',
      'convert_units',
      'date_time',
      'set_timer',
      'weather',
      'search_tools',
    ]);
    // Every offered name resolves to a talent the upstream runner can run.
    for (const tool of prepared.tools) {
      expect(talentRegistry.get(tool.function.name)).toBeDefined();
    }
    expect(currentTurn()!.offered.map(tool => tool.name)).toEqual(
      prepared.tools.map(tool => tool.function.name),
    );
    const result = await talentRegistry
      .get('calculator')!
      .execute({expression: '17 * 23'});
    expect(result).toEqual({type: 'text', summary: '17 * 23 = 391'});

    flag.set(false);
    const offline = await prepareRequest({
      messages: [{role: 'user', content: 'What is the capital of Australia?'}],
      session: {id: 'chat-1'},
      runtime: {family: 'gemma4', modelName: 'gemma-4-E2B-it', nCtx: 8192},
    });
    expect(offline.tools.map(tool => tool.function.name)).toEqual([
      'calculator',
      'convert_units',
      'date_time',
      'set_timer',
      // get_location is a local deferred tool, so the finder stays offline.
      'search_tools',
    ]);
  });

  it('respects a small model: LFM3 gets six tools at most', async () => {
    installToolEngine({directSearch: false});
    const prepared = await prepareRequest({
      messages: [{role: 'user', content: 'What is the capital of Australia?'}],
      session: {id: 'chat-2'},
      runtime: {family: 'lfm3', modelName: 'LFM3-1.7B-Q4_K_M', nCtx: 8192},
    });
    expect(prepared.tools).toHaveLength(6);
    expect(prepared.tools.map(tool => tool.function.name)).toContain(
      'search_tools',
    );
  });
});
