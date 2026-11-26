/**
 * What attached files add to a request.
 *
 *  - Small files are put in whole, in a `session` block at the end of the
 *    system message: it changes only when a file is added, so the prompt
 *    prefix stays cached from turn to turn.
 *  - Large files are searched with the user's message and the best excerpts
 *    ride on that message (`turnContext`), each with its file and page, so
 *    the answer can cite the page.
 *  - Spreadsheets appear as a schema; numbers come from `sql_query`.
 *  - Images go to a vision model through upstream's `imageUris`; without one
 *    the text OCR read from them is put in like a small file.
 */
import type {EmbedderProvider} from '../memory/embeddings/types';
import {familyProfile} from '../prompt/modelFamily';
import type {
  Contribution,
  RequestContext,
  RequestProvider,
  ToolDefinition,
} from '../prompt/types';
import type {FileRow, FilesStore} from './FilesStore';
import {fileBudgetFor, limit, type FileLimit} from './limits';
import {retrieveChunks, type RetrievedChunk} from './retrieval';
import {describeTables} from './sql';
import {SEARCH_FILES_DEFINITION, SQL_QUERY_DEFINITION} from './tools';

export const FILES_PROVIDER_ID = 'antichat.files';

export interface FilesRequestMeta {
  /** Files whose whole text is in the prompt. */
  inline: string[];
  /** Files that are searched. */
  searched: string[];
  tables: string[];
  images: string[];
  /** The excerpts added for this message, for citation chips. */
  excerpts: Array<{
    n: number;
    fileId: string;
    name: string;
    chunkId: number;
    pageStart: number;
    pageEnd: number;
    how: RetrievedChunk['how'];
  }>;
  semantic: boolean;
  limits: FileLimit[];
  tokens: {inline: number; excerpts: number};
}

export interface FilesProviderOptions {
  store: FilesStore;
  embedder?: EmbedderProvider;
  /** A vision model is loaded right now. */
  visionActive?: () => boolean;
  /** Files of the chat's project also count (default true). */
  projectFiles?: boolean;
}

const LABEL: Record<string, string> = {
  page: 'p.',
  slide: 'slide',
  sheet: 'sheet',
  section: 'section',
};

const where = (file: FileRow, start: number, end: number): string => {
  const label = LABEL[file.data.pageLabel ?? 'page'];
  return start === end ? `${label} ${start}` : `${label} ${start}-${end}`;
};

function wholeText(file: FileRow): string {
  const pages = file.data.pages ?? [];
  const label = file.data.pageLabel ?? 'page';
  const body =
    pages.length <= 1
      ? (pages[0]?.text ?? '')
      : pages
          .map(
            page =>
              `[${label} ${page.page}${page.title ? `: ${page.title}` : ''}]\n${page.text}`,
          )
          .join('\n\n');
  return `<file name="${file.name}">\n${body}\n</file>`;
}

const CITE_RULE =
  'When you answer from a file, name the page you took it from in brackets, like (p. 12). If the files do not contain the answer, say so instead of guessing.';
const TABLE_RULE =
  'For any count, sum, average, minimum, maximum or ranking over a table, call sql_query (SQLite) and report its result. Never work a figure out yourself.';

export function createFilesProvider(
  options: FilesProviderOptions,
): RequestProvider {
  const {store} = options;

  const contribute = async (
    context: RequestContext,
  ): Promise<Contribution | void> => {
    const sessionId = context.session.id;
    if (!sessionId) {
      return;
    }
    // Files attached in the composer of a new chat now belong to this chat.
    await store.adoptDrafts(sessionId);
    let files = await store.list(sessionId);
    if (options.projectFiles !== false && context.session.projectId) {
      const own = new Set(files.map(file => file.id));
      files = [
        ...(await store.listForProject(context.session.projectId)).filter(
          file => !own.has(file.id),
        ),
        ...files,
      ];
    }
    files = files.filter(file => file.status === 'ready');
    if (files.length === 0) {
      return;
    }

    const {runtime} = context;
    const budget = fileBudgetFor(runtime.deviceClass, runtime.nCtx);
    // An estimate on purpose: tokenising whole files on every send is slow,
    // and context fitting (order 900) has the last word on what fits.
    const perToken = familyProfile(runtime.family).charsPerToken;
    const count = (text: string) => Math.ceil(text.length / perToken);
    const vision = options.visionActive?.() ?? false;
    const meta: FilesRequestMeta = {
      inline: [],
      searched: [],
      tables: [],
      images: [],
      excerpts: [],
      semantic: false,
      limits: [],
      tokens: {inline: 0, excerpts: 0},
    };

    // Newest files keep their place in the prompt; older ones fall back to
    // search when the whole-text budget is used up.
    const inlineParts: string[] = [];
    const searched: FileRow[] = [];
    let left = budget.inlineTokens;
    for (const file of [...files].reverse()) {
      if (file.mode === 'vision' && vision) {
        meta.images.push(file.id);
        // Text in the picture helps a small vision model; keep it short.
        const text = file.data.pages?.[0]?.text ?? '';
        if (text.length > 40 && count(text) <= Math.min(left, 600)) {
          inlineParts.unshift(
            `<file name="${file.name}" note="text read from the image">\n${text}\n</file>`,
          );
          left -= count(text);
        }
        continue;
      }
      if (file.mode === 'vision' && !file.data.pages?.length) {
        meta.limits.push(
          limit('vision_unavailable', 'info', {name: file.name}),
        );
        continue;
      }
      if (file.mode === 'table') {
        meta.tables.push(file.id);
      }
      const whole = file.data.pages ? wholeText(file) : null;
      const cost = whole ? count(whole) : Infinity;
      if (whole && cost <= left) {
        inlineParts.unshift(whole);
        meta.inline.push(file.id);
        left -= cost;
      } else if (file.mode !== 'table') {
        searched.unshift(file);
        meta.searched.push(file.id);
      }
    }
    meta.tokens.inline = budget.inlineTokens - left;

    const blocks: string[] = [];
    const tools: ToolDefinition[] = [];
    const names = files.map(file => {
      const pages = file.pageCount
        ? `, ${file.pageCount} ${file.data.pageLabel ?? 'page'}${file.pageCount === 1 ? '' : 's'}`
        : '';
      const use = meta.inline.includes(file.id)
        ? 'full text below'
        : meta.searched.includes(file.id)
          ? 'searched per question'
          : meta.images.includes(file.id)
            ? 'image, shown to you'
            : file.mode === 'table'
              ? 'table, query with sql_query'
              : 'text below';
      return `- ${file.name} (${file.kind}${pages}; ${use})`;
    });
    blocks.push(
      `The user attached these files to this chat:\n${names.join('\n')}`,
    );
    if (inlineParts.length > 0) {
      blocks.push(inlineParts.join('\n\n'));
    }

    const tables = await store.tables(meta.tables);
    if (tables.length > 0) {
      const samples = new Map<number, unknown[][]>();
      for (const table of tables) {
        const rows = await store.db.all(
          `SELECT * FROM ${table.sqlName} LIMIT 2`,
        );
        samples.set(
          table.id,
          rows.map(row => table.columns.map(column => row[column.name])),
        );
      }
      blocks.push(`${describeTables(tables, samples)}\n${TABLE_RULE}`);
      tools.push(SQL_QUERY_DEFINITION);
    }

    const turnContext: string[] = [];
    if (searched.length > 0) {
      const result = await retrieveChunks(
        store,
        context.userText,
        searched.map(file => file.id),
        {limit: budget.retrievedChunks, embedder: options.embedder},
      );
      meta.semantic = result.semantic;
      if (result.chunks.length > 0) {
        const byId = new Map(searched.map(file => [file.id, file]));
        const lines = result.chunks.map((chunk, index) => {
          const file = byId.get(chunk.fileId)!;
          meta.excerpts.push({
            n: index + 1,
            fileId: file.id,
            name: file.name,
            chunkId: chunk.id,
            pageStart: chunk.pageStart,
            pageEnd: chunk.pageEnd,
            how: chunk.how,
          });
          return `[${file.name}, ${where(file, chunk.pageStart, chunk.pageEnd)}]\n${chunk.text}`;
        });
        const text = `Excerpts from the attached files that may answer this:\n\n${lines.join('\n\n')}`;
        meta.tokens.excerpts = count(text);
        turnContext.push(text);
      }
      tools.push(SEARCH_FILES_DEFINITION);
    }
    if (inlineParts.length > 0 || searched.length > 0) {
      blocks.push(CITE_RULE);
    }

    return {
      systemBlocks: [
        {
          id: 'files',
          slot: 'session',
          // After project (40) and memory (50-60) blocks: the largest and
          // least stable block goes last.
          order: 90,
          text: blocks.join('\n\n'),
        },
      ],
      turnContext,
      tools,
      meta: {files: meta},
    };
  };

  return {id: FILES_PROVIDER_ID, order: 60, contribute};
}
