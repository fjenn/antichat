/**
 * "Reference past chats" lookup: the engine behind the `search_chats` tool.
 *
 * It reads the conversation store's full-text index (M3) directly, because
 * a model's query needs different matching from the drawer's search box:
 * any of the words may match (ranked by bm25 and by how many of them a
 * message covers), both sides of the chat are returned, and the result is
 * a few short excerpts sized for a 4k–8k context.
 *
 * Never returned: temporary chats (they are not in the index), locked
 * chats, the chat the question is asked in, and chats of projects that
 * keep their memory to themselves.
 */
import type {Db, SqlValue} from '../store/driver';
import {buildSnippet} from '../store/search';
import {anyWordQuery, clip, coverage, stemSet} from './text';

export interface ChatSearchOptions {
  /** Chats returned (default 3). */
  limit?: number;
  /** Excerpts per chat (default 2). */
  snippetsPerChat?: number;
  /** The chat the question is asked in. */
  excludeSessionId?: string | null;
  /** Search only this project's chats (a project with its own memory). */
  onlyProjectId?: string | null;
  /** Projects whose chats stay inside the project. */
  isolatedProjectIds?: string[];
  includeArchived?: boolean;
}

export interface ChatSearchSnippet {
  role: 'user' | 'assistant';
  text: string;
  nodeId: string;
  /** Upstream message id, for "jump to message". */
  messageId: string | null;
  createdAt: number;
}

export interface ChatSearchResult {
  sessionId: string;
  title: string;
  updatedAt: number;
  /** One-line digest of the chat, when the idle pass has written one. */
  digest: string | null;
  snippets: ChatSearchSnippet[];
  /** Lower is better. */
  score: number;
}

const ROW_CAP = 80;
const REPLY_EXCERPT_CHARS = 200;
const UNSPACED_SCRIPT = /[฀-๿぀-ヿ㐀-䶿一-鿿가-힯]/;

function sessionFilter(options: ChatSearchOptions): {
  sql: string;
  params: SqlValue[];
} {
  const where = ['s.temporary = 0', 's.locked = 0'];
  const params: SqlValue[] = [];
  if (!options.includeArchived) {
    where.push('s.archived_at IS NULL');
  }
  if (options.excludeSessionId) {
    where.push('s.session_id <> ?');
    params.push(options.excludeSessionId);
  }
  if (options.onlyProjectId) {
    where.push('s.project_id = ?');
    params.push(options.onlyProjectId);
  } else if (options.isolatedProjectIds?.length) {
    where.push(
      `(s.project_id IS NULL OR s.project_id NOT IN (${options.isolatedProjectIds
        .map(() => '?')
        .join(', ')}))`,
    );
    params.push(...options.isolatedProjectIds);
  }
  return {sql: where.join(' AND '), params};
}

const joinSegments = (segments: Array<{text: string}>): string =>
  segments
    .map(segment => segment.text)
    .join('')
    .replace(/\s+/g, ' ')
    .trim();

/** Searches message text and titles of earlier chats. Best chat first. */
export async function searchChats(
  db: Db,
  query: string,
  options: ChatSearchOptions = {},
): Promise<ChatSearchResult[]> {
  const trimmed = query.trim();
  if (!trimmed) {
    return [];
  }
  const filter = sessionFilter(options);
  const limit = options.limit ?? 3;
  const perChat = options.snippetsPerChat ?? 2;
  const unspaced = UNSPACED_SCRIPT.test(trimmed);
  const match = unspaced ? null : anyWordQuery(trimmed);
  if (!unspaced && !match) {
    return [];
  }
  const rows = unspaced
    ? await db.all(
        `SELECT s.session_id, s.title, s.updated_at, n.id AS node_id, n.up_id,
            n.role, n.text, n.created_at, 0 AS rank
         FROM nodes n JOIN session_meta s ON s.session_id = n.session_id
         WHERE n.text LIKE ? ESCAPE '\\' AND n.on_path = 1
           AND n.role IN ('user', 'assistant') AND ${filter.sql}
         ORDER BY n.created_at DESC LIMIT ?`,
        [
          `%${trimmed.replace(/[\\%_]/g, char => `\\${char}`)}%`,
          ...filter.params,
          ROW_CAP,
        ],
      )
    : await db.all(
        `SELECT s.session_id, s.title, s.updated_at, n.id AS node_id, n.up_id,
            n.role, n.text, n.created_at, bm25(messages_fts) AS rank
         FROM messages_fts
         JOIN nodes n ON n.seq = messages_fts.rowid
         JOIN session_meta s ON s.session_id = n.session_id
         WHERE messages_fts MATCH ? AND n.on_path = 1
           AND n.role IN ('user', 'assistant') AND ${filter.sql}
         ORDER BY rank LIMIT ?`,
        [match!, ...filter.params, ROW_CAP],
      );
  const titleRows = match
    ? await db.all(
        `SELECT s.session_id, s.title, s.updated_at, bm25(titles_fts) AS rank
         FROM titles_fts JOIN session_meta s ON s.seq = titles_fts.rowid
         WHERE titles_fts MATCH ? AND ${filter.sql}
         ORDER BY rank LIMIT ?`,
        [match, ...filter.params, ROW_CAP],
      )
    : [];

  // A message that shares one word out of four with the query is noise:
  // keep rows that cover at least half the query's words, when any do.
  const wanted = stemSet(trimmed);
  const scored = rows.map(row => ({
    row,
    covered: unspaced ? 1 : coverage(wanted, stemSet(row.text)),
  }));
  const strong = scored.filter(entry => entry.covered >= 0.5);
  const usable = strong.length > 0 ? strong : scored;

  const chats = new Map<string, ChatSearchResult>();
  const ensure = (row: Record<string, any>): ChatSearchResult => {
    let chat = chats.get(row.session_id);
    if (!chat) {
      chat = {
        sessionId: row.session_id,
        title: row.title ?? '',
        updatedAt: row.updated_at,
        digest: null,
        snippets: [],
        score: 0,
      };
      chats.set(chat.sessionId, chat);
    }
    return chat;
  };
  for (const row of titleRows) {
    if (coverage(wanted, stemSet(row.title ?? '')) >= 0.5) {
      ensure(row).score += row.rank * 2;
    }
  }
  for (const {row, covered} of usable) {
    const chat = ensure(row);
    if (chat.snippets.length === 0) {
      chat.score += row.rank * (0.5 + covered);
    }
    // One excerpt per side of the chat, best first.
    if (
      chat.snippets.length < perChat &&
      !chat.snippets.some(snippet => snippet.role === row.role)
    ) {
      chat.snippets.push({
        role: row.role,
        text: unspaced
          ? clip(row.text, 140)
          : joinSegments(buildSnippet(row.text, trimmed, 6, 16)),
        nodeId: row.node_id,
        messageId: row.up_id ?? null,
        createdAt: row.created_at,
      });
    }
  }
  const ranked = [...chats.values()]
    .sort((a, b) => a.score - b.score || b.updatedAt - a.updatedAt)
    .slice(0, limit);
  // "What was that recipe you gave me?": the user's old question matches,
  // the answer is what is wanted. Attach the reply to a user-only hit.
  for (const chat of ranked) {
    const hit = chat.snippets[0];
    if (!hit || hit.role !== 'user' || chat.snippets.length >= perChat) {
      continue;
    }
    const reply = await db.get(
      `SELECT id, up_id, text, created_at FROM nodes
       WHERE parent_id = ? AND on_path = 1 AND role = 'assistant' LIMIT 1`,
      [hit.nodeId],
    );
    if (reply?.text) {
      chat.snippets.push({
        role: 'assistant',
        text: clip(reply.text, REPLY_EXCERPT_CHARS),
        nodeId: reply.id,
        messageId: reply.up_id ?? null,
        createdAt: reply.created_at,
      });
    }
  }
  if (ranked.length > 0) {
    try {
      const digests = await db.all<{session_id: string; digest: string}>(
        `SELECT session_id, digest FROM chat_digests
         WHERE session_id IN (${ranked.map(() => '?').join(', ')})`,
        ranked.map(chat => chat.sessionId),
      );
      const bySession = new Map(digests.map(d => [d.session_id, d.digest]));
      for (const chat of ranked) {
        chat.digest = bySession.get(chat.sessionId) ?? null;
      }
    } catch {
      // The digest table belongs to the memory namespace; fine without it.
    }
  }
  return ranked;
}

const MONTHS = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

export function shortDate(timestamp: number): string {
  const date = new Date(timestamp);
  return `${date.getDate()} ${MONTHS[date.getMonth()]} ${date.getFullYear()}`;
}

/**
 * The tool result the model reads: numbered chats with dated excerpts,
 * cut to `maxChars` so a small context is not flooded.
 */
export function formatChatSearch(
  results: ChatSearchResult[],
  maxChars: number = 900,
): string {
  if (results.length === 0) {
    return 'No earlier chat matches. Tell the user you could not find it; do not guess.';
  }
  const blocks: string[] = [];
  let used = 0;
  for (let i = 0; i < results.length; i++) {
    const chat = results[i];
    const lines = [
      `${i + 1}. "${clip(chat.title || 'Untitled chat', 60)}" (${shortDate(chat.updatedAt)})`,
    ];
    for (const snippet of chat.snippets) {
      lines.push(
        `   ${snippet.role === 'user' ? 'User' : 'Assistant'}: ${snippet.text}`,
      );
    }
    if (chat.snippets.length === 0 && chat.digest) {
      lines.push(`   ${chat.digest}`);
    }
    const block = lines.join('\n');
    if (blocks.length > 0 && used + block.length > maxChars) {
      break;
    }
    blocks.push(block);
    used += block.length;
  }
  return `Excerpts from earlier chats with the user:\n${blocks.join('\n')}`;
}
