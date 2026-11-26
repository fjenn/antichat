import {Db, SqlRow, SqlValue} from './driver';
import {migrate} from './schema';
import type {
  NodePayload,
  NodeRecord,
  OriginKind,
  Role,
  SessionMeta,
  StoreStats,
  ThreadMessage,
  UpMessage,
  UpSession,
} from './types';
import type {UpstreamGateway} from './upstream';

/**
 * The conversation tree (decision D1, docs/research/04-gap-analysis.md).
 *
 * antichat.db keeps every message ever written as a tree (`nodes`).
 * Upstream's WatermelonDB tables hold only the visible thread: the path
 * from the first message to `session_meta.current_leaf_id`. Upstream chat
 * code keeps writing to its own tables; `syncSession` folds what it wrote
 * into the tree, and `switchVersion` writes a different path back.
 *
 * Every public method that writes runs alone, in one transaction.
 */
export interface ConversationStoreOptions {
  db: Db;
  upstream: UpstreamGateway;
  now?: () => number;
  newId?: () => string;
}

/** How long a truncation announced by `beforeTruncate` may stay unfinished. */
const TRUNCATION_GRACE_MS = 30_000;

export const BRANCH_TITLE_PREFIX = 'Branch · ';

const ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

export function randomId(): string {
  let id = '';
  for (let i = 0; i < 16; i++) {
    id += ID_ALPHABET[Math.floor(Math.random() * ID_ALPHABET.length)];
  }
  return id;
}

/** The searchable, visible text of an upstream message row. */
export function payloadText(payload: NodePayload): string {
  if (payload.type === 'text') {
    return payload.text ?? '';
  }
  if (payload.type === 'assistant_turn') {
    const steps: Array<{content?: string}> = Array.isArray(
      payload.metadata?.steps,
    )
      ? payload.metadata.steps
      : [];
    return steps
      .map(step => (typeof step?.content === 'string' ? step.content : ''))
      .filter(content => content.trim().length > 0)
      .join('\n\n');
  }
  return '';
}

/** A message row without id and time, keys in one fixed order. */
export function toPayload(
  message: Pick<UpMessage, 'author' | 'type' | 'text' | 'metadata'>,
): NodePayload {
  const payload: NodePayload = {
    author: message.author,
    type: message.type,
    metadata: message.metadata ?? {},
  };
  if (message.text !== undefined && message.text !== null) {
    payload.text = message.text;
  }
  return payload;
}

/** Two user messages with the same signature are the same prompt. */
function promptSignature(payload: NodePayload): string {
  return JSON.stringify([
    payload.type,
    payload.text ?? '',
    payload.metadata?.imageUris ?? [],
  ]);
}

function nodeFromRow(row: SqlRow): NodeRecord {
  return {
    seq: row.seq,
    id: row.id,
    sessionId: row.session_id,
    parentId: row.parent_id ?? null,
    role: row.role,
    text: row.text,
    payload: JSON.parse(row.payload),
    extId: row.ext_id ?? null,
    ext: row.ext ? JSON.parse(row.ext) : null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    onPath: row.on_path === 1,
    depth: row.depth,
    activeChildId: row.active_child_id ?? null,
    upId: row.up_id ?? null,
  };
}

function metaFromRow(row: SqlRow): SessionMeta {
  return {
    sessionId: row.session_id,
    title: row.title,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    archivedAt: row.archived_at ?? null,
    pinnedAt: row.pinned_at ?? null,
    temporary: row.temporary === 1,
    locked: row.locked === 1,
    projectId: row.project_id ?? null,
    currentLeafId: row.current_leaf_id ?? null,
    originKind: row.origin_kind ?? null,
    originSessionId: row.origin_session_id ?? null,
    originNodeId: row.origin_node_id ?? null,
    extId: row.ext_id ?? null,
    ext: row.ext ? JSON.parse(row.ext) : null,
  };
}

export interface NewNode {
  id: string;
  sessionId: string;
  parentId: string | null;
  role: Role;
  payload: NodePayload;
  createdAt: number;
  onPath: boolean;
  depth: number;
  activeChildId?: string | null;
  upId?: string | null;
  extId?: string | null;
  ext?: Record<string, any> | null;
}

export interface NewMeta {
  sessionId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  archivedAt?: number | null;
  pinnedAt?: number | null;
  temporary?: boolean;
  locked?: boolean;
  projectId?: string | null;
  currentLeafId?: string | null;
  originKind?: OriginKind | null;
  originSessionId?: string | null;
  originNodeId?: string | null;
  extId?: string | null;
  ext?: Record<string, any> | null;
}

export class ConversationStore {
  readonly db: Db;
  readonly upstream: UpstreamGateway;
  readonly now: () => number;
  readonly newId: () => string;

  /**
   * Chats whose tail upstream is deleting right now (edit / regenerate).
   * Until those rows are gone a sync would mistake them for new messages.
   */
  private truncating = new Map<string, {upIds: Set<string>; at: number}>();

  constructor(options: ConversationStoreOptions) {
    this.db = options.db;
    this.upstream = options.upstream;
    this.now = options.now ?? Date.now;
    this.newId = options.newId ?? randomId;
  }

  private listeners = new Set<() => void>();

  /** Calls `listener` after every operation that changed antichat.db. */
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private deleteListeners = new Set<(sessionId: string) => void>();

  /**
   * Calls `listener` after a chat's rows are gone (deleted, or a temporary
   * chat discarded), so engines that keep rows per chat (memory use
   * records, digests, files) can drop theirs.
   */
  onSessionDeleted(listener: (sessionId: string) => void): () => void {
    this.deleteListeners.add(listener);
    return () => {
      this.deleteListeners.delete(listener);
    };
  }

  /** One exclusive unit of work; listeners hear about it if it wrote. */
  async write<T>(work: () => Promise<T>): Promise<T> {
    let before = 0;
    const result = await this.db.transaction(() => {
      before = this.db.mutations;
      return work();
    });
    if (this.db.mutations !== before) {
      for (const listener of [...this.listeners]) {
        try {
          listener();
        } catch {
          // A listener must not break the store.
        }
      }
    }
    return result;
  }

  // ---------------------------------------------------------------- setup

  /**
   * Migrates the schema, drops temporary chats a crash left behind and
   * folds every upstream chat into the tree (this is also the one-time
   * migration of chats that existed before antichat.db).
   */
  async init(): Promise<void> {
    await migrate(this.db);
    await this.purgeTemporary();
    await this.syncAll();
  }

  /** Reconciles every chat and forgets chats upstream no longer has. */
  syncAll(): Promise<void> {
    return this.write(async () => {
      const sessions = await this.upstream.listSessions();
      const known = new Set(sessions.map(session => session.id));
      for (const session of sessions) {
        await this.syncInner(session.id, session);
      }
      const metas = await this.db.all<{session_id: string}>(
        'SELECT session_id FROM session_meta',
      );
      for (const meta of metas) {
        if (!known.has(meta.session_id)) {
          await this.dropSessionRows(meta.session_id);
        }
      }
    });
  }

  /** Folds what upstream wrote for one chat into the tree. */
  syncSession(sessionId: string): Promise<void> {
    return this.write(() => this.syncInner(sessionId));
  }

  // ------------------------------------------------------------ reading

  async getMeta(sessionId: string): Promise<SessionMeta | null> {
    const row = await this.db.get(
      'SELECT * FROM session_meta WHERE session_id = ?',
      [sessionId],
    );
    return row ? metaFromRow(row) : null;
  }

  /** The visible thread, oldest first. */
  async getPath(sessionId: string): Promise<NodeRecord[]> {
    const rows = await this.db.all(
      'SELECT * FROM nodes WHERE session_id = ? AND on_path = 1 ORDER BY depth',
      [sessionId],
    );
    return rows.map(nodeFromRow);
  }

  /** Every node of a chat, visible or parked, in creation order. */
  async getAllNodes(sessionId: string): Promise<NodeRecord[]> {
    const rows = await this.db.all(
      'SELECT * FROM nodes WHERE session_id = ? ORDER BY seq',
      [sessionId],
    );
    return rows.map(nodeFromRow);
  }

  async getNode(nodeId: string): Promise<NodeRecord | null> {
    const row = await this.db.get('SELECT * FROM nodes WHERE id = ?', [nodeId]);
    return row ? nodeFromRow(row) : null;
  }

  /** The visible thread with each message's version position ("2 / 3"). */
  async getThread(sessionId: string): Promise<ThreadMessage[]> {
    const path = await this.getPath(sessionId);
    if (path.length === 0) {
      return [];
    }
    const rows = await this.db.all<{id: string; parent_id: string | null}>(
      'SELECT id, parent_id FROM nodes WHERE session_id = ? ORDER BY seq',
      [sessionId],
    );
    const siblings = new Map<string, string[]>();
    for (const row of rows) {
      const key = row.parent_id ?? '';
      const list = siblings.get(key);
      if (list) {
        list.push(row.id);
      } else {
        siblings.set(key, [row.id]);
      }
    }
    return path.map(node => {
      const versionIds = siblings.get(node.parentId ?? '') ?? [node.id];
      return {
        nodeId: node.id,
        messageId: node.upId ?? node.id,
        role: node.role,
        text: node.text,
        createdAt: node.createdAt,
        versionIndex: Math.max(0, versionIds.indexOf(node.id)),
        versionCount: versionIds.length,
        versionIds,
      };
    });
  }

  async stats(): Promise<StoreStats> {
    const row = await this.db.get(
      `SELECT
        (SELECT count(*) FROM session_meta) AS sessions,
        (SELECT count(*) FROM session_meta WHERE temporary = 1) AS temporary,
        (SELECT count(*) FROM nodes) AS nodes,
        (SELECT count(*) FROM nodes WHERE on_path = 0) AS parked`,
    );
    return {
      sessions: row?.sessions ?? 0,
      nodes: row?.nodes ?? 0,
      parkedNodes: row?.parked ?? 0,
      temporarySessions: row?.temporary ?? 0,
    };
  }

  // --------------------------------------------- edit, regenerate, versions

  /**
   * Upstream is about to delete the messages from `messageId` onward (edit
   * or regenerate). Captures their latest content and parks them: the
   * tree's visible thread now ends before them, the nodes stay.
   */
  beforeTruncate(
    sessionId: string,
    messageId: string,
    includeMessage: boolean = true,
  ): Promise<void> {
    return this.write(async () => {
      await this.syncInner(sessionId);
      const meta = await this.getMeta(sessionId);
      if (!meta || meta.temporary) {
        return;
      }
      const path = await this.getPath(sessionId);
      const index = path.findIndex(
        node => node.upId === messageId || node.id === messageId,
      );
      if (index < 0) {
        return;
      }
      const cut = includeMessage ? index : index + 1;
      const tail = path.slice(cut);
      if (tail.length === 0) {
        return;
      }
      await this.db.run(
        'UPDATE nodes SET on_path = 0 WHERE session_id = ? AND on_path = 1 AND depth >= ?',
        [sessionId, cut],
      );
      await this.db.run(
        'UPDATE session_meta SET current_leaf_id = ? WHERE session_id = ?',
        [cut > 0 ? path[cut - 1].id : null, sessionId],
      );
      this.truncating.set(sessionId, {
        upIds: new Set(tail.map(node => node.upId ?? node.id)),
        at: this.now(),
      });
    });
  }

  /**
   * Shows another version of a message: the thread keeps everything before
   * it and swaps the rest for that version's own tail. `target` is a
   * 0-based version index or a step.
   */
  switchVersion(
    sessionId: string,
    messageId: string,
    target: number | 'previous' | 'next',
  ): Promise<ThreadMessage[]> {
    return this.write(async () => {
      await this.syncInner(sessionId);
      const path = await this.getPath(sessionId);
      const index = path.findIndex(
        node => node.upId === messageId || node.id === messageId,
      );
      if (index < 0) {
        throw new Error(`Message ${messageId} is not in the visible thread`);
      }
      const current = path[index];
      const versions = await this.childrenOf(sessionId, current.parentId);
      const from = versions.findIndex(node => node.id === current.id);
      let to =
        target === 'previous'
          ? from - 1
          : target === 'next'
            ? from + 1
            : target;
      to = Math.max(0, Math.min(versions.length - 1, to));
      if (to === from) {
        return;
      }
      await this.activateBranch(sessionId, path, index, versions[to]);
    }).then(() => this.getThread(sessionId));
  }

  /**
   * Brings any node into the visible thread (a search hit inside a parked
   * version), together with the tail it last had.
   */
  showNode(sessionId: string, nodeId: string): Promise<ThreadMessage[]> {
    return this.write(async () => {
      await this.syncInner(sessionId);
      const target = await this.getNode(nodeId);
      if (!target || target.sessionId !== sessionId) {
        throw new Error(`Node ${nodeId} is not part of chat ${sessionId}`);
      }
      if (target.onPath) {
        return;
      }
      // Climb to the first ancestor that is visible; its child on the way
      // down is the version to switch to. Remember the way down so the
      // swap ends up showing `target`.
      const chain: NodeRecord[] = [target];
      let cursor = target;
      while (cursor.parentId) {
        const parent = await this.getNode(cursor.parentId);
        if (!parent) {
          break;
        }
        if (parent.onPath) {
          break;
        }
        chain.unshift(parent);
        cursor = parent;
      }
      for (let i = 0; i < chain.length - 1; i++) {
        await this.db.run('UPDATE nodes SET active_child_id = ? WHERE id = ?', [
          chain[i + 1].id,
          chain[i].id,
        ]);
      }
      const path = await this.getPath(sessionId);
      await this.activateBranch(sessionId, path, chain[0].depth, chain[0]);
    }).then(() => this.getThread(sessionId));
  }

  /**
   * Copies the thread up to and including `messageId` into a new chat and
   * records where it came from. Returns the new chat's id.
   */
  branch(
    sessionId: string,
    messageId: string,
    options: {title?: string} = {},
  ): Promise<string> {
    return this.write(async () => {
      await this.syncInner(sessionId);
      const meta = await this.getMeta(sessionId);
      if (!meta || meta.temporary) {
        throw new Error('Only a saved chat can be branched');
      }
      const path = await this.getPath(sessionId);
      const index = path.findIndex(
        node => node.upId === messageId || node.id === messageId,
      );
      if (index < 0) {
        throw new Error(`Message ${messageId} is not in the visible thread`);
      }
      const source = path.slice(0, index + 1);
      const title =
        options.title ??
        BRANCH_TITLE_PREFIX +
          (meta.title.startsWith(BRANCH_TITLE_PREFIX)
            ? meta.title.slice(BRANCH_TITLE_PREFIX.length)
            : meta.title);
      const copies: UpMessage[] = source.map(node => ({
        ...node.payload,
        id: this.newId(),
        createdAt: node.createdAt,
      }));
      const createdAt = this.now();
      const newSessionId = await this.upstream.createSession({
        title,
        createdAt,
        messages: copies,
        likeSessionId: sessionId,
      });
      await this.insertMeta({
        sessionId: newSessionId,
        title,
        createdAt,
        updatedAt: createdAt,
        projectId: meta.projectId,
        currentLeafId: copies[copies.length - 1].id,
        originKind: 'branch',
        originSessionId: sessionId,
        originNodeId: source[source.length - 1].id,
      });
      for (let i = 0; i < copies.length; i++) {
        await this.insertNode({
          id: copies[i].id,
          sessionId: newSessionId,
          parentId: i > 0 ? copies[i - 1].id : null,
          role: source[i].role,
          payload: source[i].payload,
          createdAt: source[i].createdAt,
          onPath: true,
          depth: i,
          activeChildId: i + 1 < copies.length ? copies[i + 1].id : null,
          upId: copies[i].id,
        });
      }
      return newSessionId;
    });
  }

  // ------------------------------------------------------- session flags

  rename(sessionId: string, title: string): Promise<void> {
    return this.write(async () => {
      await this.requireMeta(sessionId);
      await this.upstream.renameSession(sessionId, title);
      const meta = await this.getMeta(sessionId);
      if (meta && !meta.temporary) {
        await this.db.run(
          'UPDATE session_meta SET title = ? WHERE session_id = ?',
          [title, sessionId],
        );
      }
    });
  }

  setPinned(sessionId: string, pinned: boolean): Promise<void> {
    return this.write(async () => {
      await this.requireMeta(sessionId);
      await this.upstream.setPinned(sessionId, pinned);
      await this.db.run(
        'UPDATE session_meta SET pinned_at = ? WHERE session_id = ?',
        [pinned ? this.now() : null, sessionId],
      );
    });
  }

  setArchived(sessionId: string, archived: boolean): Promise<void> {
    return this.setFlag(sessionId, 'archived_at', archived ? this.now() : null);
  }

  /** The flag only; the biometric gate is the UI's (M4). */
  setLocked(sessionId: string, locked: boolean): Promise<void> {
    return this.setFlag(sessionId, 'locked', locked ? 1 : 0);
  }

  setProject(sessionId: string, projectId: string | null): Promise<void> {
    return this.setFlag(sessionId, 'project_id', projectId);
  }

  /** Deletes chats everywhere: upstream rows, tree, search index. */
  deleteSessions(sessionIds: string[]): Promise<void> {
    return this.write(async () => {
      if (sessionIds.length === 0) {
        return;
      }
      await this.upstream.deleteSessions(sessionIds);
      for (const sessionId of sessionIds) {
        await this.dropSessionRows(sessionId);
      }
    });
  }

  deleteSession(sessionId: string): Promise<void> {
    return this.deleteSessions([sessionId]);
  }

  // ------------------------------------------------------ temporary chat

  /**
   * Marks a chat temporary. From here on nothing of it is written to
   * antichat.db except this flag: no nodes, no title, no search rows.
   * Upstream's rows exist while the chat is open and go with
   * `discardTemporary` (or at the next launch).
   */
  markTemporary(sessionId: string): Promise<void> {
    return this.write(async () => {
      const session = await this.upstream.getSession(sessionId);
      const now = this.now();
      const existing = await this.getMeta(sessionId);
      if (existing) {
        await this.db.run(
          `UPDATE session_meta SET temporary = 1, title = '', current_leaf_id = NULL
           WHERE session_id = ?`,
          [sessionId],
        );
      } else {
        await this.insertMeta({
          sessionId,
          title: '',
          createdAt: session?.createdAt ?? now,
          updatedAt: session?.createdAt ?? now,
          temporary: true,
        });
      }
      await this.db.run('DELETE FROM nodes WHERE session_id = ?', [sessionId]);
    });
  }

  /** "Save this chat": the temporary chat becomes a normal one. */
  keepTemporary(sessionId: string): Promise<void> {
    return this.write(async () => {
      await this.db.run(
        'UPDATE session_meta SET temporary = 0 WHERE session_id = ?',
        [sessionId],
      );
      await this.syncInner(sessionId);
    });
  }

  async discardTemporary(sessionId: string): Promise<void> {
    const meta = await this.getMeta(sessionId);
    if (meta?.temporary) {
      await this.deleteSessions([sessionId]);
    }
  }

  /** Removes every temporary chat (launch, or after a crash). */
  async purgeTemporary(): Promise<number> {
    const rows = await this.db.all<{session_id: string}>(
      'SELECT session_id FROM session_meta WHERE temporary = 1',
    );
    await this.deleteSessions(rows.map(row => row.session_id));
    return rows.length;
  }

  // ------------------------------------------------------------ internals
  // Everything below runs inside a transaction opened by a public method.

  async insertNode(node: NewNode): Promise<void> {
    await this.db.run(
      `INSERT INTO nodes (id, session_id, parent_id, role, text, payload,
        ext_id, ext, created_at, updated_at, on_path, depth, active_child_id, up_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        node.id,
        node.sessionId,
        node.parentId,
        node.role,
        payloadText(node.payload),
        JSON.stringify(toPayload(node.payload)),
        node.extId ?? null,
        node.ext ? JSON.stringify(node.ext) : null,
        node.createdAt,
        node.createdAt,
        node.onPath ? 1 : 0,
        node.depth,
        node.activeChildId ?? null,
        node.upId ?? null,
      ],
    );
  }

  async insertMeta(meta: NewMeta): Promise<void> {
    await this.db.run(
      `INSERT INTO session_meta (session_id, title, created_at, updated_at,
        archived_at, pinned_at, temporary, locked, project_id, current_leaf_id,
        origin_kind, origin_session_id, origin_node_id, ext_id, ext)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        meta.sessionId,
        meta.title,
        meta.createdAt,
        meta.updatedAt,
        meta.archivedAt ?? null,
        meta.pinnedAt ?? null,
        meta.temporary ? 1 : 0,
        meta.locked ? 1 : 0,
        meta.projectId ?? null,
        meta.currentLeafId ?? null,
        meta.originKind ?? null,
        meta.originSessionId ?? null,
        meta.originNodeId ?? null,
        meta.extId ?? null,
        meta.ext ? JSON.stringify(meta.ext) : null,
      ],
    );
  }

  roleOf(payload: NodePayload): Role {
    if (payload.author === this.upstream.authors.user) {
      return 'user';
    }
    return payload.metadata?.antichatRole === 'system' ? 'system' : 'assistant';
  }

  private async childrenOf(
    sessionId: string,
    parentId: string | null,
  ): Promise<NodeRecord[]> {
    const rows =
      parentId === null
        ? await this.db.all(
            'SELECT * FROM nodes WHERE session_id = ? AND parent_id IS NULL ORDER BY seq',
            [sessionId],
          )
        : await this.db.all(
            'SELECT * FROM nodes WHERE session_id = ? AND parent_id = ? ORDER BY seq',
            [sessionId, parentId],
          );
    return rows.map(nodeFromRow);
  }

  private async requireMeta(sessionId: string): Promise<void> {
    if (!(await this.getMeta(sessionId))) {
      await this.syncInner(sessionId);
    }
    if (!(await this.getMeta(sessionId))) {
      throw new Error(`Unknown chat ${sessionId}`);
    }
  }

  private setFlag(
    sessionId: string,
    column: 'archived_at' | 'locked' | 'project_id',
    value: SqlValue,
  ): Promise<void> {
    return this.write(async () => {
      await this.requireMeta(sessionId);
      await this.db.run(
        `UPDATE session_meta SET ${column} = ? WHERE session_id = ?`,
        [value, sessionId],
      );
    });
  }

  private async dropSessionRows(sessionId: string): Promise<void> {
    await this.db.run('DELETE FROM nodes WHERE session_id = ?', [sessionId]);
    await this.db.run('DELETE FROM session_meta WHERE session_id = ?', [
      sessionId,
    ]);
    this.truncating.delete(sessionId);
    // Told after the unit of work has committed (never inside it: a
    // listener that opens its own transaction would wait on this one).
    const listeners = [...this.deleteListeners];
    if (listeners.length > 0) {
      Promise.resolve()
        .then(() => this.db.transaction(async () => undefined))
        .then(() => {
          for (const listener of listeners) {
            try {
              listener(sessionId);
            } catch {
              // A listener must not break the store.
            }
          }
        })
        .catch(() => undefined);
    }
  }

  /** The tail a version brings with it: follow the remembered children. */
  private async tailFrom(head: NodeRecord): Promise<NodeRecord[]> {
    const tail = [head];
    const seen = new Set([head.id]);
    let cursor = head;
    for (;;) {
      const children = await this.childrenOf(cursor.sessionId, cursor.id);
      if (children.length === 0) {
        break;
      }
      const next =
        children.find(child => child.id === cursor.activeChildId) ??
        children[children.length - 1];
      if (seen.has(next.id)) {
        break;
      }
      seen.add(next.id);
      tail.push(next);
      cursor = next;
    }
    return tail;
  }

  /**
   * The tail swap. `path[index]` and everything after it leave the visible
   * thread; `head` (a sibling of `path[index]`) and its tail take their
   * place, in upstream's tables first and then in the tree. If the app
   * dies in between, the next sync finds upstream's new rows by id and
   * re-adopts them; nothing is deleted on that route.
   */
  private async activateBranch(
    sessionId: string,
    path: NodeRecord[],
    index: number,
    head: NodeRecord,
  ): Promise<void> {
    const tail = await this.tailFrom(head);
    await this.upstream.replaceTail(
      sessionId,
      index,
      tail.map(node => ({
        ...node.payload,
        id: node.id,
        createdAt: node.createdAt,
      })),
    );
    await this.db.run(
      'UPDATE nodes SET on_path = 0 WHERE session_id = ? AND on_path = 1 AND depth >= ?',
      [sessionId, index],
    );
    for (let i = 0; i < tail.length; i++) {
      await this.db.run(
        `UPDATE nodes SET on_path = 1, depth = ?, up_id = id, active_child_id = ?
         WHERE id = ?`,
        [index + i, i + 1 < tail.length ? tail[i + 1].id : null, tail[i].id],
      );
    }
    if (index > 0) {
      await this.db.run('UPDATE nodes SET active_child_id = ? WHERE id = ?', [
        head.id,
        path[index - 1].id,
      ]);
    }
    await this.db.run(
      'UPDATE session_meta SET current_leaf_id = ? WHERE session_id = ?',
      [tail[tail.length - 1].id, sessionId],
    );
  }

  private async refreshNode(node: NodeRecord, message: UpMessage) {
    const payload = toPayload(message);
    const next = JSON.stringify(payload);
    if (
      next === JSON.stringify(toPayload(node.payload)) &&
      node.createdAt === message.createdAt
    ) {
      return;
    }
    await this.db.run(
      `UPDATE nodes SET payload = ?, text = ?, role = ?, created_at = ?, updated_at = ?
       WHERE id = ?`,
      [
        next,
        payloadText(payload),
        this.roleOf(payload),
        message.createdAt,
        this.now(),
        node.id,
      ],
    );
  }

  /**
   * Reconciles one chat. Rules:
   *  - Upstream and the tree agree on a prefix; those nodes only get their
   *    content refreshed.
   *  - Upstream rows after the prefix are appended under it. A row whose id
   *    belongs to a parked node re-adopts that node; a user message equal to
   *    a parked sibling reuses it (so a regenerate adds a second answer
   *    under the same prompt, as ChatGPT does); anything else is a new node.
   *  - Tree nodes after the prefix that upstream no longer has: when
   *    upstream simply ends earlier, it deleted them one by one (a failed
   *    or withdrawn reply) and they go, unless other versions hang below.
   *    In every other case they are parked.
   */
  private async syncInner(sessionId: string, known?: UpSession): Promise<void> {
    const session = known ?? (await this.upstream.getSession(sessionId));
    if (!session) {
      return;
    }
    let meta = await this.getMeta(sessionId);
    if (!meta) {
      await this.insertMeta({
        sessionId,
        title: session.title,
        createdAt: session.createdAt,
        updatedAt: session.createdAt,
        pinnedAt: session.pinned ? this.now() : null,
      });
      meta = (await this.getMeta(sessionId))!;
    }
    if (meta.temporary) {
      return;
    }

    const messages = await this.upstream.getMessages(sessionId);
    const pending = this.truncating.get(sessionId);
    if (pending) {
      const unfinished =
        this.now() - pending.at < TRUNCATION_GRACE_MS &&
        messages.some(message => pending.upIds.has(message.id));
      if (unfinished) {
        return;
      }
      this.truncating.delete(sessionId);
    }

    const path = await this.getPath(sessionId);
    let common = 0;
    while (
      common < path.length &&
      common < messages.length &&
      (path[common].upId ?? path[common].id) === messages[common].id
    ) {
      await this.refreshNode(path[common], messages[common]);
      common++;
    }

    const dropped = path.slice(common);
    if (dropped.length > 0) {
      let deleting = messages.length === common;
      for (let i = dropped.length - 1; i >= 0; i--) {
        const node = dropped[i];
        if (deleting) {
          const children = await this.childrenOf(sessionId, node.id);
          if (children.length === 0) {
            await this.db.run('DELETE FROM nodes WHERE id = ?', [node.id]);
            await this.db.run(
              'UPDATE nodes SET active_child_id = NULL WHERE active_child_id = ?',
              [node.id],
            );
            continue;
          }
          deleting = false;
        }
        await this.db.run('UPDATE nodes SET on_path = 0 WHERE id = ?', [
          node.id,
        ]);
      }
    }

    let parent: NodeRecord | null = common > 0 ? path[common - 1] : null;
    let leafId: string | null = parent?.id ?? null;
    for (let i = common; i < messages.length; i++) {
      const message = messages[i];
      const payload = toPayload(message);
      const parentId: string | null = parent?.id ?? null;
      const role = this.roleOf(payload);

      let node: NodeRecord | null = null;
      const byUpId = await this.db.get(
        `SELECT * FROM nodes WHERE session_id = ? AND on_path = 0
           AND (up_id = ? OR id = ?) ORDER BY (up_id = ?) DESC LIMIT 1`,
        [sessionId, message.id, message.id, message.id],
      );
      if (byUpId && (byUpId.parent_id ?? null) === parentId) {
        node = nodeFromRow(byUpId);
      }
      if (!node && role === 'user') {
        const signature = promptSignature(payload);
        const siblings = await this.childrenOf(sessionId, parentId);
        node =
          siblings.find(
            sibling =>
              !sibling.onPath &&
              sibling.role === 'user' &&
              promptSignature(sibling.payload) === signature,
          ) ?? null;
      }

      if (node) {
        await this.db.run(
          'UPDATE nodes SET on_path = 1, depth = ?, up_id = ? WHERE id = ?',
          [i, message.id, node.id],
        );
        await this.refreshNode(node, message);
      } else {
        // An id clash (the same upstream id under another parent) cannot
        // keep the id; the row is still tracked through `up_id`.
        const clash = await this.db.get('SELECT id FROM nodes WHERE id = ?', [
          message.id,
        ]);
        const id = clash ? this.newId() : message.id;
        if (clash) {
          await this.db.run('UPDATE nodes SET up_id = NULL WHERE up_id = ?', [
            message.id,
          ]);
        }
        await this.insertNode({
          id,
          sessionId,
          parentId,
          role,
          payload,
          createdAt: message.createdAt,
          onPath: true,
          depth: i,
          upId: message.id,
        });
        node = (await this.getNode(id))!;
      }
      if (parent && parent.activeChildId !== node.id) {
        await this.db.run('UPDATE nodes SET active_child_id = ? WHERE id = ?', [
          node.id,
          parent.id,
        ]);
      }
      parent = node;
      leafId = node.id;
    }

    // Never moves backwards: showing an older version must not sink the
    // chat in the history list.
    const updatedAt = Math.max(
      meta.updatedAt,
      messages.length > 0 ? messages[messages.length - 1].createdAt : 0,
    );
    const pinnedAt = session.pinned ? (meta.pinnedAt ?? this.now()) : null;
    if (
      meta.title !== session.title ||
      meta.currentLeafId !== leafId ||
      meta.updatedAt !== updatedAt ||
      meta.pinnedAt !== pinnedAt
    ) {
      await this.db.run(
        `UPDATE session_meta SET title = ?, current_leaf_id = ?, updated_at = ?, pinned_at = ?
         WHERE session_id = ?`,
        [session.title, leafId, updatedAt, pinnedAt, sessionId],
      );
    }
  }
}
