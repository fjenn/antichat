/**
 * A deterministic stand-in for the model.
 *
 *  - It can only "know" what is in the prompt it is given: asked for the
 *    dog's name it searches the request's messages, so a correct answer
 *    proves the fact reached the prompt (directly or through the summary).
 *  - It emulates llama.cpp's prefix cache: `timings.cache_n` is the part of
 *    the prompt shared with the previous request.
 */
import type {
  ApiCompletionParams,
  CompletionEngine,
  CompletionResult,
} from '../../../../../utils/completionTypes';
import {FOLLOWUP_SYSTEM_PROMPT} from '../../../prompt/followups';
import {
  TITLE_INLINE_INSTRUCTION,
  TITLE_SYSTEM_PROMPT,
} from '../../../prompt/title';
import type {ChatMessage} from '../../../prompt/types';
import {SUMMARY_SYSTEM_PROMPT} from '../../summary';
import {estimateTokens, messageText} from '../../tokenCounter';

export interface FakeEngine extends CompletionEngine {
  calls: Array<{
    kind: 'chat' | 'summary' | 'title' | 'followups';
    messages: ChatMessage[];
    params: Record<string, unknown>;
    promptTokens: number;
    cachedTokens: number;
  }>;
  /** Cached / total prompt tokens over chat calls. */
  cacheHitRate(kind?: string): number;
  /** Overrides for tests. */
  titleFor?: (messages: ChatMessage[]) => string;
  failSummaries?: boolean;
}

const WORDS =
  'the a of and to in it is that for with as on be at by this have from or one had not but what all were we when your can said there use an each which she do how their if will up other about out many then them these so some her would make like him into time has look two more write go see number no way could people my than first water been call who oil its now find long down day did get come made may part'.split(
    ' ',
  );

/** A reply of roughly `words` words, the same for the same seed. */
export function filler(seed: number, words: number): string {
  let state = (seed * 2654435761) % 4294967296;
  const out: string[] = [];
  for (let i = 0; i < words; i++) {
    state = (state * 1664525 + 1013904223) % 4294967296;
    out.push(WORDS[Math.floor((state / 4294967296) * WORDS.length)]);
  }
  return out.join(' ');
}

const flatten = (messages: ChatMessage[]): string =>
  messages
    .map(message => `<${message.role}>\n${messageText(message).text}\n`)
    .join('');

const commonPrefix = (a: string, b: string): number => {
  const limit = Math.min(a.length, b.length);
  let i = 0;
  while (i < limit && a.charCodeAt(i) === b.charCodeAt(i)) {
    i++;
  }
  return i;
};

const FACT_SENTENCE =
  /[^.!?\n]*\b(?:my (?:dog|cat|name|sister|brother|birthday)|i am allergic|please remember)[^.!?\n]*[.!?]?/gi;

function fakeSummary(messages: ChatMessage[]): string {
  const input = messageText(messages[messages.length - 1]).text;
  const excerpt = input.slice(input.indexOf('Excerpt of the chat:'));
  const facts = new Set<string>();
  for (const line of excerpt.split('\n')) {
    if (!line.startsWith('[User]:')) {
      continue;
    }
    for (const match of line.slice(7).matchAll(FACT_SENTENCE)) {
      facts.add(match[0].trim());
    }
  }
  const userTurns = (excerpt.match(/^\[User\]:/gm) ?? []).length;
  const factLines = facts.size
    ? [...facts].map(fact => `- ${fact}`).join('\n')
    : '- none';
  return `FACTS:\n${factLines}\nSUMMARY:\nThe user asked ${userTurns} more questions about everyday topics and got short answers.`;
}

function fakeChatReply(messages: ChatMessage[], turn: number): string {
  const everything = flatten(messages);
  const last = [...messages].reverse().find(m => m.role === 'user');
  const question = last ? messageText(last).text : '';
  if (/what is my dog called/i.test(question)) {
    const match = /my dog is called (\w+)/i.exec(everything);
    return match
      ? `Your dog is called ${match[1]}.`
      : 'I do not know what your dog is called.';
  }
  const lengthHint = /\((\d+) words\)/.exec(question);
  return `Answer ${turn}: ${filler(turn + 1, lengthHint ? Number(lengthHint[1]) : 90)}.`;
}

export function createFakeEngine(): FakeEngine {
  let previous = '';
  let chatTurns = 0;
  const engine: FakeEngine = {
    calls: [],
    cacheHitRate(kind) {
      const calls = engine.calls.filter(call => !kind || call.kind === kind);
      const total = calls.reduce((sum, call) => sum + call.promptTokens, 0);
      const cached = calls.reduce((sum, call) => sum + call.cachedTokens, 0);
      return total ? cached / total : 0;
    },
    async completion(params: ApiCompletionParams): Promise<CompletionResult> {
      const messages = (params.messages ?? []) as ChatMessage[];
      const systemText =
        messages[0]?.role === 'system' ? messageText(messages[0]).text : '';
      const lastText = messages.length
        ? messageText(messages[messages.length - 1]).text
        : '';
      let kind: FakeEngine['calls'][number]['kind'] = 'chat';
      let content: string;
      if (systemText === SUMMARY_SYSTEM_PROMPT) {
        kind = 'summary';
        if (engine.failSummaries) {
          throw new Error('summary failed');
        }
        content = fakeSummary(messages);
      } else if (
        systemText === TITLE_SYSTEM_PROMPT ||
        lastText === TITLE_INLINE_INSTRUCTION
      ) {
        kind = 'title';
        content = engine.titleFor?.(messages) ?? 'Scripted Chat Title';
      } else if (systemText === FOLLOWUP_SYSTEM_PROMPT) {
        kind = 'followups';
        content =
          '{"suggestions": ["Can you give an example?", "What should I avoid?", "How long does it take?"]}';
      } else {
        content = fakeChatReply(messages, chatTurns++);
      }
      const prompt = flatten(messages);
      const promptTokens = estimateTokens(prompt);
      const cachedTokens = estimateTokens(
        prompt.slice(0, commonPrefix(prompt, previous)),
      );
      // The reply's tokens stay in the KV cache, as in llama.cpp.
      previous = `${prompt}<assistant>\n${content}\n`;
      engine.calls.push({
        kind,
        messages,
        params: params as Record<string, unknown>,
        promptTokens,
        cachedTokens,
      });
      return {
        text: content,
        content,
        tokens_evaluated: promptTokens,
        tokens_predicted: estimateTokens(content),
        timings: {
          cache_n: cachedTokens,
          prompt_n: promptTokens - cachedTokens,
        },
      };
    },
    async stopCompletion() {},
  };
  return engine;
}
