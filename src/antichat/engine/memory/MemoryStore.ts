/**
 * Saved memories in antichat.db: rows, full-text index, settings, the hard
 * cap with eviction, tombstones of deleted facts, and the per-answer record
 * of which memories were in the prompt.
 *
 * This class only stores. Whether a new fact is a duplicate or a correction
 * of an old one is decided in `reconcile.ts`; what goes into a prompt in
 * `retrieval.ts`.
 */
import type {Db, SqlRow, SqlValue} from '../store/driver';
import {migrate} from '../store/schema';
import {registerMemoryMigrations} from './schema';
import {
  anyWordQuery,
  clip,
  factSignature,
  normalizeFact,
  sharesTopic,
  slotOf,
  stemSet,
} from './text';
import {
  DEFAULT_MEMORY_SETTINGS,
  type MemoryEvent,
  type MemoryItem,
  type MemoryKind,
  type MemoryScope,
  type MemorySettings,
  type MemoryUse,
  type MemoryUseHow,
  type MemoryUseItem,
  type NewMemory,
} from './types';

export const MAX_MEMORY_CHARS = 240;
const DAY_MS = 86_400_000;
/** Passing context loses half its weight in 45 days, a profile fact in a year. */
const HALF_LIFE_DAYS: Record<MemoryKind, number> = {
  profile: 365,
  preference: 365,
  context: 45,
};
const DEFAULT_IMPORTANCE: Record<MemoryKind, number> = {
  profile: 0.7,
  preference: 0.7,
  context: 0.45,
};
/** Use records older than this are dropped by `purge`. */
const USE_RETENTION_DAYS = 180;

export interface MemoryStoreOptions {
  db: Db;
  now?: () => number;
  newId?: () => string;
}

export interface ListOptions {
  /** `undefined`: everything. `null`: global only. A string: that project. */
  projectId?: string | null;
  /** Filter by words (manage-screen search). */
  search?: string;
  kind?: MemoryKind;
}

export interface MemoryPatch {
  text?: string;
  kind?: MemoryKind;
  pinned?: boolean;
  importance?: number;
  projectId?: string | null;
}

function randomId(): string {
  let out = 'mem_';
  for (let i = 0; i < 16; i++) {
    out += Math.floor(Math.random() * 36).toString(36);
  }
  return out;
}

function parseData(raw: unknown): Record<string, any> {
  if (typeof raw !== 'string' || raw.length === 0) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

const KINDS: MemoryKind[] = ['profile', 'preference', 'context'];

function toItem(row: SqlRow): MemoryItem {
  const data = parseData(row.data);
  return {
    id: row.id,
    text: row.text,
    kind: KINDS.includes(row.kind) ? row.kind : 'context',
    origin: row.origin ?? 'user',
    projectId: row.project_id ?? null,
    pinned: row.pinned === 1,
    importance: typeof row.importance === 'number' ? row.importance : 0.5,
    sensitive: row.sensitive ?? null,
    sourceSessionId: row.source_session_id ?? null,
    sourceNodeId: row.source_node_id ?? null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    lastUsedAt: row.last_used_at ?? null,
    useCount: row.use_count ?? 0,
    previousText:
      typeof data.previousText === 'string' ? data.previousText : null,
  };
}

/**
 * What a memory is worth keeping, 0–1.3: importance, faded by age (measured
 * from the last change or use), plus a little for being used often. Used for
 * eviction and for choosing what fits the prompt.
 */
export function memoryValue(item: MemoryItem, now: number): number {
  const touched = Math.max(item.updatedAt, item.lastUsedAt ?? 0);
  const ageDays = Math.max(0, now - touched) / DAY_MS;
  const recency = Math.pow(0.5, ageDays / HALF_LIFE_DAYS[item.kind]);
  const usage = Math.min(1, Math.log2(1 + item.useCount) / 5);
  return item.importance * (0.6 + 0.4 * recency) + 0.15 * usage;
}

/** The SQL condition for "readable in this chat". */
function scopeFilter(
  scope: MemoryScope,
  alias: string = '',
): {
  sql: string;
  params: SqlValue[];
} {
  const column = `${alias}project_id`;
  if (scope.projectId && scope.projectOnly) {
    return {sql: `${column} = ?`, params: [scope.projectId]};
  }
  if (scope.projectId) {
    return {
      sql: `(${column} IS NULL OR ${column} = ?)`,
      params: [scope.projectId],
    };
  }
  return {sql: `${column} IS NULL`, params: []};
}

export class MemoryStore {
  readonly db: Db;
  private readonly now: () => number;
  private readonly newId: () => string;
  private settings: MemorySettings = {...DEFAULT_MEMORY_SETTINGS};
  private listeners = new Set<(event: MemoryEvent) => void>();
  /**
   * Counts every change that must reach an open chat's prompt at once
   * (delete, edit, clear, switch off). Adding a memory does not count: the
   * frozen block of the open chat stays as it is.
   */
  private revisionCounter = 0;

  constructor(options: MemoryStoreOptions) {
    this.db = options.db;
    this.now = options.now ?? Date.now;
    this.newId = options.newId ?? randomId;
  }

  /** Applies the memory schema and loads the settings. Safe to call twice. */
  async init(): Promise<void> {
    registerMemoryMigrations();
    await migrate(this.db);
    const rows = await this.db.all<{key: string; value: string}>(
      'SELECT key, value FROM memory_settings',
    );
    const saved: Record<string, unknown> = {};
    for (const row of rows) {
      try {
        saved[row.key] = JSON.parse(row.value);
      } catch {
        // A damaged row falls back to the default.
      }
    }
    this.settings = {...DEFAULT_MEMORY_SETTINGS, ...saved};
  }

  get revision(): number {
    return this.revisionCounter;
  }

  /** The UI and the "Memory updated" notice listen here. */
  subscribe(listener: (event: MemoryEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(event: MemoryEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (error) {
        console.warn('[antichat] memory listener failed', error);
      }
    }
  }

  // ---- settings

  getSettings(): MemorySettings {
    return {...this.settings};
  }

  async updateSettings(
    patch: Partial<MemorySettings>,
  ): Promise<MemorySettings> {
    const next = {...this.settings, ...patch};
    next.maxItems = Math.max(10, Math.min(1000, Math.round(next.maxItems)));
    await this.db.transaction(async () => {
      for (const [key, value] of Object.entries(next)) {
        await this.db.run(
          `INSERT INTO memory_settings (key, value) VALUES (?, ?)
           ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
          [key, JSON.stringify(value)],
        );
      }
    });
    const readingChanged =
      next.enabled !== this.settings.enabled ||
      next.referenceChats !== this.settings.referenceChats;
    this.settings = next;
    if (readingChanged) {
      this.revisionCounter++;
    }
    if (patch.maxItems !== undefined) {
      await this.enforceCap();
    }
    this.emit({type: 'settings', settings: this.getSettings()});
    return this.getSettings();
  }

  /** "Pause memory": keep using what is saved, save nothing new. */
  setPaused(paused: boolean): Promise<MemorySettings> {
    return this.updateSettings({paused});
  }

  /** True when a new memory may be written right now. */
  get canWrite(): boolean {
    return this.settings.enabled && !this.settings.paused;
  }

  // ---- reading

  async get(id: string): Promise<MemoryItem | null> {
    const row = await this.db.get('SELECT * FROM memories WHERE id = ?', [id]);
    return row ? toItem(row) : null;
  }

  async getMany(ids: string[]): Promise<MemoryItem[]> {
    if (ids.length === 0) {
      return [];
    }
    const rows = await this.db.all(
      `SELECT * FROM memories WHERE id IN (${ids.map(() => '?').join(', ')})`,
      ids,
    );
    const byId = new Map(rows.map(row => [row.id as string, toItem(row)]));
    return ids.map(id => byId.get(id)).filter((m): m is MemoryItem => !!m);
  }

  /** The manage screen's list: pinned first, then newest change first. */
  async list(options: ListOptions = {}): Promise<MemoryItem[]> {
    const where: string[] = [];
    const params: SqlValue[] = [];
    if (options.projectId === null) {
      where.push('m.project_id IS NULL');
    } else if (typeof options.projectId === 'string') {
      where.push('m.project_id = ?');
      params.push(options.projectId);
    }
    if (options.kind) {
      where.push('m.kind = ?');
      params.push(options.kind);
    }
    const match = options.search ? anyWordQuery(options.search) : null;
    if (options.search && !match) {
      return [];
    }
    const rows = match
      ? await this.db.all(
          `SELECT m.* FROM memories_fts f JOIN memories m ON m.rowid = f.rowid
           WHERE memories_fts MATCH ? ${where.length ? `AND ${where.join(' AND ')}` : ''}
           ORDER BY bm25(memories_fts)`,
          [match, ...params],
        )
      : await this.db.all(
          `SELECT m.* FROM memories m
           ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
           ORDER BY m.pinned DESC, m.updated_at DESC, m.rowid DESC`,
          params,
        );
    return rows.map(toItem);
  }

  /** Every memory a chat in `scope` may read. */
  async visible(scope: MemoryScope = {}): Promise<MemoryItem[]> {
    const filter = scopeFilter(scope);
    const rows = await this.db.all(
      `SELECT * FROM memories WHERE ${filter.sql} ORDER BY created_at, rowid`,
      filter.params,
    );
    return rows.map(toItem);
  }

  async count(): Promise<number> {
    const row = await this.db.get<{c: number}>(
      'SELECT count(*) AS c FROM memories',
    );
    return row?.c ?? 0;
  }

  /**
   * Memories sharing words with `text`, best first (bm25 with stemming).
   * `rank` is bm25: lower is better.
   */
  async searchText(
    text: string,
    scope: MemoryScope = {},
    limit: number = 8,
  ): Promise<Array<{item: MemoryItem; rank: number}>> {
    const match = anyWordQuery(text);
    if (!match) {
      return [];
    }
    const filter = scopeFilter(scope, 'm.');
    const rows = await this.db.all(
      `SELECT m.*, bm25(memories_fts) AS rank
       FROM memories_fts f JOIN memories m ON m.rowid = f.rowid
       WHERE memories_fts MATCH ? AND ${filter.sql}
       ORDER BY rank LIMIT ?`,
      [match, ...filter.params, limit],
    );
    return rows.map(row => ({item: toItem(row), rank: row.rank as number}));
  }

  /** A memory with the same normalised text in the same scope. */
  async findExact(
    text: string,
    projectId: string | null,
  ): Promise<MemoryItem | null> {
    const norm = normalizeFact(text);
    const row = await this.db.get(
      `SELECT * FROM memories WHERE norm = ? AND ${
        projectId ? 'project_id = ?' : 'project_id IS NULL'
      } LIMIT 1`,
      projectId ? [norm, projectId] : [norm],
    );
    return row ? toItem(row) : null;
  }

  async findBySlot(slot: string, scope: MemoryScope): Promise<MemoryItem[]> {
    const filter = scopeFilter(scope);
    const rows = await this.db.all(
      `SELECT * FROM memories WHERE slot = ? AND ${filter.sql}
       ORDER BY updated_at DESC`,
      [slot, ...filter.params],
    );
    return rows.map(toItem);
  }

  async needingReview(): Promise<MemoryItem[]> {
    const rows = await this.db.all(
      'SELECT * FROM memories WHERE review = 1 ORDER BY created_at',
    );
    return rows.map(toItem);
  }

  // ---- writing

  /**
   * Inserts a row as it is (no duplicate check; see `reconcile.ts`), then
   * enforces the cap. Returns null when memory is off or paused, or when
   * the text is empty.
   */
  async add(
    input: NewMemory,
    options: {review?: boolean; silent?: boolean; force?: boolean} = {},
  ): Promise<MemoryItem | null> {
    const text = clip(input.text, MAX_MEMORY_CHARS);
    if (!text || (!this.canWrite && !options.force)) {
      return null;
    }
    const kind = input.kind ?? 'context';
    const now = this.now();
    const id = this.newId();
    await this.db.run(
      `INSERT INTO memories (id, text, kind, source_session_id, source_node_id,
         pinned, data, created_at, updated_at, project_id, origin, importance,
         sensitive, norm, slot, review)
       VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        text,
        kind,
        input.sourceSessionId ?? null,
        input.sourceNodeId ?? null,
        input.pinned ? 1 : 0,
        now,
        now,
        input.projectId ?? null,
        input.origin,
        Math.max(0, Math.min(1, input.importance ?? DEFAULT_IMPORTANCE[kind])),
        input.sensitive ?? null,
        normalizeFact(text),
        slotOf(text),
        options.review ? 1 : 0,
      ],
    );
    const item = (await this.get(id))!;
    if (!options.silent) {
      this.emit({
        type: 'saved',
        memory: item,
        sessionId: input.sourceSessionId ?? null,
      });
    }
    await this.enforceCap(id);
    return item;
  }

  /**
   * Edits a memory. A text change keeps the old text for "Undo" and counts
   * as a revision, so open chats drop the old wording from their prompt.
   */
  async update(
    id: string,
    patch: MemoryPatch,
    options: {sessionId?: string | null; keepReview?: boolean} = {},
  ): Promise<MemoryItem | null> {
    const current = await this.get(id);
    if (!current) {
      return null;
    }
    const text =
      patch.text !== undefined ? clip(patch.text, MAX_MEMORY_CHARS) : undefined;
    if (text !== undefined && !text) {
      return current;
    }
    const sets: string[] = ['updated_at = ?'];
    const params: SqlValue[] = [this.now()];
    const textChanged = text !== undefined && text !== current.text;
    if (textChanged) {
      sets.push('text = ?', 'norm = ?', 'slot = ?', 'data = ?');
      params.push(
        text!,
        normalizeFact(text!),
        slotOf(text!),
        JSON.stringify({previousText: current.text}),
      );
      if (!options.keepReview) {
        sets.push('review = 0');
      }
    }
    if (patch.kind !== undefined) {
      sets.push('kind = ?');
      params.push(patch.kind);
    }
    if (patch.pinned !== undefined) {
      sets.push('pinned = ?');
      params.push(patch.pinned ? 1 : 0);
    }
    if (patch.importance !== undefined) {
      sets.push('importance = ?');
      params.push(Math.max(0, Math.min(1, patch.importance)));
    }
    if (patch.projectId !== undefined) {
      sets.push('project_id = ?');
      params.push(patch.projectId);
    }
    await this.db.run(`UPDATE memories SET ${sets.join(', ')} WHERE id = ?`, [
      ...params,
      id,
    ]);
    this.revisionCounter++;
    const item = (await this.get(id))!;
    if (textChanged) {
      this.emit({
        type: 'updated',
        memory: item,
        previousText: current.text,
        sessionId: options.sessionId ?? null,
      });
    } else {
      this.emit({type: 'saved', memory: item, sessionId: null});
    }
    return item;
  }

  /** Puts the text from before the last update back ("Undo"). */
  async undoUpdate(id: string): Promise<MemoryItem | null> {
    const current = await this.get(id);
    if (!current?.previousText) {
      return current;
    }
    return this.update(id, {text: current.previousText});
  }

  setPinned(id: string, pinned: boolean): Promise<MemoryItem | null> {
    return this.update(id, {pinned});
  }

  async clearReview(id: string): Promise<void> {
    await this.db.run('UPDATE memories SET review = 0 WHERE id = ?', [id]);
  }

  /** Marks a duplicate hit as fresh without changing it. */
  async touch(id: string): Promise<void> {
    await this.db.run('UPDATE memories SET updated_at = ? WHERE id = ?', [
      this.now(),
      id,
    ]);
  }

  /**
   * Deletes memories. Deletions by the user or the `forget_memory` tool
   * leave a signature behind so the background pass does not save the same
   * fact again from an old chat.
   */
  async delete(
    ids: string[],
    reason: 'user' | 'tool' | 'evicted' | 'replaced' = 'user',
  ): Promise<number> {
    const items = await this.getMany(ids);
    if (items.length === 0) {
      return 0;
    }
    const now = this.now();
    await this.db.transaction(async () => {
      for (const item of items) {
        await this.db.run('DELETE FROM memories WHERE id = ?', [item.id]);
        await this.db.run('DELETE FROM memory_use_items WHERE memory_id = ?', [
          item.id,
        ]);
        await this.db.run(
          "DELETE FROM vectors WHERE owner_kind = 'memory' AND owner_id = ?",
          [item.id],
        );
        if (reason === 'user' || reason === 'tool') {
          await this.db.run(
            `INSERT OR REPLACE INTO memory_tombstones (signature, created_at)
             VALUES (?, ?)`,
            [factSignature(item.text), now],
          );
        }
      }
    });
    if (reason === 'user' || reason === 'tool') {
      await this.suppressDigests(items);
    }
    this.revisionCounter++;
    this.emit({type: 'deleted', ids: items.map(item => item.id), reason});
    return items.length;
  }

  /**
   * A deleted memory must stop reaching the prompt. The recent-chats block
   * quotes what the user wrote ("I'm vegetarian, dinner ideas?"), so chats
   * that touch on the deleted fact are taken off that list. They stay in
   * the chat history and can be found with `search_chats`; deleting the
   * chat removes them for good.
   */
  private async suppressDigests(items: MemoryItem[]): Promise<void> {
    const rows = await this.db.all(
      `SELECT s.session_id, s.title, d.digest, d.source,
          (SELECT n.text FROM nodes n
           WHERE n.session_id = s.session_id AND n.on_path = 1 AND n.role = 'user'
           ORDER BY n.depth LIMIT 1) AS first_user
       FROM session_meta s
       LEFT JOIN chat_digests d ON d.session_id = s.session_id
       WHERE s.temporary = 0
       ORDER BY s.updated_at DESC LIMIT 80`,
    );
    const facts = items.map(item => ({
      stems: stemSet(normalizeFact(item.text)),
      source: item.sourceSessionId,
    }));
    const now = this.now();
    for (const row of rows) {
      if (row.source === 'suppressed') {
        continue;
      }
      const said = stemSet(
        `${row.title ?? ''} ${row.digest ?? ''} ${row.first_user ?? ''}`,
      );
      if (
        !facts.some(
          fact =>
            fact.source === row.session_id || sharesTopic(fact.stems, said),
        )
      ) {
        continue;
      }
      await this.db.run(
        `INSERT INTO chat_digests (session_id, digest, through_seq, source, updated_at)
         VALUES (?, '', 0, 'suppressed', ?)
         ON CONFLICT (session_id) DO UPDATE SET digest = '',
           source = 'suppressed', updated_at = excluded.updated_at`,
        [row.session_id, now],
      );
    }
  }

  /**
   * "Delete all memories". Removes memories, their vectors, tombstones and
   * every use record. Chats already read by the background pass stay marked
   * as read, so nothing comes back from them.
   */
  async deleteAll(options: {projectId?: string} = {}): Promise<number> {
    const before = await this.count();
    if (options.projectId) {
      const rows = await this.db.all<{id: string}>(
        'SELECT id FROM memories WHERE project_id = ?',
        [options.projectId],
      );
      return this.delete(
        rows.map(row => row.id),
        'user',
      );
    }
    await this.suppressDigests(await this.list());
    await this.db.transaction(async () => {
      await this.db.run('DELETE FROM memories');
      await this.db.run('DELETE FROM memory_use_items');
      await this.db.run('DELETE FROM memory_uses');
      await this.db.run('DELETE FROM memory_tombstones');
      await this.db.run("DELETE FROM vectors WHERE owner_kind = 'memory'");
    });
    this.revisionCounter++;
    this.emit({type: 'cleared'});
    return before;
  }

  /**
   * Hard cap. Above `maxItems` the least valuable unpinned memory goes
   * first; the memory just written (`protect`) is spared unless everything
   * else is pinned.
   */
  async enforceCap(protect?: string): Promise<string[]> {
    const max = this.settings.maxItems;
    const total = await this.count();
    if (total <= max) {
      return [];
    }
    const rows = await this.db.all('SELECT * FROM memories WHERE pinned = 0');
    const now = this.now();
    const candidates = rows
      .map(toItem)
      .sort((a, b) => memoryValue(a, now) - memoryValue(b, now));
    const spared = candidates.filter(item => item.id !== protect);
    const order = spared.length > 0 ? spared : candidates;
    const evicted = order.slice(0, total - max).map(item => item.id);
    if (evicted.length > 0) {
      await this.delete(evicted, 'evicted');
    }
    return evicted;
  }

  // ---- tombstones

  async isTombstoned(text: string): Promise<boolean> {
    const row = await this.db.get(
      'SELECT 1 AS hit FROM memory_tombstones WHERE signature = ?',
      [factSignature(text)],
    );
    return !!row;
  }

  /** An explicit request to remember beats an earlier deletion. */
  async clearTombstone(text: string): Promise<void> {
    await this.db.run('DELETE FROM memory_tombstones WHERE signature = ?', [
      factSignature(text),
    ]);
  }

  // ---- "memory used" records

  /** Writes which memories are in the prompt of the answer being generated. */
  async recordUse(
    sessionId: string,
    items: Array<{memoryId: string; how: MemoryUseHow; cited?: boolean}>,
  ): Promise<string | null> {
    if (items.length === 0) {
      return null;
    }
    const id = this.newId().replace(/^mem_/, 'use_');
    const now = this.now();
    await this.db.transaction(async () => {
      await this.db.run(
        `INSERT INTO memory_uses (id, session_id, message_id, created_at)
         VALUES (?, ?, NULL, ?)`,
        [id, sessionId, now],
      );
      for (const item of items) {
        await this.db.run(
          `INSERT OR IGNORE INTO memory_use_items (use_id, memory_id, how, cited)
           VALUES (?, ?, ?, ?)`,
          [id, item.memoryId, item.how, item.cited ? 1 : 0],
        );
      }
    });
    return id;
  }

  /**
   * Called when the reply is finished: ties the record to the assistant
   * message and marks the memories the reply drew on (`citedIds`). Those
   * count as used for ranking.
   */
  async confirmUse(
    useId: string,
    details: {messageId?: string | null; citedIds?: string[]},
  ): Promise<void> {
    const now = this.now();
    await this.db.transaction(async () => {
      if (details.messageId) {
        await this.db.run(
          'UPDATE memory_uses SET message_id = ? WHERE id = ?',
          [details.messageId, useId],
        );
      }
      for (const memoryId of details.citedIds ?? []) {
        await this.db.run(
          'UPDATE memory_use_items SET cited = 1 WHERE use_id = ? AND memory_id = ?',
          [useId, memoryId],
        );
        await this.db.run(
          `UPDATE memories SET use_count = use_count + 1, last_used_at = ?
           WHERE id = ?`,
          [now, memoryId],
        );
      }
    });
    // The chip under the answer reads the record: tell it that it changed.
    this.emit({type: 'used', useId});
  }

  private async loadUses(
    where: string,
    params: SqlValue[],
  ): Promise<MemoryUse[]> {
    const rows = await this.db.all(
      `SELECT u.id AS use_id, u.session_id, u.message_id, u.created_at AS used_at,
          i.how, i.cited, m.id AS memory_id, m.text, m.kind
       FROM memory_uses u
       JOIN memory_use_items i ON i.use_id = u.id
       JOIN memories m ON m.id = i.memory_id
       WHERE ${where}
       ORDER BY u.created_at, u.rowid, i.cited DESC, m.created_at`,
      params,
    );
    const uses = new Map<string, MemoryUse>();
    for (const row of rows) {
      let use = uses.get(row.use_id);
      if (!use) {
        use = {
          id: row.use_id,
          sessionId: row.session_id,
          messageId: row.message_id ?? null,
          createdAt: row.used_at,
          items: [],
        };
        uses.set(use.id, use);
      }
      const item: MemoryUseItem = {
        memoryId: row.memory_id,
        text: row.text,
        kind: KINDS.includes(row.kind) ? row.kind : 'context',
        how: row.how,
        cited: row.cited === 1,
      };
      use.items.push(item);
    }
    return [...uses.values()];
  }

  async getUse(useId: string): Promise<MemoryUse | null> {
    return (await this.loadUses('u.id = ?', [useId]))[0] ?? null;
  }

  /** The sources of one answer (newest record if it was regenerated). */
  async useForMessage(messageId: string): Promise<MemoryUse | null> {
    const uses = await this.loadUses('u.message_id = ?', [messageId]);
    return uses[uses.length - 1] ?? null;
  }

  usesForSession(sessionId: string): Promise<MemoryUse[]> {
    return this.loadUses('u.session_id = ?', [sessionId]);
  }

  // ---- background-pass bookkeeping

  async extractedThrough(sessionId: string): Promise<number> {
    const row = await this.db.get<{through_seq: number}>(
      'SELECT through_seq FROM memory_extraction WHERE session_id = ?',
      [sessionId],
    );
    return row?.through_seq ?? 0;
  }

  async markExtracted(sessionId: string, throughSeq: number): Promise<void> {
    await this.db.run(
      `INSERT INTO memory_extraction (session_id, through_seq, updated_at)
       VALUES (?, ?, ?)
       ON CONFLICT (session_id) DO UPDATE SET
         through_seq = max(through_seq, excluded.through_seq),
         updated_at = excluded.updated_at`,
      [sessionId, throughSeq, this.now()],
    );
  }

  /**
   * Housekeeping for the idle pass: rows about chats that no longer exist,
   * and use records past their retention.
   */
  async purge(): Promise<void> {
    const cutoff = this.now() - USE_RETENTION_DAYS * DAY_MS;
    await this.db.transaction(async () => {
      for (const table of [
        'memory_uses',
        'memory_extraction',
        'chat_digests',
      ]) {
        await this.db.run(
          `DELETE FROM ${table} WHERE session_id NOT IN
             (SELECT session_id FROM session_meta)`,
        );
      }
      await this.db.run('DELETE FROM memory_uses WHERE created_at < ?', [
        cutoff,
      ]);
      await this.db.run(
        'DELETE FROM memory_use_items WHERE use_id NOT IN (SELECT id FROM memory_uses)',
      );
    });
  }
}
