/**
 * Evaluation support: a CompletionEngine over a local `llama-server` that
 * passes tool parameters through, and a small worker pool. Never bundled.
 */
import type {
  ApiCompletionParams,
  CompletionEngine,
  CompletionResult,
} from '../../../../../utils/completionTypes';
import {postJson} from '../../../context/__tests__/support/llamaServer';

/** Sampling per model card, as in the Mac spike (tools/antichat/eval/common.py). */
export const SAMPLING: Record<string, Record<string, number>> = {
  qwen35: {
    temperature: 0.7,
    top_p: 0.8,
    top_k: 20,
    min_p: 0.0,
    presence_penalty: 1.5,
  },
  gemma4: {temperature: 1.0, top_p: 0.95, top_k: 64},
  lfm3: {temperature: 0.1, top_k: 50, repeat_penalty: 1.1},
  generic: {temperature: 0.7},
};

export const MODEL_NAMES: Record<string, string> = {
  gemma4: 'gemma-4-E2B-it-qat-UD-Q4_K_XL',
  lfm3: 'LFM3-1.7B-Q4_K_M',
  qwen35: 'Qwen3.5-4B-Q4_K_M',
};

export interface EvalEngine extends CompletionEngine {
  calls: number;
  promptTokens: number;
  generatedTokens: number;
}

const PASS_THROUGH = [
  'temperature',
  'top_p',
  'top_k',
  'min_p',
  'presence_penalty',
  'repeat_penalty',
  'stop',
  'response_format',
  'tools',
  'tool_choice',
  'parallel_tool_calls',
  'seed',
];

export function createEvalEngine(
  port: number,
  defaults: Record<string, unknown> = {},
): EvalEngine {
  const engine: EvalEngine = {
    calls: 0,
    promptTokens: 0,
    generatedTokens: 0,
    async completion(params: ApiCompletionParams): Promise<CompletionResult> {
      const source = {...defaults, ...(params as Record<string, any>)};
      const body: Record<string, unknown> = {
        messages: source.messages,
        max_tokens: source.n_predict ?? 768,
        cache_prompt: true,
        chat_template_kwargs: {
          enable_thinking: !!source.enable_thinking,
          ...source.chat_template_kwargs,
        },
      };
      for (const key of PASS_THROUGH) {
        if (source[key] !== undefined) {
          body[key] = source[key];
        }
      }
      if (body.tools && body.parallel_tool_calls === undefined) {
        body.parallel_tool_calls = true;
      }
      const response = await postJson(port, '/v1/chat/completions', body);
      const choice = response.choices?.[0] ?? {};
      const message = choice.message ?? {};
      const timings = response.timings ?? {};
      const prompt = (timings.cache_n ?? 0) + (timings.prompt_n ?? 0);
      engine.calls += 1;
      engine.promptTokens += prompt;
      engine.generatedTokens += timings.predicted_n ?? 0;
      return {
        text: message.content ?? '',
        content: message.content ?? '',
        reasoning_content: message.reasoning_content,
        tool_calls: message.tool_calls,
        timings,
        tokens_evaluated: prompt,
        tokens_predicted: timings.predicted_n,
        truncated: choice.finish_reason === 'length',
      };
    },
    async stopCompletion() {},
  };
  return engine;
}

/** Run `task` over `items` with at most `size` in flight. */
export async function pool<T, R>(
  items: T[],
  size: number,
  task: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from(
    {length: Math.min(size, items.length)},
    async () => {
      for (;;) {
        const index = next++;
        if (index >= items.length) {
          return;
        }
        results[index] = await task(items[index], index);
      }
    },
  );
  await Promise.all(workers);
  return results;
}

export const percentile = (values: number[], p: number): number => {
  if (values.length === 0) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[
    Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))
  ];
};
