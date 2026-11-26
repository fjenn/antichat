/**
 * Head-to-head of the three ways to fill memory (gap analysis E4), on real
 * models:
 *   ours  — our extraction prompt over the user's messages of a finished chat;
 *   mem0  — mem0's unmodified fact-extraction prompt over the same chat;
 *   tool  — no background pass: the chat model has `save_memory` /
 *           `forget_memory` and decides during the chat (`tool-hint`: with
 *           the one-line reminder the memory provider adds).
 * `ours` and `mem0` are scored twice: `-raw` writes what the prompt
 * returned, the plain name runs the facts through `screenFacts` (the code
 * that enforces the privacy rules) first. Everything is written through
 * the same `MemoryWriter`, so only the source of the facts differs.
 *
 * Skipped unless ANTICHAT_MEMORY_EVAL is set, e.g.
 *   ANTICHAT_MEMORY_EVAL="gemma4:18891,lfm3:18892" \
 *   ANTICHAT_MEMORY_EVAL_OUT=/tmp/m9-eval.json \
 *   yarn jest extraction.eval --coverage=false
 * with one `llama-server --jinja` per port. Optional:
 *   ANTICHAT_MEMORY_EVAL_APPROACHES=ours,mem0,tool
 *   ANTICHAT_MEMORY_EVAL_CASES=<regex on case ids>
 *   ANTICHAT_MEMORY_EVAL_SET=holdout            (the 16 held-out cases)
 *   ANTICHAT_MEMORY_EVAL_STYLE=examples|rules   (prompt layout for `ours`)
 * The numbers in docs/antichat/m9-eval.md come from this file.
 */
import fs from 'fs';

import {createServerEngine} from '../../../context/__tests__/support/llamaServer';
import type {ModelFamily} from '../../../prompt/modelFamily';
import {createSystemPromptProvider} from '../../../prompt/provider';
import {
  clearRequestProviders,
  registerRequestProvider,
} from '../../../prompt/registry';
import type {ChatMessage} from '../../../prompt/types';
import {runUtilityCompletion} from '../../../prompt/utility';
import {
  extractFacts,
  parseExtraction,
  screenFacts,
  type ExtractedFact,
  type ExtractionStyle,
} from '../../extraction';
import {createMemoryProvider} from '../../provider';
import {memoryBudgetFor} from '../../retrieval';
import {createForgetMemoryTool, createSaveMemoryTool} from '../../tools';
import {relatedMemories, type ModelAccess} from '../../writer';
import {sendTurn} from '../support/chatLoop';
import {
  createMemoryHarness,
  type MemoryHarness,
} from '../support/memoryHarness';
import {EXTRACTION_SET, type EvalCase} from './extractionSet';
import {HOLDOUT_SET} from './holdoutSet';
import {mem0SystemPrompt, mem0UserPrompt} from './mem0Prompt';
import {scoreCase, totals, type CaseScore, type FinalMemory} from './score';

const targets = (process.env.ANTICHAT_MEMORY_EVAL ?? '')
  .split(',')
  .filter(Boolean)
  .map(entry => {
    const [family, port] = entry.split(':');
    return {family: family as ModelFamily, port: Number(port)};
  });
const approaches = (
  process.env.ANTICHAT_MEMORY_EVAL_APPROACHES ?? 'ours,mem0,tool,tool-hint'
).split(',');
const caseFilter = process.env.ANTICHAT_MEMORY_EVAL_CASES
  ? new RegExp(process.env.ANTICHAT_MEMORY_EVAL_CASES)
  : null;
const SET =
  process.env.ANTICHAT_MEMORY_EVAL_SET === 'holdout'
    ? HOLDOUT_SET
    : EXTRACTION_SET;
const cases = SET.filter(c => !caseFilter || caseFilter.test(c.id));
const NOW = new Date(2026, 10, 24, 14, 5);

const MEM0_SCHEMA = {
  type: 'object',
  properties: {facts: {type: 'array', items: {type: 'string'}}},
  required: ['facts'],
};

async function seeded(testCase: EvalCase): Promise<{
  harness: MemoryHarness;
  seeds: Map<string, string>;
}> {
  const harness = await createMemoryHarness();
  const seeds = new Map<string, string>();
  for (const text of testCase.seed ?? []) {
    const item = await harness.store.add(
      {text, origin: 'user', kind: 'profile'},
      {silent: true},
    );
    seeds.set(item!.id, item!.text);
  }
  return {harness, seeds};
}

async function finalState(
  harness: MemoryHarness,
  seeds: Map<string, string>,
): Promise<FinalMemory[]> {
  return (await harness.store.list()).map(item => ({
    text: item.text,
    unchangedSeed: seeds.get(item.id) === item.text,
  }));
}

/** Writes `facts` through the shared pipeline and scores the result. */
async function applyAndScore(
  testCase: EvalCase,
  facts: ExtractedFact[],
  model: ModelAccess,
): Promise<CaseScore & {memories: string[]}> {
  const {harness, seeds} = await seeded(testCase);
  try {
    for (const fact of facts) {
      await harness.writer.save(
        {
          text: fact.text,
          kind: fact.kind,
          origin: 'extraction',
          explicit: fact.explicit,
          sensitive: fact.sensitive,
        },
        model,
      );
    }
    const final = await finalState(harness, seeds);
    return {
      ...scoreCase(testCase, final),
      memories: final.map(memory => memory.text),
    };
  } finally {
    harness.close();
  }
}

interface ApproachReport {
  totals: ReturnType<typeof totals>;
  byCategory: Record<string, ReturnType<typeof totals>>;
  cases: Array<CaseScore & {memories: string[]; extra?: unknown}>;
  seconds: number;
}

function report(
  scores: Array<CaseScore & {memories: string[]; extra?: unknown}>,
  seconds: number,
): ApproachReport {
  const byCategory: ApproachReport['byCategory'] = {};
  for (const category of new Set(scores.map(score => score.category))) {
    byCategory[category] = totals(
      scores.filter(score => score.category === category),
    );
  }
  return {totals: totals(scores), byCategory, cases: scores, seconds};
}

const suite = targets.length
  ? describe.each(targets)
  : describe.skip.each([{family: 'generic' as ModelFamily, port: 0}]);

suite('memory extraction head-to-head on $family', ({family, port}) => {
  const engine = createServerEngine(port);
  const model: ModelAccess = {engine, family};
  const out: Record<string, unknown> = {
    family,
    cases: cases.length,
    tag: process.env.ANTICHAT_MEMORY_EVAL_TAG ?? '',
  };

  afterAll(() => {
    const path = process.env.ANTICHAT_MEMORY_EVAL_OUT;
    if (path) {
      fs.writeFileSync(
        path.replace(/\.json$/, `-${family}.json`),
        JSON.stringify(out, null, 1),
      );
    }
    const summary = Object.entries(out)
      .filter(([, value]) => (value as ApproachReport)?.totals)
      .map(([name, value]) => {
        const t = (value as ApproachReport).totals;
        return `${family} ${name.padEnd(9)} P ${t.precision.toFixed(2)} R ${t.recall.toFixed(2)} F1 ${t.f1.toFixed(2)} | written ${t.written} correct ${t.correct} forbidden ${t.forbidden} stale ${t.stale} spurious ${t.spurious} redundant ${t.redundant} lost ${t.lost} clean ${t.cleanCases}/${t.cases}`;
      });

    console.log(summary.join('\n'));
  });

  (approaches.includes('ours') ? it : it.skip)(
    'ours',
    async () => {
      const started = Date.now();
      const raw: Array<CaseScore & {memories: string[]; extra?: unknown}> = [];
      const screened: typeof raw = [];
      for (const testCase of cases) {
        const turns = testCase.turns.map(turn => turn.user);
        // What the writer would show the prompt: related saved memories.
        const before = await seeded(testCase);
        const known = await relatedMemories(before.harness.store, turns);
        before.harness.close();
        const extraction = await extractFacts({
          engine,
          family,
          turns,
          known,
          style: process.env.ANTICHAT_MEMORY_EVAL_STYLE as
            | ExtractionStyle
            | undefined,
        });
        raw.push({
          ...(await applyAndScore(testCase, extraction.raw, model)),
          extra: {facts: extraction.raw},
        });
        screened.push({
          ...(await applyAndScore(testCase, extraction.facts, model)),
          extra: {facts: extraction.facts},
        });
      }
      const seconds = (Date.now() - started) / 1000;
      out['ours-raw'] = report(raw, seconds);
      out.ours = report(screened, seconds);
    },
    3_600_000,
  );

  (approaches.includes('mem0') ? it : it.skip)(
    'mem0 unmodified',
    async () => {
      const started = Date.now();
      const raw: Array<CaseScore & {memories: string[]; extra?: unknown}> = [];
      const screened: typeof raw = [];
      for (const testCase of cases) {
        const messages: ChatMessage[] = [
          {role: 'system', content: mem0SystemPrompt('2026-11-24')},
          {role: 'user', content: mem0UserPrompt(testCase.turns)},
        ];
        const result = await runUtilityCompletion({
          engine,
          family,
          messages,
          maxTokens: 400,
          temperature: 0,
          jsonSchema: {name: 'facts', schema: MEM0_SCHEMA},
          timeoutMs: 120000,
        });
        const facts = parseExtraction(result?.text ?? '');
        raw.push({
          ...(await applyAndScore(testCase, facts, model)),
          extra: {facts},
        });
        const kept = screenFacts(facts, {
          turns: testCase.turns.map(turn => turn.user),
          maxFacts: 20,
        });
        screened.push({
          ...(await applyAndScore(testCase, kept, model)),
          extra: {facts: kept},
        });
      }
      const seconds = (Date.now() - started) / 1000;
      out['mem0-raw'] = report(raw, seconds);
      out.mem0 = report(screened, seconds);
    },
    3_600_000,
  );

  const toolArms = [
    {name: 'tool', hint: false},
    {name: 'tool-hint', hint: true},
  ].filter(arm => approaches.includes(arm.name));

  (toolArms.length
    ? it.each(toolArms)
    : it.skip.each(toolArms.concat([{name: 'tool', hint: false}])))(
    '$name: tools only, no background pass',
    async ({name, hint}) => {
      const started = Date.now();
      const nCtx = family === 'lfm3' ? 4096 : 8192;
      const scores: Array<CaseScore & {memories: string[]; extra?: unknown}> =
        [];
      for (const testCase of cases) {
        const {harness, seeds} = await seeded(testCase);
        clearRequestProviders();
        registerRequestProvider(
          createSystemPromptProvider({personalization: () => null}),
        );
        registerRequestProvider(
          createMemoryProvider({
            store: harness.store,
            resolveChat: async sessionId => ({
              sessionId,
              temporary: false,
              scope: {},
              isolatedProjectIds: [],
            }),
            // Only the two write tools: this arm measures saving.
            budget: n => ({...memoryBudgetFor(n), searchChats: false}),
            toolHint: hint,
          }),
        );
        let userText = '';
        const toolOptions = {
          store: harness.store,
          writer: harness.writer,
          context: () => ({sessionId: testCase.id, scope: {}, userText}),
        };
        const tools = [
          createSaveMemoryTool(toolOptions),
          createForgetMemoryTool(toolOptions),
        ];
        let history: ChatMessage[] = [];
        const log: unknown[] = [];
        try {
          for (const turn of testCase.turns) {
            userText = turn.user;
            try {
              const sent = await sendTurn({
                engine,
                family,
                nCtx,
                history,
                userText: turn.user,
                session: {id: testCase.id},
                tools,
                now: NOW,
                maxTokens: 300,
              });
              history = sent.history;
              log.push({
                user: turn.user,
                reply: sent.reply.slice(0, 300),
                calls: sent.toolCalls,
              });
            } catch (error) {
              // A malformed tool call fails the turn, as it would on device.
              history = [
                ...history,
                {role: 'user', content: turn.user},
                {role: 'assistant', content: turn.assistant},
              ];
              log.push({user: turn.user, error: String(error).slice(0, 200)});
            }
          }
          const final = await finalState(harness, seeds);
          scores.push({
            ...scoreCase(testCase, final),
            memories: final.map(memory => memory.text),
            extra: {log},
          });
        } finally {
          clearRequestProviders();
          harness.close();
        }
      }
      out[name] = report(scores, (Date.now() - started) / 1000);
    },
    3_600_000,
  );
});
