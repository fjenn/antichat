/**
 * Projects (#10): a named space with shared instructions, attached files
 * and its own chats and memories.
 *
 * The store owns the `projects` rows and the project side of `files`.
 * A chat's membership lives in `session_meta.project_id`, which belongs to
 * the conversation store (M3); it is written only through `ProjectChats`
 * (M3's `setProject` / `deleteSessions`).
 */
import type {Db, SqlRow} from '../store/driver';
import {migrate} from '../store/schema';
import {registerProjectMigrations} from './schema';
import {
  MAX_PROJECT_FILES,
  MAX_PROJECT_INSTRUCTIONS_CHARS,
  MAX_PROJECT_NAME_CHARS,
  type NewProjectFile,
  type Project,
  type ProjectChats,
  type ProjectFile,
  type ProjectMemoryScope,
  type ProjectSummary,
} from './types';

export interface ProjectStoreOptions {
  db: Db;
  chats?: ProjectChats;
  now?: () => number;
  newId?: () => string;
}

export interface ProjectPatch {
  name?: string;
  instructions?: string;
  memoryScope?: ProjectMemoryScope;
  appearance?: Record<string, unknown>;
  archived?: boolean;
}

function randomId(prefix: string): string {
  let out = prefix;
  for (let i = 0; i < 16; i++) {
    out += Math.floor(Math.random() * 36).toString(36);
  }
  return out;
}

function parseData(raw: unknown): Record<string, unknown> {
  if (typeof raw !== 'string' || !raw) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

function toProject(row: SqlRow): Project {
  return {
    id: row.id,
    name: row.name,
    instructions: row.instructions ?? '',
    memoryScope: row.memory_scope === 'project' ? 'project' : 'default',
    appearance: parseData(row.data),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    archivedAt: row.archived_at ?? null,
  };
}

function toFile(row: SqlRow): ProjectFile {
  return {
    id: row.id,
    projectId: row.project_id,
    name: row.name,
    mimeType: row.mime_type ?? null,
    size: row.size ?? null,
    uri: row.uri ?? null,
    status: row.status ?? 'pending',
    createdAt: row.created_at,
  };
}

const cleanName = (name: string): string =>
  name.replace(/\s+/g, ' ').trim().slice(0, MAX_PROJECT_NAME_CHARS);

export class ProjectStore {
  readonly db: Db;
  private readonly chats?: ProjectChats;
  private readonly now: () => number;
  private readonly newId: () => string;
  private listeners = new Set<() => void>();

  constructor(options: ProjectStoreOptions) {
    this.db = options.db;
    this.chats = options.chats;
    this.now = options.now ?? Date.now;
    this.newId = options.newId ?? (() => randomId('prj_'));
  }

  /** Applies the projects schema. Safe to call twice. */
  async init(): Promise<void> {
    registerProjectMigrations();
    await migrate(this.db);
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed(): void {
    this.listeners.forEach(listener => listener());
  }

  // ---- projects

  async create(input: {
    name: string;
    instructions?: string;
    memoryScope?: ProjectMemoryScope;
    appearance?: Record<string, unknown>;
  }): Promise<Project> {
    const name = cleanName(input.name);
    if (!name) {
      throw new Error('A project needs a name');
    }
    const id = this.newId();
    const now = this.now();
    await this.db.run(
      `INSERT INTO projects (id, name, instructions, data, created_at,
         updated_at, memory_scope)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        name,
        (input.instructions ?? '').slice(0, MAX_PROJECT_INSTRUCTIONS_CHARS),
        input.appearance ? JSON.stringify(input.appearance) : null,
        now,
        now,
        input.memoryScope ?? 'default',
      ],
    );
    this.changed();
    return (await this.get(id))!;
  }

  async get(id: string): Promise<Project | null> {
    const row = await this.db.get('SELECT * FROM projects WHERE id = ?', [id]);
    return row ? toProject(row) : null;
  }

  /** Projects with their counts, most recently active first. */
  async list(
    options: {includeArchived?: boolean} = {},
  ): Promise<ProjectSummary[]> {
    const rows = await this.db.all(
      `SELECT p.*,
          (SELECT count(*) FROM session_meta s
           WHERE s.project_id = p.id AND s.temporary = 0) AS chat_count,
          (SELECT max(s.updated_at) FROM session_meta s
           WHERE s.project_id = p.id AND s.temporary = 0) AS last_chat_at,
          (SELECT count(*) FROM files f WHERE f.project_id = p.id) AS file_count
       FROM projects p
       ${options.includeArchived ? '' : 'WHERE p.archived_at IS NULL'}`,
    );
    const memoryCounts = new Map<string, number>();
    try {
      const counts = await this.db.all<{project_id: string; c: number}>(
        `SELECT project_id, count(*) AS c FROM memories
         WHERE project_id IS NOT NULL GROUP BY project_id`,
      );
      counts.forEach(row => memoryCounts.set(row.project_id, row.c));
    } catch {
      // The memory namespace is not installed: no project memories.
    }
    return rows
      .map(row => ({
        ...toProject(row),
        chatCount: row.chat_count ?? 0,
        fileCount: row.file_count ?? 0,
        memoryCount: memoryCounts.get(row.id) ?? 0,
        lastChatAt: row.last_chat_at ?? null,
      }))
      .sort(
        (a, b) =>
          Math.max(b.lastChatAt ?? 0, b.updatedAt) -
          Math.max(a.lastChatAt ?? 0, a.updatedAt),
      );
  }

  async update(id: string, patch: ProjectPatch): Promise<Project | null> {
    const current = await this.get(id);
    if (!current) {
      return null;
    }
    const name = patch.name !== undefined ? cleanName(patch.name) : undefined;
    await this.db.run(
      `UPDATE projects SET name = ?, instructions = ?, memory_scope = ?,
         data = ?, archived_at = ?, updated_at = ? WHERE id = ?`,
      [
        name || current.name,
        (patch.instructions ?? current.instructions).slice(
          0,
          MAX_PROJECT_INSTRUCTIONS_CHARS,
        ),
        patch.memoryScope ?? current.memoryScope,
        JSON.stringify(patch.appearance ?? current.appearance),
        patch.archived === undefined
          ? current.archivedAt
          : patch.archived
            ? (current.archivedAt ?? this.now())
            : null,
        this.now(),
        id,
      ],
    );
    this.changed();
    return this.get(id);
  }

  /**
   * Deletes a project with its files and memories. Its chats are deleted
   * too (ChatGPT's behaviour) unless `keepChats` moves them back out.
   */
  async delete(id: string, options: {keepChats?: boolean} = {}): Promise<void> {
    const sessionIds = await this.sessionIds(id);
    if (sessionIds.length > 0) {
      if (!this.chats) {
        throw new Error(
          'ProjectStore needs `chats` to delete a project with chats',
        );
      }
      if (options.keepChats) {
        for (const sessionId of sessionIds) {
          await this.chats.setProject(sessionId, null);
        }
      } else {
        await this.chats.deleteSessions(sessionIds);
      }
    }
    await this.db.transaction(async () => {
      const files = await this.db.all<{id: string}>(
        'SELECT id FROM files WHERE project_id = ?',
        [id],
      );
      for (const file of files) {
        await this.dropFileRows(file.id);
      }
      try {
        await this.db.run(
          `DELETE FROM vectors WHERE owner_kind = 'memory' AND owner_id IN
             (SELECT id FROM memories WHERE project_id = ?)`,
          [id],
        );
        await this.db.run(
          `DELETE FROM memory_use_items WHERE memory_id IN
             (SELECT id FROM memories WHERE project_id = ?)`,
          [id],
        );
        await this.db.run('DELETE FROM memories WHERE project_id = ?', [id]);
      } catch {
        // Memory namespace not installed.
      }
      await this.db.run('DELETE FROM projects WHERE id = ?', [id]);
    });
    this.changed();
  }

  // ---- chats

  async sessionIds(projectId: string): Promise<string[]> {
    const rows = await this.db.all<{session_id: string}>(
      `SELECT session_id FROM session_meta
       WHERE project_id = ? AND temporary = 0 ORDER BY updated_at DESC`,
      [projectId],
    );
    return rows.map(row => row.session_id);
  }

  /** The project a chat is in, or null. */
  async projectOfSession(sessionId: string): Promise<Project | null> {
    const row = await this.db.get(
      `SELECT p.* FROM session_meta s JOIN projects p ON p.id = s.project_id
       WHERE s.session_id = ?`,
      [sessionId],
    );
    return row ? toProject(row) : null;
  }

  /** Moves a chat into a project, or out of any project with `null`. */
  async moveChat(sessionId: string, projectId: string | null): Promise<void> {
    if (!this.chats) {
      throw new Error('ProjectStore needs `chats` to move a chat');
    }
    if (projectId && !(await this.get(projectId))) {
      throw new Error(`Unknown project ${projectId}`);
    }
    await this.chats.setProject(sessionId, projectId);
    if (projectId) {
      await this.db.run('UPDATE projects SET updated_at = ? WHERE id = ?', [
        this.now(),
        projectId,
      ]);
    }
    this.changed();
  }

  // ---- files (references; content and chunks belong to M10)

  async listFiles(projectId: string): Promise<ProjectFile[]> {
    const rows = await this.db.all(
      'SELECT * FROM files WHERE project_id = ? ORDER BY created_at, rowid',
      [projectId],
    );
    return rows.map(toFile);
  }

  async attachFile(
    projectId: string,
    file: NewProjectFile,
  ): Promise<ProjectFile> {
    if (!(await this.get(projectId))) {
      throw new Error(`Unknown project ${projectId}`);
    }
    const existing = await this.listFiles(projectId);
    if (existing.length >= MAX_PROJECT_FILES) {
      throw new Error(`A project holds at most ${MAX_PROJECT_FILES} files`);
    }
    const fileId = this.newId().replace(/^prj_/, 'file_');
    await this.db.run(
      `INSERT INTO files (id, project_id, session_id, name, mime_type, size,
         uri, status, data, created_at)
       VALUES (?, ?, NULL, ?, ?, ?, ?, ?, NULL, ?)`,
      [
        fileId,
        projectId,
        file.name.trim() || 'File',
        file.mimeType ?? null,
        file.size ?? null,
        file.uri ?? null,
        file.status ?? 'pending',
        this.now(),
      ],
    );
    await this.db.run('UPDATE projects SET updated_at = ? WHERE id = ?', [
      this.now(),
      projectId,
    ]);
    this.changed();
    const row = await this.db.get('SELECT * FROM files WHERE id = ?', [fileId]);
    return toFile(row!);
  }

  /** M10 reports progress here once it has read (or failed to read) a file. */
  async setFileStatus(
    fileId: string,
    status: ProjectFile['status'],
  ): Promise<void> {
    await this.db.run('UPDATE files SET status = ? WHERE id = ?', [
      status,
      fileId,
    ]);
    this.changed();
  }

  async removeFile(fileId: string): Promise<void> {
    await this.db.transaction(() => this.dropFileRows(fileId));
    this.changed();
  }

  private async dropFileRows(fileId: string): Promise<void> {
    await this.db.run(
      `DELETE FROM vectors WHERE owner_kind = 'chunk' AND owner_id IN
         (SELECT CAST(id AS TEXT) FROM chunks WHERE file_id = ?)`,
      [fileId],
    );
    await this.db.run('DELETE FROM chunks WHERE file_id = ?', [fileId]);
    await this.db.run('DELETE FROM files WHERE id = ?', [fileId]);
  }
}
