/**
 * AntiChat's tool loop for one turn: the harness the tool cases and the
 * search evaluation run through. It wraps the model calls with every guard
 * of this directory:
 *
 *   before the first step   forced direct search when the gate says the turn
 *                           needs fresh information (no model step spent on
 *                           deciding or on writing a query)
 *   each step               tools re-resolved (search_tools activations),
 *                           native calls, else the text fallback
 *   each call               validation + coercion, one repair prompt, the
 *                           duplicate / similar / budget guards, a timeout,
 *                           the result cap, typed events
 *   the answer              output hygiene, one retry for an empty answer
 *                           after a tool result, one nudge when the model
 *                           says it did something no tool did, a text-only
 *                           last step when the step budget is spent
 */
import type {
  ApiCompletionParams,
  CompletionEngine,
  CompletionResult,
} from '../../../utils/completionTypes';
import {cleanModelOutput} from '../prompt/hygiene';
import type {ChatMessage} from '../prompt/types';
import type {SearchVerdict} from '../search/decision';
import type {ToolEvent} from './events';
import {executeGuarded, type GuardedResult, type TurnGuards} from './execute';
import {
  BUDGET_NOTICE,
  LoopGuard,
  cutOffNotice,
  looksRunaway,
  type LoopPolicy,
} from './loopGuard';
import {ANSWER_WITHOUT_TOOLS_NOTICE, RepairState} from './repair';
import {hasToolCallMarkup, parseToolCallsFromText} from './textFallback';
import {
  toToolDefinition,
  type AntichatTool,
  type ToolCall,
  type ToolContext,
} from './types';

export interface TurnCall {
  id: string;
  name: string;
  /** Validated arguments, or the raw text when validation failed. */
  args: Record<string, unknown> | string;
  status: GuardedResult['status'];
  /** The harness made this call (forced search), not the model. */
  synthetic: boolean;
  /** Parsed from text instead of the template's call channel. */
  fromText: boolean;
  step: number;
  durationMs: number;
  fixes: string[];
}

export type StopReason =
  | 'answer'
  | 'step_budget'
  | 'repair_failed'
  | 'runaway'
  | 'cancelled'
  | 'error';

export interface TurnResult {
  /** The answer, cleaned for display. */
  text: string;
  reasoning: string | null;
  /** The request messages plus everything this turn appended. */
  messages: ChatMessage[];
  calls: TurnCall[];
  /** Model steps used. */
  steps: number;
  stopReason: StopReason;
  flags: {
    forcedSearch: boolean;
    repaired: number;
    textFallback: number;
    emptyRetry: boolean;
    actionNudge: boolean;
    markupRetry: boolean;
  };
  timings: {
    promptTokens: number;
    generatedTokens: number;
    modelMs: number;
    toolMs: number;
    /** Wall time until the step that produced the answer started streaming. */
    totalMs: number;
  };
  error?: string;
}

export interface TurnOptions {
  engine: CompletionEngine;
  /** Prepared messages (system prompt and history included). */
  messages: ChatMessage[];
  /** Tools offered at the first step. */
  tools: AntichatTool[];
  /** Re-evaluated before every later step (search_tools activations). */
  resolveTools?: () => AntichatTool[];
  params?: Partial<ApiCompletionParams>;
  policy: LoopPolicy;
  context: ToolContext;
  turnId: string;
  /** Characters of a tool result the model is shown. */
  resultChars?: number;
  /** The search gate's verdict for this turn. */
  searchVerdict?: SearchVerdict;
  /** Queries for the forced search (default: the user's message). */
  directQueries?: () => string[];
  /** Allow the forced direct search (model caps). Default true. */
  directSearch?: boolean;
  /** Guards to switch off for baseline measurements. */
  disable?: Array<
    'textFallback' | 'emptyRetry' | 'actionNudge' | 'softWithhold'
  >;
  onEvent?: (event: ToolEvent) => void;
  signal?: AbortSignal;
}

/** Names that change something for the user: saying "done" needs a call. */
const WRITE_TOOL =
  /(?:^|_)(?:send|create|add|set|schedule|book|delete|remove|update|write|post|reply|cancel|move|save)(?:_|$)/i;

const CLAIMS_ACTION =
  /\b(?:i(?:'ve| have)(?: just| now| successfully| already)? (?:sent|scheduled|created|added|booked|set(?: up)?|saved|deleted|removed|updated|cancell?ed|moved|posted)|(?:has|have) been (?:successfully )?(?:sent|scheduled|created|added|booked|set|saved|deleted|removed|updated|cancell?ed)|(?:is|are) now (?:scheduled|booked|set|on your calendar|in your calendar)|ich habe .{0,40}(?:gesendet|geschickt|erstellt|eingetragen|hinzugefügt|gelöscht|gespeichert)|he (?:enviado|creado|añadido|programado)|j'ai (?:envoyé|créé|ajouté|programmé))\b/i;

const ACTION_NUDGE =
  '[System Notice] You wrote that it is done, but no tool was called, so nothing has happened yet. Call the tool now with the right arguments; if it cannot be done, tell the user it was not done.';

/** The user asked for something to be done (not described). */
const ASKS_ACTION =
  /\b(?:create|schedule|add|book|send|delete|remove|cancel|reply to|put .{1,60} (?:in|on|into) (?:my|the) calendar|e-?mail \S+@\S+|erstelle|trage .{0,40} ein|schicke?|sende|füge .{0,40} hinzu|crea|añade|envía|crée|ajoute|envoie)\b/i;

/** The answer reports a reason it was not done; no nudge then. */
const DECLINES =
  /\b(?:not free|aren't free|are not free|not available|unavailable|busy|conflict|overlap|clash|already (?:have|has|booked|scheduled|exists?|taken)|is taken|no (?:\w+ ){0,3}found|didn't find|did not find|couldn't find|could not find|nothing (?:found|matching))\b/i;

const PENDING_NUDGE =
  '[System Notice] The user asked you to do this, not only to describe it, and no tool has done it yet. If nothing prevents it, call the tool now (once per item); if something prevents it, say what.';

const EMPTY_NUDGE =
  "[System Notice] Answer the user's last question now, in plain text, using the tool result above.";

let turnCounter = 0;
const newCallId = (): string =>
  `call-${Date.now().toString(36)}-${turnCounter++}`;

const lastUserText = (messages: ChatMessage[]): string => {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (
      messages[i].role === 'user' &&
      typeof messages[i].content === 'string'
    ) {
      return messages[i].content as string;
    }
  }
  return '';
};

function nativeCalls(result: CompletionResult): ToolCall[] {
  const calls = (result.tool_calls ?? []) as Array<{
    id?: string;
    function?: {name?: string; arguments?: unknown};
  }>;
  return calls
    .filter(call => call?.function?.name)
    .map(call => ({
      id: call.id || newCallId(),
      name: String(call.function!.name),
      argumentsText:
        typeof call.function!.arguments === 'string'
          ? (call.function!.arguments as string)
          : JSON.stringify(call.function!.arguments ?? {}),
    }));
}

const assistantCallMessage = (
  text: string,
  calls: Array<{id: string; name: string; args: unknown}>,
): ChatMessage => ({
  role: 'assistant',
  content: text,
  tool_calls: calls.map(call => ({
    id: call.id,
    type: 'function',
    function: {
      name: call.name,
      arguments:
        typeof call.args === 'string'
          ? call.args
          : JSON.stringify(call.args ?? {}),
    },
  })),
});

export async function runToolTurn(options: TurnOptions): Promise<TurnResult> {
  const started = Date.now();
  const disabled = new Set(options.disable ?? []);
  const messages: ChatMessage[] = [...options.messages];
  const guards: TurnGuards = {
    repair: new RepairState(),
    guard: new LoopGuard(options.policy),
  };
  const context: ToolContext = {
    ...options.context,
    userText: options.context.userText ?? lastUserText(messages),
    turnId: options.context.turnId ?? options.turnId,
    signal: options.signal ?? options.context.signal,
  };
  const calls: TurnCall[] = [];
  const flags: TurnResult['flags'] = {
    forcedSearch: false,
    repaired: 0,
    textFallback: 0,
    emptyRetry: false,
    actionNudge: false,
    markupRetry: false,
  };
  const timings = {
    promptTokens: 0,
    generatedTokens: 0,
    modelMs: 0,
    toolMs: 0,
    totalMs: 0,
  };
  let tools = options.tools;
  let step = 0;
  let endToolUse = false;
  let gotToolResult = false;

  const finish = (
    stopReason: StopReason,
    text: string,
    reasoning: string | null = null,
    error?: string,
  ): TurnResult => ({
    text,
    reasoning,
    messages,
    calls,
    steps: step,
    stopReason,
    flags,
    timings: {...timings, totalMs: Date.now() - started},
    error,
  });

  const run = async (
    call: ToolCall,
    offered: AntichatTool[],
    extra: {synthetic?: boolean; fromText?: boolean} = {},
  ): Promise<GuardedResult> => {
    const result = await executeGuarded({
      callId: call.id,
      turnId: options.turnId,
      name: call.name,
      rawArguments: call.argumentsText,
      offered,
      guards,
      context,
      resultChars: options.resultChars,
      onEvent: options.onEvent,
      synthetic: extra.synthetic,
    });
    timings.toolMs += result.durationMs;
    if (result.status === 'repair') {
      flags.repaired += 1;
    }
    calls.push({
      id: call.id,
      name: call.name,
      args: result.args ?? call.argumentsText,
      status: result.status,
      synthetic: !!extra.synthetic,
      fromText: !!extra.fromText,
      step,
      durationMs: result.durationMs,
      fixes: result.fixes,
    });
    return result;
  };

  // --- forced direct search --------------------------------------------------
  const verdict = options.searchVerdict;
  const searchTool = tools.find(tool => tool.name === 'web_search');
  if (
    verdict?.decision === 'force' &&
    searchTool &&
    options.directSearch !== false
  ) {
    const queries = options.directQueries?.() ?? [context.userText ?? ''];
    const query = queries.find(Boolean);
    if (query) {
      const call: ToolCall = {
        id: newCallId(),
        name: 'web_search',
        argumentsText: JSON.stringify({query}),
      };
      const result = await run(call, tools, {synthetic: true});
      if (result.status === 'ok' || result.status === 'tool_error') {
        flags.forcedSearch = true;
        gotToolResult = true;
        messages.push(
          assistantCallMessage('', [
            {id: call.id, name: call.name, args: result.args ?? {query}},
          ]),
          {role: 'tool', tool_call_id: call.id, content: result.content},
        );
      }
    }
  }

  // "none": keep the tool list (the cached prefix survives) but tell the
  // template not to expect a call. Tools come off only if that leaks markup.
  let toolChoice: 'auto' | 'none' =
    verdict?.decision === 'none' && !disabled.has('softWithhold')
      ? 'none'
      : 'auto';
  let dropTools = verdict?.decision === 'none' && disabled.has('softWithhold');

  for (;;) {
    if (options.signal?.aborted) {
      return finish('cancelled', '');
    }
    const mayCall = guards.guard.beginStep() && !endToolUse;
    step += 1;
    if (!mayCall && !endToolUse) {
      // Step budget spent: one last, text-only step.
      messages.push({role: 'user', content: BUDGET_NOTICE});
    }
    const offered = dropTools ? [] : tools;
    const definitions = offered.map(toToolDefinition);
    const request: Record<string, unknown> = {
      ...options.params,
      messages,
    };
    if (definitions.length > 0) {
      request.tools = definitions;
      request.tool_choice = mayCall ? toolChoice : 'none';
    }
    let result: CompletionResult;
    const modelStarted = Date.now();
    try {
      result = await options.engine.completion(request as ApiCompletionParams);
    } catch (error) {
      return finish(
        'error',
        '',
        null,
        (error as Error)?.message ?? 'completion failed',
      );
    }
    timings.modelMs += Date.now() - modelStarted;
    timings.promptTokens += result.tokens_evaluated ?? 0;
    timings.generatedTokens +=
      result.tokens_predicted ?? result.timings?.predicted_n ?? 0;

    const rawText = result.content ?? result.text ?? '';
    let stepCalls = mayCall && toolChoice !== 'none' ? nativeCalls(result) : [];
    let fromText = false;
    let visible = rawText;
    const names = offered.map(tool => tool.name);
    if (stepCalls.length === 0 && rawText && !disabled.has('textFallback')) {
      const parsed = parseToolCallsFromText(rawText, names);
      if (parsed.calls.length > 0) {
        visible = parsed.text;
        if (mayCall && toolChoice !== 'none' && offered.length > 0) {
          stepCalls = parsed.calls;
          fromText = true;
          flags.textFallback += parsed.calls.length;
        } else if (
          !visible.trim() &&
          !flags.markupRetry &&
          definitions.length > 0
        ) {
          // A call although none was allowed, and no answer: take the tools
          // away and ask once more.
          flags.markupRetry = true;
          dropTools = true;
          step -= 1;
          continue;
        }
      } else if (hasToolCallMarkup(rawText)) {
        visible = parsed.text;
      }
    }

    const cleaned = cleanModelOutput(visible, {streaming: false});
    const answer = cleaned.content.trim();
    const reasoning = cleaned.reasoning ?? result.reasoning_content ?? null;

    if (stepCalls.length === 0) {
      if (result.truncated && looksRunaway(rawText)) {
        return finish('runaway', answer, reasoning);
      }
      if (
        !answer &&
        gotToolResult &&
        !flags.emptyRetry &&
        !disabled.has('emptyRetry')
      ) {
        flags.emptyRetry = true;
        messages.push({role: 'user', content: EMPTY_NUDGE});
        endToolUse = true;
        continue;
      }
      if (
        mayCall &&
        !flags.actionNudge &&
        !disabled.has('actionNudge') &&
        CLAIMS_ACTION.test(answer) &&
        offered.some(tool => WRITE_TOOL.test(tool.name)) &&
        !calls.some(call => WRITE_TOOL.test(call.name) && call.status === 'ok')
      ) {
        flags.actionNudge = true;
        messages.push(
          {role: 'assistant', content: answer},
          {role: 'user', content: ACTION_NUDGE},
        );
        continue;
      }
      if (
        mayCall &&
        gotToolResult &&
        !flags.actionNudge &&
        !disabled.has('actionNudge') &&
        ASKS_ACTION.test(context.userText ?? '') &&
        !DECLINES.test(answer) &&
        offered.some(tool => WRITE_TOOL.test(tool.name)) &&
        !calls.some(call => WRITE_TOOL.test(call.name))
      ) {
        flags.actionNudge = true;
        messages.push(
          {role: 'assistant', content: answer},
          {role: 'user', content: PENDING_NUDGE},
        );
        continue;
      }
      messages.push({role: 'assistant', content: answer});
      const stopReason: StopReason =
        !mayCall && !endToolUse
          ? 'step_budget'
          : guards.repair.repairsUsed > 0 && endToolUse
            ? 'repair_failed'
            : 'answer';
      return finish(stopReason, answer, reasoning);
    }

    // --- run the calls of this step ----------------------------------------
    const limited = stepCalls.slice(0, options.policy.maxCallsPerStep);
    const results: Array<{call: ToolCall; result: GuardedResult}> = [];
    for (const call of limited) {
      if (result.truncated && !call.argumentsText.trim().endsWith('}')) {
        results.push({
          call,
          result: {
            status: 'repair',
            content: cutOffNotice(call.name),
            durationMs: 0,
            fixes: [],
            endToolUse: false,
          },
        });
        continue;
      }
      results.push({call, result: await run(call, offered, {fromText})});
      if (options.signal?.aborted) {
        return finish('cancelled', '');
      }
    }
    messages.push(
      assistantCallMessage(
        fromText ? '' : cleaned.content.trim(),
        results.map(({call, result: outcome}) => ({
          id: call.id,
          name: call.name,
          args: outcome.args ?? call.argumentsText,
        })),
      ),
    );
    for (const {call, result: outcome} of results) {
      messages.push({
        role: 'tool',
        tool_call_id: call.id,
        content: outcome.content,
      });
      if (outcome.status === 'ok' || outcome.status === 'tool_error') {
        gotToolResult = true;
      }
      if (outcome.endToolUse) {
        endToolUse = true;
      }
    }
    if (endToolUse) {
      messages.push({role: 'user', content: ANSWER_WITHOUT_TOOLS_NOTICE});
    }
    toolChoice = 'auto';
    if (options.resolveTools) {
      tools = options.resolveTools();
    }
  }
}
