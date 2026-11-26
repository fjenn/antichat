/**
 * Test support: a CompletionEngine and a TokenCounter that talk to a local
 * `llama-server`. Used by the real-model evaluation and to record the
 * tokeniser fixtures; never bundled into the app.
 */
import http from 'http';

import type {
  ApiCompletionParams,
  CompletionEngine,
  CompletionResult,
} from '../../../../../utils/completionTypes';
import type {ChatMessage, ToolDefinition} from '../../../prompt/types';
import type {TokenCounter} from '../../tokenCounter';

export function postJson(
  port: number,
  path: string,
  body: unknown,
): Promise<any> {
  return new Promise((resolve, reject) => {
    const payload = Buffer.from(JSON.stringify(body));
    const request = http.request(
      {
        host: '127.0.0.1',
        port,
        path,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': payload.length,
        },
      },
      response => {
        const chunks: Buffer[] = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          try {
            const parsed = JSON.parse(text);
            if (parsed?.error) {
              reject(new Error(JSON.stringify(parsed.error).slice(0, 400)));
            } else {
              resolve(parsed);
            }
          } catch {
            reject(
              new Error(`bad response from ${path}: ${text.slice(0, 200)}`),
            );
          }
        });
      },
    );
    request.on('error', reject);
    request.write(payload);
    request.end();
  });
}

export interface ServerEngine extends CompletionEngine {
  /** Every result, in order, for cache statistics. */
  log: Array<{
    promptTokens: number;
    cachedTokens: number;
    predicted: number;
    ms: number;
  }>;
}

export function createServerEngine(port: number): ServerEngine {
  const log: ServerEngine['log'] = [];
  return {
    log,
    async completion(params: ApiCompletionParams): Promise<CompletionResult> {
      const source = params as Record<string, any>;
      const body: Record<string, unknown> = {
        messages: source.messages,
        max_tokens: source.n_predict ?? 512,
        cache_prompt: true,
        chat_template_kwargs: {
          enable_thinking: !!source.enable_thinking,
          ...source.chat_template_kwargs,
        },
      };
      for (const key of [
        'temperature',
        'top_p',
        'top_k',
        'min_p',
        'stop',
        'response_format',
        'tools',
        'seed',
      ]) {
        if (source[key] !== undefined) {
          body[key] = source[key];
        }
      }
      const started = Date.now();
      const response = await postJson(port, '/v1/chat/completions', body);
      const message = response.choices?.[0]?.message ?? {};
      const timings = response.timings ?? {};
      const cached = timings.cache_n ?? 0;
      const evaluated = timings.prompt_n ?? 0;
      log.push({
        promptTokens: cached + evaluated,
        cachedTokens: cached,
        predicted: timings.predicted_n ?? 0,
        ms: Date.now() - started,
      });
      return {
        text: message.content ?? '',
        content: message.content ?? '',
        reasoning_content: message.reasoning_content,
        tool_calls: message.tool_calls,
        timings,
        tokens_evaluated: cached + evaluated,
        tokens_predicted: timings.predicted_n,
        truncated: response.choices?.[0]?.finish_reason === 'length',
      };
    },
    async stopCompletion() {},
  };
}

export function createServerCounter(port: number): TokenCounter {
  const countText = async (text: string) => {
    if (!text) {
      return 0;
    }
    const response = await postJson(port, '/tokenize', {content: text});
    return response.tokens.length;
  };
  return {
    exact: true,
    countText,
    countPrompt: async (
      messages: readonly ChatMessage[],
      tools?: readonly ToolDefinition[],
    ) => {
      const formatted = await postJson(port, '/apply-template', {
        messages,
        ...(tools?.length ? {tools} : {}),
        chat_template_kwargs: {enable_thinking: false},
      });
      const response = await postJson(port, '/tokenize', {
        content: formatted.prompt,
        add_special: true,
        parse_special: true,
      });
      return response.tokens.length;
    },
  };
}
