/**
 * Rolling per-chat digests ("reference past chats", H3).
 *
 * ChatGPT injects a digest of recent chats made mostly of the user's own
 * messages. Here every chat has a one-line digest:
 *  - a deterministic one from the first and the latest user message, free
 *    and available at once;
 *  - on phones with room for it, the idle pass lets the model rewrite it
 *    from the previous digest plus the new user messages (rolling, so a
 *    long chat is never re-read).
 * The newest few digests form a system block; `search_chats` covers the
 * rest.
 */
import type {CompletionEngine} from '../../../utils/completionTypes';
import type {TokenCounter} from '../context/tokenCounter';
import type {ModelFamily} from '../prompt/modelFamily';
import {runUtilityCompletion} from '../prompt/utility';
import type {Db, SqlValue} from '../store/driver';
import {hasMemoryCue} from './extraction';
import {clip} from './text';

/**
 * `suppressed`: the chat touched on a memory the user deleted; it is left
 * out of the recent-chats block (it can still be found by searching).
 */
export type DigestSource = 'rule' | 'model' | 'suppressed';

export interface ChatDigest {
  sessionId: string;
  digest: string;
  throughSeq: number;
  source: DigestSource;
  updatedAt: number;
}

export interface RecentChat {
  sessionId: string;
  title: string;
  updatedAt: number;
  digest: string;
}

export interface RecentChatsOptions {
  limit: number;
  excludeSessionId?: string | null;
  onlyProjectId?: string | null;
  isolatedProjectIds?: string[];
}

const DIGEST_CHARS = 150;

/** First user message, plus the latest one when the chat moved on. */
export function ruleDigest(userTurns: string[]): string {
  // "Remember that I'm vegetarian" is a memory request, not a topic; a
  // digest of it would keep the fact in the prompt after the memory is
  // deleted.
  const turns = userTurns
    .map(turn => turn.trim())
    .filter(turn => turn && !hasMemoryCue(turn));
  if (turns.length === 0) {
    return '';
  }
  const first = clip(turns[0], turns.length > 1 ? 90 : DIGEST_CHARS);
  if (turns.length === 1) {
    return first;
  }
  const last = clip(turns[turns.length - 1], 55);
  return `${first} … ${last}`;
}

export const DIGEST_SYSTEM_PROMPT =
  'You keep one-line notes about past chats so they can be found again later. Given the previous note (if any) and the newest messages the user wrote in the chat, write the updated note: what the user wanted and anything decided, in at most 20 words, in the language the user writes in. Name the concrete subject (places, products, people). Output only the note.';

/** One model-written digest. Null on failure. */
export async function writeModelDigest(input: {
  engine: CompletionEngine;
  family?: ModelFamily;
  previous?: string | null;
  turns: string[];
  signal?: AbortSignal;
}): Promise<string | null> {
  const turns = input.turns
    .filter(turn => !hasMemoryCue(turn))
    .map(turn => clip(turn, 300))
    .filter(Boolean)
    .slice(-6);
  if (turns.length === 0) {
    return null;
  }
  const result = await runUtilityCompletion({
    engine: input.engine,
    family: input.family,
    messages: [
      {role: 'system', content: DIGEST_SYSTEM_PROMPT},
      {
        role: 'user',
        content: `Previous note: ${input.previous?.trim() || 'none'}\n\nNew user messages:\n${turns
          .map((turn, index) => `${index + 1}. ${turn}`)
          .join('\n')}\n\nNote:`,
      },
    ],
    maxTokens: 60,
    temperature: 0.2,
    stop: ['\n\n'],
    timeoutMs: 20000,
    signal: input.signal,
  });
  const note = result?.text
    .split('\n')
    .map(part => part.replace(/^(?:updated )?note\s*:\s*/i, '').trim())
    .find(Boolean);
  if (!note || note.length < 8) {
    return null;
  }
  return clip(note.replace(/^["'“]|["'”]$/g, ''), DIGEST_CHARS);
}

export class DigestStore {
  constructor(
    private readonly db: Db,
    private readonly now: () => number = Date.now,
  ) {}

  async get(sessionId: string): Promise<ChatDigest | null> {
    const row = await this.db.get(
      'SELECT * FROM chat_digests WHERE session_id = ?',
      [sessionId],
    );
    return row
      ? {
          sessionId: row.session_id,
          digest: row.digest,
          throughSeq: row.through_seq,
          source: row.source,
          updatedAt: row.updated_at,
        }
      : null;
  }

  async set(
    sessionId: string,
    digest: string,
    throughSeq: number,
    source: DigestSource,
  ): Promise<void> {
    await this.db.run(
      `INSERT INTO chat_digests (session_id, digest, through_seq, source, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (session_id) DO UPDATE SET digest = excluded.digest,
         through_seq = excluded.through_seq, source = excluded.source,
         updated_at = excluded.updated_at`,
      [sessionId, clip(digest, DIGEST_CHARS), throughSeq, source, this.now()],
    );
  }

  async delete(sessionId: string): Promise<void> {
    await this.db.run('DELETE FROM chat_digests WHERE session_id = ?', [
      sessionId,
    ]);
  }

  /**
   * The newest chats with a line each. A chat the idle pass has not reached
   * yet gets its line from its first user message on the spot. Temporary,
   * locked and archived chats are never listed.
   */
  async recent(options: RecentChatsOptions): Promise<RecentChat[]> {
    if (options.limit <= 0) {
      return [];
    }
    const where = ['s.temporary = 0', 's.locked = 0', 's.archived_at IS NULL'];
    const params: SqlValue[] = [];
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
    const rows = await this.db.all(
      `SELECT s.session_id, s.title, s.updated_at, d.digest,
          (SELECT n.text FROM nodes n
           WHERE n.session_id = s.session_id AND n.on_path = 1 AND n.role = 'user'
           ORDER BY n.depth LIMIT 1) AS first_user
       FROM session_meta s
       LEFT JOIN chat_digests d ON d.session_id = s.session_id
       WHERE ${where.join(' AND ')}
       ORDER BY s.updated_at DESC LIMIT ?`,
      [...params, options.limit + 4],
    );
    return rows
      .map(row => ({
        sessionId: row.session_id as string,
        title: (row.title as string) ?? '',
        updatedAt: row.updated_at as number,
        digest: (row.digest as string) ?? ruleDigest([row.first_user ?? '']),
      }))
      .filter(chat => chat.digest.length > 0)
      .slice(0, options.limit);
  }
}

export const RECENT_CHATS_HEADER =
  'Recent chats with the user, newest first (date, title: what the user asked).';
export const RECENT_CHATS_SEARCH_HINT =
  ' Call search_chats to look up details.';

const MONTHS = 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split(' ');

/** The digest block, cut to `tokens`. Empty string when nothing fits. */
export async function renderRecentChats(
  chats: RecentChat[],
  tokens: number,
  counter: TokenCounter,
  searchable: boolean,
): Promise<{text: string; count: number; tokens: number}> {
  if (chats.length === 0 || tokens <= 0) {
    return {text: '', count: 0, tokens: 0};
  }
  const header =
    RECENT_CHATS_HEADER + (searchable ? RECENT_CHATS_SEARCH_HINT : '');
  let used = await counter.countText(header);
  const lines: string[] = [];
  for (const chat of chats) {
    const date = new Date(chat.updatedAt);
    const title = clip(chat.title || 'Untitled', 40);
    const text = `- ${date.getDate()} ${MONTHS[date.getMonth()]}, ${title}: ${chat.digest}`;
    const cost = (await counter.countText(text)) + 1;
    if (used + cost > tokens) {
      break;
    }
    lines.push(text);
    used += cost;
  }
  if (lines.length === 0) {
    return {text: '', count: 0, tokens: 0};
  }
  return {
    text: `${header}\n${lines.join('\n')}`,
    count: lines.length,
    tokens: used,
  };
}
