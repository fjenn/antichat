/**
 * Thinking on/off per request (thinking is OFF by default on phones: Qwen3.5
 * small models fail most tasks with thinking under a 4k budget, see
 * docs/research/03 §1).
 */
import type {ApiCompletionParams} from '../../../utils/completionTypes';
import {familyProfile, type ModelFamily} from './modelFamily';

export interface ThinkingRequest {
  family: ModelFamily;
  enabled: boolean;
  /** Token budget for the thinking block when enabled. */
  budgetTokens?: number;
}

/** Default thinking budgets by context window. */
export function thinkingBudgetFor(nCtx: number): number {
  if (nCtx <= 4096) {
    return 384;
  }
  if (nCtx <= 8192) {
    return 768;
  }
  return 1536;
}

/**
 * Params that switch thinking for one request. Always sent explicitly, in
 * both directions, because LFM3's template thinks unless told not to.
 */
export function thinkingParams(
  request: ThinkingRequest,
): Partial<ApiCompletionParams> {
  const params: Partial<ApiCompletionParams> = {
    enable_thinking: request.enabled,
    reasoning_format: 'auto',
    chat_template_kwargs: {enable_thinking: request.enabled},
  };
  if (request.enabled && request.budgetTokens) {
    (params as Record<string, unknown>).thinking_budget_tokens =
      request.budgetTokens;
  }
  return params;
}

/**
 * True when switching thinking for this family rewrites the start of the
 * prompt, so the next turn pays a full prompt evaluation. The UI can use it
 * to explain a slower first token after the toggle.
 */
export function thinkingToggleBreaksCache(family: ModelFamily): boolean {
  return familyProfile(family).thinkingSwitch === 'prefix';
}
