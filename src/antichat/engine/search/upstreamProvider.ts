/**
 * PocketPal's search providers (Tavily, Brave API, Exa, Firecrawl, Parallel,
 * keyless You.com) behind AntiChat's provider interface. The upstream
 * adapters are used as they are; only the shapes are mapped.
 */
import type {
  SearchProvider as UpstreamProvider,
  SearchProviderId,
} from '../../../services/search/types';
import {
  SearchProviderError,
  type SearchRequest,
  type SearchResult,
  type WebSearchProvider,
} from './types';

const NAMES: Record<SearchProviderId, string> = {
  tavily: 'Tavily',
  brave: 'Brave Search API',
  exa: 'Exa',
  firecrawl: 'Firecrawl',
  parallel: 'Parallel',
  you: 'You.com',
};

export interface UpstreamProviderOptions {
  /** `fallback` for the keyless You.com quota; `race` for a user's own key. */
  tier?: 'race' | 'fallback';
  isAvailable?: () => boolean;
}

export function fromUpstreamProvider(
  provider: UpstreamProvider,
  options: UpstreamProviderOptions = {},
): WebSearchProvider {
  const id = provider.id === 'brave' ? 'brave-api' : provider.id;
  return {
    id,
    name: NAMES[provider.id] ?? provider.id,
    tier: options.tier ?? 'fallback',
    isAvailable: options.isAvailable,
    async search(request: SearchRequest): Promise<SearchResult[]> {
      let hits;
      try {
        hits = await provider.search(
          request.query,
          {maxResults: request.maxResults},
          request.signal,
        );
      } catch (error) {
        const message = (error as Error)?.message ?? 'failed';
        const kind = /limit|429/i.test(message)
          ? 'quota'
          : /timed out/i.test(message)
            ? 'timeout'
            : /key not set/i.test(message)
              ? 'unavailable'
              : 'network';
        throw new SearchProviderError(kind, message);
      }
      const results = hits
        .filter(hit => hit.url && /^https?:\/\//i.test(hit.url))
        .map(hit => ({
          title: hit.title || hit.url,
          url: hit.url,
          snippet: hit.snippet ?? '',
          publishedAt: hit.publishedAt,
          engine: id,
        }));
      if (results.length === 0) {
        throw new SearchProviderError('empty', 'no results');
      }
      return results;
    },
  };
}
