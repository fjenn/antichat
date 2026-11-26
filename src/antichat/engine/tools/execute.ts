/**
 * One guarded tool call: validation, the repair decision, the loop guard, a
 * per-tool timeout, the result cap and the typed events. Shared by
 * AntiChat's loop (`runner.ts`) and the adapter that exposes the tools to
 * upstream's agent runner (`talentAdapter.ts`).
 */
import {emitToolEvent, toolLabel, type ToolEvent} from './events';
import {LoopGuard} from './loopGuard';
import {RepairState, checkCall, ANSWER_WITHOUT_TOOLS_NOTICE} from './repair';
import type {AntichatTool, ToolContext, ToolOutput} from './types';

export const DEFAULT_TIMEOUT_MS = 15000;

export interface TurnGuards {
  repair: RepairState;
  guard: LoopGuard;
}

export interface GuardedOptions {
  callId: string;
  turnId: string;
  name: string;
  /** Argument text or object as the model produced it. */
  rawArguments: string | object | undefined;
  /** Tools offered this step. */
  offered: readonly AntichatTool[];
  guards: TurnGuards;
  context: ToolContext;
  /** Characters of the result the model is shown. */
  resultChars?: number;
  onEvent?: (event: ToolEvent) => void;
  /** The harness made this call itself. */
  synthetic?: boolean;
}

export type GuardedStatus =
  | 'ok'
  | 'tool_error'
  | 'repair'
  | 'give_up'
  | 'skipped'
  | 'timeout'
  | 'cancelled';

export interface GuardedResult {
  status: GuardedStatus;
  /** What goes back to the model as the tool message. */
  content: string;
  /** Validated arguments (when the call ran or was skipped as duplicate). */
  args?: Record<string, unknown>;
  output?: ToolOutput;
  durationMs: number;
  /** Silent argument fixes that were applied. */
  fixes: string[];
  /** After this result the model must answer without tools. */
  endToolUse: boolean;
}

/** Cut a result at a line or sentence end and say that it was cut. */
export function capResult(text: string, maxChars?: number): string {
  if (!maxChars || text.length <= maxChars) {
    return text;
  }
  // A results block keeps its closing rules: cut the middle, not the end.
  const closing = text.lastIndexOf('</web_results>');
  if (closing !== -1) {
    const tailStart = text.lastIndexOf('\n\n', closing);
    const tail = text.slice(tailStart === -1 ? closing : tailStart);
    const room = Math.max(200, maxChars - tail.length);
    const head = text.slice(0, room);
    const stop = Math.max(head.lastIndexOf('\n'), head.lastIndexOf('. '));
    return `${head.slice(0, stop > room * 0.6 ? stop + 1 : room).trimEnd()} …${tail}`;
  }
  const head = text.slice(0, maxChars);
  const stop = Math.max(head.lastIndexOf('\n'), head.lastIndexOf('. '));
  return `${head.slice(0, stop > maxChars * 0.6 ? stop + 1 : maxChars).trimEnd()} … [cut: ${text.length - maxChars} more characters]`;
}

class ToolTimeout extends Error {}

function withTimeout<T>(
  run: (signal: AbortSignal) => Promise<T>,
  ms: number,
  outer?: AbortSignal,
): Promise<T> {
  const controller = new AbortController();
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => {
      controller.abort();
      reject(new Error('cancelled'));
    };
    if (outer?.aborted) {
      onAbort();
      return;
    }
    outer?.addEventListener('abort', onAbort);
    const timer = setTimeout(() => {
      controller.abort();
      reject(new ToolTimeout(`timed out after ${Math.round(ms / 1000)} s`));
    }, ms);
    run(controller.signal)
      .then(resolve, reject)
      .finally(() => {
        clearTimeout(timer);
        outer?.removeEventListener('abort', onAbort);
      });
  });
}

export async function executeGuarded(
  options: GuardedOptions,
): Promise<GuardedResult> {
  const {callId, turnId, name, guards, context} = options;
  const started = Date.now();
  const emit = (event: ToolEvent) => {
    emitToolEvent(event);
    options.onEvent?.(event);
  };
  const base = {turnId, callId, name};
  const error = (
    code: Extract<ToolEvent, {type: 'error'}>['code'],
    message: string,
    willRetry: boolean,
  ) =>
    emit({
      ...base,
      type: 'error',
      at: Date.now(),
      durationMs: Date.now() - started,
      code,
      message,
      willRetry,
    });

  const check = checkCall(name, options.rawArguments, options.offered, context);
  if (!check.ok) {
    const tool = options.offered.find(candidate => candidate.name === name);
    const next = guards.repair.onMalformed(name, check.problem, tool?.example);
    const code =
      check.kind === 'unknown_tool' ? 'unknown_tool' : 'invalid_arguments';
    if (next.action === 'repair') {
      error(code, check.problem, true);
      return {
        status: 'repair',
        content: next.prompt,
        durationMs: Date.now() - started,
        fixes: [],
        endToolUse: false,
      };
    }
    error(code, check.problem, false);
    return {
      status: 'give_up',
      content: `[System Notice] The call to ${name} was not run: ${check.problem}. ${ANSWER_WITHOUT_TOOLS_NOTICE.replace('[System Notice] ', '')}`,
      durationMs: Date.now() - started,
      fixes: [],
      endToolUse: true,
    };
  }

  const tool = options.offered.find(candidate => candidate.name === name)!;
  const verdict = guards.guard.admit(name, check.args);
  if (verdict.action === 'skip') {
    error('skipped', verdict.reason, false);
    return {
      status: 'skipped',
      content: verdict.notice,
      args: check.args,
      durationMs: Date.now() - started,
      fixes: check.fixes,
      endToolUse: verdict.reason !== 'duplicate',
    };
  }

  emit({
    ...base,
    type: 'started',
    at: started,
    args: check.args,
    label: toolLabel(name),
    synthetic: options.synthetic,
  });

  let output: ToolOutput;
  try {
    output = await withTimeout(
      signal =>
        tool.execute(check.args, {
          ...context,
          signal,
          turnId: context.turnId ?? turnId,
          onProgress: (note, fraction) =>
            emit({...base, type: 'progress', at: Date.now(), note, fraction}),
        }),
      tool.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      context.signal,
    );
  } catch (failure) {
    const timedOut = failure instanceof ToolTimeout;
    const cancelled = !timedOut && !!context.signal?.aborted;
    const message = (failure as Error)?.message ?? 'failed';
    error(
      timedOut ? 'timeout' : cancelled ? 'cancelled' : 'failed',
      message,
      false,
    );
    return {
      status: timedOut ? 'timeout' : cancelled ? 'cancelled' : 'tool_error',
      content: timedOut
        ? `[System Notice] ${name} ${message} and was stopped. Do not call it again; answer with what you have and say that ${name.replace(/_/g, ' ')} did not respond.`
        : `${name} failed: ${message}. Do not retry with the same arguments; answer with what you have.`,
      args: check.args,
      durationMs: Date.now() - started,
      fixes: check.fixes,
      endToolUse: false,
    };
  }

  const content = capResult(output.text, options.resultChars ?? tool.resultCap);
  const durationMs = Date.now() - started;
  if (output.isError) {
    error('failed', output.text.slice(0, 200), false);
  } else {
    emit({
      ...base,
      type: 'result',
      at: Date.now(),
      durationMs,
      text: content,
      card: output.card,
      sources: output.sources,
      images: output.images,
    });
  }
  return {
    status: output.isError ? 'tool_error' : 'ok',
    content,
    args: check.args,
    output,
    durationMs,
    fixes: check.fixes,
    endToolUse: false,
  };
}
