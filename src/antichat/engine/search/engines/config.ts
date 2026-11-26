/**
 * The keyless engines, as data. Port of AntiChat Mac
 * `catalog/search-engines.yaml`: URL templates, safe-search and recency
 * parameters and an on/off flag per engine, so a markup or URL change is
 * fixed by a catalogue update (`applyEngineOverrides`) instead of an app
 * release. An override can disable or re-point an engine this build has a
 * parser for; it can never add one.
 *
 * Transport facts measured on 2026-11-24 from a residential connection:
 *   duckduckgo  plain fetch works (html endpoint; lite as second try), but
 *               answered 202 "anomaly" for most of an hour after about 75
 *               queries in ten minutes
 *   bing        plain fetch works with setlang/cc/form parameters. The Mac
 *               catalogue ships Bing switched off; on the phone it is on,
 *               because without it one blocked engine leaves no second
 *               scraped source (set `enabled: false` to follow the Mac)
 *   brave       plain fetch works, but result links are opaque redirect
 *               tokens: URLs are rebuilt from the breadcrumb (approximate)
 *   mojeek      plain fetch → 403 "automated queries"; needs the WebView
 *   startpage   plain fetch → JavaScript verification page; needs the WebView
 */

export type EngineTransport = 'fetch' | 'webview' | 'fetch_then_webview';

export interface EngineConfig {
  id: string;
  name: string;
  enabled: boolean;
  /** `{q}` = encoded query. */
  urlTemplate: string;
  /** Second URL tried when the first is blocked or empty. */
  fallbackUrlTemplate?: string;
  parser:
    | 'duckduckgo'
    | 'duckduckgo-lite'
    | 'bing'
    | 'brave'
    | 'mojeek'
    | 'startpage';
  fallbackParser?: EngineConfig['parser'];
  transport: EngineTransport;
  safeParam?: {off: string; on: string};
  /** Query parameters for day / week / month / year filters. */
  recencyParam?: {day: string; week: string; month: string; year: string};
  /** `{lang}`-`{region}` style parameter, e.g. DuckDuckGo's `kl`. */
  regionParam?: Record<string, string>;
  /** Result URLs starting with these are dropped (engine-internal links). */
  dropUrlPrefixes?: string[];
}

export const DEFAULT_ENGINES: EngineConfig[] = [
  {
    id: 'duckduckgo',
    name: 'DuckDuckGo',
    enabled: true,
    urlTemplate: 'https://html.duckduckgo.com/html/?q={q}',
    fallbackUrlTemplate: 'https://lite.duckduckgo.com/lite/?q={q}',
    parser: 'duckduckgo',
    fallbackParser: 'duckduckgo-lite',
    transport: 'fetch_then_webview',
    safeParam: {off: 'kp=-2', on: 'kp=1'},
    recencyParam: {day: 'df=d', week: 'df=w', month: 'df=m', year: 'df=y'},
    regionParam: {
      en: 'kl=wt-wt',
      de: 'kl=de-de',
      es: 'kl=es-es',
      fr: 'kl=fr-fr',
      nl: 'kl=nl-nl',
      pt: 'kl=pt-pt',
      it: 'kl=it-it',
    },
    dropUrlPrefixes: [
      'https://duckduckgo.com/y.js',
      'https://duckduckgo.com/l/',
    ],
  },
  {
    id: 'bing',
    name: 'Bing',
    enabled: true,
    urlTemplate: 'https://www.bing.com/search?q={q}&form=QBLH',
    parser: 'bing',
    transport: 'fetch',
    safeParam: {off: 'adlt=off', on: 'adlt=strict'},
    recencyParam: {
      day: 'filters=ex1%3a%22ez1%22',
      week: 'filters=ex1%3a%22ez2%22',
      month: 'filters=ex1%3a%22ez3%22',
      year: 'filters=ex1%3a%22ez5_19000_99999%22',
    },
    regionParam: {
      en: 'setlang=en&cc=US',
      de: 'setlang=de&cc=DE',
      es: 'setlang=es&cc=ES',
      fr: 'setlang=fr&cc=FR',
      nl: 'setlang=nl&cc=NL',
      pt: 'setlang=pt&cc=PT',
      it: 'setlang=it&cc=IT',
    },
    dropUrlPrefixes: ['https://www.bing.com/', 'https://bing.com/'],
  },
  {
    id: 'brave',
    name: 'Brave',
    enabled: true,
    urlTemplate: 'https://search.brave.com/search?q={q}&source=web',
    parser: 'brave',
    transport: 'fetch',
    safeParam: {off: 'safesearch=off', on: 'safesearch=strict'},
    recencyParam: {day: 'tf=pd', week: 'tf=pw', month: 'tf=pm', year: 'tf=py'},
  },
  {
    id: 'mojeek',
    name: 'Mojeek',
    enabled: true,
    urlTemplate: 'https://www.mojeek.com/search?q={q}',
    parser: 'mojeek',
    transport: 'fetch_then_webview',
    safeParam: {off: 'safe=0', on: 'safe=1'},
    recencyParam: {
      day: 'since=day',
      week: 'since=week',
      month: 'since=month',
      year: 'since=year',
    },
  },
  {
    id: 'startpage',
    name: 'Startpage',
    enabled: true,
    urlTemplate:
      'https://www.startpage.com/sp/search?query={q}&cat=web&t=device&lui=english&language=english&segment=organic',
    parser: 'startpage',
    transport: 'webview',
    safeParam: {off: 'qadf=none', on: 'qadf=heavy'},
    dropUrlPrefixes: ['https://www.google.com'],
  },
];

export interface EngineOverride {
  id: string;
  enabled?: boolean;
  urlTemplate?: string;
  fallbackUrlTemplate?: string;
  transport?: EngineTransport;
}

/** Apply catalogue overrides by id. Unknown ids are ignored. */
export function applyEngineOverrides(
  engines: EngineConfig[],
  overrides: EngineOverride[] | undefined,
): EngineConfig[] {
  if (!overrides?.length) {
    return engines;
  }
  return engines.map(engine => {
    const override = overrides.find(candidate => candidate.id === engine.id);
    if (!override) {
      return engine;
    }
    const next = {...engine};
    if (typeof override.enabled === 'boolean') {
      next.enabled = override.enabled;
    }
    for (const key of ['urlTemplate', 'fallbackUrlTemplate'] as const) {
      const value = override[key];
      // Re-pointing stays on the engine's own site.
      if (typeof value === 'string' && sameSite(value, engine.urlTemplate)) {
        next[key] = value;
      }
    }
    if (override.transport) {
      next.transport = override.transport;
    }
    return next;
  });
}

const site = (url: string): string => {
  const host = /^https:\/\/([^/?#]+)/.exec(url)?.[1] ?? '';
  return host.split('.').slice(-2).join('.');
};

const sameSite = (a: string, b: string): boolean =>
  !!site(a) && site(a) === site(b);

export function recencyBucket(
  days?: number,
): 'day' | 'week' | 'month' | 'year' | undefined {
  if (!days || days <= 0) {
    return undefined;
  }
  if (days <= 1) {
    return 'day';
  }
  if (days <= 7) {
    return 'week';
  }
  if (days <= 31) {
    return 'month';
  }
  return 'year';
}

export function buildEngineUrl(
  template: string,
  engine: EngineConfig,
  request: {
    query: string;
    safeSearch?: boolean;
    recencyDays?: number;
    language?: string;
  },
): string {
  let url = template.replace('{q}', encodeURIComponent(request.query));
  const add = (param?: string) => {
    if (param) {
      url += (url.includes('?') ? '&' : '?') + param;
    }
  };
  if (engine.safeParam && request.safeSearch !== undefined) {
    add(request.safeSearch ? engine.safeParam.on : engine.safeParam.off);
  }
  const bucket = recencyBucket(request.recencyDays);
  if (bucket && engine.recencyParam) {
    add(engine.recencyParam[bucket]);
  }
  if (engine.regionParam) {
    add(engine.regionParam[request.language ?? 'en'] ?? engine.regionParam.en);
  }
  return url;
}
