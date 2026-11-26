/**
 * Token counting for context fitting.
 *
 * `countText` counts one string; `countPrompt` counts the whole request the
 * way the model will see it (chat template applied, tools rendered). On device
 * both go to the loaded llama.rn context, so the numbers are the model's own.
 * The character estimate exists only for the moments no context is loaded.
 */
import type {ChatMessage, ToolDefinition} from '../prompt/types';

export interface TokenCounter {
  /** True when counts come from the model's tokeniser. */
  readonly exact: boolean;
  countText(text: string): Promise<number>;
  countPrompt(
    messages: readonly ChatMessage[],
    tools?: readonly ToolDefinition[],
  ): Promise<number>;
}

/** Tokens a template adds around each message (role markers, newlines). */
export const MESSAGE_OVERHEAD_TOKENS = 6;
/** Tokens for BOS and the generation prompt. */
export const PROMPT_OVERHEAD_TOKENS = 8;
/** Assumed cost of one image when the projector's real count is unknown. */
export const IMAGE_TOKENS_ESTIMATE = 512;

const WIDE_CHARS = /[぀-ヿ㐀-䶿一-鿿가-힯؀-ۿЀ-ӿ]/g;

/** Characters → tokens, with scripts that tokenise densely counted as such. */
export function estimateTokens(text: string, charsPerToken = 3.3): number {
  if (!text) {
    return 0;
  }
  const wide = text.match(WIDE_CHARS)?.length ?? 0;
  const narrow = text.length - wide;
  return Math.ceil(narrow / charsPerToken + wide * 0.9);
}

/** The text of a message; images are reported separately. */
export function messageText(message: ChatMessage): {
  text: string;
  images: number;
} {
  const content = message.content;
  let text = '';
  let images = 0;
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    for (const part of content) {
      if (part && typeof part === 'object') {
        const typed = part as {type?: string; text?: unknown};
        if (typed.type === 'text' && typeof typed.text === 'string') {
          text += typed.text;
        } else if (typed.type === 'image_url' || typed.type === 'image') {
          images++;
        }
      }
    }
  }
  if (Array.isArray(message.tool_calls) && message.tool_calls.length > 0) {
    text += JSON.stringify(message.tool_calls);
  }
  if (typeof message.reasoning_content === 'string') {
    text += message.reasoning_content;
  }
  return {text, images};
}

export function createEstimatingCounter(charsPerToken = 3.3): TokenCounter {
  const countText = async (text: string) => estimateTokens(text, charsPerToken);
  return {
    exact: false,
    countText,
    countPrompt: async (messages, tools) => {
      let total = PROMPT_OVERHEAD_TOKENS;
      for (const message of messages) {
        const {text, images} = messageText(message);
        total +=
          estimateTokens(text, charsPerToken) +
          MESSAGE_OVERHEAD_TOKENS +
          images * IMAGE_TOKENS_ESTIMATE;
      }
      if (tools?.length) {
        total += estimateTokens(JSON.stringify(tools), charsPerToken) + 64;
      }
      return total;
    },
  };
}

/** The slice of a llama.rn context the counter needs. */
export interface TokenisingContext {
  tokenize(text: string): Promise<{tokens: number[]}>;
  getFormattedChat(
    messages: any[],
    template?: string | null,
    params?: Record<string, unknown>,
  ): Promise<{prompt: string} | string>;
}

export interface LlamaCounterOptions {
  charsPerToken?: number;
  /** Extra template arguments, e.g. `enable_thinking`. */
  templateParams?: Record<string, unknown>;
}

/**
 * Counter backed by the loaded model. Images are not tokenised (that needs
 * the projector); each is charged a fixed estimate on top of the text.
 */
export function createLlamaTokenCounter(
  context: TokenisingContext,
  options: LlamaCounterOptions = {},
): TokenCounter {
  const fallback = createEstimatingCounter(options.charsPerToken);
  const countText = async (text: string) => {
    if (!text) {
      return 0;
    }
    try {
      return (await context.tokenize(text)).tokens.length;
    } catch {
      return fallback.countText(text);
    }
  };
  return {
    exact: true,
    countText,
    countPrompt: async (messages, tools) => {
      try {
        let images = 0;
        const textOnly = messages.map(message => {
          const {images: count} = messageText(message);
          images += count;
          if (!Array.isArray(message.content)) {
            return message;
          }
          return {
            ...message,
            content: message.content.filter(
              part => (part as {type?: string})?.type === 'text',
            ),
          };
        });
        const formatted = await context.getFormattedChat(textOnly, null, {
          jinja: true,
          ...(tools?.length ? {tools: [...tools]} : {}),
          ...options.templateParams,
        });
        const prompt =
          typeof formatted === 'string' ? formatted : formatted.prompt;
        return (
          (await context.tokenize(prompt)).tokens.length +
          images * IMAGE_TOKENS_ESTIMATE
        );
      } catch {
        return fallback.countPrompt(messages, tools);
      }
    },
  };
}

/**
 * Memoise `countText` (history messages are counted again every turn) with a
 * bounded map. `countPrompt` is not cached: it is called once or twice a turn
 * on a prompt that is new each time.
 */
export function withTokenCache(
  counter: TokenCounter,
  maxEntries = 2000,
): TokenCounter {
  const cache = new Map<string, number>();
  return {
    exact: counter.exact,
    countPrompt: counter.countPrompt,
    countText: async text => {
      const hit = cache.get(text);
      if (hit !== undefined) {
        return hit;
      }
      const count = await counter.countText(text);
      if (cache.size >= maxEntries) {
        const oldest = cache.keys().next().value;
        if (oldest !== undefined) {
          cache.delete(oldest);
        }
      }
      cache.set(text, count);
      return count;
    },
  };
}
