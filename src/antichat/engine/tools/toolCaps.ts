/**
 * Per-model tool caps, as data. Numbers come from the Mac spike
 * (docs/research/spike/results-mac/toolcall, 3 seeds × 30 cases) and from the
 * M8 runs in docs/antichat/m8-eval.md:
 *
 *   - 6 tools and 20 tools pass equally for every model tested.
 *   - 60 flat tools cost Gemma 4 E2B and LFM3 runaways and leaked markup;
 *     Qwen3.5-4B holds.
 *   - 5 retrieved tools without pinned ones loses half the cases; 2 pinned +
 *     6 retrieved by keyword matches the flat 6-tool result.
 *
 *   - docs/research/04-model-eval-mac.md §3.2: no model gains from more than
 *     8 tools in the prompt, so 8 is the ceiling for every model: the two
 *     pinned web tools plus six seats for retrieved or activated tools.
 *
 * So: a small always-on set, a hard cap, and the rest behind `search_tools`.
 * Rows are matched in order against the lower-cased model name / file name;
 * the first match wins. Remote-catalogue overrides can replace this table
 * (`setToolCaps`) without an app release.
 */
import type {ModelFamily} from '../prompt/modelFamily';

export interface ToolCaps {
  /** Tools in one request, `search_tools` included. 0 = chat only. */
  maxTools: number;
  /** Approximate token ceiling for all tool schemas together. */
  schemaTokens: number;
  /** Characters of a tool result the model is shown. */
  resultChars: number;
  /** Model steps per turn that may call tools. */
  maxSteps: number;
  /** Tool calls taken from one model step. */
  parallelCalls: number;
  /**
   * The harness runs the first web search itself, with the user's words,
   * when the search gate says the turn needs fresh information. Saves one
   * model step and does not depend on the model deciding to search.
   */
  directSearch: boolean;
  /** Offer `search_tools` when deferred tools exist. */
  toolSearch: boolean;
  /**
   * Add the one-line citation rule to the system prompt while web tools are
   * offered. Qwen3.5 needs it (it cited in 43 % of its web answers without);
   * Gemma 4 and LFM3 cite from the rule in the result block alone, and on
   * LFM3 the extra line triggers a second, redundant search.
   */
  citeRule: boolean;
  /**
   * How a turn that needs no tool is handled. true: the tool list stays (the
   * cached prefix survives) and the request carries `tool_choice: none`.
   * false: the tools are left out for that turn. LFM3 ignores `tool_choice:
   * none` and prints a call as text (6 of 21 no-tool runs), so it gets false.
   */
  softWithhold: boolean;
}

export interface ToolCapRule extends Partial<ToolCaps> {
  /** RegExp source tested against the model label. */
  match: string;
  family?: ModelFamily;
  note?: string;
}

export const DEFAULT_CAPS: ToolCaps = {
  maxTools: 6,
  schemaTokens: 900,
  resultChars: 2000,
  maxSteps: 4,
  parallelCalls: 2,
  directSearch: true,
  toolSearch: true,
  citeRule: false,
  softWithhold: true,
};

export const DEFAULT_TOOL_CAP_RULES: ToolCapRule[] = [
  {
    match: 'qwen[-_ ]?3(\\.\\d)?[-_ ]?0\\.[5-9]b',
    citeRule: true,
    maxTools: 3,
    schemaTokens: 450,
    resultChars: 1000,
    maxSteps: 2,
    parallelCalls: 1,
    toolSearch: false,
    note: '0.8B: single-step tools only (Mac made it chat-only at 39/50)',
  },
  {
    match: 'qwen[-_ ]?3(\\.\\d)?[-_ ]?(1\\.7|2)b',
    citeRule: true,
    maxTools: 6,
    schemaTokens: 900,
    resultChars: 1500,
    maxSteps: 3,
    parallelCalls: 2,
  },
  {
    match: 'qwen[-_ ]?3(\\.\\d)?[-_ ]?4b',
    citeRule: true,
    maxTools: 8,
    schemaTokens: 1500,
    resultChars: 3000,
    maxSteps: 5,
    parallelCalls: 3,
  },
  {
    match: 'qwen[-_ ]?3(\\.\\d)?[-_ ]?(8|9|1[0-9])b',
    citeRule: true,
    maxTools: 8,
    schemaTokens: 2500,
    resultChars: 4000,
    maxSteps: 6,
    parallelCalls: 4,
    directSearch: false,
  },
  {
    match: 'gemma[-_ ]?(4|3n)[-_ ]?e2b',
    maxTools: 8,
    schemaTokens: 1000,
    resultChars: 2000,
    maxSteps: 4,
    parallelCalls: 2,
  },
  {
    match: 'gemma[-_ ]?(4|3n)[-_ ]?e4b',
    maxTools: 8,
    schemaTokens: 1500,
    resultChars: 3000,
    maxSteps: 5,
    parallelCalls: 3,
  },
  {
    match: 'lfm[-_ ]?[23]',
    softWithhold: false,
    maxTools: 6,
    schemaTokens: 800,
    resultChars: 1500,
    maxSteps: 3,
    parallelCalls: 1,
    note: 'calls a tool for anything when one fits loosely: keep the set tight',
  },
];

const FAMILY_FALLBACK: Record<ModelFamily, Partial<ToolCaps>> = {
  gemma4: {maxTools: 8},
  qwen35: {maxTools: 6, citeRule: true},
  lfm3: {maxTools: 6, parallelCalls: 1, maxSteps: 3, softWithhold: false},
  generic: {},
};

let rules: ToolCapRule[] = DEFAULT_TOOL_CAP_RULES;

/** Replace the table (remote catalogue); `null` restores the built-in one. */
export function setToolCaps(next: ToolCapRule[] | null): void {
  rules = next ?? DEFAULT_TOOL_CAP_RULES;
}

export function toolCapsFor(
  modelName: string | undefined,
  family: ModelFamily = 'generic',
  nCtx?: number,
): ToolCaps {
  const label = (modelName ?? '').toLowerCase();
  let caps: ToolCaps = {...DEFAULT_CAPS, ...FAMILY_FALLBACK[family]};
  for (const rule of rules) {
    let hit = false;
    try {
      hit = !!label && new RegExp(rule.match, 'i').test(label);
    } catch {
      hit = false;
    }
    if (hit) {
      const values: Partial<ToolCapRule> = {...rule};
      delete values.match;
      delete values.family;
      delete values.note;
      caps = {...caps, ...(values as Partial<ToolCaps>)};
      break;
    }
  }
  // A small window shrinks everything: at 4k the schemas and one tool result
  // must leave room for the conversation.
  if (nCtx && nCtx <= 4096) {
    caps = {
      ...caps,
      maxTools: Math.min(caps.maxTools, 4),
      schemaTokens: Math.min(caps.schemaTokens, 500),
      resultChars: Math.min(caps.resultChars, 1200),
      maxSteps: Math.min(caps.maxSteps, 3),
    };
  }
  return caps;
}
