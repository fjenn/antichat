/**
 * Argument parsing and the one-shot repair policy (H13).
 *
 * Order for a call the model produced:
 *   1. JSON.parse; on failure `jsonrepair` (trailing commas, single quotes,
 *      unquoted keys, a cut-off closing brace).
 *   2. Tool exists? → the tool's own `normalize` (fill-ins with one meaning).
 *   3. Schema validation with gentle coercion (`schema.ts`).
 *   4. Still wrong → one repair prompt carrying the exact problem, sent as
 *      the call's tool result; a second malformed call in the same turn ends
 *      tool use and the model answers in text.
 *
 * Prompt wording: AntiChat Mac `RepairRetry.swift` / `ToolLoopPolicy.swift`.
 */
import {jsonrepair} from 'jsonrepair';

import {validateArguments} from './schema';
import type {AntichatTool, JsonSchema, ToolContext} from './types';

export interface ParsedArguments {
  ok: boolean;
  value: Record<string, unknown>;
  /** True when `jsonrepair` had to fix the text. */
  repaired: boolean;
}

/** Parse the argument text of a call; never throws. */
export function parseArguments(
  text: string | object | undefined,
): ParsedArguments {
  if (text && typeof text === 'object') {
    return {ok: true, value: text as Record<string, unknown>, repaired: false};
  }
  const raw = (text ?? '').toString().trim();
  if (!raw) {
    return {ok: true, value: {}, repaired: false};
  }
  const asObject = (parsed: unknown): Record<string, unknown> | null => {
    // Some templates double-encode: the arguments are a JSON string.
    if (typeof parsed === 'string') {
      try {
        parsed = JSON.parse(parsed);
      } catch {
        return null;
      }
    }
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  };
  try {
    const value = asObject(JSON.parse(raw));
    if (value) {
      return {ok: true, value, repaired: false};
    }
  } catch {
    // try the repair below
  }
  try {
    const value = asObject(JSON.parse(jsonrepair(raw)));
    if (value) {
      return {ok: true, value, repaired: true};
    }
  } catch {
    // unrepairable
  }
  return {ok: false, value: {}, repaired: false};
}

export type CallCheck =
  | {
      ok: true;
      args: Record<string, unknown>;
      fixes: string[];
      repaired: boolean;
    }
  | {ok: false; problem: string; kind: 'unknown_tool' | 'bad_json' | 'schema'};

export interface CheckableTool {
  name: string;
  parameters: JsonSchema;
  normalize?: AntichatTool['normalize'];
}

/** Steps 1–3 for one call against the tools offered this turn. */
export function checkCall(
  name: string,
  argumentsText: string | object | undefined,
  offered: readonly CheckableTool[],
  context: ToolContext,
): CallCheck {
  const tool = offered.find(candidate => candidate.name === name);
  if (!tool) {
    const names = offered.map(candidate => candidate.name).sort();
    return {
      ok: false,
      kind: 'unknown_tool',
      problem: `there is no tool named "${name}"; the tools are: ${names.join(', ')}`,
    };
  }
  const parsed = parseArguments(argumentsText);
  if (!parsed.ok) {
    return {
      ok: false,
      kind: 'bad_json',
      problem: 'the arguments are not a JSON object',
    };
  }
  let args = parsed.value;
  if (tool.normalize) {
    try {
      args = tool.normalize({...args}, context) ?? args;
    } catch {
      // a broken normaliser never blocks a call
    }
  }
  const result = validateArguments(args, tool.parameters);
  if (!result.ok) {
    return {
      ok: false,
      kind: 'schema',
      problem: `the arguments do not match the schema: ${result.problems
        .slice(0, 5)
        .join('; ')}`,
    };
  }
  return {
    ok: true,
    args: result.value,
    fixes: result.fixes,
    repaired: parsed.repaired,
  };
}

export const MAX_REPAIRS = 1;

/** Mac `RepairRetry.prompt`, verbatim. */
export function repairPrompt(
  name: string,
  problem: string,
  example?: Record<string, unknown>,
): string {
  if (!example) {
    return `[System Notice] The call to ${name} was not run: ${problem}. Call it again with arguments that match its schema, or answer without it.`;
  }
  return `[System Notice] The call to ${name} was not run. Errors: ${problem}\nFix exactly these errors and call ${name} again now. A minimal valid call looks like this: ${JSON.stringify(example)}`;
}

/** Per-turn repair budget: one repair prompt, then a text-only answer. */
export class RepairState {
  private used = 0;

  constructor(private readonly max = MAX_REPAIRS) {}

  get repairsUsed(): number {
    return this.used;
  }

  onMalformed(
    name: string,
    problem: string,
    example?: Record<string, unknown>,
  ): {action: 'repair'; prompt: string} | {action: 'final_answer'} {
    if (this.used >= this.max) {
      return {action: 'final_answer'};
    }
    this.used += 1;
    return {action: 'repair', prompt: repairPrompt(name, problem, example)};
  }
}

/** Sent as a user-side notice when tool use is ended for the turn. */
export const ANSWER_WITHOUT_TOOLS_NOTICE =
  '[System Notice] Do not call any more tools. Answer the user now with what you have; if something could not be done, say so in one sentence.';
