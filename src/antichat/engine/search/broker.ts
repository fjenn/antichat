/**
 * Keyless metasearch on the phone. Port of AntiChat Mac `SearchBroker`:
 * per query every available `race` provider runs in parallel under one
 * wall-clock budget; results merge by reciprocal rank, dedupe by normalised
 * URL and keep the engines that found them. When the race comes back thin
 * the `fallback` providers are tried in order (keyless You.com, then
 * Wikipedia). Only the query words leave the device.
 */
import {hostOf, normalizeUrl} from './html';
import {
  SearchProviderError,
  type SearchAttempt,
  type SearchOutcome,
  type SearchRequest,
  type SearchResult,
  type WebSearchProvider,
} from './types';

export interface BrokerOptions {
  providers: WebSearchProvider[];
  /** Wall-clock budget for one engine race. Mac: 2.5 s; phones get 4 s. */
  raceBudgetMs?: number;
  /** Once one engine has answered, the others get this much longer. */
  graceMs?: number;
  /** Below this many merged results the fallback tier is tried. */
  minResults?: number;
  /** Per-engine health is reported here (hit-rate statistics). */
  onAttempt?: (attempt: SearchAttempt) => void;
  now?: () => number;
}

export interface BrokerRequest extends Omit<SearchRequest, 'query'> {
  queries: string[];
}

const RRF_K = 60;

const LOW_VALUE_HOSTS =
  /(^|\.)(pinterest\.[a-z.]+|quora\.com|facebook\.com|instagram\.com|tiktok\.com|x\.com|twitter\.com)$/i;

const QUERY_STOP = new Set([
  'the',
  'and',
  'for',
  'are',
  'was',
  'what',
  'who',
  'how',
  'when',
  'where',
  'which',
  'with',
  'that',
  'this',
  'from',
  'does',
  'did',
  'has',
  'have',
  'will',
  'most',
  'recent',
  'latest',
  'current',
  'best',
  'way',
  'next',
  'der',
  'die',
  'das',
  'und',
  'ist',
  'wie',
  'was',
  'los',
  'las',
  'les',
  'des',
  'est',
]);

const tokens = (text: string): string[] =>
  text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(
      word =>
        word.length > 1 &&
        !QUERY_STOP.has(word) &&
        !/^(?:19|20)\d{2}$/.test(word),
    );

/**
 * Merge ranked lists. Score = reciprocal-rank fusion over the lists a URL
 * appears in, plus a small bonus for query words in the title or snippet,
 * minus penalties for rebuilt URLs, empty snippets and low-value hosts.
 * Then at most `perHost` results per host, so one site cannot fill the list.
 */
export function mergeResults(
  lists: SearchResult[][],
  options: {query?: string; perHost?: number; limit?: number} = {},
): SearchResult[] {
  const byKey = new Map<
    string,
    SearchResult & {score: number; engines: string[]}
  >();
  for (const list of lists) {
    list.forEach((result, rank) => {
      const key = normalizeUrl(result.url);
      if (!key) {
        return;
      }
      const gain = 1 / (RRF_K + rank + 1);
      const existing = byKey.get(key);
      if (existing) {
        existing.score += gain;
        if (!existing.engines.includes(result.engine)) {
          existing.engines.push(result.engine);
        }
        // Prefer an exact URL and the longer snippet.
        if (existing.approximateUrl && !result.approximateUrl) {
          existing.url = result.url;
          existing.approximateUrl = undefined;
        }
        if ((result.snippet?.length ?? 0) > (existing.snippet?.length ?? 0)) {
          existing.snippet = result.snippet;
        }
        existing.publishedAt ??= result.publishedAt;
      } else {
        byKey.set(key, {...result, score: gain, engines: [result.engine]});
      }
    });
  }
  const queryWords = new Set(tokens(options.query ?? ''));
  const scored = [...byKey.values()].map(result => {
    let score = result.score;
    if (queryWords.size > 0) {
      const have = new Set(tokens(`${result.title} ${result.snippet}`));
      let shared = 0;
      queryWords.forEach(word => {
        if (have.has(word)) {
          shared++;
        }
      });
      // A nudge for query words in the title or snippet (the engines' own
      // order still decides), and a real penalty for a full-text fallback
      // hit that shares none of them: that is what Wikipedia's search returns
      // for a whole question.
      score += (shared / queryWords.size) * 0.0006;
      if (
        shared === 0 &&
        queryWords.size >= 2 &&
        result.engine === 'wikipedia'
      ) {
        score -= 0.012;
      }
    }
    if (result.approximateUrl) {
      score -= 0.004;
    }
    if (!result.snippet) {
      score -= 0.003;
    }
    if (LOW_VALUE_HOSTS.test(hostOf(result.url))) {
      score -= 0.006;
    }
    return {...result, score};
  });
  scored.sort((a, b) => b.score - a.score);
  const perHost = options.perHost ?? 2;
  const counts = new Map<string, number>();
  const kept: SearchResult[] = [];
  const overflow: SearchResult[] = [];
  for (const result of scored) {
    const host = hostOf(result.url);
    const count = counts.get(host) ?? 0;
    if (count < perHost) {
      counts.set(host, count + 1);
      kept.push(result);
    } else {
      overflow.push(result);
    }
  }
  const all = [...kept, ...overflow];
  return options.limit ? all.slice(0, options.limit) : all;
}

/**
 * Share of a result list that mentions at least one content word of the
 * query (title, snippet or URL; whole word or 5-letter stem). Engines that
 * suspect a bot do not always refuse: Bing answered some plain requests with
 * a full page of unrelated shops and people (measured, m8-eval.md §6).
 */
export function relevantShare(results: SearchResult[], query: string): number {
  const words = [...new Set(tokens(query))];
  if (results.length === 0 || words.length === 0) {
    return 1;
  }
  const matches = results.filter(result => {
    const text =
      `${result.title} ${result.snippet} ${result.url}`.toLowerCase();
    return words.some(
      word =>
        text.includes(word) ||
        (word.length > 5 && text.includes(word.slice(0, 5))),
    );
  });
  return matches.length / results.length;
}

/**
 * A list counts as unrelated when none of at least three results mentions
 * the query, or fewer than three in ten of at least five. Deliberately low:
 * good results often use other words than the question ("Grand Prix" for
 * "race"), but engines echo query words in most snippets.
 */
export function looksUnrelated(
  results: SearchResult[],
  query: string,
): boolean {
  if (results.length < 3) {
    return false;
  }
  const share = relevantShare(results, query);
  return share === 0 || (results.length >= 5 && share < 0.3);
}

const failureOf = (
  error: unknown,
): {kind: SearchAttempt['kind']; message: string} => {
  if (error instanceof SearchProviderError) {
    return {kind: error.kind, message: error.message};
  }
  return {kind: 'network', message: (error as Error)?.message ?? 'failed'};
};

export class SearchBroker {
  private readonly raceBudgetMs: number;
  private readonly graceMs: number;
  private readonly minResults: number;
  private readonly now: () => number;

  constructor(private readonly options: BrokerOptions) {
    this.raceBudgetMs = options.raceBudgetMs ?? 4000;
    this.graceMs = options.graceMs ?? 900;
    this.minResults = options.minResults ?? 3;
    this.now = options.now ?? Date.now;
  }

  get providers(): WebSearchProvider[] {
    return this.options.providers;
  }

  private available(tier: WebSearchProvider['tier']): WebSearchProvider[] {
    return this.options.providers.filter(
      provider => provider.tier === tier && (provider.isAvailable?.() ?? true),
    );
  }

  /**
   * The providers of a race. With fewer than two healthy scraped engines the
   * first fallback provider (keyless You.com by default) runs alongside, so
   * a block of one engine costs neither time nor a second source of results.
   */
  private racers(): WebSearchProvider[] {
    const race = this.available('race');
    if (race.length >= 2) {
      return race;
    }
    const promoted = this.available('fallback').find(
      provider => provider.id !== 'wikipedia',
    );
    return promoted ? [...race, promoted] : race;
  }

  private async call(
    provider: WebSearchProvider,
    query: string,
    request: BrokerRequest,
    signal: AbortSignal,
    timeoutMs: number,
  ): Promise<{results: SearchResult[]; attempt: SearchAttempt}> {
    const started = this.now();
    try {
      const results = await provider.search({
        query,
        maxResults: request.maxResults,
        language: request.language,
        safeSearch: request.safeSearch,
        recencyDays: request.recencyDays,
        signal,
        timeoutMs,
      });
      if (looksUnrelated(results, query)) {
        throw new SearchProviderError(
          'irrelevant',
          'results do not match the query',
        );
      }
      const attempt: SearchAttempt = {
        engine: provider.id,
        query,
        ok: results.length > 0,
        count: results.length,
        ms: this.now() - started,
        ...(results.length === 0 ? {kind: 'empty' as const} : {}),
      };
      return {results, attempt};
    } catch (error) {
      const {kind, message} = failureOf(error);
      return {
        results: [],
        attempt: {
          engine: provider.id,
          query,
          ok: false,
          count: 0,
          ms: this.now() - started,
          kind: signal.aborted && kind === 'network' ? 'timeout' : kind,
          error: message.slice(0, 120),
        },
      };
    }
  }

  /** All race providers for one query; ends at the budget or the grace. */
  private race(
    query: string,
    request: BrokerRequest,
  ): Promise<{lists: SearchResult[][]; attempts: SearchAttempt[]}> {
    const providers = this.racers();
    if (providers.length === 0) {
      return Promise.resolve({lists: [], attempts: []});
    }
    return new Promise(resolve => {
      const controller = new AbortController();
      const lists: SearchResult[][] = providers.map(() => []);
      const attempts: Array<SearchAttempt | null> = providers.map(() => null);
      let pending = providers.length;
      let settled = false;
      let graceTimer: ReturnType<typeof setTimeout> | null = null;
      const started = this.now();

      const finish = () => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(budgetTimer);
        if (graceTimer) {
          clearTimeout(graceTimer);
        }
        request.signal?.removeEventListener('abort', finish);
        controller.abort();
        resolve({
          lists,
          attempts: attempts.map(
            (attempt, index) =>
              attempt ?? {
                engine: providers[index].id,
                query,
                ok: false,
                count: 0,
                ms: this.now() - started,
                kind: 'timeout' as const,
                error: 'race budget',
              },
          ),
        });
      };
      const budgetTimer = setTimeout(finish, this.raceBudgetMs);
      request.signal?.addEventListener('abort', finish);

      providers.forEach((provider, index) => {
        this.call(
          provider,
          query,
          request,
          controller.signal,
          this.raceBudgetMs,
        ).then(({results, attempt}) => {
          if (settled) {
            return;
          }
          lists[index] = results;
          attempts[index] = attempt;
          this.options.onAttempt?.(attempt);
          pending -= 1;
          if (pending === 0) {
            finish();
          } else if (results.length > 0 && !graceTimer) {
            graceTimer = setTimeout(finish, this.graceMs);
          }
        });
      });
    });
  }

  async search(request: BrokerRequest): Promise<SearchOutcome> {
    const started = this.now();
    const queries = [
      ...new Set(request.queries.map(query => query.trim()).filter(Boolean)),
    ];
    if (queries.length === 0) {
      return {
        results: [],
        attempts: [],
        elapsedMs: 0,
        queries,
        failure: 'no query',
      };
    }
    const perQuery = await Promise.all(
      queries.map(query => this.race(query, request)),
    );
    const attempts = perQuery.flatMap(entry => entry.attempts);
    const lists = perQuery.flatMap(entry => entry.lists);

    const mergedCount = () => mergeResults(lists).length;
    if (mergedCount() < this.minResults && !request.signal?.aborted) {
      const controller = new AbortController();
      const onAbort = () => controller.abort();
      request.signal?.addEventListener('abort', onAbort);
      try {
        const raced = new Set(this.racers().map(provider => provider.id));
        for (const provider of this.available('fallback')) {
          if (raced.has(provider.id)) {
            continue;
          }
          const {results, attempt} = await this.call(
            provider,
            queries[0],
            request,
            controller.signal,
            Math.max(this.raceBudgetMs, 5000),
          );
          attempts.push(attempt);
          this.options.onAttempt?.(attempt);
          lists.push(results);
          if (mergedCount() >= this.minResults || request.signal?.aborted) {
            break;
          }
        }
      } finally {
        request.signal?.removeEventListener('abort', onAbort);
      }
    }

    const results = mergeResults(lists, {
      query: queries.join(' '),
      limit: request.maxResults,
    });
    const outcome: SearchOutcome = {
      results,
      attempts,
      elapsedMs: this.now() - started,
      queries,
    };
    if (results.length === 0) {
      const kinds = [
        ...new Set(attempts.map(attempt => attempt.kind).filter(Boolean)),
      ];
      outcome.failure = kinds.length ? kinds.join(',') : 'no engine available';
    }
    return outcome;
  }
}

/** Running per-engine hit statistics (settings screen, evaluation). */
export class EngineStats {
  private readonly rows = new Map<
    string,
    {calls: number; hits: number; ms: number; kinds: Record<string, number>}
  >();

  record = (attempt: SearchAttempt): void => {
    const row = this.rows.get(attempt.engine) ?? {
      calls: 0,
      hits: 0,
      ms: 0,
      kinds: {},
    };
    row.calls += 1;
    row.ms += attempt.ms;
    if (attempt.ok) {
      row.hits += 1;
    } else if (attempt.kind) {
      row.kinds[attempt.kind] = (row.kinds[attempt.kind] ?? 0) + 1;
    }
    this.rows.set(attempt.engine, row);
  };

  summary(): Record<
    string,
    {
      calls: number;
      hitRate: number;
      meanMs: number;
      failures: Record<string, number>;
    }
  > {
    const out: Record<
      string,
      {
        calls: number;
        hitRate: number;
        meanMs: number;
        failures: Record<string, number>;
      }
    > = {};
    this.rows.forEach((row, engine) => {
      out[engine] = {
        calls: row.calls,
        hitRate: row.calls ? row.hits / row.calls : 0,
        meanMs: row.calls ? Math.round(row.ms / row.calls) : 0,
        failures: row.kinds,
      };
    });
    return out;
  }
}
