import type {PortError} from '../../contracts';
import {translate, type MessageKey} from '../../locales';

/** "5s", "1m 20s": how long the model thought. */
export function formatThinkingTime(durationMs: number): string {
  const total = Math.max(1, Math.round(durationMs / 1000));
  if (total < 60) {
    return translate('thread.seconds', {count: total});
  }
  return translate('thread.minutes', {
    minutes: Math.floor(total / 60),
    seconds: total % 60,
  });
}

const ERROR_KEYS: Record<PortError['code'], MessageKey> = {
  model_not_loaded: 'errors.modelNotLoaded',
  out_of_memory: 'errors.outOfMemory',
  context_full: 'errors.contextFull',
  offline: 'errors.offline',
  cancelled: 'errors.cancelled',
  unsupported: 'errors.unsupported',
  failed: 'errors.generation',
};

/** Our own wording for a failed answer; the port's detail is for logs. */
export function errorMessage(error: PortError | undefined): string {
  return translate(error ? ERROR_KEYS[error.code] : 'errors.generation');
}

/** Markdown as plain text for copying and sharing an answer. */
export function plainText(markdown: string): string {
  return markdown.trim();
}

/** A quoted passage in front of the message it refers to. */
export function withQuote(text: string, quote: string | null): string {
  if (!quote) {
    return text;
  }
  const quoted = quote
    .split('\n')
    .map(line => `> ${line}`)
    .join('\n');
  return `${quoted}\n\n${text}`;
}

/** Can the image view load this? (The in-memory backend hands out made-up URIs.) */
export function isLoadableImage(uri: string): boolean {
  return /^(file|content|ph|assets-library|https?|data):/i.test(uri);
}

/**
 * Markdown for the select-text sheet, which shows an answer as one run of
 * text: a table has no cells there, so each row becomes a line.
 */
export function flowMarkdown(markdown: string): string {
  const out: string[] = [];
  let fenced = false;
  for (const line of markdown.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced;
      out.push(line);
    } else if (fenced) {
      out.push(line);
    } else if (/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line)) {
      // The |---|---| line under a table header: nothing to show.
    } else if (/^\s*\|.*\|\s*$/.test(line)) {
      const cells = line
        .trim()
        .replace(/^\||\|$/g, '')
        .split('|')
        .map(cell => cell.trim());
      out.push(`${cells.join(' · ')}  `);
    } else {
      out.push(line);
    }
  }
  return out.join('\n');
}
