/**
 * The tool catalogue and `search_tools`.
 *
 * Every AntiChat tool registers here. A few are always offered; the rest are
 * "deferred": the model does not see their schemas until it asks for them
 * through the `search_tools` meta-tool, which runs a BM25 search (minisearch)
 * over names, descriptions and keywords and returns the best three with
 * their schemas. Found tools are switched on for the chat and offered from
 * the next model step. This keeps the prompt small no matter how many tools
 * (connectors, MCP servers) are installed.
 */
import MiniSearch from 'minisearch';

import {activateTools} from './chips';
import type {AntichatTool, ToolContext} from './types';

export interface ToolHit {
  tool: AntichatTool;
  score: number;
}

const tokenize = (text: string): string[] =>
  text
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(token => token.length > 1);

const STOP = new Set([
  'the',
  'for',
  'and',
  'with',
  'use',
  'tool',
  'tools',
  'user',
  'when',
  'that',
  'this',
  'from',
  'can',
  'you',
  'get',
  'my',
  'me',
]);

export class ToolCatalog {
  private readonly tools = new Map<string, AntichatTool>();
  private index: MiniSearch | null = null;
  private readonly listeners = new Set<() => void>();

  register(tool: AntichatTool): () => void {
    this.tools.set(tool.name, tool);
    this.index = null;
    this.listeners.forEach(listener => listener());
    return () => {
      if (this.tools.get(tool.name) === tool) {
        this.tools.delete(tool.name);
        this.index = null;
      }
    };
  }

  unregister(name: string): void {
    this.tools.delete(name);
    this.index = null;
  }

  get(name: string): AntichatTool | undefined {
    return this.tools.get(name);
  }

  has(name: string): boolean {
    return this.tools.has(name);
  }

  /** Registration order: the stable order tools are offered in. */
  all(): AntichatTool[] {
    return [...this.tools.values()];
  }

  deferred(): AntichatTool[] {
    return this.all().filter(tool => tool.tier === 'deferred');
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  clear(): void {
    this.tools.clear();
    this.index = null;
  }

  private ensureIndex(): MiniSearch {
    if (!this.index) {
      this.index = new MiniSearch({
        idField: 'name',
        fields: ['nameWords', 'description', 'keywords'],
        tokenize,
        processTerm: term => (STOP.has(term) ? null : term),
        searchOptions: {
          boost: {nameWords: 3, keywords: 2},
          prefix: term => term.length > 3,
          fuzzy: term => (term.length > 5 ? 0.2 : false),
          combineWith: 'OR',
        },
      });
      this.index.addAll(
        this.all().map(tool => ({
          name: tool.name,
          nameWords: tool.name.replace(/[_.-]+/g, ' '),
          description: tool.description,
          keywords: (tool.keywords ?? []).join(' '),
        })),
      );
    }
    return this.index;
  }

  /** BM25 search over names, descriptions and keywords. */
  search(
    query: string,
    options: {limit?: number; filter?: (tool: AntichatTool) => boolean} = {},
  ): ToolHit[] {
    const limit = options.limit ?? 3;
    if (!query.trim() || this.tools.size === 0) {
      return [];
    }
    const hits: ToolHit[] = [];
    for (const hit of this.ensureIndex().search(query)) {
      const tool = this.tools.get(String(hit.id));
      if (!tool || (options.filter && !options.filter(tool))) {
        continue;
      }
      hits.push({tool, score: hit.score});
      if (hits.length >= limit) {
        break;
      }
    }
    return hits;
  }
}

/** The app-wide catalogue. */
export const toolCatalog = new ToolCatalog();

export const SEARCH_TOOLS_NAME = 'search_tools';

export interface SearchToolsOptions {
  catalog?: ToolCatalog;
  /** Tools that may be returned right now (offline gating, device class). */
  usable?: (tool: AntichatTool, context: ToolContext) => boolean;
  /** Chat the found tools are switched on for. */
  chatId?: (context: ToolContext) => string | undefined;
  /**
   * `step`: found tools are callable from the next model step (AntiChat's
   * loop). `turn`: from the user's next message (upstream's loop keeps the
   * tool list fixed for a run).
   */
  activation?: 'step' | 'turn';
}

/** The meta-tool. Mac `find_tools`, with the schemas in the result. */
export function createSearchToolsTool(
  options: SearchToolsOptions = {},
): AntichatTool {
  const catalog = options.catalog ?? toolCatalog;
  return {
    name: SEARCH_TOOLS_NAME,
    description:
      'Find more tools by what they do (e.g. "send email", "calendar", "pictures"). Use when no listed tool fits the request.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'What the tool should do, 1-5 words',
          minLength: 1,
        },
      },
      required: ['query'],
      additionalProperties: false,
    },
    kind: 'local',
    tier: 'always',
    timeoutMs: 2000,
    example: {query: 'send email'},
    normalize: args => {
      const query = args.query ?? args.q ?? args.task ?? args.description;
      return query === undefined ? args : {query};
    },
    async execute(args, context) {
      const hits = catalog.search(String(args.query), {
        limit: 3,
        filter: tool =>
          tool.name !== SEARCH_TOOLS_NAME &&
          tool.tier === 'deferred' &&
          (options.usable?.(tool, context) ?? true),
      });
      if (hits.length === 0) {
        return {
          text: `No tool found for "${args.query}". Answer without a tool, or tell the user this is not available.`,
        };
      }
      activateTools(
        options.chatId?.(context) ?? context.turnId,
        hits.map(hit => hit.tool.name),
      );
      const when =
        options.activation === 'turn'
          ? 'They are switched on for this chat and can be called from your next reply; tell the user what you can now do.'
          : 'They are now available: call the one that fits.';
      const lines = hits.map(
        hit =>
          `- ${hit.tool.name}: ${hit.tool.description} Arguments: ${JSON.stringify(
            hit.tool.parameters.properties ?? {},
          )}${
            hit.tool.parameters.required?.length
              ? ` Required: ${hit.tool.parameters.required.join(', ')}.`
              : ''
          }`,
      );
      return {
        text: `Found ${hits.length} tool${hits.length === 1 ? '' : 's'}. ${when}\n${lines.join('\n')}`,
      };
    },
  };
}
