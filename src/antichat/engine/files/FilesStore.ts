/**
 * Rows of the files engine in antichat.db: files, their chunks (with a
 * keyword index kept by triggers), chunk vectors and imported tables.
 */
import {VectorStore} from '../memory/embeddings/vectorStore';
import type {Db, SqlValue} from '../store/driver';
import type {Chunk} from './chunk';
import type {DocumentKind, ExtractedTable, PageLabel} from './extract/types';
import type {FileLimit} from './limits';

export type FileMode =
  | 'inline'
  | 'retrieval'
  | 'vision'
  | 'ocr'
  | 'table'
  | 'audio';
export type FileStatus = 'processing' | 'ready' | 'failed';

export interface FileData {
  pageLabel?: PageLabel;
  /** Full text by page, kept for files small enough to be put in whole. */
  pages?: Array<{page: number; text: string; title?: string}>;
  limits?: FileLimit[];
  /** Pages read with OCR. */
  ocrPages?: number;
  /** Chunks that have a vector (semantic search works for them). */
  embedded?: number;
  error?: string;
  width?: number;
  height?: number;
}

export interface FileRow {
  id: string;
  sessionId: string | null;
  projectId: string | null;
  messageId: string | null;
  name: string;
  mimeType: string | null;
  size: number | null;
  uri: string;
  kind: DocumentKind;
  status: FileStatus;
  mode: FileMode | null;
  pageCount: number | null;
  tokenCount: number | null;
  data: FileData;
  createdAt: number;
}

export interface ChunkRow {
  id: number;
  fileId: string;
  position: number;
  text: string;
  pageStart: number;
  pageEnd: number;
}

export interface TableRow {
  id: number;
  fileId: string;
  /** The name the model uses. */
  name: string;
  /** The real table in antichat.db. */
  sqlName: string;
  columns: Array<{name: string; type: 'number' | 'text'}>;
  rowCount: number;
}

/** A draft that no chat owns yet (the composer of a new chat). */
export const DRAFT_SESSION = '';

const toFile = (row: Record<string, any>): FileRow => ({
  id: row.id,
  sessionId: row.session_id || null,
  projectId: row.project_id ?? null,
  messageId: row.message_id ?? null,
  name: row.name,
  mimeType: row.mime_type ?? null,
  size: row.size ?? null,
  uri: row.uri ?? '',
  kind: (row.kind ?? 'unknown') as DocumentKind,
  status: (row.status ?? 'processing') as FileStatus,
  mode: (row.mode ?? null) as FileMode | null,
  pageCount: row.page_count ?? null,
  tokenCount: row.token_count ?? null,
  data: row.data ? JSON.parse(row.data) : {},
  createdAt: row.created_at,
});

const toChunk = (row: Record<string, any>): ChunkRow => ({
  id: row.id,
  fileId: row.file_id,
  position: row.position,
  text: row.text,
  pageStart: row.page_start ?? 1,
  pageEnd: row.page_end ?? row.page_start ?? 1,
});

/** A safe SQL identifier from a sheet or column name. */
export function sqlIdentifier(name: string, fallback: string): string {
  const clean = name
    .normalize('NFKD')
    .replace(/[^\w]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toLowerCase();
  const safe = clean && !/^\d/.test(clean) ? clean : `${fallback}${clean}`;
  return safe.slice(0, 48) || fallback;
}

export class FilesStore {
  readonly vectors: VectorStore;

  constructor(
    readonly db: Db,
    private readonly now: () => number = Date.now,
  ) {
    this.vectors = new VectorStore(db);
  }

  async insert(file: {
    id: string;
    sessionId: string | null;
    projectId?: string | null;
    name: string;
    mimeType?: string | null;
    size?: number | null;
    uri: string;
    kind: DocumentKind;
  }): Promise<void> {
    await this.db.run(
      `INSERT INTO files (id, project_id, session_id, name, mime_type, size,
          uri, status, kind, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'processing', ?, ?)`,
      [
        file.id,
        file.projectId ?? null,
        file.sessionId ?? DRAFT_SESSION,
        file.name,
        file.mimeType ?? null,
        file.size ?? null,
        file.uri,
        file.kind,
        this.now(),
      ],
    );
  }

  async finish(
    id: string,
    result: {
      status: FileStatus;
      mode?: FileMode | null;
      pageCount?: number | null;
      tokenCount?: number | null;
      data: FileData;
    },
  ): Promise<void> {
    await this.db.run(
      `UPDATE files SET status = ?, mode = ?, page_count = ?, token_count = ?,
          data = ? WHERE id = ?`,
      [
        result.status,
        result.mode ?? null,
        result.pageCount ?? null,
        result.tokenCount ?? null,
        JSON.stringify(result.data),
        id,
      ],
    );
  }

  async patchData(id: string, patch: Partial<FileData>): Promise<void> {
    const file = await this.get(id);
    if (file) {
      await this.db.run('UPDATE files SET data = ? WHERE id = ?', [
        JSON.stringify({...file.data, ...patch}),
        id,
      ]);
    }
  }

  async get(id: string): Promise<FileRow | null> {
    const row = await this.db.get('SELECT * FROM files WHERE id = ?', [id]);
    return row ? toFile(row) : null;
  }

  /** Files of a chat (drafts of that chat included), oldest first. */
  async list(sessionId: string | null): Promise<FileRow[]> {
    const rows = await this.db.all(
      'SELECT * FROM files WHERE session_id = ? ORDER BY created_at, id',
      [sessionId ?? DRAFT_SESSION],
    );
    return rows.map(toFile);
  }

  async listForProject(projectId: string): Promise<FileRow[]> {
    const rows = await this.db.all(
      'SELECT * FROM files WHERE project_id = ? ORDER BY created_at, id',
      [projectId],
    );
    return rows.map(toFile);
  }

  /** The new chat's drafts become files of the chat that was just created. */
  async adoptDrafts(sessionId: string): Promise<number> {
    const drafts = await this.list(null);
    if (drafts.length > 0) {
      await this.db.run(
        'UPDATE files SET session_id = ? WHERE session_id = ?',
        [sessionId, DRAFT_SESSION],
      );
    }
    return drafts.length;
  }

  /** Marks the chat's unsent files as sent with `messageId`. */
  async markSent(sessionId: string, messageId: string): Promise<void> {
    await this.db.run(
      'UPDATE files SET message_id = ? WHERE session_id = ? AND message_id IS NULL',
      [messageId, sessionId],
    );
  }

  async addChunks(fileId: string, chunks: Chunk[]): Promise<void> {
    await this.db.transaction(async () => {
      for (const chunk of chunks) {
        await this.db.run(
          `INSERT INTO chunks (file_id, position, text, page_start, page_end, data)
           VALUES (?, ?, ?, ?, ?, ?)`,
          [
            fileId,
            chunk.position,
            chunk.text,
            chunk.pageStart,
            chunk.pageEnd,
            chunk.title ? JSON.stringify({title: chunk.title}) : null,
          ],
        );
      }
    });
  }

  async chunks(fileId: string): Promise<ChunkRow[]> {
    const rows = await this.db.all(
      'SELECT * FROM chunks WHERE file_id = ? ORDER BY position',
      [fileId],
    );
    return rows.map(toChunk);
  }

  async chunksById(ids: number[]): Promise<Map<number, ChunkRow>> {
    const out = new Map<number, ChunkRow>();
    for (let i = 0; i < ids.length; i += 400) {
      const batch = ids.slice(i, i + 400);
      const rows = await this.db.all(
        `SELECT * FROM chunks WHERE id IN (${batch.map(() => '?').join(', ')})`,
        batch,
      );
      rows.forEach(row => out.set(row.id, toChunk(row)));
    }
    return out;
  }

  /** Keyword hits among the chunks of `fileIds`, best first. */
  async keywordSearch(
    match: string,
    fileIds: string[],
    limit: number,
  ): Promise<Array<{id: number; rank: number}>> {
    if (fileIds.length === 0) {
      return [];
    }
    const rows = await this.db.all<{id: number; rank: number}>(
      `SELECT c.id AS id, bm25(chunks_fts) AS rank
       FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid
       WHERE chunks_fts MATCH ?
         AND c.file_id IN (${fileIds.map(() => '?').join(', ')})
       ORDER BY rank LIMIT ?`,
      [match, ...fileIds, limit],
    );
    return rows;
  }

  async chunkIds(fileIds: string[]): Promise<number[]> {
    if (fileIds.length === 0) {
      return [];
    }
    const rows = await this.db.all<{id: number}>(
      `SELECT id FROM chunks WHERE file_id IN (${fileIds
        .map(() => '?')
        .join(', ')})`,
      fileIds,
    );
    return rows.map(row => row.id);
  }

  // ---------------------------------------------------------------- tables

  /** Copies a spreadsheet table into a table of its own for SQL questions. */
  async importTable(fileId: string, table: ExtractedTable): Promise<TableRow> {
    const taken = new Set(
      (await this.tables([fileId])).map(existing => existing.name),
    );
    let name = sqlIdentifier(table.name, 't_');
    for (let n = 2; taken.has(name); n++) {
      name = `${sqlIdentifier(table.name, 't_')}_${n}`;
    }
    const used = new Set<string>();
    const columns = table.columns.map((column, index) => {
      let id = sqlIdentifier(column, 'c_');
      for (let n = 2; used.has(id); n++) {
        id = `${sqlIdentifier(column, 'c_')}_${n}`;
      }
      used.add(id);
      const values = table.rows.map(row => row[index]).filter(v => v !== null);
      const numeric =
        values.length > 0 && values.every(v => typeof v === 'number');
      return {
        name: id,
        type: numeric ? ('number' as const) : ('text' as const),
      };
    });
    return this.db.transaction(async () => {
      await this.db.run(
        `INSERT INTO file_tables (file_id, name, sql_name, columns, row_count)
         VALUES (?, ?, '', ?, ?)`,
        [fileId, name, JSON.stringify(columns), table.rows.length],
      );
      const row = await this.db.get<{id: number}>(
        'SELECT last_insert_rowid() AS id',
      );
      const sqlName = `ft_${row!.id}`;
      await this.db.run('UPDATE file_tables SET sql_name = ? WHERE id = ?', [
        sqlName,
        row!.id,
      ]);
      await this.db.run(
        `CREATE TABLE ${sqlName} (${columns
          .map(c => `"${c.name}" ${c.type === 'number' ? 'REAL' : 'TEXT'}`)
          .join(', ')})`,
      );
      // Multi-row inserts: SQLite allows 32,766 bound values per statement.
      const perStatement = Math.max(1, Math.floor(900 / columns.length));
      const one = `(${columns.map(() => '?').join(', ')})`;
      for (let i = 0; i < table.rows.length; i += perStatement) {
        const batch = table.rows.slice(i, i + perStatement);
        await this.db.run(
          `INSERT INTO ${sqlName} VALUES ${batch.map(() => one).join(', ')}`,
          batch.flatMap(cells =>
            columns.map((_c, c) => (cells[c] ?? null) as SqlValue),
          ),
        );
      }
      return {
        id: row!.id,
        fileId,
        name,
        sqlName,
        columns,
        rowCount: table.rows.length,
      };
    });
  }

  async tables(fileIds: string[]): Promise<TableRow[]> {
    if (fileIds.length === 0) {
      return [];
    }
    const rows = await this.db.all(
      `SELECT * FROM file_tables WHERE file_id IN (${fileIds
        .map(() => '?')
        .join(', ')}) ORDER BY id`,
      fileIds,
    );
    return rows.map(row => ({
      id: row.id,
      fileId: row.file_id,
      name: row.name,
      sqlName: row.sql_name,
      columns: JSON.parse(row.columns),
      rowCount: row.row_count,
    }));
  }

  // --------------------------------------------------------------- removal

  async remove(fileId: string): Promise<FileRow | null> {
    const file = await this.get(fileId);
    if (!file) {
      return null;
    }
    const chunkIds = await this.chunkIds([fileId]);
    await this.vectors.delete('chunk', chunkIds.map(String));
    const tables = await this.tables([fileId]);
    await this.db.transaction(async () => {
      for (const table of tables) {
        await this.db.run(`DROP TABLE IF EXISTS ${table.sqlName}`);
      }
      await this.db.run('DELETE FROM file_tables WHERE file_id = ?', [fileId]);
      await this.db.run('DELETE FROM chunks WHERE file_id = ?', [fileId]);
      await this.db.run('DELETE FROM files WHERE id = ?', [fileId]);
    });
    return file;
  }

  /** Everything a chat had attached (the chat was deleted). */
  async removeForSession(sessionId: string): Promise<FileRow[]> {
    const removed: FileRow[] = [];
    for (const file of await this.list(sessionId)) {
      const gone = await this.remove(file.id);
      if (gone) {
        removed.push(gone);
      }
    }
    return removed;
  }
}
