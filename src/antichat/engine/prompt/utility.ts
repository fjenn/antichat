/**
 * Small side generations (title, follow-ups, summary) on the chat engine.
 *
 * Thinking is always off, output is capped and cleaned, and a timeout stops
 * the engine so a stuck side job can never hold the generation lease.
 */
import type {
  ApiCompletionParams,
  CompletionEngine,
} from '../../../utils/completionTypes';
import {cleanModelOutput} from './hygiene';
import type {ModelFamily} from './modelFamily';
import {thinkingParams} from './thinking';
import type {ChatMessage} from './types';

export interface UtilityRequest {
  engine: CompletionEngine;
  messages: ChatMessage[];
  maxTokens: number;
  family?: ModelFamily;
  temperature?: number;
  stop?: string[];
  /** JSON schema for a constrained answer. */
  jsonSchema?: {name: string; schema: object};
  timeoutMs?: number;
  signal?: AbortSignal;
}

export interface UtilityResult {
  text: string;
  /** Prompt tokens served from the KV cache, when the engine reports it. */
  tokensCached?: number;
  tokensEvaluated?: number;
  truncated: boolean;
}

const DEFAULT_TIMEOUT_MS = 20000;

/** Run one side generation. Resolves null on failure, abort or timeout. */
export async function runUtilityCompletion(
  request: UtilityRequest,
): Promise<UtilityResult | null> {
  if (request.signal?.aborted) {
    return null;
  }
  const params = {
    messages: request.messages,
    n_predict: request.maxTokens,
    temperature: request.temperature ?? 0.2,
    ...(request.stop?.length ? {stop: request.stop} : {}),
    ...thinkingParams({family: request.family ?? 'generic', enabled: false}),
    ...(request.jsonSchema
      ? {
          response_format: {
            type: 'json_schema',
            json_schema: {
              name: request.jsonSchema.name,
              strict: true,
              schema: request.jsonSchema.schema,
            },
          },
        }
      : {}),
  } as unknown as ApiCompletionParams;

  let timedOut = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    request.engine.stopCompletion().catch(() => {});
  };
  const onAbort = () => stop();
  request.signal?.addEventListener('abort', onAbort);
  try {
    const timeout = new Promise<null>(resolve => {
      timer = setTimeout(() => {
        timedOut = true;
        stop();
        resolve(null);
      }, request.timeoutMs ?? DEFAULT_TIMEOUT_MS);
    });
    const result = await Promise.race([
      request.engine.completion(params),
      timeout,
    ]);
    if (!result || timedOut || request.signal?.aborted) {
      return null;
    }
    const raw = result.content || result.text || '';
    const text = cleanModelOutput(raw, {
      normalize: false,
      cutTailLoop: false,
    }).content;
    const timings = result.timings;
    return {
      text,
      tokensCached:
        (result as {tokens_cached?: number}).tokens_cached ?? timings?.cache_n,
      tokensEvaluated: result.tokens_evaluated ?? timings?.prompt_n,
      truncated: !!result.truncated || !!result.stopped_limit,
    };
  } catch {
    return null;
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
    request.signal?.removeEventListener('abort', onAbort);
  }
}

/** Collapse whitespace and cut to `limit` characters with an ellipsis. */
export function clipText(text: string, limit: number): string {
  const trimmed = text.trim();
  return trimmed.length > limit
    ? `${trimmed.slice(0, limit).trimEnd()}…`
    : trimmed;
}
