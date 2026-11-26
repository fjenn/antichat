/**
 * Live evaluation of the search layer. Skipped unless ANTICHAT_SEARCH_EVAL
 * names the parts to run:
 *
 *   engines   50 synthetic queries against every keyless engine: hit rate,
 *             failure kinds and latency per engine, merged result counts
 *   classify  the optional one-token model pre-pass on fresh-vs-stable-200
 *   answers   the 50 queries end to end through the harness on each model in
 *             ANTICHAT_EVAL, then the citation check; ANTICHAT_JUDGE=<port>
 *             adds a larger model that labels every cited sentence
 *
 *   ANTICHAT_SEARCH_EVAL=engines,answers ANTICHAT_EVAL="gemma4:18801" \
 *   ANTICHAT_JUDGE=18804 ANTICHAT_EVAL_OUT=/tmp/m8 ANTICHAT_HTTP_CACHE=/tmp/m8/http \
 *   yarn jest search.eval --coverage=false
 *
 * Only the synthetic queries of `__fixtures__/live-queries-50.json` leave
 * the machine. Responses are cached on disk so every model sees the same
 * pages.
 */
import fs from 'fs';

import freshSet from '../__fixtures__/fresh-vs-stable-200.json';
import liveSet from '../__fixtures__/live-queries-50.json';
import {buildSystemPrompt} from '../../prompt/systemPrompt';
import type {ModelFamily} from '../../prompt/modelFamily';
import {LOOP_POLICY} from '../../tools/loopGuard';
import {runToolTurn} from '../../tools/runner';
import {toolCapsFor} from '../../tools/toolCaps';
import {
  MODEL_NAMES,
  SAMPLING,
  createEvalEngine,
  percentile,
  pool,
} from '../../tools/__tests__/support/server';
import {SearchBroker, EngineStats, mergeResults} from '../broker';
import {
  applyGrounding,
  attachCitations,
  citedClaims,
} from '../citations/grounding';
import {normalizeMarkers, validateMarkers} from '../citations/markers';
import {buildCitedAnswer} from '../citations/output';
import {registryForTurn} from '../citations/registry';
import {classifySearchNeed, decideSearch} from '../decision';
import {DEFAULT_ENGINES} from '../engines/config';
import {ScrapeEngineProvider} from '../engines/scrapeProvider';
import {WikipediaProvider} from '../engines/wikipedia';
import {knowledgeCutoffFor} from '../freshTerms';
import {buildQueries} from '../query';
import {CITE_SYSTEM_RULE} from '../resultsBlock';
import {createReadUrlTool, createWebSearchTool} from '../searchTools';
import {SearchService} from '../service';
import {
  SearchProviderError,
  type HttpGet,
  type WebSearchProvider,
} from '../types';
import {createCachedHttpGet} from './support/cachedHttp';

const parts = (process.env.ANTICHAT_SEARCH_EVAL ?? '')
  .split(',')
  .filter(Boolean);
const targets = (process.env.ANTICHAT_EVAL ?? '')
  .split(',')
  .filter(Boolean)
  .map(entry => {
    const [family, port] = entry.split(':');
    return {family: family as ModelFamily, port: Number(port)};
  });
const judgePort = Number(process.env.ANTICHAT_JUDGE ?? 0);
const outDir = process.env.ANTICHAT_EVAL_OUT ?? '';
const cacheDir =
  process.env.ANTICHAT_HTTP_CACHE ?? `${outDir || '.'}/http-cache`;
const limit = Number(process.env.ANTICHAT_EVAL_LIMIT ?? 0);
const now = new Date();

const QUERIES = (
  liveSet as {queries: Array<{id: string; category: string; question: string}>}
).queries.slice(0, limit || undefined);

const write = (name: string, data: unknown) => {
  if (outDir) {
    fs.mkdirSync(outDir, {recursive: true});
    fs.writeFileSync(`${outDir}/${name}`, JSON.stringify(data, null, 1));
  }
};

/** Keyless You.com through the same transport (measurement only). */
const youKeyless = (httpGet: HttpGet): WebSearchProvider => ({
  id: 'you',
  name: 'You.com (keyless)',
  tier: 'fallback',
  async search(request) {
    const response = await httpGet(
      `https://api.you.com/v1/agents/search?query=${encodeURIComponent(request.query)}&count=${request.maxResults}`,
      {headers: {Accept: 'application/json'}, timeoutMs: request.timeoutMs},
    );
    if (response.status === 429) {
      throw new SearchProviderError('quota', 'daily limit');
    }
    if (response.status >= 400) {
      throw new SearchProviderError('network', `HTTP ${response.status}`);
    }
    const web = JSON.parse(response.text)?.results?.web ?? [];
    if (web.length === 0) {
      throw new SearchProviderError('empty', 'no results');
    }
    return web.map((row: any) => ({
      title: row.title ?? '',
      url: row.url ?? '',
      snippet: row.description || row.snippets?.[0] || '',
      engine: 'you',
    }));
  },
});

const part = (name: string) =>
  parts.includes(name) ? describe : describe.skip;

part('engines')('keyless engines, 50 live queries', () => {
  it('measures hit rate per engine', async () => {
    const httpGet = createCachedHttpGet(`${cacheDir}/serp`, {delayMs: 1500});
    const providers: WebSearchProvider[] = [
      ...DEFAULT_ENGINES.map(
        engine =>
          // A short cool-down, so a blocked engine is probed again during
          // the run and its real hit rate shows.
          new ScrapeEngineProvider(engine, {httpGet, blockCooldownMs: 20000}),
      ),
      youKeyless(httpGet),
      new WikipediaProvider(httpGet),
    ];
    const rows: any[] = [];
    const stats = new EngineStats();
    for (const item of QUERIES) {
      const query = buildQueries({userText: item.question, now}).queries[0];
      const perEngine: Record<string, any> = {};
      const lists: any[] = [];
      await Promise.all(
        providers.map(async provider => {
          if (provider.isAvailable && !provider.isAvailable()) {
            perEngine[provider.id] = {
              ok: false,
              kind: 'unavailable',
              count: 0,
              ms: 0,
            };
            stats.record({
              engine: provider.id,
              query,
              ok: false,
              count: 0,
              ms: 0,
              kind: 'unavailable',
            });
            return;
          }
          const started = Date.now();
          try {
            const results = await provider.search({
              query,
              maxResults: 8,
              timeoutMs: 8000,
            });
            perEngine[provider.id] = {
              ok: true,
              count: results.length,
              ms: Date.now() - started,
            };
            stats.record({
              engine: provider.id,
              query,
              ok: true,
              count: results.length,
              ms: Date.now() - started,
            });
            if (provider.tier === 'race') {
              lists.push(results);
            }
          } catch (error) {
            const kind =
              error instanceof SearchProviderError ? error.kind : 'network';
            perEngine[provider.id] = {
              ok: false,
              kind,
              count: 0,
              ms: Date.now() - started,
              error: (error as Error).message,
            };
            stats.record({
              engine: provider.id,
              query,
              ok: false,
              count: 0,
              ms: Date.now() - started,
              kind,
            });
          }
        }),
      );
      const merged = mergeResults(lists, {query, limit: 8});
      rows.push({
        ...item,
        query,
        perEngine,
        merged: merged.length,
        multiEngine: merged.filter(result => (result.engines?.length ?? 0) > 1)
          .length,
      });
    }
    const summary = {
      queries: rows.length,
      engines: stats.summary(),
      anyRaceEngine: rows.filter(row => row.merged > 0).length / rows.length,
      meanMerged: rows.reduce((sum, row) => sum + row.merged, 0) / rows.length,
      live: httpGet.live,
      cached: httpGet.cached,
    };
    console.log('[m8-eval] engines', JSON.stringify(summary));
    write('search-engines.json', {summary, rows});
    expect(rows.length).toBe(QUERIES.length);
  }, 1800000);

  it('measures the broker race (latency with the default budget)', async () => {
    const httpGet = createCachedHttpGet(`${cacheDir}/serp-race`, {delayMs: 0});
    const broker = new SearchBroker({
      providers: [
        ...DEFAULT_ENGINES.map(
          engine => new ScrapeEngineProvider(engine, {httpGet}),
        ),
        new WikipediaProvider(httpGet),
      ],
    });
    const elapsed: number[] = [];
    let nonEmpty = 0;
    const sample = QUERIES.filter((_, index) => index % 5 === 0);
    for (const item of sample) {
      const outcome = await broker.search({
        queries: [
          `${buildQueries({userText: item.question, now}).queries[0]} overview`,
        ],
        maxResults: 8,
      });
      elapsed.push(outcome.elapsedMs);
      nonEmpty += outcome.results.length > 0 ? 1 : 0;
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
    const summary = {
      n: sample.length,
      nonEmpty,
      p50: percentile(elapsed, 50),
      p90: percentile(elapsed, 90),
    };
    console.log('[m8-eval] race', JSON.stringify(summary));
    write('search-race.json', summary);
  }, 600000);
});

part('warm')('fill the page cache for the answer runs', () => {
  it('searches and reads every query once, slowly', async () => {
    const httpGet = createCachedHttpGet(`${cacheDir}/pages`, {delayMs: 2500});
    const service = new SearchService({
      httpGet,
      images: false,
      extraProviders: [youKeyless(httpGet)],
    });
    const served: Record<string, number> = {};
    let empty = 0;
    for (const item of QUERIES) {
      const run = await service.webSearch({
        queries: buildQueries({userText: item.question, now}).queries,
        userText: item.question,
        now,
        nCtx: 8192,
      });
      if (!run.output.sources?.length) {
        empty += 1;
      }
      for (const engine of new Set(
        run.outcome.results.flatMap(
          result => result.engines ?? [result.engine],
        ),
      )) {
        served[engine] = (served[engine] ?? 0) + 1;
      }
    }
    const summary = {
      n: QUERIES.length,
      empty,
      served,
      engines: service.stats.summary(),
      live: httpGet.live,
    };
    console.log('[m8-eval] warm', JSON.stringify(summary));
    write('search-warm.json', summary);
  }, 3600000);
});

part('latency')('search pipeline latency, unthrottled', () => {
  it('times search and page reads for a few queries', async () => {
    const httpGet = createCachedHttpGet(`${cacheDir}/latency-${Date.now()}`, {
      delayMs: 0,
    });
    const service = new SearchService({httpGet, images: false});
    const sample = QUERIES.filter((_, index) => index % 6 === 2);
    const rows: Array<{
      search: number;
      read: number;
      total: number;
      pages: number;
      sources: number;
      tokens: number;
    }> = [];
    for (const item of sample) {
      const run = await service.webSearch({
        queries: service.directQueries({
          userText: item.question,
          now,
          nCtx: 8192,
        }),
        userText: item.question,
        now,
        nCtx: 8192,
      });
      rows.push({
        ...run.ms,
        pages: run.pagesRead,
        sources: run.output.sources?.length ?? 0,
        tokens: Math.round(run.output.text.length / 3.6),
      });
      await new Promise(resolve => setTimeout(resolve, 3000));
    }
    const pick = (key: 'search' | 'read' | 'total' | 'tokens') =>
      rows.map(row => row[key]);
    const summary = {
      n: rows.length,
      searchMs: {
        p50: percentile(pick('search'), 50),
        p90: percentile(pick('search'), 90),
      },
      readMs: {
        p50: percentile(pick('read'), 50),
        p90: percentile(pick('read'), 90),
      },
      totalMs: {
        p50: percentile(pick('total'), 50),
        p90: percentile(pick('total'), 90),
      },
      blockTokens: {
        p50: percentile(pick('tokens'), 50),
        max: Math.max(...pick('tokens')),
      },
      meanPages: rows.reduce((sum, row) => sum + row.pages, 0) / rows.length,
      engines: service.stats.summary(),
    };
    console.log('[m8-eval] latency', JSON.stringify(summary));
    write('search-latency.json', {summary, rows});
  }, 600000);
});

const suite = targets.length
  ? describe.each(targets)
  : describe.skip.each([{family: 'generic' as ModelFamily, port: 0}]);

suite('search on $family', ({family, port}) => {
  const modelName = MODEL_NAMES[family];

  (parts.includes('classify') ? it : it.skip)(
    'model pre-pass on fresh-vs-stable-200',
    async () => {
      const rows = (freshSet as {rows: Array<{prompt: string; label: string}>})
        .rows;
      const engine = createEvalEngine(port, {seed: 42});
      const times: number[] = [];
      const results = await pool(rows, 4, async row => {
        const started = Date.now();
        const route = await classifySearchNeed({
          engine,
          userText: row.prompt,
          dateLine: `Current date: ${now.toISOString().slice(0, 10)}.`,
        });
        times.push(Date.now() - started);
        return {
          ...row,
          route,
          rule: decideSearch({
            userText: row.prompt,
            knowledgeCutoff: knowledgeCutoffFor(modelName),
          }).decision,
        };
      });
      const fresh = results.filter(row => row.label === 'fresh');
      const stable = results.filter(row => row.label === 'stable');
      const tp = fresh.filter(row => row.route === 'search').length;
      const fp = stable.filter(row => row.route === 'search').length;
      // The pre-pass as it would be used: only on the rule gate's `auto` band.
      const combinedTp = fresh.filter(
        row =>
          row.rule === 'force' ||
          (row.rule === 'auto' && row.route === 'search'),
      ).length;
      const combinedFp = stable.filter(
        row =>
          row.rule === 'force' ||
          (row.rule === 'auto' && row.route === 'search'),
      ).length;
      const summary = {
        family,
        n: results.length,
        unparsed: results.filter(row => !row.route).length,
        model: {
          precision: tp / Math.max(1, tp + fp),
          recall: tp / fresh.length,
        },
        rulesThenModel: {
          precision: combinedTp / Math.max(1, combinedTp + combinedFp),
          recall: combinedTp / fresh.length,
        },
        ms: {p50: percentile(times, 50), p90: percentile(times, 90)},
        promptTokensPerCall: Math.round(engine.promptTokens / engine.calls),
      };
      console.log('[m8-eval] classify', JSON.stringify(summary));
      write(`search-classify-${family}.json`, {summary, results});
    },
    1800000,
  );

  (parts.includes('answers') ? it : it.skip)(
    'answers the 50 live queries with citations',
    async () => {
      const httpGet = createCachedHttpGet(`${cacheDir}/pages`, {
        // Gentle on the engines: DuckDuckGo answered 202 after ~20 queries
        // in a minute during the first run.
        delayMs: 2500,
      });
      const service = new SearchService({
        httpGet,
        images: false,
        // The app's default chain: scraped engines, keyless You.com, Wikipedia.
        extraProviders: [youKeyless(httpGet)],
      });
      const tools = [
        createWebSearchTool(() => service),
        createReadUrlTool(() => service),
      ];
      const caps = toolCapsFor(modelName, family, 8192);
      // What the selection provider adds while web tools are offered.
      const system = [
        buildSystemPrompt({family, now, hasTools: true}),
        ...(caps.citeRule ? [CITE_SYSTEM_RULE] : []),
      ].join('\n\n');
      const judge = judgePort
        ? createEvalEngine(judgePort, {seed: 7, temperature: 0})
        : null;
      const records = await pool(QUERIES, 3, async (item, index) => {
        const turnId = `live-${family}-${index}`;
        const engine = createEvalEngine(port, {
          ...SAMPLING[family],
          seed: 42,
          n_predict: 600,
        });
        const verdict = decideSearch({
          userText: item.question,
          knowledgeCutoff: knowledgeCutoffFor(modelName),
        });
        const started = Date.now();
        const turn = await runToolTurn({
          engine,
          messages: [
            {role: 'system', content: system},
            {role: 'user', content: item.question},
          ],
          tools,
          params: {enable_thinking: false} as never,
          policy: {
            ...LOOP_POLICY.B,
            maxSteps: caps.maxSteps,
            maxCallsPerStep: caps.parallelCalls,
          },
          context: {now, nCtx: 8192, userText: item.question, turnId},
          turnId,
          resultChars: 8000,
          searchVerdict: verdict,
          directSearch: caps.directSearch,
          directQueries: () =>
            buildQueries({userText: item.question, now}).queries,
        });
        const registry = registryForTurn(turnId);
        const cited = buildCitedAnswer(turn.text, registry);
        // The same text before the grounding check, for the judge.
        const before = validateMarkers(
          normalizeMarkers(turn.text),
          registry.sources.map(source => source.n),
        );
        const grounded = applyGrounding(before.text, registry.evidence());
        const kept = citedClaims(grounded.text);
        const removed = grounded.removedClaims;
        const claims: Array<{
          claim: string;
          sources: number[];
          kept: boolean;
          missing?: string[];
          attached: boolean;
          supported: boolean | null;
        }> = citedClaims(before.text).map(claim => ({
          ...claim,
          kept: !removed.includes(claim.claim),
          missing: grounded.missing[removed.indexOf(claim.claim)],
          attached: false,
          supported: null,
        }));
        if (kept.length === 0) {
          const added = attachCitations(grounded.text, registry.evidence());
          for (const attachment of added.attached) {
            claims.push({
              claim: attachment.claim,
              sources: [attachment.source],
              kept: true,
              attached: true,
              supported: null,
            });
          }
        }
        if (judge) {
          const evidence = registry.evidence();
          for (const claim of claims) {
            const passage = claim.sources
              .map(number => evidence[number] ?? '')
              .join('\n---\n')
              .slice(0, 6000);
            try {
              const verdictJson = await judge.completion({
                messages: [
                  {
                    role: 'system',
                    content:
                      'You check citations. Given a SOURCE text and a CLAIM, decide whether the source text states the claim. "supported": every fact of the claim is stated in the source (paraphrase is fine). "partial": the main fact is stated but a detail (a number, date, name, qualifier) is not. "unsupported": the source does not state it. Judge only from the source text.',
                  },
                  {
                    role: 'user',
                    content: `SOURCE:\n${passage}\n\nCLAIM:\n${claim.claim}`,
                  },
                ],
                n_predict: 20,
                response_format: {
                  type: 'json_schema',
                  json_schema: {
                    name: 'verdict',
                    strict: true,
                    schema: {
                      type: 'object',
                      properties: {
                        label: {
                          type: 'string',
                          enum: ['supported', 'partial', 'unsupported'],
                        },
                      },
                      required: ['label'],
                      additionalProperties: false,
                    },
                  },
                },
              } as never);
              const label = /"label"\s*:\s*"(\w+)"/.exec(
                verdictJson.content ?? '',
              )?.[1];
              (claim as any).label = label;
              claim.supported = label === 'supported';
            } catch {
              claim.supported = null;
            }
          }
        }
        return {
          ...item,
          verdict: `${verdict.decision}/${verdict.reason}`,
          searched: turn.calls.some(
            call => call.name === 'web_search' && call.status === 'ok',
          ),
          forced: turn.flags.forcedSearch,
          engines: [
            ...new Set(
              registry.sources.map(source => source.engine).filter(Boolean),
            ),
          ],
          calls: turn.calls.map(
            call =>
              `${call.name}:${call.status}${call.synthetic ? ':forced' : ''}`,
          ),
          sources: registry.size,
          fetched: registry.sources.filter(source => source.fetched).length,
          stats: cited.stats,
          keptClaims: kept.length,
          claims,
          answer: turn.text,
          answerChars: turn.text.length,
          rawUrls: (turn.text.match(/https?:\/\/\S+/g) ?? []).length,
          steps: turn.steps,
          ms: {
            total: Date.now() - started,
            model: turn.timings.modelMs,
            tools: turn.timings.toolMs,
          },
          promptTokens: turn.timings.promptTokens,
          generatedTokens: turn.timings.generatedTokens,
        };
      });
      const searched = records.filter(record => record.searched);
      const withSources = records.filter(record => record.sources > 0);
      const allClaims = records.flatMap(record => record.claims);
      const judgedAll = allClaims.filter(claim => claim.supported !== null);
      const attachedJudged = judgedAll.filter(claim => claim.attached);
      const judged = judgedAll.filter(claim => !claim.attached);
      const keptJudged = judged.filter(claim => claim.kept);
      const removedJudged = judged.filter(claim => !claim.kept);
      const share = (list: any[], test: (item: any) => boolean) =>
        list.length
          ? Number((list.filter(test).length / list.length).toFixed(3))
          : null;
      const summary = {
        family,
        n: records.length,
        searched: searched.length,
        forced: records.filter(record => record.forced).length,
        withSources: withSources.length,
        meanSources: Number(
          (
            withSources.reduce((sum, record) => sum + record.sources, 0) /
            Math.max(1, withSources.length)
          ).toFixed(2),
        ),
        meanPagesRead: Number(
          (
            withSources.reduce((sum, record) => sum + record.fetched, 0) /
            Math.max(1, withSources.length)
          ).toFixed(2),
        ),
        citation: {
          answersWithMarker: share(
            withSources,
            record => record.stats.written > 0,
          ),
          answersWithPillAfterCheck: share(
            withSources,
            record => record.stats.distinctSources > 0,
          ),
          answersWithTwoSources: share(
            withSources,
            record => record.stats.distinctSources >= 2,
          ),
          markersWritten: withSources.reduce(
            (sum, record) => sum + record.stats.written,
            0,
          ),
          outOfRange: withSources.reduce(
            (sum, record) => sum + record.stats.outOfRange,
            0,
          ),
          checked: withSources.reduce(
            (sum, record) => sum + record.stats.checked,
            0,
          ),
          attachedByApp: withSources.reduce(
            (sum, record) => sum + record.stats.attached,
            0,
          ),
          removedByCheck: withSources.reduce(
            (sum, record) => sum + record.stats.ungrounded,
            0,
          ),
          answersWithRawUrl: records.filter(record => record.rawUrls > 0)
            .length,
        },
        judge: judge
          ? {
              claims: judged.length,
              supportedBeforeCheck: share(judged, claim => claim.supported),
              supportedAfterCheck: share(keptJudged, claim => claim.supported),
              keptClaims: keptJudged.length,
              removedClaims: removedJudged.length,
              removedThatWereUnsupported: share(
                removedJudged,
                claim => !claim.supported,
              ),
              attachedClaims: attachedJudged.length,
              attachedSupported: share(
                attachedJudged,
                claim => claim.supported,
              ),
              supportedPillsShown: share(
                [...keptJudged, ...attachedJudged],
                claim => claim.supported,
              ),
              supportedClaimsKept: share(
                judged.filter(claim => claim.supported),
                claim => claim.kept,
              ),
            }
          : null,
        ms: {
          totalP50: percentile(
            records.map(record => record.ms.total),
            50,
          ),
          totalP90: percentile(
            records.map(record => record.ms.total),
            90,
          ),
          toolsP50: percentile(
            searched.map(record => record.ms.tools),
            50,
          ),
          toolsP90: percentile(
            searched.map(record => record.ms.tools),
            90,
          ),
          modelP50: percentile(
            records.map(record => record.ms.model),
            50,
          ),
        },
        meanPromptTokens: Math.round(
          records.reduce((sum, record) => sum + record.promptTokens, 0) /
            records.length,
        ),
        httpLive: httpGet.live,
        httpCached: httpGet.cached,
      };
      console.log('[m8-eval] answers', JSON.stringify(summary));
      write(`search-answers-${family}.json`, {summary, records});
      expect(records.length).toBe(QUERIES.length);
    },
    3600000,
  );
});
