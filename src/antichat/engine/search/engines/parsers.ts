/**
 * Result-page parsers. Regular expressions over the HTML, because Hermes has
 * no DOM; each parser reads the same nodes the Mac's selectors and Private
 * Mind's injected script read. A parser returns [] when the page has no
 * results it recognises; `looksBlocked` then tells a bot wall from an empty
 * result page.
 */
import {attribute, decodeEntities, hostOf, isHttpUrl, textOf} from '../html';
import type {SearchResult} from '../types';
import type {EngineConfig} from './config';

type Parsed = Omit<SearchResult, 'engine'>;

const MAX_RESULTS = 12;

/** DuckDuckGo wraps outbound links: //duckduckgo.com/l/?uddg=<encoded>. */
export function derefDuckDuckGo(href: string): string {
  const match = /[?&]uddg=([^&]+)/.exec(href);
  if (match) {
    try {
      return decodeURIComponent(match[1]);
    } catch {
      return href;
    }
  }
  return href.startsWith('//') ? `https:${href}` : href;
}

export function parseDuckDuckGo(html: string): Parsed[] {
  const out: Parsed[] = [];
  const blocks = html
    .split(/<div[^>]+class="[^"]*\bresult\b[^"]*results_links[^"]*"/i)
    .slice(1);
  for (const block of blocks) {
    if (/result--ad\b/.test(block.slice(0, 200))) {
      continue;
    }
    const link =
      /<a\b[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*>([\s\S]*?)<\/a>/i.exec(
        block,
      );
    if (!link) {
      continue;
    }
    const url = derefDuckDuckGo(attribute(link[0], 'href') ?? '');
    const snippet =
      /<a\b[^>]*class="[^"]*\bresult__snippet\b[^"]*"[^>]*>([\s\S]*?)<\/a>/i.exec(
        block,
      );
    out.push({title: textOf(link[1]), url, snippet: textOf(snippet?.[1])});
    if (out.length >= MAX_RESULTS) {
      break;
    }
  }
  return out;
}

export function parseDuckDuckGoLite(html: string): Parsed[] {
  const out: Parsed[] = [];
  const pattern =
    /<a\b[^>]*class=['"]result-link['"][^>]*>([\s\S]*?)<\/a>|<a\b[^>]*href=[^>]*class=['"]result-link['"][^>]*>([\s\S]*?)<\/a>/gi;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(html)) !== null && out.length < MAX_RESULTS) {
    const url = derefDuckDuckGo(attribute(match[0], 'href') ?? '');
    const rest = html.slice(pattern.lastIndex, pattern.lastIndex + 3000);
    const next = rest.search(/class=['"]result-link['"]/i);
    const scope = next === -1 ? rest : rest.slice(0, next);
    const snippet =
      /<td\b[^>]*class=['"]result-snippet['"][^>]*>([\s\S]*?)<\/td>/i.exec(
        scope,
      );
    out.push({
      title: textOf(match[1] ?? match[2]),
      url,
      snippet: textOf(snippet?.[1]),
    });
  }
  return out;
}

/**
 * Brave serves result links as opaque `/go/v1/…` tokens (resolved by script
 * on click), so the URL is rebuilt from the breadcrumb under the title:
 * "https://bbc.co.uk › sport › tennis" → https://bbc.co.uk/sport/tennis.
 * A breadcrumb that is cut short ("…") or has spaces yields the site root
 * plus the clean leading segments, flagged approximate.
 */
export function urlFromBreadcrumb(
  cite: string,
): {url: string; approximate: boolean} | null {
  const parts = cite
    .split('›')
    .map(part => part.trim())
    .filter(Boolean);
  if (parts.length === 0) {
    return null;
  }
  let origin = parts[0];
  if (!/^https?:\/\//i.test(origin)) {
    origin = `https://${origin}`;
  }
  if (!/^https?:\/\/[a-z0-9.-]+\.[a-z]{2,}$/i.test(origin)) {
    return null;
  }
  const segments: string[] = [];
  let approximate = false;
  for (const part of parts.slice(1)) {
    if (/[…\s]|\.\.\./.test(part) || !/^[\w.~%@+,;=:()!*'-]+$/.test(part)) {
      approximate = true;
      break;
    }
    segments.push(part);
  }
  // Even a clean breadcrumb may hide a trailing slug or query string.
  return {
    url: segments.length ? `${origin}/${segments.join('/')}` : `${origin}/`,
    approximate: approximate || segments.length > 0,
  };
}

export function parseBrave(html: string): Parsed[] {
  const out: Parsed[] = [];
  const blocks = html
    .split(/<div[^>]+class="snippet\b[^"]*"[^>]*data-type="web"/i)
    .slice(1);
  for (const raw of blocks) {
    const block = raw.slice(0, 12000);
    const titleTag =
      /<div[^>]+class="[^"]*\bsearch-snippet-title\b[^"]*"[^>]*>([\s\S]*?)<\/div>/i.exec(
        block,
      );
    const title =
      textOf(titleTag?.[1]) ||
      (titleTag ? (attribute(titleTag[0], 'title') ?? '') : '');
    if (!title) {
      continue;
    }
    // A direct outbound link, when Brave serves one, beats the breadcrumb.
    const direct =
      /<a\b[^>]*href="(https?:\/\/[^"]+)"[^>]*class="[^"]*\b(?:l1|heading-serpresult)\b/i.exec(
        block,
      );
    let url = direct ? decodeEntities(direct[1]) : '';
    let approximate = false;
    if (!url || /(^|\.)brave\.com$/i.test(hostOf(url))) {
      const cite = /<cite\b[^>]*>([\s\S]*?)<\/cite>/i.exec(block);
      const rebuilt = cite ? urlFromBreadcrumb(textOf(cite[1])) : null;
      if (!rebuilt) {
        continue;
      }
      url = rebuilt.url;
      approximate = rebuilt.approximate;
    }
    const content =
      /<div[^>]+class="[^"]*\bcontent\b[^"]*line-clamp[^"]*"[^>]*>([\s\S]*?)<\/div>/i.exec(
        block,
      );
    let snippet = textOf(content?.[1]);
    let publishedAt: string | undefined;
    const age =
      /^((?:\d+ (?:minute|hour|day|week|month|year)s? ago)|(?:[A-Z][a-z]+ \d{1,2}, \d{4}))\s*-\s*/.exec(
        snippet,
      );
    if (age) {
      publishedAt = age[1];
      snippet = snippet.slice(age[0].length);
    }
    out.push({
      title,
      url,
      snippet,
      publishedAt,
      approximateUrl: approximate || undefined,
    });
    if (out.length >= MAX_RESULTS) {
      break;
    }
  }
  return out;
}

/** Bing wraps some links: /ck/a?…&u=a1<base64url of the target>. */
export function derefBing(href: string): string {
  const match = /[?&]u=a1([A-Za-z0-9_-]+)/.exec(href);
  if (!/bing\.com\/ck\/a/i.test(href) || !match) {
    return href;
  }
  try {
    const base64 = match[1].replace(/-/g, '+').replace(/_/g, '/');
    const decoded = decodeBase64(base64);
    return /^https?:\/\//i.test(decoded) ? decoded : href;
  } catch {
    return href;
  }
}

const BASE64 =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/* eslint-disable no-bitwise */
/** Small base64 decoder (URLs are ASCII; Hermes has no atob everywhere). */
function decodeBase64(input: string): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const char of input.replace(/[=]+$/, '')) {
    const index = BASE64.indexOf(char);
    if (index === -1) {
      throw new Error('bad base64');
    }
    value = (value << 6) | index;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += String.fromCharCode((value >> bits) & 0xff);
    }
  }
  return out;
}

/* eslint-enable no-bitwise */

export function parseBing(html: string): Parsed[] {
  const out: Parsed[] = [];
  const items = html.split(/<li[^>]+class="b_algo"/i).slice(1);
  for (const raw of items) {
    const item = raw.slice(0, 20000).replace(/<style[\s\S]*?<\/style>/gi, '');
    const heading =
      /<a\b[^>]*href="([^"]+)"[^>]*>\s*<h2[^>]*>([\s\S]*?)<\/h2>/i.exec(item) ??
      /<h2[^>]*>\s*<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i.exec(item);
    if (!heading) {
      continue;
    }
    const url = derefBing(decodeEntities(heading[1]));
    const paragraph = /<p\b[^>]*>([\s\S]*?)<\/p>/i.exec(item);
    let snippet = textOf(paragraph?.[1]);
    let publishedAt: string | undefined;
    const dated =
      /^([A-Z][a-z]{2} \d{1,2}, \d{4}|\d+ (?:minute|hour|day)s? ago)\s*[·\-–]\s*/.exec(
        snippet,
      );
    if (dated) {
      publishedAt = dated[1];
      snippet = snippet.slice(dated[0].length);
    }
    out.push({title: textOf(heading[2]), url, snippet, publishedAt});
    if (out.length >= MAX_RESULTS) {
      break;
    }
  }
  return out;
}

export function parseMojeek(html: string): Parsed[] {
  const out: Parsed[] = [];
  const list =
    /<ul[^>]+class="[^"]*\bresults[^"]*"[^>]*>([\s\S]*?)<\/ul>/i.exec(html);
  const items = (list ? list[1] : html).split(/<li\b/i).slice(1);
  for (const item of items) {
    const link =
      /<h2[^>]*>\s*<a\b[^>]*>([\s\S]*?)<\/a>/i.exec(item) ??
      /<a\b[^>]*class="[^"]*\btitle\b[^"]*"[^>]*>([\s\S]*?)<\/a>/i.exec(item);
    if (!link) {
      continue;
    }
    const url = attribute(link[0].slice(link[0].indexOf('<a')), 'href') ?? '';
    const snippet = /<p[^>]+class="s"[^>]*>([\s\S]*?)<\/p>/i.exec(item);
    out.push({title: textOf(link[1]), url, snippet: textOf(snippet?.[1])});
    if (out.length >= MAX_RESULTS) {
      break;
    }
  }
  return out;
}

export function parseStartpage(html: string): Parsed[] {
  const out: Parsed[] = [];
  const blocks = html.split(/<div[^>]+class="result\b[^"]*"/i).slice(1);
  for (const block of blocks) {
    const link =
      /<a\b[^>]*class="[^"]*\bresult-(?:title|link)\b[^"]*"[^>]*>/i.exec(
        block,
      ) ?? /<a\b[^>]*href="https?:[^>]*>/i.exec(block);
    const heading = /<h2[^>]*>([\s\S]*?)<\/h2>/i.exec(block);
    if (!link || !heading) {
      continue;
    }
    const snippet = /<p\b[^>]*>([\s\S]*?)<\/p>/i.exec(block);
    out.push({
      title: textOf(heading[1]),
      url: attribute(link[0], 'href') ?? '',
      snippet: textOf(snippet?.[1]),
    });
    if (out.length >= MAX_RESULTS) {
      break;
    }
  }
  return out;
}

const PARSERS: Record<EngineConfig['parser'], (html: string) => Parsed[]> = {
  duckduckgo: parseDuckDuckGo,
  'duckduckgo-lite': parseDuckDuckGoLite,
  bing: parseBing,
  brave: parseBrave,
  mojeek: parseMojeek,
  startpage: parseStartpage,
};

const ENGINE_HOSTS =
  /(^|\.)(duckduckgo\.com|mojeek\.com|brave\.com|startpage\.com|bing\.com)$/i;

/** Parse and sanitise: http(s) only, no engine-internal links, no duplicates. */
export function parseResults(
  parser: EngineConfig['parser'],
  html: string,
  engine: Pick<EngineConfig, 'id' | 'dropUrlPrefixes'>,
): SearchResult[] {
  const seen = new Set<string>();
  const out: SearchResult[] = [];
  for (const item of PARSERS[parser](html)) {
    const url = item.url.trim();
    if (!isHttpUrl(url) || ENGINE_HOSTS.test(hostOf(url))) {
      continue;
    }
    if (engine.dropUrlPrefixes?.some(prefix => url.startsWith(prefix))) {
      continue;
    }
    if (!item.title || seen.has(url)) {
      continue;
    }
    seen.add(url);
    out.push({
      ...item,
      url,
      title: item.title.slice(0, 200),
      snippet: item.snippet.slice(0, 500),
      engine: engine.id,
    });
  }
  return out;
}

const BLOCK_PHRASES =
  /are you a robot|unusual traffic|automated queries|verify(?:ing)? (?:you are|you're|your request)|checking your browser|enable javascript and cookies|just a moment|attention required|anomaly|captcha|access denied|request blocked|too many requests|pardon our interruption/i;

/** A challenge, captcha or rate-limit page instead of results. */
export function looksBlocked(status: number, html: string): boolean {
  if (
    status === 403 ||
    status === 429 ||
    status === 202 ||
    status === 418 ||
    status === 503
  ) {
    return true;
  }
  const text = textOf(html.slice(0, 60000)).slice(0, 4000);
  return html.length < 40000
    ? BLOCK_PHRASES.test(text)
    : /class="anomaly-modal|id="challenge-form|cf-browser-verification/.test(
        html,
      );
}
