/**
 * Chat titles (H1): one short generation after the first reply.
 *
 * ChatGPT's titles are at most 36 characters, under five words, in the
 * user's language, with no end punctuation. Prompt: AntiChat Mac `title.txt`
 * (after Open WebUI), sanitiser: Mac `TitleService.sanitize` (after Osaurus),
 * fallback: Private Mind `toChatTitle` (break at a word).
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import {detectDominantScript} from './hygiene/normalizeModelText';
import type {ModelFamily} from './modelFamily';
import type {ChatMessage} from './types';
import {clipText, runUtilityCompletion} from './utility';

export const TITLE_MAX_CHARS = 36;
export const TITLE_MIN_WORDS = 2;
export const TITLE_MAX_WORDS = 5;
export const TITLE_MAX_TOKENS = 24;
const USER_CLIP = 600;

export const TITLE_SYSTEM_PROMPT =
  'You name chat conversations. Given the first message of a conversation, reply with ONLY a title of 2 to 5 words that names its topic. Write the title in the same language as the message. Do not answer the message. No quotes, no trailing punctuation, no emoji, no markdown, no explanations.';

/** Instruction for the cache-friendly variant, appended as a user turn. */
export const TITLE_INLINE_INSTRUCTION =
  'Give this conversation a title: 2 to 5 words that name its topic, written in the language I used above. Reply with ONLY the title. No quotes, no trailing punctuation, no emoji, no markdown, no explanations.';

const QUOTES = '"\'“”‘’«»„‚‹›「」『』`';
const TRAILING_PUNCTUATION = /[\s.,;:!?…。、！？：；·\-–—]+$/u;
const LEADING_LABEL =
  /^\s*(?:(?:title|titel|título|titre|titolo|subject|betreff|タイトル|标题|標題|제목)\s*[:：]\s*)+/iu;
const EMOJI = /[\p{Extended_Pictographic}️‍]/gu;
const UNSPACED = new Set(['cjk']);
/** Longest title in a script without spaces; longer output is a sentence. */
const UNSPACED_MAX_CHARS = 16;

// Words a title must not end on: what is left when a longer phrase is cut.
const DANGLING = new Set(
  (
    'a an the and or of for to in on at by with from vs your my is are if that which without ' +
    'der die das den dem ein eine und oder von für fuer mit zu zum zur im in am auf bei ohne dass ' +
    'el la los las un una y o de del para por con en a al ' +
    'le les des du et ou pour avec dans sur au aux à ' +
    'il lo gli i e di da per con su nel ' +
    'o os as um uma do da dos das em com no na ' +
    'het een en van voor met op te ' +
    'и или в на с по для от к о'
  ).split(' '),
);

const dropDanglingWords = (words: string[]): string[] => {
  const out = [...words];
  while (out.length && DANGLING.has(out[out.length - 1].toLowerCase())) {
    out.pop();
  }
  return out;
};

const stripWrapping = (text: string): string => {
  let out = text.trim();
  // Markdown emphasis / heading markers around the title.
  out = out.replace(/^[#*_`\s]+/, '').replace(/[*_`\s]+$/, '');
  let changed = true;
  while (changed && out.length > 1) {
    changed = false;
    if (QUOTES.includes(out[0])) {
      out = out.slice(1).trimStart();
      changed = true;
    }
    if (out.length && QUOTES.includes(out[out.length - 1])) {
      out = out.slice(0, -1).trimEnd();
      changed = true;
    }
  }
  return out;
};

const clampWords = (text: string, maxChars: number): string => {
  if (text.length <= maxChars) {
    return text;
  }
  let out = '';
  for (const word of text.split(' ')) {
    const candidate = out ? `${out} ${word}` : word;
    if (candidate.length > maxChars) {
      break;
    }
    out = candidate;
  }
  // One very long word (or an unspaced script): hard cut.
  return out || text.slice(0, maxChars);
};

/**
 * Turn raw model output into a title, or null when it is unusable (empty,
 * structural characters, a single word, an apology…).
 */
export function sanitizeTitle(
  raw: string,
  maxChars = TITLE_MAX_CHARS,
): string | null {
  const firstLine = raw
    .split(/\r?\n/)
    .map(line => line.trim())
    .find(line => line.length > 0);
  if (!firstLine) {
    return null;
  }
  let title = firstLine.replace(LEADING_LABEL, '');
  title = stripWrapping(title);
  title = title.replace(EMOJI, '').replace(/\s+/g, ' ').trim();
  title = title.replace(TRAILING_PUNCTUATION, '');
  title = stripWrapping(title).replace(TRAILING_PUNCTUATION, '');
  if (!title || /[<>{}|[\]]/.test(title)) {
    return null;
  }
  const unspaced = UNSPACED.has(detectDominantScript(title));
  if (unspaced) {
    return title.length >= 2 && title.length <= UNSPACED_MAX_CHARS
      ? title
      : null;
  }
  const words = title.split(' ').filter(Boolean);
  if (words.length < TITLE_MIN_WORDS) {
    return null;
  }
  // A sentence, not a title: the model answered instead of naming.
  if (words.length > TITLE_MAX_WORDS + 3) {
    return null;
  }
  title = clampWords(words.slice(0, TITLE_MAX_WORDS).join(' '), maxChars);
  const kept = dropDanglingWords(
    title.replace(TRAILING_PUNCTUATION, '').split(' ').filter(Boolean),
  );
  if (kept.length < TITLE_MIN_WORDS) {
    return null;
  }
  return kept.join(' ').replace(TRAILING_PUNCTUATION, '');
}

/**
 * Title from the user's own words: used at once while the model is busy and
 * whenever generation fails. Never ends in punctuation or an ellipsis.
 */
export function fallbackTitle(
  userMessage: string,
  maxChars = TITLE_MAX_CHARS,
): string {
  const collapsed = userMessage
    .replace(/```[\s\S]*?(?:```|$)/g, ' ')
    .replace(/[#*_`>]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!collapsed) {
    return 'New chat';
  }
  let title = collapsed;
  const limit = UNSPACED.has(detectDominantScript(collapsed))
    ? Math.min(maxChars, 20)
    : maxChars;
  if (title.length > limit) {
    const clipped = title.slice(0, limit);
    const lastBreak = clipped.lastIndexOf(' ');
    const endsOnWord = /\s/.test(title[limit]);
    title =
      !endsOnWord && lastBreak >= limit / 2
        ? clipped.slice(0, lastBreak)
        : clipped;
    const kept = dropDanglingWords(
      title.replace(TRAILING_PUNCTUATION, '').split(' '),
    );
    if (kept.length >= 2) {
      title = kept.join(' ');
    }
  }
  title = title.replace(TRAILING_PUNCTUATION, '');
  if (!title) {
    return 'New chat';
  }
  return title[0].toUpperCase() + title.slice(1);
}

/**
 * A title must be in the user's language. Languages cannot be told apart
 * cheaply, but scripts can: a Latin title for a Japanese, Russian or Arabic
 * message is rejected and the fallback (the user's own words) is used.
 */
export function titleMatchesScript(
  title: string,
  userMessage: string,
): boolean {
  const user = detectDominantScript(userMessage);
  if (user === 'latin' || user === 'other') {
    return true;
  }
  return detectDominantScript(title) === user;
}

/** Messages of one or two short words carry no topic to name. */
export function isTooShortToName(userMessage: string): boolean {
  const text = userMessage.trim();
  if (!text) {
    return true;
  }
  if (UNSPACED.has(detectDominantScript(text))) {
    return text.length < 4;
  }
  return text.split(/\s+/).length < 3 && text.length < 16;
}

export interface TitleRequest {
  engine: CompletionEngine;
  userMessage: string;
  assistantReply?: string;
  family?: ModelFamily;
  signal?: AbortSignal;
  timeoutMs?: number;
  /**
   * The chat request as it was sent (system + first user turn). When given,
   * the title is asked for as one more turn of that conversation, so the
   * prompt reuses the chat's KV cache and the next chat turn still finds its
   * prefix cached. Without it a stand-alone prompt is used.
   */
  chatMessages?: ChatMessage[];
}

export function buildTitleMessages(request: TitleRequest): ChatMessage[] {
  const reply = (request.assistantReply ?? '').trim();
  if (request.chatMessages?.length) {
    return [
      ...request.chatMessages,
      ...(reply ? [{role: 'assistant', content: reply}] : []),
      {role: 'user', content: TITLE_INLINE_INSTRUCTION},
    ];
  }
  // The reply is deliberately not shown: small models copy its first words
  // instead of naming the topic (measured on LFM3 and Qwen3.5-0.8B).
  const prompt = `Message:\n${clipText(request.userMessage, USER_CLIP)}\n\nTitle:`;
  return [
    {role: 'system', content: TITLE_SYSTEM_PROMPT},
    {role: 'user', content: prompt},
  ];
}

const STOPWORDS: Record<string, string[]> = {
  en: 'the and is are to of in for with what how do does can my you it this that'.split(
    ' ',
  ),
  de: 'der die das und ist nicht ich wie für mit ein eine mir bitte ohne zu auf was'.split(
    ' ',
  ),
  es: 'el la los las que es de para cómo como cuál mejor una un por con mi qué'.split(
    ' ',
  ),
  fr: 'le la les des est que pour comment une un je tu entre et du peux avec quoi'.split(
    ' ',
  ),
  it: 'il lo la che per come una un di è sono mi dammi con del della cosa'.split(
    ' ',
  ),
  pt: 'o os as que para como uma um de é não faço meu minha com todo mês do'.split(
    ' ',
  ),
  nl: 'de het een en ik hoe voor met is niet van wat mijn je goede naar op'.split(
    ' ',
  ),
};

const wordsOf = (text: string): string[] =>
  text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];

/**
 * Best guess at the language of Latin-script text from its function words,
 * or null when there is no clear winner. Only good enough to tell "clearly
 * not English" from the rest, which is all the title guard needs.
 */
export function guessLatinLanguage(text: string): string | null {
  const words = wordsOf(text);
  let best: string | null = null;
  let bestScore = 0;
  let second = 0;
  for (const [language, list] of Object.entries(STOPWORDS)) {
    const score = words.filter(word => list.includes(word)).length;
    if (score > bestScore) {
      second = bestScore;
      bestScore = score;
      best = language;
    } else if (score > second) {
      second = score;
    }
  }
  return bestScore >= 2 && bestScore > second ? best : null;
}

/**
 * Guard against an English title for a non-English chat, the usual failure
 * of small models. For a message that is clearly not English, most words of
 * the title must come from the conversation itself (same four-letter stem).
 */
export function titleMatchesLanguage(
  title: string,
  userMessage: string,
  assistantReply = '',
): boolean {
  if (!titleMatchesScript(title, userMessage)) {
    return false;
  }
  const language = guessLatinLanguage(userMessage);
  if (!language || language === 'en') {
    return true;
  }
  const stems = new Set(
    wordsOf(`${userMessage} ${assistantReply}`).map(word => word.slice(0, 4)),
  );
  const content = wordsOf(title).filter(word => word.length >= 4);
  if (!content.length) {
    return true;
  }
  const known = content.filter(word => stems.has(word.slice(0, 4))).length;
  return known / content.length >= 0.6;
}

export interface TitleResult {
  title: string;
  /** False when the fallback was used. */
  generated: boolean;
  tokensCached?: number;
}

/** Generate a title; always returns something usable. */
export async function generateTitle(
  request: TitleRequest,
): Promise<TitleResult> {
  const fallback = fallbackTitle(request.userMessage);
  // "hi", "thanks", "ok?": nothing to name yet. Measured on LFM3 and
  // Qwen3.5: the model titles its own instruction or itself instead.
  if (isTooShortToName(request.userMessage)) {
    return {title: fallback, generated: false};
  }
  const result = await runUtilityCompletion({
    engine: request.engine,
    messages: buildTitleMessages(request),
    maxTokens: TITLE_MAX_TOKENS,
    temperature: 0.2,
    family: request.family,
    signal: request.signal,
    timeoutMs: request.timeoutMs ?? 8000,
  });
  const title = result ? sanitizeTitle(result.text) : null;
  if (
    !title ||
    !titleMatchesLanguage(title, request.userMessage, request.assistantReply)
  ) {
    return {
      title: fallback,
      generated: false,
      tokensCached: result?.tokensCached,
    };
  }
  return {title, generated: true, tokensCached: result?.tokensCached};
}
