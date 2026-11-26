/**
 * Clean-up of text taken from a PDF's text layer or from OCR: words split
 * by a hyphen at a line end are joined, invisible characters go, and hard
 * line wraps become paragraphs. Lists, headings and table-like lines stay
 * on their own lines.
 */
const INVISIBLE = new RegExp(
  '[\\u0000-\\u0008\\u000b-\\u000c\\u000e-\\u001f\\u007f\\u00ad\\u200b-\\u200f\\u2028-\\u2029\\u202a-\\u202e\\u2060\\ufeff]',
  'g',
);
const LIST_OR_HEADING = /^(\s*([-•·*▪◦–]|\d{1,3}[.)]|[a-z][.)])\s+|#{1,6}\s)/i;

export function normalizePdfText(text: string): string {
  const lines = text
    .replace(/\r\n?/g, '\n')
    .replace(INVISIBLE, '')
    .replace(/[ \t ]+/g, ' ')
    .split('\n')
    .map(line => line.trim());
  const out: string[] = [];
  let paragraph = '';
  const flush = () => {
    if (paragraph) {
      out.push(paragraph);
      paragraph = '';
    }
  };
  for (const line of lines) {
    if (line === '') {
      flush();
      if (out.length > 0 && out[out.length - 1] !== '') {
        out.push('');
      }
      continue;
    }
    const tableLike = line.includes(' | ') || /\S {2,}\S.* {2,}\S/.test(line);
    if (LIST_OR_HEADING.test(line) || tableLike) {
      flush();
      out.push(line);
      continue;
    }
    if (!paragraph) {
      paragraph = line;
    } else if (/[A-Za-zÀ-ÿ]-$/.test(paragraph) && /^[a-zà-ÿ]/.test(line)) {
      paragraph = paragraph.slice(0, -1) + line;
    } else {
      paragraph += ' ' + line;
    }
    // A short line that ends a sentence closes the paragraph.
    if (line.length < 50 && /[.!?:]$/.test(line)) {
      flush();
    }
  }
  flush();
  return out
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}
