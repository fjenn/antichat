/**
 * Plain text, Markdown, code, JSON, HTML and RTF. No dependency: Hermes
 * decodes UTF-8 only, so the other encodings are done here.
 */
import {ExtractError} from './types';
import type {DocumentKind, ExtractedDocument, ExtractLimits} from './types';

function decodeUtf16(bytes: Uint8Array, littleEndian: boolean): string {
  let out = '';
  for (let i = 0; i + 1 < bytes.length; i += 2) {
    out += String.fromCharCode(
      littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return out;
}

/** UTF-8 by hand; returns null on the first invalid sequence. */
function decodeUtf8Strict(bytes: Uint8Array): string | null {
  const parts: string[] = [];
  let chunk = '';
  let i = 0;
  while (i < bytes.length) {
    const b = bytes[i];
    let code: number;
    let extra: number;
    if (b < 0x80) {
      code = b;
      extra = 0;
    } else if (b >= 0xc2 && b < 0xe0) {
      code = b & 0x1f;
      extra = 1;
    } else if (b >= 0xe0 && b < 0xf0) {
      code = b & 0x0f;
      extra = 2;
    } else if (b >= 0xf0 && b < 0xf5) {
      code = b & 0x07;
      extra = 3;
    } else {
      return null;
    }
    if (i + extra >= bytes.length + (extra === 0 ? 1 : 0)) {
      return null;
    }
    for (let k = 1; k <= extra; k++) {
      const next = bytes[i + k];
      if ((next & 0xc0) !== 0x80) {
        return null;
      }
      code = (code << 6) | (next & 0x3f);
    }
    i += extra + 1;
    chunk += String.fromCodePoint(code);
    if (chunk.length > 8192) {
      parts.push(chunk);
      chunk = '';
    }
  }
  parts.push(chunk);
  return parts.join('');
}

function decodeLatin1(bytes: Uint8Array): string {
  const parts: string[] = [];
  for (let i = 0; i < bytes.length; i += 8192) {
    parts.push(
      String.fromCharCode.apply(
        null,
        bytes.subarray(i, i + 8192) as unknown as number[],
      ),
    );
  }
  return parts.join('');
}

/** Bytes to text: BOM, then UTF-8, then Latin-1 when UTF-8 is invalid. */
export function decodeText(bytes: Uint8Array): string {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return decodeUtf8Strict(bytes.subarray(3)) ?? decodeLatin1(bytes);
  }
  if (bytes[0] === 0xff && bytes[1] === 0xfe) {
    return decodeUtf16(bytes.subarray(2), true);
  }
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    return decodeUtf16(bytes.subarray(2), false);
  }
  return decodeUtf8Strict(bytes) ?? decodeLatin1(bytes);
}

const ENTITIES: Record<string, string> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
  ndash: '–',
  mdash: '—',
  hellip: '…',
  euro: '€',
  copy: '©',
};

export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, name) => {
    if (name[0] === '#') {
      const code =
        name[1] === 'x' || name[1] === 'X'
          ? parseInt(name.slice(2), 16)
          : parseInt(name.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code < 0x110000
        ? String.fromCodePoint(code)
        : whole;
    }
    return ENTITIES[name.toLowerCase()] ?? whole;
  });
}

export function htmlToText(html: string): string {
  return decodeEntities(
    html
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/<(script|style|head|svg|noscript)\b[\s\S]*?<\/\1>/gi, '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<li\b[^>]*>/gi, '\n- ')
      .replace(/<\/(td|th)>/gi, ' | ')
      .replace(/<h([1-6])\b[^>]*>/gi, (_m, n) => `\n\n${'#'.repeat(+n)} `)
      .replace(
        /<\/?(p|div|section|article|tr|table|ul|ol|h[1-6]|blockquote|pre)\b[^>]*>/gi,
        '\n',
      )
      .replace(/<[^>]+>/g, ''),
  )
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/[ \t]{2,}/g, ' ')
    .trim();
}

const RTF_SKIP =
  /^(fonttbl|colortbl|stylesheet|info|pict|themedata|datastore|\*)$/;

export function rtfToText(rtf: string): string {
  let out = '';
  let i = 0;
  const skipDepth: number[] = [];
  let depth = 0;
  let ucSkip = 1;
  const skipping = () => skipDepth.length > 0;
  while (i < rtf.length) {
    const ch = rtf[i];
    if (ch === '{') {
      depth++;
      i++;
      // A group that starts with a destination we do not want.
      const m = /^\\(\*|[a-z]+)/.exec(rtf.slice(i, i + 24));
      if (m && RTF_SKIP.test(m[1])) {
        skipDepth.push(depth);
      }
    } else if (ch === '}') {
      if (skipDepth[skipDepth.length - 1] === depth) {
        skipDepth.pop();
      }
      depth--;
      i++;
    } else if (ch === '\\') {
      const next = rtf[i + 1];
      if (next === "'") {
        if (!skipping()) {
          out += String.fromCharCode(parseInt(rtf.slice(i + 2, i + 4), 16));
        }
        i += 4;
      } else if (next === '\\' || next === '{' || next === '}') {
        if (!skipping()) {
          out += next;
        }
        i += 2;
      } else {
        const m = /^\\([a-z]+)(-?\d+)? ?/i.exec(rtf.slice(i, i + 40));
        if (!m) {
          i += 2;
          continue;
        }
        i += m[0].length;
        const [, word, arg] = m;
        if (skipping()) {
          continue;
        }
        if (word === 'par' || word === 'line' || word === 'row') {
          out += '\n';
        } else if (word === 'tab' || word === 'cell') {
          out += '\t';
        } else if (word === 'uc') {
          ucSkip = Number(arg ?? 1);
        } else if (word === 'u' && arg) {
          const code = Number(arg);
          out += String.fromCharCode(code < 0 ? code + 65536 : code);
          // The fallback characters that follow \uN.
          for (let k = 0; k < ucSkip && i < rtf.length; k++) {
            i += rtf[i] === '\\' && rtf[i + 1] === "'" ? 4 : 1;
          }
        }
      }
    } else {
      if (!skipping() && ch !== '\r' && ch !== '\n') {
        out += ch;
      }
      i++;
    }
  }
  return out.replace(/\n{3,}/g, '\n\n').trim();
}

/** One-page document from text-like content. */
export function extractText(
  input: Uint8Array | string,
  kind: DocumentKind,
  limits: ExtractLimits,
): ExtractedDocument {
  let text = typeof input === 'string' ? input : decodeText(input);
  if (kind === 'html') {
    text = htmlToText(text);
  } else if (kind === 'rtf') {
    text = rtfToText(text);
  }
  text = text.replace(/\r\n?/g, '\n').replace(/\u0000/g, '');
  if (!text.trim()) {
    throw new ExtractError('empty', 'The file has no text');
  }
  const warnings: string[] = [];
  if (text.length > limits.maxChars) {
    text = text.slice(0, limits.maxChars);
    warnings.push('truncated');
  }
  return {
    kind,
    pageLabel: 'section',
    pages: [{page: 1, text}],
    tables: [],
    warnings,
  };
}
