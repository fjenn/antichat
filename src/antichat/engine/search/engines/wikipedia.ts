/**
 * Wikipedia search API: keyless, permissive rate limit, entity questions.
 * The fallback of last resort when every result page failed.
 */
import {defaultHttpGet} from '../http';
import {textOf} from '../html';
import {
  SearchProviderError,
  type HttpGet,
  type SearchRequest,
  type SearchResult,
  type WebSearchProvider,
} from '../types';

const QUESTION_WORDS =
  /^(?:who|what|when|where|which|why|how|is|are|was|were|does|do|did|will|can|the|a|an|of|in|on|for|to|and|or|most|recent|latest|current|currently|best|way|next|new|today|now|published|released|step|by|wer|was|wann|wo|wie|ist|der|die|das|qué|quién|cuándo|dónde|cómo|el|la|qui|quoi|quand|où|comment|le|les)$/i;

/**
 * Wikipedia's search is full-text: a whole question matches pages that
 * happen to share its function words. Send the content words only, and no
 * date (an article is not dated like news).
 */
export function wikipediaQuery(query: string): string {
  const words = query
    .replace(
      /\b(?:\d{1,2} )?(?:January|February|March|April|May|June|July|August|September|October|November|December) \d{4}\b/g,
      ' ',
    )
    .split(/[^\p{L}\p{N}.'+#-]+/u)
    .filter(word => word && !QUESTION_WORDS.test(word));
  return (words.length > 0 ? words : query.split(/\s+/)).slice(0, 8).join(' ');
}

const EDITIONS = new Set([
  'en',
  'de',
  'es',
  'fr',
  'nl',
  'pt',
  'it',
  'ja',
  'zh',
  'ru',
  'pl',
  'sv',
  'ar',
  'ko',
  'tr',
]);

export class WikipediaProvider implements WebSearchProvider {
  readonly id = 'wikipedia';
  readonly name = 'Wikipedia';
  readonly tier = 'fallback' as const;

  constructor(private readonly httpGet: HttpGet = defaultHttpGet) {}

  async search(request: SearchRequest): Promise<SearchResult[]> {
    const lang =
      request.language && EDITIONS.has(request.language)
        ? request.language
        : 'en';
    const url =
      `https://${lang}.wikipedia.org/w/api.php?action=query&list=search&format=json&origin=*` +
      `&srlimit=${Math.min(request.maxResults, 10)}&srsearch=${encodeURIComponent(wikipediaQuery(request.query))}`;
    let body: any;
    try {
      const response = await this.httpGet(url, {
        signal: request.signal,
        timeoutMs: request.timeoutMs ?? 5000,
        // Wikimedia asks API clients for a descriptive agent; a generic one,
        // nothing about the device or the user.
        headers: {
          Accept: 'application/json',
          'Api-User-Agent': 'MobileSearchClient/1.0 (on-device app)',
        },
      });
      if (response.status >= 400) {
        throw new SearchProviderError(
          response.status === 429 ? 'quota' : 'network',
          `HTTP ${response.status}`,
        );
      }
      body = JSON.parse(response.text);
    } catch (error) {
      if (error instanceof SearchProviderError) {
        throw error;
      }
      throw new SearchProviderError('network', (error as Error).message);
    }
    const rows: any[] = body?.query?.search ?? [];
    if (rows.length === 0) {
      throw new SearchProviderError('empty', 'no results');
    }
    return rows.map(row => ({
      title: String(row.title),
      url: `https://${lang}.wikipedia.org/wiki/${encodeURIComponent(String(row.title).replace(/ /g, '_'))}`,
      snippet: textOf(String(row.snippet ?? '')),
      publishedAt:
        typeof row.timestamp === 'string'
          ? row.timestamp.slice(0, 10)
          : undefined,
      engine: 'wikipedia',
    }));
  }
}
