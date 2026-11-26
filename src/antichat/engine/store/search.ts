import type {Db, SqlRow, SqlValue} from './driver';
import type {SearchHit, SearchOptions, TextSegment} from './types';

const MARK_OPEN = '\u0001';
const MARK_CLOSE = '\u0002';
/** Message rows read per query before grouping by chat. */
const MESSAGE_ROW_CAP = 400;
/** Weight of the title's bm25 next to the best message's. */
const TITLE_WEIGHT = 4;

/**
 * Scripts written without spaces. FTS5's unicode61 tokenizer sees a whole
 * run of them as one token, so these queries use a substring scan instead.
 */
const UNSPACED_SCRIPT = /[฀-๿぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]/;

/**
 * Turns what the user typed into an FTS5 query: every word must appear,
 * each as a prefix ("ban bre" finds "banana bread"). Returns null when
 * nothing searchable is left.
 */
export function buildFtsQuery(
  input: string,
  mode: 'all' | 'any' = 'all',
): string | null {
  const words = input
    .normalize('NFKC')
    .split(/[^\p{L}\p{N}]+/u)
    .filter(word => word.length > 0);
  if (words.length === 0) {
    return null;
  }
  // 'any': one shared word is enough; bm25 ranks chats sharing more higher.
  return [...new Set(words)]
    .map(word => `"${word}"*`)
    .join(mode === 'any' ? ' OR ' : ' ');
}

/** Lower case, accents removed: how the index compares words. */
function fold(text: string): string {
  return text
    .normalize('NFD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase();
}

/**
 * A short excerpt of `text` around the first word that matches the query,
 * with every matching word marked. Done in JavaScript: FTS5's `snippet()`
 * re-runs the whole match per row and costs more than the search itself.
 */
export function buildSnippet(
  text: string,
  query: string,
  before: number = 5,
  after: number = 9,
): TextSegment[] {
  const wanted = query
    .normalize('NFKC')
    .split(/[^\p{L}\p{N}]+/u)
    .filter(word => word.length > 0)
    .map(fold);
  const tokens: {start: number; end: number; match: boolean}[] = [];
  const pattern = /[\p{L}\p{N}\p{M}]+/gu;
  let first = -1;
  for (let found = pattern.exec(text); found; found = pattern.exec(text)) {
    const folded = fold(found[0]);
    const match = wanted.some(word => folded.startsWith(word));
    if (match && first < 0) {
      first = tokens.length;
    }
    tokens.push({
      start: found.index,
      end: found.index + found[0].length,
      match,
    });
    if (first >= 0 && tokens.length > first + after) {
      break;
    }
  }
  if (tokens.length === 0) {
    return [];
  }
  const from = Math.max(0, (first < 0 ? 0 : first) - before);
  const to = Math.min(tokens.length - 1, from + before + after);
  const segments: TextSegment[] = [];
  const push = (value: string, match: boolean) => {
    const clean = value.replace(/\s+/g, ' ');
    const last = segments[segments.length - 1];
    if (clean.length === 0) {
      return;
    }
    if (last && last.match === match) {
      last.text += clean;
    } else {
      segments.push({text: clean, match});
    }
  };
  let cursor = from === 0 ? 0 : tokens[from].start;
  if (from > 0) {
    push('…', false);
  }
  for (let i = from; i <= to; i++) {
    push(text.slice(cursor, tokens[i].start), false);
    if (tokens[i].match) {
      segments.push({
        text: text.slice(tokens[i].start, tokens[i].end),
        match: true,
      });
    } else {
      push(text.slice(tokens[i].start, tokens[i].end), false);
    }
    cursor = tokens[i].end;
  }
  // Trailing punctuation belongs to the excerpt; more text means an ellipsis.
  const rest = text.slice(cursor);
  const tail = /^[^\p{L}\p{N}\s]*/u.exec(rest)?.[0] ?? '';
  push(tail, false);
  if (rest.slice(tail.length).trim().length > 0) {
    push('…', false);
  }
  return segments;
}

/** Splits FTS5 `snippet()` / `highlight()` output into runs. */
export function parseMarked(marked: string): TextSegment[] {
  const segments: TextSegment[] = [];
  let rest = marked;
  while (rest.length > 0) {
    const open = rest.indexOf(MARK_OPEN);
    if (open < 0) {
      segments.push({text: rest, match: false});
      break;
    }
    if (open > 0) {
      segments.push({text: rest.slice(0, open), match: false});
    }
    const close = rest.indexOf(MARK_CLOSE, open);
    if (close < 0) {
      segments.push({text: rest.slice(open + 1), match: true});
      break;
    }
    segments.push({text: rest.slice(open + 1, close), match: true});
    rest = rest.slice(close + 1);
  }
  return segments.map(segment => ({
    ...segment,
    text: segment.text.replace(/\s+/g, ' '),
  }));
}

/** Highlights every occurrence of `needle`, with ~40 characters of context. */
export function substringSegments(
  text: string,
  needle: string,
  context: number = 40,
): TextSegment[] {
  const lower = text.toLowerCase();
  const target = needle.toLowerCase();
  const first = lower.indexOf(target);
  if (first < 0 || target.length === 0) {
    return [{text: text.slice(0, context * 2), match: false}];
  }
  const start = Math.max(0, first - context);
  const end = Math.min(text.length, first + target.length + context);
  const segments: TextSegment[] = [];
  let cursor = start;
  if (start > 0) {
    segments.push({text: '…', match: false});
  }
  for (;;) {
    const at = lower.indexOf(target, cursor);
    if (at < 0 || at + target.length > end) {
      break;
    }
    if (at > cursor) {
      segments.push({text: text.slice(cursor, at), match: false});
    }
    segments.push({text: text.slice(at, at + target.length), match: true});
    cursor = at + target.length;
  }
  if (cursor < end) {
    segments.push({text: text.slice(cursor, end), match: false});
  }
  if (end < text.length) {
    segments.push({text: '…', match: false});
  }
  return segments.map(segment => ({
    ...segment,
    text: segment.text.replace(/\s+/g, ' '),
  }));
}

function sessionFilter(options: SearchOptions): {
  sql: string;
  params: SqlValue[];
} {
  const where = ['s.temporary = 0'];
  const params: SqlValue[] = [];
  if (!options.includeArchived) {
    where.push('s.archived_at IS NULL');
  }
  if (!options.includeLocked) {
    where.push('s.locked = 0');
  }
  if (options.projectId) {
    where.push('s.project_id = ?');
    params.push(options.projectId);
  }
  return {sql: where.join(' AND '), params};
}

function hitFromSession(row: SqlRow): SearchHit {
  return {
    sessionId: row.session_id,
    title: row.title,
    titleSegments: [{text: row.title, match: false}],
    titleMatched: false,
    snippet: null,
    messageMatches: 0,
    score: 0,
    updatedAt: row.updated_at,
    archived: row.archived_at !== null && row.archived_at !== undefined,
    locked: row.locked === 1,
  };
}

/** Chats whose title matches lead; within a tier, best score, then newest. */
function rank(hits: Map<string, SearchHit>, limit: number): SearchHit[] {
  return [...hits.values()]
    .sort(
      (a, b) =>
        Number(b.titleMatched) - Number(a.titleMatched) ||
        a.score - b.score ||
        b.updatedAt - a.updatedAt,
    )
    .slice(0, limit);
}

const SESSION_COLUMNS =
  's.session_id, s.title, s.updated_at, s.archived_at, s.locked';

async function searchFts(
  db: Db,
  query: string,
  match: string,
  options: SearchOptions,
): Promise<SearchHit[]> {
  const filter = sessionFilter(options);
  const hits = new Map<string, SearchHit>();

  const titleRows = await db.all(
    `SELECT ${SESSION_COLUMNS}, bm25(titles_fts) AS rank,
        highlight(titles_fts, 0, char(1), char(2)) AS marked
     FROM titles_fts JOIN session_meta s ON s.seq = titles_fts.rowid
     WHERE titles_fts MATCH ? AND ${filter.sql}
     ORDER BY rank LIMIT ?`,
    [match, ...filter.params, MESSAGE_ROW_CAP],
  );
  for (const row of titleRows) {
    const hit = hitFromSession(row);
    hit.titleSegments = parseMarked(row.marked);
    hit.titleMatched = true;
    hit.score = row.rank * TITLE_WEIGHT;
    hits.set(hit.sessionId, hit);
  }

  // Rank first; only the best row of each listed chat gets a snippet.
  const messageRows = await db.all(
    `SELECT ${SESSION_COLUMNS}, n.seq, n.id AS node_id, n.up_id, n.role, n.on_path,
        bm25(messages_fts) AS rank
     FROM messages_fts
     JOIN nodes n ON n.seq = messages_fts.rowid
     JOIN session_meta s ON s.session_id = n.session_id
     WHERE messages_fts MATCH ? AND ${filter.sql}
       ${options.includeParked ? '' : 'AND n.on_path = 1'}
       ${options.role ? 'AND n.role = ?' : ''}
     ORDER BY rank LIMIT ?`,
    [
      match,
      ...filter.params,
      ...(options.role ? [options.role] : []),
      MESSAGE_ROW_CAP,
    ],
  );
  const bestRow = new Map<string, number>();
  for (const row of messageRows) {
    let hit = hits.get(row.session_id);
    if (!hit) {
      hit = hitFromSession(row);
      hits.set(hit.sessionId, hit);
    }
    hit.messageMatches++;
    if (!hit.snippet) {
      // Rows arrive best first, so the first one per chat is its snippet.
      hit.snippet = {
        nodeId: row.node_id,
        messageId: row.on_path === 1 ? (row.up_id ?? row.node_id) : null,
        role: row.role,
        onActivePath: row.on_path === 1,
        segments: [],
      };
      hit.score += row.rank;
      bestRow.set(hit.sessionId, row.seq);
    }
  }
  const ranked = rank(hits, options.limit ?? 30);
  const wanted = ranked
    .map(hit => bestRow.get(hit.sessionId))
    .filter((seq): seq is number => seq !== undefined);
  if (wanted.length > 0) {
    const texts = await db.all<{seq: number; text: string}>(
      `SELECT seq, text FROM nodes WHERE seq IN (${wanted.map(() => '?').join(', ')})`,
      wanted,
    );
    const bySeq = new Map(texts.map(row => [row.seq, row.text]));
    for (const hit of ranked) {
      const seq = bestRow.get(hit.sessionId);
      if (hit.snippet && seq !== undefined) {
        hit.snippet.segments = buildSnippet(bySeq.get(seq) ?? '', query);
      }
    }
  }
  return ranked;
}

async function searchSubstring(
  db: Db,
  needle: string,
  options: SearchOptions,
): Promise<SearchHit[]> {
  const filter = sessionFilter(options);
  const pattern = `%${needle.replace(/[\\%_]/g, char => `\\${char}`)}%`;
  const hits = new Map<string, SearchHit>();

  const titleRows = await db.all(
    `SELECT ${SESSION_COLUMNS} FROM session_meta s
     WHERE s.title LIKE ? ESCAPE '\\' AND ${filter.sql}
     ORDER BY s.updated_at DESC LIMIT ?`,
    [pattern, ...filter.params, MESSAGE_ROW_CAP],
  );
  for (const row of titleRows) {
    const hit = hitFromSession(row);
    hit.titleSegments = substringSegments(row.title, needle, 200);
    hit.titleMatched = true;
    hit.score = -TITLE_WEIGHT;
    hits.set(hit.sessionId, hit);
  }

  const messageRows = await db.all(
    `SELECT ${SESSION_COLUMNS}, n.id AS node_id, n.up_id, n.role, n.on_path, n.text
     FROM nodes n JOIN session_meta s ON s.session_id = n.session_id
     WHERE n.text LIKE ? ESCAPE '\\' AND ${filter.sql}
       ${options.includeParked ? '' : 'AND n.on_path = 1'}
     ORDER BY n.created_at DESC LIMIT ?`,
    [pattern, ...filter.params, MESSAGE_ROW_CAP],
  );
  for (const row of messageRows) {
    let hit = hits.get(row.session_id);
    if (!hit) {
      hit = hitFromSession(row);
      hits.set(hit.sessionId, hit);
    }
    hit.messageMatches++;
    if (!hit.snippet) {
      hit.snippet = {
        nodeId: row.node_id,
        messageId: row.on_path === 1 ? (row.up_id ?? row.node_id) : null,
        role: row.role,
        onActivePath: row.on_path === 1,
        segments: substringSegments(row.text, needle),
      };
      hit.score -= 1;
    }
  }
  return rank(hits, options.limit ?? 30);
}

/**
 * Full-text search over chat titles and message text. One hit per chat,
 * best first, each with the title and the best message snippet split into
 * highlighted runs. Temporary chats are never indexed; archived and locked
 * chats are left out unless asked for.
 */
export async function searchConversations(
  db: Db,
  query: string,
  options: SearchOptions = {},
): Promise<SearchHit[]> {
  const trimmed = query.trim();
  if (trimmed.length === 0) {
    return [];
  }
  if (UNSPACED_SCRIPT.test(trimmed)) {
    return searchSubstring(db, trimmed, options);
  }
  const match = buildFtsQuery(trimmed, options.match ?? 'all');
  if (!match) {
    return [];
  }
  return searchFts(db, trimmed, match, options);
}
