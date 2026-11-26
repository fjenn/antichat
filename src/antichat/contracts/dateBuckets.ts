import type {
  ConversationSection,
  ConversationView,
  DateBucket,
} from './conversation';

const DAY_MS = 24 * 60 * 60 * 1000;

function startOfDay(time: number): number {
  const date = new Date(time);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** The drawer's date group for a chat last used at `updatedAt`. */
export function bucketFor(updatedAt: number, now: number): DateBucket {
  const today = startOfDay(now);
  if (updatedAt >= today) {
    return 'today';
  }
  if (updatedAt >= today - DAY_MS) {
    return 'yesterday';
  }
  if (updatedAt >= today - 7 * DAY_MS) {
    return 'previous7Days';
  }
  if (updatedAt >= today - 30 * DAY_MS) {
    return 'previous30Days';
  }
  return 'older';
}

const ORDER: Array<ConversationSection['key']> = [
  'pinned',
  'today',
  'yesterday',
  'previous7Days',
  'previous30Days',
  'older',
];

/**
 * Groups chats for the drawer: pinned first, then date groups, newest first
 * inside each. Archived and temporary chats are left out; empty groups too.
 */
export function buildSections(
  conversations: readonly ConversationView[],
  now: number,
): ConversationSection[] {
  const groups = new Map<ConversationSection['key'], ConversationView[]>();
  [...conversations]
    .filter(conversation => !conversation.archived && !conversation.temporary)
    .sort((a, b) => b.updatedAt - a.updatedAt)
    .forEach(conversation => {
      const key = conversation.pinned
        ? 'pinned'
        : bucketFor(conversation.updatedAt, now);
      groups.set(key, [...(groups.get(key) ?? []), conversation]);
    });
  return ORDER.filter(key => groups.has(key)).map(key => ({
    key,
    conversations: groups.get(key)!,
  }));
}
