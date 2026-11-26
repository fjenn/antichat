/**
 * The two tools files bring: `search_files` (look again in the large
 * files, with other words) and `sql_query` (numbers from spreadsheets).
 * They are offered by the files provider only in chats that have such
 * files, and registered with upstream's talent registry so the tool loop
 * can run them.
 */
import type {TalentEngine, TalentResult} from '../../../services/talents/types';
import type {EmbedderProvider} from '../memory/embeddings/types';
import type {ToolDefinition} from '../prompt/types';
import type {FilesStore} from './FilesStore';
import type {FileBudget} from './limits';
import {retrieveChunks} from './retrieval';
import {SqlRejected, runSelect} from './sql';

export const SEARCH_FILES = 'search_files';
export const SQL_QUERY = 'sql_query';

export const SEARCH_FILES_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: SEARCH_FILES,
    description:
      'Search the text of the files attached to this chat. Call it when the excerpts you were given do not contain the answer; use different keywords.',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description:
            'Keywords or a short question, for example "notice period".',
        },
      },
      required: ['query'],
    },
  },
};

export const SQL_QUERY_DEFINITION: ToolDefinition = {
  type: 'function',
  function: {
    name: SQL_QUERY,
    description:
      'Run one read-only SQLite SELECT on the tables of the attached spreadsheets and get the result. Use it for every count, sum, average, minimum, maximum or ranking.',
    parameters: {
      type: 'object',
      properties: {
        sql: {
          type: 'string',
          description:
            'One SELECT statement, for example "SELECT AVG(units) FROM orders".',
        },
      },
      required: ['sql'],
    },
  },
};

const text = (summary: string): TalentResult => ({type: 'text', summary});

const firstString = (
  args: Record<string, any>,
  keys: string[],
): string | undefined => {
  for (const key of keys) {
    const value = Array.isArray(args?.[key]) ? args[key][0] : args?.[key];
    if (typeof value === 'string' && value.trim()) {
      return value.trim();
    }
  }
  return undefined;
};

export interface FileToolsOptions {
  store: FilesStore;
  currentSessionId: () => string | null | undefined;
  budget: () => FileBudget;
  /** The tool runs while the chat model is busy: usually keywords only. */
  embedder?: EmbedderProvider;
  /** Told about every query that ran (dev run, UI "ran a query" row). */
  onSql?: (event: {sql: string; ok: boolean; text: string}) => void;
}

export function createSearchFilesTool(options: FileToolsOptions): TalentEngine {
  return {
    name: SEARCH_FILES,
    toToolDefinition: () => SEARCH_FILES_DEFINITION,
    async execute(args) {
      const query = firstString(args, ['query', 'q', 'keywords', 'text']);
      if (!query) {
        return text('No query given.');
      }
      const files = (
        await options.store.list(options.currentSessionId() ?? null)
      )
        .filter(file => file.status === 'ready' && file.mode !== 'table')
        .filter(file => file.mode !== 'vision' || file.data.pages?.length);
      if (files.length === 0) {
        return text('This chat has no files to search.');
      }
      const {chunks} = await retrieveChunks(
        options.store,
        query,
        files.map(file => file.id),
        {limit: options.budget().retrievedChunks, embedder: options.embedder},
      );
      if (chunks.length === 0) {
        return text(
          'Nothing in the files matches those words. Try other keywords, or tell the user the files do not say.',
        );
      }
      const byId = new Map(files.map(file => [file.id, file]));
      return text(
        chunks
          .map(chunk => {
            const file = byId.get(chunk.fileId)!;
            const page =
              chunk.pageStart === chunk.pageEnd
                ? `${chunk.pageStart}`
                : `${chunk.pageStart}-${chunk.pageEnd}`;
            return `[${file.name}, p. ${page}]\n${chunk.text}`;
          })
          .join('\n\n') + '\n\nCite the page you used, like (p. 12).',
      );
    },
  };
}

export function createSqlQueryTool(options: FileToolsOptions): TalentEngine {
  return {
    name: SQL_QUERY,
    toToolDefinition: () => SQL_QUERY_DEFINITION,
    async execute(args) {
      const sql = firstString(args, ['sql', 'query', 'statement', 'q']);
      if (!sql) {
        return text('No SQL given. Pass one SELECT statement in "sql".');
      }
      const files = await options.store.list(
        options.currentSessionId() ?? null,
      );
      const tables = await options.store.tables(files.map(file => file.id));
      if (tables.length === 0) {
        return text('This chat has no spreadsheet tables.');
      }
      try {
        const result = await runSelect(
          options.store.db,
          sql,
          tables,
          options.budget().sqlResultRows,
        );
        options.onSql?.({sql, ok: true, text: result.text});
        return text(
          `${result.text}\n\nThis is the exact result. Give the user the figure as it is.`,
        );
      } catch (error) {
        const message =
          error instanceof SqlRejected
            ? error.message
            : `SQLite error: ${String((error as Error)?.message ?? error)}`;
        options.onSql?.({sql, ok: false, text: message});
        return text(
          `${message}\nTables: ${tables
            .map(
              table =>
                `${table.name}(${table.columns.map(c => c.name).join(', ')})`,
            )
            .join('; ')}. Correct the query and call sql_query again.`,
        );
      }
    },
  };
}
