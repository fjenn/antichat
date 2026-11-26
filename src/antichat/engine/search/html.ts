/** Small HTML helpers for result-page parsing (no DOM in Hermes). */

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
  rsquo: '’',
  lsquo: '‘',
  rdquo: '”',
  ldquo: '“',
  middot: '·',
  euro: '€',
  pound: '£',
  deg: '°',
  copy: '©',
  reg: '®',
  trade: '™',
  times: '×',
  laquo: '«',
  raquo: '»',
  rsaquo: '›',
  lsaquo: '‹',
};

const fromCode = (code: number): string => {
  if (!Number.isFinite(code) || code <= 0 || code > 0x10ffff) {
    return '';
  }
  try {
    return String.fromCodePoint(code);
  } catch {
    return '';
  }
};

export function decodeEntities(text: string): string {
  return text
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => fromCode(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec) => fromCode(Number(dec)))
    .replace(
      /&([a-z][a-z0-9]{1,7});/gi,
      (whole, name) => ENTITIES[name.toLowerCase()] ?? whole,
    );
}

/** Visible text of an HTML fragment: tags and comments out, entities decoded. */
export function textOf(html: string | undefined): string {
  if (!html) {
    return '';
  }
  return decodeEntities(
    html
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/<(script|style|svg)\b[\s\S]*?<\/\1>/gi, ' ')
      .replace(/<[^>]+>/g, ' '),
  )
    .replace(/\s+/g, ' ')
    .trim();
}

export function attribute(tag: string, name: string): string | undefined {
  const match = new RegExp(
    `\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`,
    'i',
  ).exec(tag);
  return match
    ? decodeEntities(match[1] ?? match[2] ?? match[3] ?? '')
    : undefined;
}

export const hostOf = (url: string): string => {
  const match = /^(?:https?:)?\/\/([^/?#]+)/i.exec(url);
  return match ? match[1].toLowerCase().replace(/^www\./, '') : '';
};

/** Dedupe key: host without www, path without trailing slash, no tracking. */
export function normalizeUrl(raw: string): string {
  const trimmed = raw.trim();
  const match = /^(?:https?:)?\/\/([^/?#]+)([^?#]*)(\?[^#]*)?/i.exec(trimmed);
  if (!match) {
    return trimmed.toLowerCase();
  }
  const host = match[1]
    .toLowerCase()
    .replace(/^www\./, '')
    .replace(/^m\./, '');
  let path = match[2] ?? '';
  while (path.endsWith('/')) {
    path = path.slice(0, -1);
  }
  const query = (match[3] ?? '')
    .slice(1)
    .split('&')
    .filter(
      part =>
        part &&
        !/^(?:utm_[a-z]+|fbclid|gclid|ref|ref_src|srsltid|mc_cid|mc_eid)=/i.test(
          part,
        ),
    )
    .join('&');
  return host + path + (query ? `?${query}` : '');
}

export const isHttpUrl = (url: string): boolean => /^https?:\/\//i.test(url);
