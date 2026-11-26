/**
 * The 30 tool cases of docs/research/spike/toolcall-cases.json and their
 * judge, ported from tools/antichat/eval/toolcall_eval.py so the numbers are
 * comparable with the Mac spike. Tool results are the scripted mock results.
 */
import spec from '../../../../../../docs/research/spike/toolcall-cases.json';
import {
  createReadUrlTool,
  createWebSearchTool,
} from '../../../search/searchTools';
import type {AntichatTool} from '../../types';

export type FailureClass =
  | 'malformed'
  | 'wrong_tool'
  | 'wrong_args'
  | 'extra_call'
  | 'repeated_call'
  | 'missing_call'
  | 'called_when_not_needed'
  | 'bad_final'
  | 'no_answer'
  | 'runaway'
  | 'leaked_markup'
  | 'error';

type Checks = Record<string, any>;
interface Step {
  expect_tool: string;
  arg_checks?: Record<string, Checks>;
  mock_result: any;
}
export interface ToolCase {
  id: string;
  category: string;
  user: string;
  steps: Step[];
  final: Checks;
  history?: any[];
  notes?: string;
}

export const CASES: ToolCase[] = (spec as any).cases;
export const CASE_TOOLS: any[] = (spec as any).tools;
export const CASE_SYSTEM: string = (spec as any).system_prompt;
export const CASE_NOW = new Date(2026, 10, 24, 10, 0, 0);

const ORDER_FREE = new Set(['ms-04', 'ms-05']);

export const MARKUP =
  /<tool_call|<\/tool_call|<\|tool_call|<tool_call\|>|<function=|<parameter=|<think>|<\/think>|<\|channel\|>|<\|tool_response|<start_function_call>|\[TOOL_CALLS?\]|<\|tool_list|<\|im_start\|>|<\|im_end\|>/i;

const norm = (text: string): string =>
  (text ?? '').replace(/[’‘]/g, "'").replace(/[  ]/g, ' ');

function parseIso(value: unknown): [string, string | null] | null {
  if (typeof value !== 'string') {
    return null;
  }
  const match = /^\s*(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(
    value,
  );
  if (!match) {
    return null;
  }
  return [
    `${match[1]}-${match[2]}-${match[3]}`,
    match[4] ? `${match[4]}:${match[5]}` : null,
  ];
}

export function checkValue(input: unknown, ops: Checks): string | null {
  const value = typeof input === 'string' ? norm(input) : input;
  for (const [op, want] of Object.entries(ops)) {
    let ok = true;
    if (op === 'optional') {
      continue;
    } else if (op === 'equals') {
      ok = typeof value === 'string' && value.trim() === want;
    } else if (op === 'regex') {
      ok = typeof value === 'string' && new RegExp(want).test(value);
    } else if (/^i?contains_(any|all)$/.test(op)) {
      let text = typeof value === 'string' ? value : JSON.stringify(value);
      let list: string[] = want;
      if (op.startsWith('i')) {
        text = text.toLowerCase();
        list = list.map(item => item.toLowerCase());
      }
      ok = op.endsWith('any')
        ? list.some(item => text.includes(item))
        : list.every(item => text.includes(item));
    } else if (op === 'date_equals') {
      ok = parseIso(value)?.[0] === want;
    } else if (op === 'date_in') {
      const parsed = parseIso(value);
      ok = !!parsed && want.includes(parsed[0]);
    } else if (op === 'datetime_equals') {
      const parsed = parseIso(value);
      ok =
        !!parsed && parsed[1] !== null && `${parsed[0]}T${parsed[1]}` === want;
    } else if (op === 'array_equals') {
      ok =
        Array.isArray(value) &&
        JSON.stringify(
          value.map(item => String(item).trim().toLowerCase()).sort(),
        ) ===
          JSON.stringify(
            [...want].map((item: string) => item.toLowerCase()).sort(),
          );
    } else if (op === 'int_range') {
      ok =
        Number.isInteger(value) &&
        (value as number) >= want[0] &&
        (value as number) <= want[1];
    } else if (op === 'min_chars') {
      ok = typeof value === 'string' && value.trim().length >= want;
    }
    if (!ok) {
      return `${op} failed: got ${JSON.stringify(value)?.slice(0, 120)}`;
    }
  }
  return null;
}

function checkArgs(
  args: Record<string, unknown>,
  checks: Record<string, Checks> = {},
): string | null {
  for (const [key, ops] of Object.entries(checks)) {
    if (!(key in args)) {
      if (ops.optional) {
        continue;
      }
      return `missing checked arg ${key}`;
    }
    const reason = checkValue(args[key], ops);
    if (reason) {
      return `${key}: ${reason}`;
    }
  }
  return null;
}

export function checkFinal(text: string, final: Checks): string | null {
  for (const op of [
    'icontains_any',
    'icontains_all',
    'contains_any',
    'contains_all',
    'min_chars',
  ]) {
    if (op in final) {
      const reason = checkValue(norm(text), {[op]: final[op]});
      if (reason) {
        return reason;
      }
    }
  }
  return null;
}

/** Strict schema check of the spike (no coercion): the baseline's bar. */
export function strictSchemaError(args: unknown, schema: any): string | null {
  if (!args || typeof args !== 'object' || Array.isArray(args)) {
    return 'arguments not an object';
  }
  const props = schema.properties ?? {};
  for (const name of schema.required ?? []) {
    if (!(name in (args as object))) {
      return `missing required ${name}`;
    }
  }
  for (const [key, value] of Object.entries(args as object)) {
    if (!(key in props)) {
      return `unknown argument ${key}`;
    }
    const type = props[key].type;
    if (type === 'string' && typeof value !== 'string') {
      return `${key} not a string`;
    }
    if (type === 'integer') {
      if (!Number.isInteger(value)) {
        return `${key} not an integer`;
      }
      if (
        (props[key].minimum !== undefined && value < props[key].minimum) ||
        (props[key].maximum !== undefined && value > props[key].maximum)
      ) {
        return `${key} out of range`;
      }
    }
    if (
      type === 'array' &&
      (!Array.isArray(value) || !value.every(item => typeof item === 'string'))
    ) {
      return `${key} not an array of strings`;
    }
  }
  return null;
}

/** Matches calls against the expected steps and hands out mock results. */
export class CaseJudge {
  failure: {kind: FailureClass; detail: string} | null = null;
  readonly calls: Array<{name: string; args: unknown}> = [];
  private remaining: number[];
  private extraAllowed = 0;
  private readonly seen: string[] = [];

  constructor(readonly testCase: ToolCase) {
    this.remaining = testCase.steps.map((_, index) => index);
  }

  get pending(): number[] {
    return this.remaining;
  }

  private fail(kind: FailureClass, detail: string): string {
    this.failure ??= {kind, detail};
    return JSON.stringify({error: 'not available'});
  }

  /** Returns the tool result text for a valid call. */
  onCall(name: string, args: Record<string, unknown>): string {
    const {testCase} = this;
    const steps = testCase.steps;
    this.calls.push({name, args});
    const signature = JSON.stringify([name, args]);
    const repeated = this.seen.includes(signature);
    this.seen.push(signature);
    const shown = `${name}(${JSON.stringify(args).slice(0, 160)})`;
    let mock: unknown;
    if (this.remaining.length === 0) {
      if (this.extraAllowed > 0 && name === 'web_search') {
        this.extraAllowed -= 1;
        mock = {results: steps.map(step => step.mock_result.results[0])};
      } else if (testCase.final.must_not_call || steps.length === 0) {
        return this.fail('called_when_not_needed', shown);
      } else {
        return this.fail(repeated ? 'repeated_call' : 'extra_call', shown);
      }
    } else if (testCase.id === 'ms-04' && name === 'web_search') {
      const query = String(args.query ?? '').toLowerCase();
      const hasIphone = query.includes('iphone 18 pro');
      const hasPixel = query.includes('pixel 11 pro');
      if (hasIphone && hasPixel) {
        mock = {results: steps.map(step => step.mock_result.results[0])};
        this.remaining = [];
        this.extraAllowed = 1;
      } else if (hasIphone && this.remaining.includes(0)) {
        this.remaining = this.remaining.filter(index => index !== 0);
        mock = steps[0].mock_result;
      } else if (hasPixel && this.remaining.includes(1)) {
        this.remaining = this.remaining.filter(index => index !== 1);
        mock = steps[1].mock_result;
      } else if (hasIphone || hasPixel) {
        return this.fail(
          'repeated_call',
          `searched the same phone twice: ${query}`,
        );
      } else {
        return this.fail('wrong_args', `query names neither phone: ${query}`);
      }
    } else {
      const candidates = ORDER_FREE.has(testCase.id)
        ? this.remaining
        : this.remaining.slice(0, 1);
      let hit: number | null = null;
      let why: [FailureClass, string] | null = null;
      for (const index of candidates) {
        if (steps[index].expect_tool !== name) {
          why ??= [
            'wrong_tool',
            `expected ${steps[index].expect_tool}, got ${shown}`,
          ];
          continue;
        }
        const reason = checkArgs(args, steps[index].arg_checks);
        if (reason) {
          why = ['wrong_args', `${name}: ${reason}`];
          continue;
        }
        hit = index;
        break;
      }
      if (hit === null) {
        return this.fail(why![0], why![1]);
      }
      this.remaining = this.remaining.filter(index => index !== hit);
      mock = steps[hit].mock_result;
    }
    return JSON.stringify(mock);
  }

  /** Verdict once the turn has ended with `finalText`. */
  verdict(finalText: string): {
    passed: boolean;
    failure?: FailureClass;
    detail?: string;
  } {
    if (this.failure) {
      return {
        passed: false,
        failure: this.failure.kind,
        detail: this.failure.detail,
      };
    }
    if (MARKUP.test(finalText)) {
      return {
        passed: false,
        failure: 'leaked_markup',
        detail: finalText.slice(0, 200),
      };
    }
    if (this.remaining.length > 0) {
      return {
        passed: false,
        failure: 'missing_call',
        detail: `answered without calling ${this.testCase.steps[this.remaining[0]].expect_tool}: ${finalText.slice(0, 160)}`,
      };
    }
    if (!finalText.trim()) {
      return {
        passed: false,
        failure: 'no_answer',
        detail: 'empty final message',
      };
    }
    const reason = checkFinal(finalText, this.testCase.final);
    if (reason) {
      return {
        passed: false,
        failure: 'bad_final',
        detail: `${reason} | ${finalText.slice(0, 160)}`,
      };
    }
    return {passed: true};
  }
}

/** Argument fill-ins of the real tools: part of the harness, not of the mock. */
const NORMALIZERS: Record<string, AntichatTool['normalize']> = {
  web_search: createWebSearchTool().normalize,
  read_url: createReadUrlTool().normalize,
};

/** The six case tools as AntiChat tools whose results come from the judge. */
export function mockTools(judge: CaseJudge): AntichatTool[] {
  return CASE_TOOLS.map(definition => {
    const name: string = definition.function.name;
    const online = name === 'web_search' || name === 'read_url';
    return {
      name,
      description: definition.function.description,
      parameters: definition.function.parameters,
      kind: online ? 'online' : 'local',
      tier: 'always',
      timeoutMs: 5000,
      normalize: NORMALIZERS[name],
      async execute(args: Record<string, unknown>) {
        return {text: judge.onCall(name, args)};
      },
    } as AntichatTool;
  });
}

export function historyMessages(testCase: ToolCase): any[] {
  const messages: any[] = [];
  (testCase.history ?? []).forEach((entry, index) => {
    if (entry.role === 'assistant' && entry.tool_calls) {
      messages.push({
        role: 'assistant',
        content: '',
        tool_calls: entry.tool_calls.map((call: any, position: number) => ({
          id: `hist${index}_${position}`,
          type: 'function',
          function: {
            name: call.name,
            arguments: JSON.stringify(call.arguments),
          },
        })),
      });
    } else if (entry.role === 'tool') {
      messages.push({
        role: 'tool',
        tool_call_id: `hist${index - 1}_0`,
        name: entry.name,
        content:
          typeof entry.content === 'string'
            ? entry.content
            : JSON.stringify(entry.content),
      });
    } else {
      messages.push({role: entry.role, content: entry.content});
    }
  });
  return messages;
}

export function gateOf(
  passed: number,
  byCategory: Record<string, {passed: number; total: number}>,
  failures: Record<string, number>,
  total: number,
): string {
  const scale = total / 30;
  const noTool = byCategory.no_tool ?? {passed: 0, total: 0};
  const multi = byCategory.multi_step ?? {passed: 0, total: 0};
  if (
    passed >= 26 * scale &&
    noTool.passed >= 6 * scale &&
    multi.passed >= 5 * scale &&
    !failures.malformed &&
    !failures.runaway
  ) {
    return 'default_eligible';
  }
  return passed >= 20 * scale ? 'tools_limited' : 'chat_only';
}
