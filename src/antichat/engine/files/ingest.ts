/**
 * From a file to something the model can use.
 *
 *   detect → extract (native PDF pages, OCR for pages without text, JS for
 *   Office / CSV / text) → decide how it is used → store chunks → embed.
 *
 * How a file is used (`mode`):
 *   inline     small enough to be put into the prompt whole;
 *   retrieval  too large: chunked, searched per question, cited by page;
 *   table      a spreadsheet: imported into SQLite for `sql_query`
 *              (its preview is also inline);
 *   vision     an image for a vision model (OCR text kept as a fallback);
 *   ocr        an image or scan read by OCR because no vision model runs;
 *   audio      a transcript from the voice engine's hook.
 */
import type {EmbeddingService} from '../memory/embeddings/service';
import {chunkDocument, estimateTokens} from './chunk';
import {
  ExtractError,
  detectKind,
  extractFromBytes,
  normalizePdfText,
  type DocumentKind,
  type ExtractedDocument,
  type ExtractedPage,
} from './extract';
import type {FileData, FileMode, FileRow, FilesStore} from './FilesStore';
import {limit, type FileBudget, type FileLimit} from './limits';
import type {FileIo} from './native';
import {getAudioTranscriber, transcriptPages} from './transcription';

export interface IngestInput {
  id: string;
  uri: string;
  name: string;
  mimeType?: string | null;
  sizeBytes?: number | null;
  sessionId: string | null;
  projectId?: string | null;
}

export interface IngestDeps {
  store: FilesStore;
  io: FileIo;
  budget: () => FileBudget;
  embedding?: EmbeddingService;
  /** A vision model is loaded right now. */
  visionActive?: () => boolean;
  charsPerToken?: () => number;
  onProgress?: (fileId: string, fraction: number) => void;
}

export interface IngestResult {
  file: FileRow;
  /** Milliseconds per stage, for the dev run. */
  timings: Record<string, number>;
}

const PDF_BATCH = 25;
/** A page with fewer characters than this has no usable text layer. */
const MIN_PAGE_CHARS = 24;
const EMBED_BATCH = 8;

class Blocked extends Error {
  constructor(readonly limit: FileLimit) {
    super(limit.code);
  }
}

async function readPdf(
  input: IngestInput,
  deps: IngestDeps,
  budget: FileBudget,
  limits: FileLimit[],
  progress: (fraction: number) => void,
): Promise<{doc: ExtractedDocument; ocrPages: number}> {
  const pages: ExtractedPage[] = [];
  let pageCount = 0;
  let chars = 0;
  try {
    for (let start = 0; ; start += PDF_BATCH) {
      const batch = await deps.io.pdfPages(input.uri, start, PDF_BATCH);
      pageCount = batch.pageCount;
      batch.pages.forEach((text, index) => {
        const clean = normalizePdfText(text);
        chars += clean.length;
        pages.push({page: start + index + 1, text: clean});
      });
      const last = Math.min(pageCount, budget.maxPages);
      progress(last ? Math.min(1, pages.length / last) * 0.5 : 0.5);
      if (
        batch.pages.length === 0 ||
        pages.length >= last ||
        chars >= budget.maxChars
      ) {
        break;
      }
    }
  } catch (error) {
    const code = (error as {code?: string}).code;
    throw new Blocked(
      limit(code === 'ENCRYPTED' ? 'encrypted' : 'unsupported_type', 'blocked'),
    );
  }
  if (pageCount > pages.length) {
    limits.push(
      limit('pages_capped', 'info', {read: pages.length, total: pageCount}),
    );
  }
  // Pages without a text layer: OCR, up to the class's cap.
  const blank = pages.filter(page => page.text.length < MIN_PAGE_CHARS);
  let ocrPages = 0;
  if (blank.length > 0 && blank.length >= pages.length * 0.2) {
    for (const page of blank.slice(0, budget.ocrPages)) {
      try {
        const result = await deps.io.ocrPdfPage(input.uri, page.page - 1);
        page.text = normalizePdfText(result.text);
        page.ocr = true;
        ocrPages++;
      } catch {
        // The page stays empty.
      }
      progress(
        0.5 + (ocrPages / Math.min(blank.length, budget.ocrPages)) * 0.2,
      );
    }
    if (ocrPages > 0) {
      limits.push(limit('ocr_used', 'info', {pages: ocrPages}));
    }
    if (blank.length > budget.ocrPages) {
      limits.push(
        limit('ocr_pages_capped', 'info', {
          read: budget.ocrPages,
          total: blank.length,
        }),
      );
    }
  }
  return {
    doc: {
      kind: 'pdf',
      pageLabel: 'page',
      pages: pages.filter(page => page.text.length > 0),
      tables: [],
      warnings: [],
    },
    ocrPages,
  };
}

export async function ingestFile(
  input: IngestInput,
  deps: IngestDeps,
): Promise<IngestResult> {
  const {store, io} = deps;
  const budget = deps.budget();
  const timings: Record<string, number> = {};
  const limits: FileLimit[] = [];
  const progress = (fraction: number) => deps.onProgress?.(input.id, fraction);
  let mark = Date.now();
  const lap = (name: string) => {
    timings[name] = Date.now() - mark;
    mark = Date.now();
  };

  const size = input.sizeBytes ?? (await io.size(input.uri));
  const head = await io.readBytes(input.uri, 16).catch(() => undefined);
  const kind: DocumentKind = detectKind({
    name: input.name,
    mimeType: input.mimeType,
    head,
  });
  await store.insert({...input, size, kind});

  const fail = async (blocked: FileLimit, detail?: string) => {
    await store.finish(input.id, {
      status: 'failed',
      data: {limits: [...limits, blocked], error: detail},
    });
    return {file: (await store.get(input.id))!, timings};
  };

  try {
    if (size !== null && size > budget.maxFileBytes) {
      throw new Blocked(
        limit('file_too_large', 'blocked', {
          bytes: size,
          maxBytes: budget.maxFileBytes,
        }),
      );
    }
    const existing = (await store.list(input.sessionId)).filter(
      file => file.id !== input.id && file.status !== 'failed',
    );
    if (existing.length >= budget.maxFilesPerChat) {
      throw new Blocked(
        limit('chat_file_limit', 'blocked', {max: budget.maxFilesPerChat}),
      );
    }

    const data: FileData = {limits};
    let doc: ExtractedDocument;
    let mode: FileMode | null = null;

    if (kind === 'pdf') {
      const read = await readPdf(input, deps, budget, limits, progress);
      doc = read.doc;
      data.ocrPages = read.ocrPages;
      if (read.ocrPages > 0 && read.ocrPages === doc.pages.length) {
        mode = 'ocr';
      }
    } else if (kind === 'image') {
      const vision = deps.visionActive?.() ?? false;
      let text = '';
      try {
        text = normalizePdfText((await io.ocrImage(input.uri)).text);
      } catch {
        // No OCR in this build, or nothing readable: the image stands alone.
      }
      if (!vision) {
        limits.push(limit('vision_unavailable', 'info'));
        if (!text) {
          throw new Blocked(limit('no_text_found', 'blocked'));
        }
      }
      mode = vision ? 'vision' : 'ocr';
      data.ocrPages = text ? 1 : 0;
      doc = {
        kind,
        pageLabel: 'page',
        pages: text ? [{page: 1, text, ocr: true}] : [],
        tables: [],
        warnings: [],
      };
    } else if (kind === 'audio') {
      const transcriber = getAudioTranscriber();
      if (
        !transcriber ||
        budget.audioMinutes === 0 ||
        !(await transcriber.available())
      ) {
        throw new Blocked(limit('audio_unavailable', 'blocked'));
      }
      const transcript = await transcriber.transcribe(input.uri, {
        onProgress: fraction => progress(fraction * 0.7),
      });
      if (transcript.durationSec > budget.audioMinutes * 60) {
        limits.push(
          limit('audio_too_long', 'info', {minutes: budget.audioMinutes}),
        );
      }
      mode = 'audio';
      doc = {
        kind,
        pageLabel: 'section',
        pages: transcriptPages(transcript),
        tables: [],
        warnings: [],
      };
    } else {
      doc = extractFromBytes(
        await io.readBytes(input.uri),
        {name: input.name, mimeType: input.mimeType},
        {
          maxChars: budget.maxChars,
          maxTableRows: budget.maxTableRows,
          maxTableColumns: budget.maxTableColumns,
        },
      );
      if (doc.warnings.includes('unsupported') || doc.kind === 'unknown') {
        throw new Blocked(limit('unsupported_type', 'blocked'));
      }
      if (doc.pages.length > budget.maxPages) {
        limits.push(
          limit('pages_capped', 'info', {
            read: budget.maxPages,
            total: doc.pages.length,
          }),
        );
        doc.pages = doc.pages.slice(0, budget.maxPages);
      }
    }
    lap('extract');
    progress(0.7);

    if (doc.warnings.includes('truncated')) {
      limits.push(limit('text_truncated', 'info', {maxChars: budget.maxChars}));
    }
    if (doc.warnings.includes('table_truncated')) {
      limits.push(
        limit('table_truncated', 'info', {maxRows: budget.maxTableRows}),
      );
    }
    const text = doc.pages.map(page => page.text).join('\n\n');
    if (!text.trim() && mode !== 'vision') {
      throw new Blocked(limit('no_text_found', 'blocked'));
    }
    const charsPerToken = deps.charsPerToken?.() ?? 3.6;
    const tokens = estimateTokens(text, charsPerToken);

    for (const table of doc.tables) {
      await store.importTable(input.id, table);
    }
    lap('tables');

    if (!mode || mode === 'ocr' || mode === 'audio') {
      const whole = tokens <= budget.inlineTokens;
      if (doc.tables.length > 0) {
        mode = 'table';
      } else if (!whole) {
        mode = 'retrieval';
        limits.push(limit('searched_not_read_whole', 'info'));
      } else {
        mode = mode ?? 'inline';
      }
    }
    data.pageLabel = doc.pageLabel;
    // Whole text is kept only where it can ever be put in whole.
    if (tokens <= budget.inlineTokens) {
      data.pages = doc.pages.map(({page, text: pageText, title}) => ({
        page,
        text: pageText,
        ...(title ? {title} : {}),
      }));
    }

    // Chunks for every text document: a small file may still have to be
    // searched when several files share the prompt.
    const chunks =
      doc.tables.length > 0
        ? []
        : chunkDocument(doc, {targetTokens: budget.chunkTokens, charsPerToken});
    await store.addChunks(input.id, chunks);
    lap('chunk');

    let embedded = 0;
    if (mode === 'retrieval' && chunks.length > 0) {
      if (budget.embeddings && deps.embedding) {
        const rows = await store.chunks(input.id);
        for (let i = 0; i < rows.length; i += EMBED_BATCH) {
          const batch = rows.slice(i, i + EMBED_BATCH);
          const vectors = await deps.embedding.use('index', embedder =>
            embedder.embed(
              batch.map(row => row.text),
              'document',
            ),
          );
          if (!vectors) {
            break;
          }
          for (let k = 0; k < batch.length; k++) {
            await store.vectors.save(
              'chunk',
              String(batch[k].id),
              deps.embedding.spec.id,
              vectors[k],
            );
          }
          embedded += batch.length;
          progress(0.75 + (embedded / rows.length) * 0.25);
        }
      }
      if (embedded < chunks.length) {
        limits.push(
          limit('keyword_search_only', 'info', {
            reason: deps.embedding?.lastUnavailable ?? 'device-class',
          }),
        );
      }
    }
    data.embedded = embedded;
    lap('embed');

    await store.finish(input.id, {
      status: 'ready',
      mode,
      pageCount: doc.pages.length || (mode === 'vision' ? 1 : 0),
      tokenCount: tokens,
      data,
    });
    progress(1);
    return {file: (await store.get(input.id))!, timings};
  } catch (error) {
    if (error instanceof Blocked) {
      return fail(error.limit);
    }
    if (error instanceof ExtractError) {
      return fail(
        limit(
          error.code === 'encrypted'
            ? 'encrypted'
            : error.code === 'empty'
              ? 'no_text_found'
              : 'unsupported_type',
          'blocked',
        ),
        error.message,
      );
    }
    return fail(limit('unsupported_type', 'blocked'), String(error));
  }
}
