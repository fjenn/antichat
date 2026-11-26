/**
 * Switching the tool layer on.
 *
 * `registerAntichatTalents` is the one call upstream makes
 * (`src/services/talents/index.ts`, marked `// ANTICHAT:`). It only hands
 * AntiChat the talent registry and upstream's search settings. Nothing is
 * registered until `installToolEngine` runs (M1's adapter calls it once at
 * start-up, next to `installPromptEngine`): then the catalogue is filled,
 * every AntiChat tool becomes a talent — `web_search` and `read_url` replace
 * upstream's with the keyless, citation-aware versions — and the selection
 * provider joins the D2 seam. A build that never installs the engine behaves
 * exactly as upstream.
 */
import type {SearchAccess} from '../../../services/talents/searchAccess';
import type {TalentEngine} from '../../../services/talents/types';
import {registerRequestProvider} from '../prompt/registry';
import {
  createImageSearchTool,
  createReadUrlTool,
  createWebSearchTool,
} from '../search/searchTools';
import {configureSearch, type SearchServiceOptions} from '../search/service';
import {fromUpstreamProvider} from '../search/upstreamProvider';
import {webViewScraper} from '../search/webview/scraper';
import {calculatorTool} from './builtin/calculator';
import {dateTimeTool} from './builtin/datetime';
import {allowedOffline, chatOfTurn, isOfflineChat} from '../offline';
import {createLocationTool, isLocationAllowed} from './builtin/location';
import {setTimerTool} from './builtin/timer';
import {convertUnitsTool} from './builtin/units';
import {createWeatherTool} from './builtin/weather';
import {createSearchToolsTool, toolCatalog, type ToolCatalog} from './catalog';
import {setConnectivity, isOnline, type Connectivity} from './connectivity';
import {
  createToolSelectionProvider,
  type ToolSelectionOptions,
} from './selection';
import {asTalentEngine} from './talentAdapter';
import type {AntichatTool} from './types';

/** The built-in tools, in the order they are offered. */
export function builtinTools(): AntichatTool[] {
  return [
    createWebSearchTool(),
    createReadUrlTool(),
    calculatorTool,
    convertUnitsTool,
    dateTimeTool,
    setTimerTool,
    createWeatherTool(),
    createImageSearchTool(),
    // M12: deferred, found through search_tools ("near me").
    createLocationTool(),
  ];
}

export interface TalentRegistryLike {
  register(engine: TalentEngine): void;
  get?(name: string): TalentEngine | undefined;
}

let filled = false;

/** Fill the catalogue once (idempotent). */
export function registerBuiltinTools(catalog: ToolCatalog = toolCatalog): void {
  if (filled && catalog === toolCatalog) {
    return;
  }
  builtinTools().forEach(tool => catalog.register(tool));
  catalog.register(
    createSearchToolsTool({
      catalog,
      usable: (tool, context) =>
        (isOnline() || tool.kind !== 'online') &&
        (isLocationAllowed() || tool.name !== 'get_location') &&
        (!isOfflineChat(chatOfTurn(context.turnId)) ||
          allowedOffline(tool.name, () => tool.kind)),
      activation: 'turn',
    }),
  );
  if (catalog === toolCatalog) {
    filled = true;
  }
}

interface Attachment {
  registry: TalentRegistryLike;
  searchAccess?: SearchAccess;
  searchOptions: SearchServiceOptions;
}

let attachment: Attachment | null = null;
let installed = false;
/** Upstream talents AntiChat replaced, to put back on uninstall. */
const replaced = new Map<string, TalentEngine>();
let stopWatching: (() => void) | null = null;

function publish(): void {
  if (!attachment) {
    return;
  }
  const {registry} = attachment;
  for (const tool of toolCatalog.all()) {
    const existing = registry.get?.(tool.name);
    if (existing && !replaced.has(tool.name) && !isAntichatTalent(existing)) {
      replaced.set(tool.name, existing);
    }
    registry.register(markAntichat(asTalentEngine(tool)));
  }
}

const MARK = '__antichat';
const markAntichat = (engine: TalentEngine): TalentEngine =>
  Object.assign(engine, {[MARK]: true});
const isAntichatTalent = (engine: TalentEngine): boolean =>
  !!(engine as unknown as Record<string, unknown>)[MARK];

function activate(): void {
  if (!attachment) {
    return;
  }
  try {
    registerBuiltinTools();
    const {searchAccess, searchOptions} = attachment;
    const extraProviders = [...(searchOptions.extraProviders ?? [])];
    if (searchAccess) {
      extraProviders.push({
        // Resolved per search: the user may switch provider or key any time.
        id: 'user-provider',
        name: 'Search provider from settings',
        tier: 'fallback',
        isAvailable: () => {
          try {
            return searchAccess.canSearch();
          } catch {
            return false;
          }
        },
        search: request =>
          fromUpstreamProvider(searchAccess.getActiveProvider()).search(
            request,
          ),
      });
    }
    configureSearch({
      webView: () => webViewScraper,
      ...searchOptions,
      extraProviders,
    });
    publish();
    stopWatching?.();
    stopWatching = toolCatalog.onChange(publish);
  } catch (error) {
    console.warn(
      '[antichat] tool registration failed; upstream talents stay',
      error,
    );
  }
}

/**
 * Called from upstream's `registerDefaultTalents`. `searchAccess` is
 * upstream's view of the user's search settings: the provider the user chose
 * (with their key, or keyless You.com) joins AntiChat's chain behind the
 * same interface. Registers nothing unless the tool engine is installed.
 */
export function registerAntichatTalents(
  registry: TalentRegistryLike,
  searchAccess?: SearchAccess,
  searchOptions: SearchServiceOptions = {},
): void {
  attachment = {registry, searchAccess, searchOptions};
  if (installed) {
    activate();
  }
}

export interface ToolEngineOptions extends ToolSelectionOptions {
  connectivity?: Connectivity;
}

/**
 * Switch the tool layer on: tools become talents and active-tool selection
 * joins the D2 seam. Returns the function that undoes both.
 */
export function installToolEngine(options: ToolEngineOptions = {}): () => void {
  registerBuiltinTools();
  if (options.connectivity) {
    setConnectivity(options.connectivity);
  }
  installed = true;
  activate();
  const removeProvider = registerRequestProvider(
    createToolSelectionProvider(options),
  );
  return () => {
    removeProvider();
    installed = false;
    stopWatching?.();
    stopWatching = null;
    // Put upstream's own talents back where AntiChat had replaced them.
    replaced.forEach(engine => attachment?.registry.register(engine));
    replaced.clear();
  };
}

/** Test helper. */
export function resetToolInstall(): void {
  filled = false;
  installed = false;
  attachment = null;
  replaced.clear();
  stopWatching?.();
  stopWatching = null;
  toolCatalog.clear();
}
