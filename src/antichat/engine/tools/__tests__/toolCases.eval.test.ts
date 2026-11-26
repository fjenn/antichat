/**
 * Real-model run of the 30 tool cases, before and after the harness.
 *
 * Skipped unless ANTICHAT_EVAL is set, e.g.
 *   ANTICHAT_EVAL="gemma4:18801,lfm3:18802,qwen35:18803" \
 *   ANTICHAT_EVAL_MODES=baseline,harness ANTICHAT_EVAL_OUT=/tmp/m8 \
 *   yarn jest toolCases.eval --coverage=false
 * with one `llama-server --jinja -np 4` per port. `baseline` is the bare
 * native tool loop of the Mac spike (strict JSON, strict schema, no guards);
 * `harness` sends every case through `prepareRequest` with the tool
 * selection provider and then through `runToolTurn`. Results are written as
 * JSON; the numbers in docs/antichat/m8-eval.md come from these files.
 */
import fs from 'fs';

import type {ModelFamily} from '../../prompt/modelFamily';
import {
  clearRequestProviders,
  prepareRequest,
  registerRequestProvider,
} from '../../prompt/registry';
import type {ChatMessage} from '../../prompt/types';
import {buildQueries} from '../../search/query';
import {ToolCatalog} from '../catalog';
import {LOOP_POLICY} from '../loopGuard';
import {runToolTurn, type TurnOptions} from '../runner';
import {createToolSelectionProvider, type ToolsMeta} from '../selection';
import {toolCapsFor} from '../toolCaps';
import type {AntichatTool} from '../types';
import {
  MODEL_NAMES,
  SAMPLING,
  createEvalEngine,
  percentile,
  pool,
} from './support/server';
import {
  CASES,
  CASE_NOW,
  CASE_SYSTEM,
  CASE_TOOLS,
  CaseJudge,
  MARKUP,
  gateOf,
  historyMessages,
  mockTools,
  strictSchemaError,
  type FailureClass,
  type ToolCase,
} from './support/toolCases';

const targets = (process.env.ANTICHAT_EVAL ?? '')
  .split(',')
  .filter(Boolean)
  .map(entry => {
    const [family, port] = entry.split(':');
    return {family: family as ModelFamily, port: Number(port)};
  });
const modes = (process.env.ANTICHAT_EVAL_MODES ?? 'baseline,harness').split(
  ',',
);
const seeds = (process.env.ANTICHAT_EVAL_SEEDS ?? '42,43,44')
  .split(',')
  .map(Number);
const only = (process.env.ANTICHAT_EVAL_CASES ?? '').split(',').filter(Boolean);
const disable = (process.env.ANTICHAT_EVAL_DISABLE ?? '')
  .split(',')
  .filter(Boolean);
const outDir = process.env.ANTICHAT_EVAL_OUT;
const MAX_TURNS = 6;

interface Record_ {
  id: string;
  category: string;
  seed: number;
  passed: boolean;
  failure?: FailureClass;
  detail?: string;
  calls: Array<{name: string; args: unknown}>;
  final: string;
  steps: number;
  wallMs: number;
  modelMs?: number;
  promptTokens?: number;
  generatedTokens?: number;
  flags?: Record<string, unknown>;
  verdict?: string;
}

/** The spike's base variant: native tools, strict checks, no guards. */
async function runBaseline(
  port: number,
  family: ModelFamily,
  testCase: ToolCase,
  seed: number,
): Promise<Record_> {
  const engine = createEvalEngine(port, {
    ...SAMPLING[family],
    seed,
    n_predict: 768,
  });
  const judge = new CaseJudge(testCase);
  const schemas = Object.fromEntries(
    CASE_TOOLS.map(tool => [tool.function.name, tool.function.parameters]),
  );
  const messages: any[] = [
    {role: 'system', content: CASE_SYSTEM},
    ...historyMessages(testCase),
    {role: 'user', content: testCase.user},
  ];
  const started = Date.now();
  const record: Record_ = {
    id: testCase.id,
    category: testCase.category,
    seed,
    passed: false,
    calls: judge.calls,
    final: '',
    steps: 0,
    wallMs: 0,
  };
  const done = (verdict: {
    passed: boolean;
    failure?: FailureClass;
    detail?: string;
  }) => ({
    ...record,
    ...verdict,
    wallMs: Date.now() - started,
    promptTokens: engine.promptTokens,
    generatedTokens: engine.generatedTokens,
  });
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    record.steps = turn + 1;
    let result;
    try {
      result = await engine.completion({
        messages,
        tools: CASE_TOOLS,
        tool_choice: 'auto',
      } as never);
    } catch (error) {
      const message = (error as Error).message;
      return done({
        passed: false,
        failure: /parse/i.test(message) ? 'malformed' : 'error',
        detail: message.slice(0, 200),
      });
    }
    const calls = (result.tool_calls ?? []) as any[];
    const content = result.content ?? '';
    if (calls.length === 0) {
      record.final = content;
      if (
        MARKUP.test(content) &&
        judge.pending.length > 0 &&
        /tool_call|<function=|call:/.test(content)
      ) {
        return done({
          passed: false,
          failure: 'malformed',
          detail: content.slice(0, 200),
        });
      }
      return done(judge.verdict(content));
    }
    messages.push({role: 'assistant', content, tool_calls: calls});
    for (const call of calls) {
      const name = call.function?.name;
      let args: any = null;
      try {
        args =
          typeof call.function?.arguments === 'string'
            ? JSON.parse(call.function.arguments)
            : call.function?.arguments;
      } catch {
        args = null;
      }
      if (!(name in schemas)) {
        return done({
          passed: false,
          failure: 'wrong_tool',
          detail: `unknown tool ${name}`,
        });
      }
      if (args === null) {
        return done({
          passed: false,
          failure: 'malformed',
          detail: 'arguments not JSON',
        });
      }
      const schemaError = strictSchemaError(args, schemas[name]);
      if (schemaError) {
        return done({
          passed: false,
          failure: 'wrong_args',
          detail: `schema: ${name}: ${schemaError}`,
        });
      }
      const mock = judge.onCall(name, args);
      if (judge.failure) {
        return done({
          passed: false,
          failure: judge.failure.kind,
          detail: judge.failure.detail,
        });
      }
      messages.push({role: 'tool', tool_call_id: call.id, name, content: mock});
    }
  }
  return done({
    passed: false,
    failure: 'runaway',
    detail: `no final answer within ${MAX_TURNS} turns`,
  });
}

// One catalogue for all harness runs; each tool finds its judge by turn id.
const judges = new Map<string, CaseJudge>();
const sharedCatalog = new ToolCatalog();
CASE_TOOLS.forEach(definition => {
  const name: string = definition.function.name;
  sharedCatalog.register({
    ...mockTools(new CaseJudge(CASES[0])).find(tool => tool.name === name)!,
    async execute(args, context) {
      const judge = judges.get(context.turnId ?? '');
      return {text: judge ? judge.onCall(name, args) : '{"error":"no judge"}'};
    },
  } as AntichatTool);
});

let runCounter = 0;

async function runHarness(
  port: number,
  family: ModelFamily,
  testCase: ToolCase,
  seed: number,
): Promise<Record_> {
  const engine = createEvalEngine(port, {
    ...SAMPLING[family],
    seed,
    n_predict: 768,
  });
  const judge = new CaseJudge(testCase);
  const modelName = MODEL_NAMES[family];
  const started = Date.now();
  const history = historyMessages(testCase) as ChatMessage[];
  const prepared = await prepareRequest({
    messages: [
      {role: 'system', content: CASE_SYSTEM},
      ...history,
      {role: 'user', content: testCase.user},
    ],
    session: {id: `case-${testCase.id}-${seed}-${runCounter++}`},
    tools: [],
    params: {},
    runtime: {nCtx: 8192, family, modelName, deviceClass: 'B', now: CASE_NOW},
  });
  const meta = prepared.meta.tools as ToolsMeta;
  judges.set(meta.turnId, judge);
  const caps = toolCapsFor(modelName, family, 8192);
  const offered = meta.selected
    .map(name => sharedCatalog.get(name))
    .filter((tool): tool is AntichatTool => !!tool);
  const previous = history
    .filter(message => message.role === 'user')
    .map(message => String(message.content));
  let result;
  try {
    result = await runToolTurn({
      engine,
      messages: prepared.messages,
      tools: offered,
      params: {enable_thinking: false} as TurnOptions['params'],
      policy: {
        ...LOOP_POLICY.B,
        maxSteps: caps.maxSteps,
        maxCallsPerStep: caps.parallelCalls,
      },
      context: {now: CASE_NOW, nCtx: 8192, userText: testCase.user},
      turnId: meta.turnId,
      resultChars: caps.resultChars,
      searchVerdict: meta.verdict,
      directSearch: caps.directSearch && !disable.includes('directSearch'),
      directQueries: () =>
        buildQueries({
          userText: testCase.user,
          previousUserTexts: previous,
          now: CASE_NOW,
        }).queries,
      disable: [
        ...disable.filter(
          item => item !== 'directSearch' && item !== 'dateTable',
        ),
        ...(caps.softWithhold ? [] : ['softWithhold']),
      ] as TurnOptions['disable'],
    });
  } finally {
    judges.delete(meta.turnId);
  }
  const verdict =
    result.stopReason === 'runaway'
      ? {
          passed: false,
          failure: 'runaway' as FailureClass,
          detail: result.text.slice(-160),
        }
      : result.stopReason === 'error'
        ? {
            passed: false,
            failure: 'error' as FailureClass,
            detail: result.error,
          }
        : judge.verdict(result.text);
  return {
    id: testCase.id,
    category: testCase.category,
    seed,
    ...verdict,
    calls: judge.calls,
    final: result.text,
    steps: result.steps,
    wallMs: Date.now() - started,
    modelMs: result.timings.modelMs,
    promptTokens: engine.promptTokens,
    generatedTokens: engine.generatedTokens,
    flags: {
      ...result.flags,
      statuses: result.calls.map(
        call =>
          `${call.name}:${call.status}${call.synthetic ? ':forced' : ''}${call.fromText ? ':text' : ''}`,
      ),
    },
    verdict: `${meta.verdict.decision}/${meta.verdict.reason}`,
  };
}

function summarise(records: Record_[]) {
  const byCategory: Record<string, {passed: number; total: number}> = {};
  const failures: Record<string, number> = {};
  for (const record of records) {
    const row = (byCategory[record.category] ??= {passed: 0, total: 0});
    row.total += 1;
    if (record.passed) {
      row.passed += 1;
    } else {
      failures[record.failure ?? 'error'] =
        (failures[record.failure ?? 'error'] ?? 0) + 1;
    }
  }
  const passed = records.filter(record => record.passed).length;
  const wall = records.map(record => record.wallMs);
  return {
    total: records.length,
    passed,
    rate: Number((passed / records.length).toFixed(3)),
    byCategory,
    failures,
    gate: gateOf(passed, byCategory, failures, records.length),
    wallMs: {p50: percentile(wall, 50), p90: percentile(wall, 90)},
    meanSteps: Number(
      (
        records.reduce((sum, record) => sum + record.steps, 0) / records.length
      ).toFixed(2),
    ),
    meanPromptTokens: Math.round(
      records.reduce((sum, record) => sum + (record.promptTokens ?? 0), 0) /
        records.length,
    ),
    failed: records
      .filter(record => !record.passed)
      .map(record => `${record.id}@${record.seed}:${record.failure}`),
  };
}

const suite = targets.length
  ? describe.each(targets)
  : describe.skip.each([{family: 'generic' as ModelFamily, port: 0}]);

suite('tool cases on $family', ({family, port}) => {
  const cases = only.length
    ? CASES.filter(testCase => only.includes(testCase.id))
    : CASES;
  const jobs = seeds.flatMap(seed => cases.map(testCase => ({testCase, seed})));

  beforeAll(() => {
    clearRequestProviders();
    registerRequestProvider(
      createToolSelectionProvider({
        catalog: sharedCatalog,
        online: () => true,
        directSearch: false,
        dateTable: !disable.includes('dateTable'),
      }),
    );
  });
  afterAll(() => clearRequestProviders());

  it.each(modes)(
    '%s',
    async mode => {
      const records = await pool(jobs, 4, ({testCase, seed}) =>
        (mode === 'baseline' ? runBaseline : runHarness)(
          port,
          family,
          testCase,
          seed,
        ).catch(
          (error): Record_ => ({
            id: testCase.id,
            category: testCase.category,
            seed,
            passed: false,
            failure: 'error',
            detail: String(error?.message ?? error).slice(0, 200),
            calls: [],
            final: '',
            steps: 0,
            wallMs: 0,
          }),
        ),
      );
      const summary = summarise(records);
      const tag = disable.length ? `${mode}-no-${disable.join('-')}` : mode;
      console.log(`[m8-eval] ${family} ${tag}`, JSON.stringify(summary));
      if (outDir) {
        fs.mkdirSync(outDir, {recursive: true});
        fs.writeFileSync(
          `${outDir}/toolcases-${family}-${tag}.json`,
          JSON.stringify({family, mode: tag, seeds, summary, records}, null, 1),
        );
      }
      expect(records.length).toBe(jobs.length);
    },
    1800000,
  );
});
