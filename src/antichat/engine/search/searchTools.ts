/**
 * `web_search`, `read_url` and `image_search` as AntiChat tools.
 */
import type {AntichatTool} from '../tools/types';
import {searchImages} from './images';
import {buildQueries} from './query';
import {normalizeUrlInput} from './reader/fetchPage';
import {getSearchService, type SearchService} from './service';

export function createWebSearchTool(
  service: () => SearchService = getSearchService,
): AntichatTool {
  return {
    name: 'web_search',
    description:
      'Search the web for current or factual information: news, prices, weather, sports, releases, opening hours, or anything you are not sure about.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Short keyword query, 2-8 words',
          minLength: 1,
        },
        recency_days: {
          type: 'integer',
          description: 'Only results newer than this many days',
          minimum: 1,
          maximum: 365,
        },
      },
      required: ['query'],
      additionalProperties: false,
    },
    kind: 'online',
    tier: 'always',
    chip: 'search',
    keywords: [
      'search',
      'google',
      'look up',
      'news',
      'internet',
      'find',
      'current',
    ],
    timeoutMs: 20000,
    example: {query: 'nobel prize physics 2026 winner'},
    normalize: (args, context) => {
      const out: Record<string, unknown> = {...args};
      // Small models send `queries: [...]`, `q`, or nothing at all.
      let query =
        out.query ?? out.q ?? out.search ?? out.search_query ?? out.keywords;
      if (query === undefined && Array.isArray(out.queries)) {
        query = out.queries[0];
      }
      if (Array.isArray(query)) {
        query = query[0];
      }
      if ((typeof query !== 'string' || !query.trim()) && context.userText) {
        query = buildQueries({userText: context.userText, now: context.now})
          .queries[0];
      }
      for (const key of [
        'q',
        'search',
        'search_query',
        'keywords',
        'queries',
      ]) {
        delete out[key];
      }
      if (query !== undefined) {
        out.query = query;
      }
      if (out.recency_days === undefined && out.recency !== undefined) {
        out.recency_days = out.recency;
      }
      delete out.recency;
      return out;
    },
    async execute(args, context) {
      const run = await service().webSearch({
        queries: [String(args.query)],
        userText: context.userText,
        recencyDays: args.recency_days as number | undefined,
        nCtx: context.nCtx,
        deviceClass: context.deviceClass,
        turnId: context.turnId,
        now: context.now,
        signal: context.signal,
        onProgress: context.onProgress,
      });
      return run.output;
    },
  };
}

export function createReadUrlTool(
  service: () => SearchService = getSearchService,
): AntichatTool {
  return {
    name: 'read_url',
    description:
      'Fetch a web page and return its readable text. Use when the user gives a URL or when a search result needs to be read in full.',
    parameters: {
      type: 'object',
      properties: {
        url: {
          type: 'string',
          description: 'Absolute http(s) URL',
          minLength: 4,
        },
      },
      required: ['url'],
      additionalProperties: false,
    },
    kind: 'online',
    tier: 'always',
    keywords: [
      'open',
      'page',
      'link',
      'article',
      'website',
      'summarise',
      'summarize',
      'url',
    ],
    timeoutMs: 20000,
    example: {url: 'https://example.org/article'},
    normalize: args => {
      const url = args.url ?? args.link ?? args.href ?? args.uri ?? args.page;
      if (typeof url !== 'string') {
        return args;
      }
      return {url: normalizeUrlInput(url)};
    },
    async execute(args, context) {
      return service().readUrl({
        url: String(args.url),
        question: context.userText,
        nCtx: context.nCtx,
        deviceClass: context.deviceClass,
        turnId: context.turnId,
        now: context.now,
        signal: context.signal,
      });
    },
  };
}

export function createImageSearchTool(): AntichatTool {
  return {
    name: 'image_search',
    description:
      'Find freely licensed pictures of a thing, place, animal or person to show the user.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'What to show, 1-5 words',
          minLength: 1,
        },
      },
      required: ['query'],
      additionalProperties: false,
    },
    kind: 'online',
    tier: 'deferred',
    keywords: [
      'picture',
      'photo',
      'image',
      'look like',
      'show',
      'bild',
      'foto',
    ],
    timeoutMs: 10000,
    example: {query: 'red panda'},
    async execute(args, context) {
      const images = await searchImages(String(args.query), {
        signal: context.signal,
      });
      if (images.length === 0) {
        return {
          text: `image_search: no pictures found for "${args.query}".`,
          isError: true,
        };
      }
      return {
        text: `Found ${images.length} pictures of "${args.query}"; the app shows them to the user. Describe in one sentence what they show.`,
        images,
      };
    },
  };
}
