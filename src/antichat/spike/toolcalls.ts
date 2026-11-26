/**
 * Runs docs/research/spike/toolcall-cases.json against a loaded llama.rn
 * context in two modes (protocol step 2):
 *   native - messages + tools, llama.cpp's own template parser / lazy grammar
 *   router - no tools; every turn is forced through a JSON schema
 * Tool results are the scripted mock_result values, so no network is needed.
 */
import type {LlamaContext} from 'llama.rn';

import cases from '../../../docs/research/spike/toolcall-cases.json';

export type ToolMode = 'native' | 'router';

export type FailureClass =
  | 'malformed'
  | 'wrong_tool'
  | 'wrong_args'
  | 'extra_call'
  | 'missing_call'
  | 'called_when_not_needed'
  | 'bad_final'
  | 'runaway'
  | 'leaked_markup'
  | 'error';

type Checks = Record<string, any>;
type Step = {
  expect_tool: string;
  arg_checks?: Record<string, Checks>;
  mock_result: unknown;
};
type Case = {
  id: string;
  category: string;
  user: string;
  steps: Step[];
  final: Checks;
  history?: any[];
  notes?: string;
};
type Call = {name: string; arguments: string};

export type CaseResult = {
  id: string;
  category: string;
  pass: boolean;
  failure?: FailureClass;
  detail?: string;
  note?: string;
  calls: Array<{name: string; arguments: unknown}>;
  final_text: string;
  turns: number;
  prompt_tokens: number;
  generated_tokens: number;
  ttft_ms: number | null;
  wall_ms: number;
};

export type ToolRunSummary = {
  mode: ToolMode;
  total: number;
  passed: number;
  by_category: Record<string, {passed: number; total: number}>;
  failures: Record<string, number>;
  mean_seconds_per_case: number;
  mean_generated_tokens_per_case: number;
  gate: 'default_eligible' | 'tools_limited' | 'chat_only' | 'partial_run';
  cases: CaseResult[];
};

const TOOLS: any[] = (cases as any).tools;
const SETTINGS = (cases as any).run_settings;
const SYSTEM_PROMPT: string = (cases as any).system_prompt;
const TOOL_SCHEMAS: Record<string, any> = Object.fromEntries(
  TOOLS.map(t => [t.function.name, t.function.parameters]),
);

const MARKUP =
  /<\/?tool_call>|<\|tool_call|<tool_response>|<\/?think>|<start_function_call>|<function=|\[TOOL_CALLS\]|<\|python_tag\|>|<\|im_start\|>|<start_of_turn>/i;

/**
 * Drops a leading, closed think block. Qwen-style templates emit an empty one
 * even with thinking off, and the app would never show it; anything else that
 * matches MARKUP still counts as a leak.
 */
export function stripThinkBlock(text: string): string {
  return text.replace(/^\s*<think>[\s\S]*?<\/think>/i, '').trim();
}

export const toolTestAssets = {tools: TOOLS, systemPrompt: SYSTEM_PROMPT};

// ---------------------------------------------------------------- arg checks

const asText = (v: unknown) =>
  typeof v === 'string' ? v : JSON.stringify(v ?? '');
const isoParts = (v: unknown) => {
  const m = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}))?/.exec(asText(v).trim());
  return m ? {date: m[1], time: m[2]} : undefined;
};

/** Returns an error string, or undefined when every op holds. */
function checkValue(value: unknown, checks: Checks): string | undefined {
  if (value === undefined || value === null) {
    return checks.optional ? undefined : 'missing';
  }
  const text = asText(value);
  const lower = text.toLowerCase();
  for (const [op, want] of Object.entries(checks)) {
    let ok = true;
    switch (op) {
      case 'optional':
        break;
      case 'equals':
        ok = text.trim() === String(want).trim();
        break;
      case 'regex':
        ok = new RegExp(want).test(text);
        break;
      case 'contains_any':
        ok = want.some((w: string) => text.includes(w));
        break;
      case 'contains_all':
        ok = want.every((w: string) => text.includes(w));
        break;
      case 'icontains_any':
        ok = want.some((w: string) => lower.includes(w.toLowerCase()));
        break;
      case 'icontains_all':
        ok = want.every((w: string) => lower.includes(w.toLowerCase()));
        break;
      case 'date_equals':
        ok = isoParts(value)?.date === want;
        break;
      case 'date_in':
        ok = want.includes(isoParts(value)?.date);
        break;
      case 'datetime_equals': {
        const got = isoParts(value);
        const exp = isoParts(want);
        ok = !!got && !!exp && got.date === exp.date && got.time === exp.time;
        break;
      }
      case 'array_equals': {
        const norm = (a: unknown[]) =>
          a.map(x => String(x).trim().toLowerCase()).sort();
        ok =
          Array.isArray(value) &&
          JSON.stringify(norm(value)) === JSON.stringify(norm(want));
        break;
      }
      case 'int_range':
        ok =
          Number.isInteger(value) &&
          (value as number) >= want[0] &&
          (value as number) <= want[1];
        break;
      case 'min_chars':
        ok = text.trim().length >= want;
        break;
      case 'must_not_call':
      case 'max_extra_tool_calls':
        break;
      default:
        return `unknown op ${op}`;
    }
    if (!ok) {
      return `${op} failed (got ${text.slice(0, 120)})`;
    }
  }
  return undefined;
}

function checkArgs(
  args: Record<string, unknown>,
  step: Step,
): string | undefined {
  for (const [name, checks] of Object.entries(step.arg_checks ?? {})) {
    const err = checkValue(args[name], checks);
    if (err) {
      return `${name}: ${err}`;
    }
  }
  return undefined;
}

/** Minimal JSON-schema validation for the six flat tool schemas. */
function validateAgainstSchema(args: unknown, schema: any): string | undefined {
  if (typeof args !== 'object' || args === null || Array.isArray(args)) {
    return 'arguments is not an object';
  }
  const props = schema.properties ?? {};
  for (const key of schema.required ?? []) {
    if (!(key in (args as object))) {
      return `missing required argument ${key}`;
    }
  }
  for (const [key, value] of Object.entries(args)) {
    const spec = props[key];
    if (!spec) {
      return `unknown argument ${key}`;
    }
    const ok =
      spec.type === 'string'
        ? typeof value === 'string'
        : spec.type === 'integer'
          ? Number.isInteger(value)
          : spec.type === 'number'
            ? typeof value === 'number'
            : spec.type === 'boolean'
              ? typeof value === 'boolean'
              : spec.type === 'array'
                ? Array.isArray(value)
                : true;
    if (!ok) {
      return `argument ${key} is not ${spec.type}`;
    }
  }
  return undefined;
}

// ------------------------------------------------------------- conversation

function routerSchema() {
  return {
    oneOf: [
      ...TOOLS.map(t => ({
        type: 'object',
        properties: {
          action: {const: 'call'},
          tool: {const: t.function.name},
          arguments: t.function.parameters,
        },
        required: ['action', 'tool', 'arguments'],
        additionalProperties: false,
      })),
      {
        type: 'object',
        properties: {action: {const: 'answer'}, answer: {type: 'string'}},
        required: ['action', 'answer'],
        additionalProperties: false,
      },
    ],
  };
}

function routerSystemPrompt() {
  const list = TOOLS.map(
    t =>
      `- ${t.function.name}: ${t.function.description}\n  arguments schema: ${JSON.stringify(t.function.parameters)}`,
  ).join('\n');
  return (
    `${SYSTEM_PROMPT}\n\nAvailable tools:\n${list}\n\n` +
    'Reply with exactly one JSON object and nothing else. To call a tool: ' +
    '{"action":"call","tool":"<name>","arguments":{...}}. To answer the user: ' +
    '{"action":"answer","answer":"<text>"}. Call one tool at a time; its result ' +
    'arrives in the next message starting with TOOL_RESULT.'
  );
}

function historyMessages(history: any[] | undefined, mode: ToolMode): any[] {
  const out: any[] = [];
  let n = 0;
  for (const m of history ?? []) {
    if (m.role === 'assistant' && m.tool_calls) {
      if (mode === 'native') {
        out.push({
          role: 'assistant',
          content: '',
          tool_calls: m.tool_calls.map((c: any) => ({
            type: 'function',
            id: `call_h${++n}`,
            function: {name: c.name, arguments: JSON.stringify(c.arguments)},
          })),
        });
      } else {
        const c = m.tool_calls[0];
        out.push({
          role: 'assistant',
          content: JSON.stringify({
            action: 'call',
            tool: c.name,
            arguments: c.arguments,
          }),
        });
      }
    } else if (m.role === 'tool') {
      out.push(
        mode === 'native'
          ? {
              role: 'tool',
              tool_call_id: `call_h${n}`,
              name: m.name,
              content: m.content,
            }
          : {role: 'user', content: `TOOL_RESULT ${m.name}: ${m.content}`},
      );
    } else if (m.role === 'assistant' && mode === 'router') {
      out.push({
        role: 'assistant',
        content: JSON.stringify({action: 'answer', answer: m.content}),
      });
    } else {
      out.push({role: m.role, content: m.content});
    }
  }
  return out;
}

async function runCase(
  ctx: LlamaContext,
  c: Case,
  mode: ToolMode,
  thinking: boolean,
): Promise<CaseResult> {
  const started = Date.now();
  const remaining = [...c.steps];
  const madeCalls: CaseResult['calls'] = [];
  const messages: any[] = [
    {
      role: 'system',
      content: mode === 'native' ? SYSTEM_PROMPT : routerSystemPrompt(),
    },
    ...historyMessages(c.history, mode),
    {role: 'user', content: c.user},
  ];
  const res: CaseResult = {
    id: c.id,
    category: c.category,
    pass: false,
    calls: madeCalls,
    final_text: '',
    turns: 0,
    prompt_tokens: 0,
    generated_tokens: 0,
    ttft_ms: null,
    wall_ms: 0,
  };
  const fail = (failure: FailureClass, detail?: string) => {
    res.failure = failure;
    res.detail = detail;
    res.wall_ms = Date.now() - started;
    return res;
  };
  const nPredict = thinking ? 2048 : SETTINGS.n_predict;
  let callId = 0;

  for (let turn = 1; turn <= SETTINGS.max_turns_per_case; turn++) {
    res.turns = turn;
    const t0 = Date.now();
    let firstToken: number | null = null;
    const out = await ctx.completion(
      {
        messages,
        jinja: true,
        enable_thinking: thinking,
        reasoning_format: 'auto',
        temperature: SETTINGS.temperature,
        seed: SETTINGS.seed,
        n_predict: nPredict,
        ...(mode === 'native'
          ? {tools: TOOLS, tool_choice: 'auto', parallel_tool_calls: true}
          : {
              response_format: {
                type: 'json_schema',
                json_schema: {strict: true, schema: routerSchema()},
              },
            }),
      } as any,
      () => {
        firstToken ??= Date.now() - t0;
      },
    );
    if (turn === 1) {
      res.ttft_ms = firstToken;
    }
    res.prompt_tokens += out.timings?.prompt_n ?? 0;
    res.generated_tokens +=
      out.timings?.predicted_n ?? out.tokens_predicted ?? 0;
    const text = stripThinkBlock(out.content ?? out.text ?? '');
    if (
      (out.stopped_limit ?? 0) > 0 ||
      (out.tokens_predicted ?? 0) >= nPredict
    ) {
      res.final_text = text.slice(0, 2000);
      return fail('runaway', `hit n_predict ${nPredict}`);
    }

    // Normalise this turn into tool calls or a final answer.
    let calls: Call[] = [];
    let answer = text;
    if (mode === 'native') {
      calls = (out.tool_calls ?? []).map(tc => tc.function);
    } else {
      let parsed: any;
      try {
        // Some templates echo the generation prompt before the JSON object.
        parsed = JSON.parse(text.slice(Math.max(0, text.indexOf('{'))));
      } catch {
        res.final_text = text.slice(0, 2000);
        return fail('malformed', 'router output is not JSON');
      }
      if (parsed.action === 'call') {
        calls = [
          {
            name: parsed.tool,
            arguments: JSON.stringify(parsed.arguments ?? {}),
          },
        ];
      } else {
        answer = String(parsed.answer ?? '');
      }
    }

    if (calls.length === 0) {
      res.final_text = answer.slice(0, 4000);
      if (MARKUP.test(answer)) {
        return fail('leaked_markup', answer.slice(0, 200));
      }
      if (remaining.length > 0) {
        return fail(
          'missing_call',
          `expected ${remaining.map(s => s.expect_tool).join(', ')}`,
        );
      }
      const err = checkValue(answer, c.final);
      if (err) {
        return fail('bad_final', err);
      }
      res.pass = true;
      res.wall_ms = Date.now() - started;
      return res;
    }

    const assistantCalls: any[] = [];
    const toolMessages: any[] = [];
    for (const call of calls) {
      let args: any;
      try {
        args =
          typeof call.arguments === 'string'
            ? JSON.parse(call.arguments || '{}')
            : call.arguments;
      } catch {
        madeCalls.push({name: call.name, arguments: call.arguments});
        return fail(
          'malformed',
          `arguments are not JSON: ${String(call.arguments).slice(0, 200)}`,
        );
      }
      madeCalls.push({name: call.name, arguments: args});
      const schema = TOOL_SCHEMAS[call.name];
      if (!schema) {
        return fail('malformed', `unknown tool ${call.name}`);
      }
      const schemaErr = validateAgainstSchema(args, schema);
      if (schemaErr) {
        return fail('malformed', schemaErr);
      }
      if (c.final.must_not_call) {
        return fail('called_when_not_needed', call.name);
      }
      if (remaining.length === 0) {
        return fail('extra_call', call.name);
      }
      if (remaining[0].expect_tool !== call.name) {
        return fail(
          remaining.some(s => s.expect_tool === call.name)
            ? 'missing_call'
            : 'wrong_tool',
          `expected ${remaining[0].expect_tool}, got ${call.name}`,
        );
      }
      // Order-free among consecutive steps for the same tool.
      let idx = -1;
      let argErr: string | undefined;
      for (
        let i = 0;
        i < remaining.length && remaining[i].expect_tool === call.name;
        i++
      ) {
        const err = checkArgs(args, remaining[i]);
        if (!err) {
          idx = i;
          break;
        }
        argErr ??= err;
      }
      if (idx < 0) {
        return fail('wrong_args', argErr);
      }
      let mock = remaining[idx].mock_result;
      remaining.splice(idx, 1);
      // ms-04 note: one combined query may answer both halves.
      if (c.id === 'ms-04' && remaining.length === 1) {
        const q = String(args.query ?? '').toLowerCase();
        if (q.includes('iphone 18 pro') && q.includes('pixel 11 pro')) {
          mock = {
            results: [
              ...(mock as any).results,
              ...(remaining[0].mock_result as any).results,
            ],
          };
          remaining.splice(0, 1);
          res.note = 'single combined query (pass-with-note rule)';
        }
      }
      const id = `call_${++callId}`;
      assistantCalls.push({
        type: 'function',
        id,
        function: {name: call.name, arguments: JSON.stringify(args)},
      });
      toolMessages.push(
        mode === 'native'
          ? {
              role: 'tool',
              tool_call_id: id,
              name: call.name,
              content: JSON.stringify(mock),
            }
          : {
              role: 'user',
              content: `TOOL_RESULT ${call.name}: ${JSON.stringify(mock)}`,
            },
      );
    }
    messages.push(
      mode === 'native'
        ? {
            role: 'assistant',
            content: out.content ?? '',
            tool_calls: assistantCalls,
          }
        : {role: 'assistant', content: text},
      ...toolMessages,
    );
  }
  return fail(
    'runaway',
    `no final answer within ${SETTINGS.max_turns_per_case} turns`,
  );
}

export async function runToolCases(
  ctx: LlamaContext,
  mode: ToolMode,
  opts: {
    limit?: number;
    thinking?: boolean;
    onProgress?: (line: string) => void;
  } = {},
): Promise<ToolRunSummary> {
  const all = (cases as any).cases as Case[];
  // A limited run takes a spread over the categories, not just the first ones.
  const list =
    opts.limit && opts.limit < all.length
      ? Array.from(
          {length: opts.limit},
          (_, i) => all[Math.floor((i * all.length) / opts.limit!)],
        )
      : all;
  const results: CaseResult[] = [];
  for (const c of list) {
    let r: CaseResult;
    try {
      r = await runCase(ctx, c, mode, !!opts.thinking);
    } catch (e: any) {
      r = {
        id: c.id,
        category: c.category,
        pass: false,
        failure: 'error',
        detail: String(e?.message ?? e).slice(0, 500),
        calls: [],
        final_text: '',
        turns: 0,
        prompt_tokens: 0,
        generated_tokens: 0,
        ttft_ms: null,
        wall_ms: 0,
      };
    }
    results.push(r);
    opts.onProgress?.(
      `${mode} ${c.id} ${r.pass ? 'pass' : `FAIL ${r.failure}`}`,
    );
  }

  const by: ToolRunSummary['by_category'] = {};
  const failures: Record<string, number> = {};
  for (const r of results) {
    by[r.category] ??= {passed: 0, total: 0};
    by[r.category].total++;
    if (r.pass) {
      by[r.category].passed++;
    } else {
      failures[r.failure!] = (failures[r.failure!] ?? 0) + 1;
    }
  }
  const passed = results.filter(r => r.pass).length;
  const mean = (f: (r: CaseResult) => number) =>
    results.length ? results.reduce((a, r) => a + f(r), 0) / results.length : 0;
  const gate: ToolRunSummary['gate'] =
    list.length < all.length
      ? 'partial_run'
      : passed >= 26 &&
          (by.no_tool?.passed ?? 0) >= 6 &&
          (by.multi_step?.passed ?? 0) >= 5 &&
          !failures.malformed &&
          !failures.runaway
        ? 'default_eligible'
        : passed >= 20
          ? 'tools_limited'
          : 'chat_only';
  return {
    mode,
    total: results.length,
    passed,
    by_category: by,
    failures,
    mean_seconds_per_case: mean(r => r.wall_ms) / 1000,
    mean_generated_tokens_per_case: mean(r => r.generated_tokens),
    gate,
    cases: results,
  };
}
