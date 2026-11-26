/**
 * Unfinished-markdown repair for text that is still streaming.
 *
 * The renderer (M2) gets a string that always parses as complete markdown, so
 * a half-written code fence, bold run, formula or link never flashes as raw
 * markup. The stored message is never changed: this is a display hand-off.
 */

export interface OpenConstructs {
  codeFence: boolean;
  inlineCode: boolean;
  bold: boolean;
  italic: boolean;
  strikethrough: boolean;
  math: boolean;
  link: boolean;
}

export interface MarkdownRepair {
  /** Text with every open construct closed (or its dangling opener removed). */
  text: string;
  /** What was open at the end of the input. */
  open: OpenConstructs;
}

const FENCE_LINE = /^ {0,3}(```+|~~~+)/;

const NOTHING_OPEN: OpenConstructs = {
  codeFence: false,
  inlineCode: false,
  bold: false,
  italic: false,
  strikethrough: false,
  math: false,
  link: false,
};

/** The fence that is still open at the end of `text`, or null. */
const openFence = (text: string): string | null => {
  let fence: string | null = null;
  for (const line of text.split('\n')) {
    const match = FENCE_LINE.exec(line);
    if (!match) {
      continue;
    }
    const marker = match[1];
    if (fence === null) {
      fence = marker;
    } else if (
      marker[0] === fence[0] &&
      marker.length >= fence.length &&
      line.trim() === marker
    ) {
      fence = null;
    }
  }
  return fence;
};

const countOccurrences = (text: string, needle: string): number =>
  needle ? text.split(needle).length - 1 : 0;

/** Inline code spans are opaque to every other inline rule. */
const withoutInlineCode = (line: string): string =>
  line.replace(/`[^`\n]*`/g, match => ' '.repeat(match.length));

const lastBlock = (text: string): {head: string; block: string} => {
  const cut = text.lastIndexOf('\n\n');
  return cut === -1
    ? {head: '', block: text}
    : {head: text.slice(0, cut + 2), block: text.slice(cut + 2)};
};

const DANGLING_LINE = /\n[ \t]*(?:[-*+]|\d+[.)]|#{1,6}|>)[ \t]*$/;

/**
 * Close whatever markdown is still open at the end of a partial answer.
 * Safe on complete text: it returns it unchanged.
 */
export function repairUnfinishedMarkdown(input: string): MarkdownRepair {
  if (!input) {
    return {text: input, open: {...NOTHING_OPEN}};
  }
  const open: OpenConstructs = {...NOTHING_OPEN};

  const fence = openFence(input);
  if (fence !== null) {
    open.codeFence = true;
    return {
      text: `${input}${input.endsWith('\n') ? '' : '\n'}${fence}`,
      open,
    };
  }

  // A list marker, heading marker or quote marker with nothing after it yet.
  let text = input.replace(DANGLING_LINE, '');

  // Block math: $$ … or \[ … still open.
  const blockMathOpen =
    countOccurrences(text, '$$') % 2 === 1 ||
    countOccurrences(text, '\\[') > countOccurrences(text, '\\]');
  if (blockMathOpen) {
    open.math = true;
    const usesDollars = countOccurrences(text, '$$') % 2 === 1;
    if (usesDollars && text.trimEnd().endsWith('$$')) {
      // Only the opener has arrived.
      return {text: text.trimEnd().slice(0, -2).trimEnd(), open};
    }
    return {text: `${text}${usesDollars ? '\n$$' : '\\]'}`, open};
  }

  const {head, block} = lastBlock(text);
  let tail = block;

  // A link or image whose target is still streaming: show the label only.
  const partialLink = /(!?)\[([^\]\n]*)\]\([^)\n]*$/.exec(tail);
  if (partialLink) {
    open.link = true;
    tail =
      tail.slice(0, partialLink.index) +
      (partialLink[1] === '!' ? '' : partialLink[2]);
  }

  // Inline code on the last line.
  const lastLineStart = tail.lastIndexOf('\n') + 1;
  const lastLine = tail.slice(lastLineStart);
  if (countOccurrences(lastLine, '`') % 2 === 1) {
    open.inlineCode = true;
    tail = tail.endsWith('`') ? tail.slice(0, -1) : `${tail}\``;
    return {text: head + tail, open};
  }

  const visible = withoutInlineCode(tail);

  if (countOccurrences(visible, '\\(') > countOccurrences(visible, '\\)')) {
    open.math = true;
    tail = `${tail}\\)`;
    return {text: head + tail, open};
  }

  if (countOccurrences(visible, '~~') % 2 === 1) {
    open.strikethrough = true;
    tail = tail.endsWith('~~') ? tail.slice(0, -2) : `${tail}~~`;
  }

  const boldCount = countOccurrences(visible, '**');
  if (boldCount % 2 === 1) {
    open.bold = true;
    tail = /\*\*\s*$/.test(tail)
      ? tail.replace(/\*\*\s*$/, '')
      : `${tail.trimEnd()}**`;
  }

  // Single-asterisk emphasis; list bullets ("* item") are not emphasis.
  const singles = withoutInlineCode(tail)
    .replace(/\*\*/g, '')
    .replace(/^[ \t]*\*[ \t]/gm, '')
    // A free-standing asterisk is multiplication, not emphasis.
    .replace(/(^|\s)\*(?=\s|$)/g, '$1')
    .replace(/\\\*/g, '');
  const singleCount = countOccurrences(singles, '*');
  if (singleCount % 2 === 1) {
    open.italic = true;
    tail = /(^|[^*])\*\s*$/.test(tail)
      ? tail.replace(/\*\s*$/, '')
      : `${tail.trimEnd()}*`;
  }

  text = head + tail;
  return {text, open};
}
