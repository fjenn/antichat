import type {Db, SqlRow, SqlValue} from './driver';
import type {
  HistoryGroup,
  HistoryItem,
  HistoryListing,
  HistoryOptions,
} from './types';

const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const DAY_MS = 24 * 60 * 60 * 1000;

function startOfDay(time: number): number {
  const date = new Date(time);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** Whole calendar days between two instants, in the phone's time zone. */
function daysBetween(now: number, then: number): number {
  return Math.round((startOfDay(now) - startOfDay(then)) / DAY_MS);
}

/**
 * Groups chats the way ChatGPT's drawer does: Today, Yesterday, Previous 7
 * Days, Previous 30 Days, then one group per month of this year, then one
 * per earlier year. Input must be sorted newest first.
 */
export function groupHistory(
  items: HistoryItem[],
  now: number,
): HistoryGroup[] {
  const groups: HistoryGroup[] = [];
  const thisYear = new Date(now).getFullYear();
  for (const item of items) {
    const days = daysBetween(now, item.updatedAt);
    const date = new Date(item.updatedAt);
    let group: Omit<HistoryGroup, 'items'>;
    if (days <= 0) {
      group = {key: 'today', label: 'Today'};
    } else if (days === 1) {
      group = {key: 'yesterday', label: 'Yesterday'};
    } else if (days <= 7) {
      group = {key: 'previous7Days', label: 'Previous 7 Days'};
    } else if (days <= 30) {
      group = {key: 'previous30Days', label: 'Previous 30 Days'};
    } else if (date.getFullYear() === thisYear) {
      group = {
        key: 'month',
        month: date.getMonth(),
        year: thisYear,
        label: MONTHS[date.getMonth()],
      };
    } else {
      group = {
        key: 'year',
        year: date.getFullYear(),
        label: String(date.getFullYear()),
      };
    }
    const last = groups[groups.length - 1];
    if (
      last &&
      last.key === group.key &&
      last.month === group.month &&
      last.year === group.year
    ) {
      last.items.push(item);
    } else {
      groups.push({...group, items: [item]});
    }
  }
  return groups;
}

export function historyItemFromRow(row: SqlRow): HistoryItem {
  return {
    sessionId: row.session_id,
    title: row.title,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    pinned: row.pinned_at !== null && row.pinned_at !== undefined,
    archived: row.archived_at !== null && row.archived_at !== undefined,
    locked: row.locked === 1,
    projectId: row.project_id ?? null,
    originKind: row.origin_kind ?? null,
    originSessionId: row.origin_session_id ?? null,
  };
}

/**
 * The drawer's data: pinned chats first (latest pin on top), the rest in
 * date groups, newest first. Temporary chats never appear.
 */
export async function listHistory(
  db: Db,
  options: HistoryOptions = {},
): Promise<HistoryListing> {
  const scope = options.scope ?? 'active';
  const where = ['temporary = 0'];
  const params: SqlValue[] = [];
  if (scope === 'active') {
    where.push('archived_at IS NULL');
  } else if (scope === 'archived') {
    where.push('archived_at IS NOT NULL');
  }
  if (options.projectId !== undefined) {
    if (options.projectId === null) {
      where.push('project_id IS NULL');
    } else {
      where.push('project_id = ?');
      params.push(options.projectId);
    }
  }
  const rows = await db.all(
    `SELECT session_id, title, created_at, updated_at, pinned_at, archived_at,
        locked, project_id, origin_kind, origin_session_id
     FROM session_meta WHERE ${where.join(' AND ')}
     ORDER BY updated_at DESC, seq DESC`,
    params,
  );
  // The archive list is flat by date; pins only lead the live list.
  const pinFirst = scope !== 'archived';
  const pinnedRows = pinFirst
    ? rows
        .filter(row => row.pinned_at !== null && row.pinned_at !== undefined)
        .sort((a, b) => b.pinned_at - a.pinned_at)
    : [];
  const rest = pinFirst
    ? rows.filter(row => row.pinned_at === null || row.pinned_at === undefined)
    : rows;
  return {
    pinned: pinnedRows.map(historyItemFromRow),
    groups: groupHistory(
      rest.map(historyItemFromRow),
      options.now ?? Date.now(),
    ),
  };
}
