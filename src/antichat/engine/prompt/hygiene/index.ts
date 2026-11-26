/**
 * Output hygiene (H14): what the user sees is the model's answer, never its
 * template tokens, a leaked thinking block or half-written markdown.
 *
 * `cleanModelOutput` is the single entry point for the display path (M2 calls
 * it for the streaming bubble and the stored message) and for assistant text
 * that goes back into the context.
 */
import {normalizeModelText} from './normalizeModelText';
import {repairUnfinishedMarkdown, type OpenConstructs} from './markdownRepair';
import {stripSpecialTokens} from './specialTokens';
import {
  THINK_CLOSE,
  THINK_OPEN,
  parseThinkingContent,
  unclosedThinkAsAnswer,
} from './thinking';

export * from './thinking';
export {stripSpecialTokens} from './specialTokens';
export {normalizeModelText} from './normalizeModelText';
export {
  truncateAtRepeatedClause,
  isRepetitionFromTheStart,
} from './loopDetection';
export {repairUnfinishedMarkdown} from './markdownRepair';
export type {OpenConstructs, MarkdownRepair} from './markdownRepair';

export interface CleanOptions {
  /** True while tokens are still arriving. */
  streaming?: boolean;
  /** Close open markdown so a partial answer renders. Default: `streaming`. */
  repairMarkdown?: boolean;
  /** Fold look-alike characters and unit spellings. Default true. */
  normalize?: boolean;
  /** Cut a runaway repetition at the end of the text. Default true. */
  cutTailLoop?: boolean;
}

export interface CleanOutput {
  /** The answer, ready to render. */
  content: string;
  /** Thinking text separated from the answer, or null. */
  reasoning: string | null;
  /** False while a thinking block is still open. */
  reasoningComplete: boolean;
  /** The text ends in a runaway repetition: the caller should stop the run. */
  loopDetected: boolean;
  /** Markdown constructs that were open at the end (streaming only). */
  open: OpenConstructs | null;
}

// Other families' thinking markup, mapped onto <think> … </think>.
const THINK_ALIASES: Array<[RegExp, string]> = [
  // Gemma 4: <|channel>thought\n … <channel|>
  [/<\|channel\|?>\s*(?:thought|thinking|analysis)\s*\n?/gi, THINK_OPEN],
  [/<channel\|>/gi, THINK_CLOSE],
  // gpt-oss style channels
  [/<\|channel\|>final<\|message\|>/gi, THINK_CLOSE],
  [/<\/?(?:thinking|thought|reasoning)>/gi, ''],
];

const normaliseThinkMarkup = (text: string): string => {
  if (!text.includes('<')) {
    return text;
  }
  let out = text;
  for (const [pattern, replacement] of THINK_ALIASES) {
    out = out.replace(pattern, match => {
      if (replacement) {
        return replacement;
      }
      return match.startsWith('</') ? THINK_CLOSE : THINK_OPEN;
    });
  }
  return out;
};

const KNOWN_TAG_PREFIXES = [
  THINK_OPEN,
  THINK_CLOSE,
  '<tool_call>',
  '</tool_call>',
  '<start_of_turn>',
  '<end_of_turn>',
  '<channel|>',
  '<turn|>',
];

/**
 * While streaming, a marker can arrive in pieces ("<|im_", "</thi"). Hold the
 * fragment back so it never shows for a frame.
 */
export function holdBackPartialMarker(text: string): string {
  const lastOpen = text.lastIndexOf('<');
  if (lastOpen === -1 || text.length - lastOpen > 40) {
    return text;
  }
  const fragment = text.slice(lastOpen);
  if (fragment.includes('>') || /\s/.test(fragment)) {
    return text;
  }
  if (/^<\|[^<>|]*\|?$/.test(fragment)) {
    return text.slice(0, lastOpen);
  }
  if (
    fragment.length > 1 &&
    KNOWN_TAG_PREFIXES.some(tag => tag.startsWith(fragment))
  ) {
    return text.slice(0, lastOpen);
  }
  return text;
}

const TAIL_WINDOW = 1600;
const MIN_PERIOD = 6;
const MAX_PERIOD = 240;
const TAIL_REPEATS = 4;

/**
 * Index at which a runaway repetition at the END of the text starts repeating
 * (the first copy is kept), or -1. Deliberately strict — the same unit four
 * times in a row — so tables, code and lists are never cut.
 */
export function findTailLoop(text: string): number {
  const offset = Math.max(0, text.length - TAIL_WINDOW);
  const tail = text.slice(offset);
  const maxPeriod = Math.min(
    MAX_PERIOD,
    Math.floor(tail.length / TAIL_REPEATS),
  );
  for (let period = MIN_PERIOD; period <= maxPeriod; period++) {
    const unit = tail.slice(tail.length - period);
    if (!/[\p{L}\p{N}]/u.test(unit)) {
      continue;
    }
    let repeats = 1;
    while (
      (repeats + 1) * period <= tail.length &&
      tail.slice(
        tail.length - (repeats + 1) * period,
        tail.length - repeats * period,
      ) === unit
    ) {
      repeats++;
    }
    if (repeats >= TAIL_REPEATS) {
      return offset + tail.length - (repeats - 1) * period;
    }
  }
  return -1;
}

const CODE_SPAN = /```[\s\S]*?(?:```|$)|`[^`\n]*`/g;

const mapOutsideCode = (
  text: string,
  transform: (segment: string) => string,
): string => {
  let out = '';
  let cursor = 0;
  for (const span of text.matchAll(CODE_SPAN)) {
    const start = span.index ?? 0;
    out += transform(text.slice(cursor, start)) + span[0];
    cursor = start + span[0].length;
  }
  return out + transform(text.slice(cursor));
};

/** Clean raw model text for display or for re-use as context. */
export function cleanModelOutput(
  raw: string,
  options: CleanOptions = {},
): CleanOutput {
  const streaming = options.streaming ?? false;
  const repair = options.repairMarkdown ?? streaming;
  if (!raw) {
    return {
      content: '',
      reasoning: null,
      reasoningComplete: true,
      loopDetected: false,
      open: null,
    };
  }

  let source = normaliseThinkMarkup(raw);
  if (streaming) {
    source = holdBackPartialMarker(source);
  }

  const parts = parseThinkingContent(source);
  let content: string;
  let reasoning = parts.thinkingContent;
  let reasoningComplete = true;
  if (!parts.hasThinking) {
    content = parts.normalContent;
  } else if (parts.isThinkingComplete) {
    content = `${parts.normalContent}${parts.normalAfterThink ?? ''}`;
  } else if (streaming) {
    content = parts.normalContent;
    reasoningComplete = false;
  } else {
    // The run ended inside a thinking block: the text is all there is, so it
    // is the answer (Private Mind's rule).
    content = unclosedThinkAsAnswer(source);
    reasoning = null;
  }

  content = stripSpecialTokens(content);
  if (reasoning) {
    reasoning = stripSpecialTokens(reasoning).trim();
  }
  if (options.normalize ?? true) {
    content = mapOutsideCode(content, normalizeModelText);
  }
  content = content.replace(/^\s*\n/, '');
  if (!streaming) {
    content = content.trim();
  }

  let loopDetected = false;
  if (options.cutTailLoop ?? true) {
    const loopAt = findTailLoop(content);
    if (loopAt !== -1) {
      loopDetected = true;
      content = content.slice(0, loopAt).trimEnd();
    }
  }

  let open: OpenConstructs | null = null;
  if (repair) {
    const repaired = repairUnfinishedMarkdown(content);
    content = repaired.text;
    open = repaired.open;
  }

  return {content, reasoning, reasoningComplete, loopDetected, open};
}

/**
 * Assistant text as it should go back into the context: no thinking, no
 * leaked markers. Cheap enough to run over the whole history every turn.
 */
export function cleanForContext(raw: string): string {
  if (!raw || !raw.includes('<')) {
    return raw;
  }
  return cleanModelOutput(raw, {
    normalize: false,
    cutTailLoop: false,
    repairMarkdown: false,
  }).content;
}
