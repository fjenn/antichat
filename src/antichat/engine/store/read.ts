/**
 * Read-only views of the chat tree for other engines (memory, files).
 *
 * They exist so nobody outside the store writes SQL against `nodes` and
 * `session_meta`: the columns may change, these functions may not.
 */
import type {Db} from './driver';

export interface ChatActivity {
  sessionId: string;
  updatedAt: number;
  /** Highest `seq` on the visible thread (0 for a chat without messages). */
  topSeq: number;
  /** When a message of the visible thread was last written. */
  lastWrite: number;
  temporary: boolean;
  projectId: string | null;
}

function toActivity(row: Record<string, any>): ChatActivity {
  return {
    sessionId: row.session_id,
    updatedAt: row.updated_at,
    topSeq: row.top_seq ?? 0,
    lastWrite: row.last_write ?? 0,
    temporary: row.temporary === 1,
    projectId: row.project_id ?? null,
  };
}

const ACTIVITY = `SELECT s.session_id, s.updated_at, s.temporary, s.project_id,
    max(n.seq) AS top_seq, max(n.updated_at) AS last_write
  FROM session_meta s
  JOIN nodes n ON n.session_id = s.session_id AND n.on_path = 1`;

/**
 * Saved (not temporary) chats that have messages, most recently written
 * first. `quietSince` keeps only chats without a write after that time.
 */
export async function listChatActivity(
  db: Db,
  options: {quietSince?: number} = {},
): Promise<ChatActivity[]> {
  const rows = await db.all(
    `${ACTIVITY}
     WHERE s.temporary = 0
     GROUP BY s.session_id
     HAVING last_write <= ?
     ORDER BY last_write DESC`,
    [options.quietSince ?? Number.MAX_SAFE_INTEGER],
  );
  return rows.map(toActivity);
}

/** The same for one chat (temporary ones included); null when unknown. */
export async function getChatActivity(
  db: Db,
  sessionId: string,
): Promise<ChatActivity | null> {
  const row = await db.get(
    `${ACTIVITY} WHERE s.session_id = ? GROUP BY s.session_id`,
    [sessionId],
  );
  return row ? toActivity(row) : null;
}

/** Flags of a chat that prompt providers need; null for an unknown chat. */
export async function getChatFlags(
  db: Db,
  sessionId: string,
): Promise<{temporary: boolean; projectId: string | null} | null> {
  const row = await db.get<{temporary: number; project_id: string | null}>(
    'SELECT temporary, project_id FROM session_meta WHERE session_id = ?',
    [sessionId],
  );
  return row
    ? {temporary: row.temporary === 1, projectId: row.project_id ?? null}
    : null;
}

/** The user's messages on the visible thread after `afterSeq`, oldest first. */
export async function userTurnsAfter(
  db: Db,
  sessionId: string,
  afterSeq: number,
): Promise<string[]> {
  const rows = await db.all<{text: string}>(
    `SELECT text FROM nodes
     WHERE session_id = ? AND on_path = 1 AND role = 'user' AND seq > ?
     ORDER BY depth`,
    [sessionId, afterSeq],
  );
  return rows.map(row => row.text).filter(text => text.trim().length > 0);
}
