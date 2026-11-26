/**
 * Truncation rules for single messages (H9, H11, H13):
 *
 *  - A tool result is cut when it is INSERTED (head kept, marker appended);
 *    it is never shortened again later, so the cached prefix stays valid. The
 *    full text stays in the database.
 *  - Pasted or attached text in one message may use at most half the prompt
 *    budget; the middle is removed (the start and the end of a document carry
 *    the title and the conclusion).
 *  - The newest user message is cut only as a last resort, when it alone does
 *    not fit the window.
 */
import type {ChatMessage} from '../prompt/types';
import type {TokenCounter} from './tokenCounter';

export const HEAD_MARKER = '\n[… truncated]';
export const MIDDLE_MARKER = '\n\n[… middle omitted to fit this model …]\n\n';

/** Keep the first `maxTokens` tokens' worth of text. */
export async function truncateHead(
  text: string,
  maxTokens: number,
  counter: TokenCounter,
): Promise<string> {
  // A token is at least one character, so short texts need no count.
  if (text.length <= maxTokens) {
    return text;
  }
  const tokens = await counter.countText(text);
  if (tokens <= maxTokens) {
    return text;
  }
  let keep = Math.floor((text.length * maxTokens) / tokens);
  for (let attempt = 0; attempt < 6; attempt++) {
    const candidate = text.slice(0, keep).trimEnd() + HEAD_MARKER;
    if ((await counter.countText(candidate)) <= maxTokens) {
      return candidate;
    }
    keep = Math.floor(keep * 0.85);
  }
  return text.slice(0, Math.max(0, keep)).trimEnd() + HEAD_MARKER;
}

/** Keep the start and the end; drop the middle. */
export async function truncateMiddle(
  text: string,
  maxTokens: number,
  counter: TokenCounter,
  headShare = 0.6,
): Promise<string> {
  if (text.length <= maxTokens) {
    return text;
  }
  const tokens = await counter.countText(text);
  if (tokens <= maxTokens) {
    return text;
  }
  let keep = Math.floor((text.length * maxTokens) / tokens);
  for (let attempt = 0; attempt < 6; attempt++) {
    const head = Math.floor(keep * headShare);
    const tail = keep - head;
    const candidate =
      text.slice(0, head).trimEnd() +
      MIDDLE_MARKER +
      text.slice(text.length - tail).trimStart();
    if ((await counter.countText(candidate)) <= maxTokens) {
      return candidate;
    }
    keep = Math.floor(keep * 0.85);
  }
  const head = Math.floor(keep * headShare);
  return text.slice(0, head).trimEnd() + MIDDLE_MARKER;
}

const mapText = async (
  message: ChatMessage,
  transform: (text: string) => Promise<string>,
): Promise<ChatMessage> => {
  if (typeof message.content === 'string') {
    const next = await transform(message.content);
    return next === message.content ? message : {...message, content: next};
  }
  if (Array.isArray(message.content)) {
    let changed = false;
    const parts: unknown[] = [];
    for (const part of message.content) {
      const typed = part as {type?: string; text?: string};
      if (typed?.type === 'text' && typeof typed.text === 'string') {
        const next = await transform(typed.text);
        changed = changed || next !== typed.text;
        parts.push({...typed, text: next});
      } else {
        parts.push(part);
      }
    }
    return changed ? {...message, content: parts} : message;
  }
  return message;
};

export interface TruncationLimits {
  toolResultTokens: number;
  attachmentTokens: number;
}

/**
 * Apply the insertion rules to every message. Deterministic: the same input
 * always gives the same output, so applying it on every turn does not change
 * earlier messages and the prefix stays cached.
 */
export async function applyInsertionLimits(
  messages: ChatMessage[],
  limits: TruncationLimits,
  counter: TokenCounter,
): Promise<ChatMessage[]> {
  const out: ChatMessage[] = [];
  for (const message of messages) {
    if (message.role === 'tool') {
      out.push(
        await mapText(message, text =>
          truncateHead(text, limits.toolResultTokens, counter),
        ),
      );
    } else if (message.role === 'user') {
      out.push(
        await mapText(message, text =>
          truncateMiddle(text, limits.attachmentTokens, counter),
        ),
      );
    } else {
      out.push(message);
    }
  }
  return out;
}

/** Last resort: shrink the text of one message to `maxTokens`. */
export function shrinkMessage(
  message: ChatMessage,
  maxTokens: number,
  counter: TokenCounter,
): Promise<ChatMessage> {
  return mapText(message, text => truncateMiddle(text, maxTokens, counter));
}
