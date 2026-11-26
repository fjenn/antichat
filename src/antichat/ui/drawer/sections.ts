/**
 * The drawer's list as one flat array: a header item, then its chats. Flat
 * so one virtualised list can hold thousands of rows.
 *
 * Groups follow ChatGPT's drawer: Pinned, Today, Yesterday, Previous 7 days,
 * Previous 30 days, then a group per month of this year, then one per
 * earlier year.
 */
import type {ConversationView} from '../../contracts';

export type DrawerItem =
  | {kind: 'header'; key: string; title: string}
  | {kind: 'chat'; key: string; conversation: ConversationView};

export interface SectionLabels {
  pinned: string;
  today: string;
  yesterday: string;
  previous7Days: string;
  previous30Days: string;
  /** 0 = January. */
  month: (month: number, year: number) => string;
}

const DAY_MS = 24 * 60 * 60 * 1000;

function startOfDay(time: number): number {
  const date = new Date(time);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** Group key and title for a chat last used at `updatedAt`. */
export function groupOf(
  updatedAt: number,
  now: number,
  labels: SectionLabels,
): {key: string; title: string} {
  const days = Math.round((startOfDay(now) - startOfDay(updatedAt)) / DAY_MS);
  if (days <= 0) {
    return {key: 'today', title: labels.today};
  }
  if (days === 1) {
    return {key: 'yesterday', title: labels.yesterday};
  }
  if (days <= 7) {
    return {key: 'previous7Days', title: labels.previous7Days};
  }
  if (days <= 30) {
    return {key: 'previous30Days', title: labels.previous30Days};
  }
  const date = new Date(updatedAt);
  const year = date.getFullYear();
  if (year === new Date(now).getFullYear()) {
    const month = date.getMonth();
    return {key: `month-${year}-${month}`, title: labels.month(month, year)};
  }
  return {key: `year-${year}`, title: String(year)};
}

/**
 * `conversations` must be newest first (as the port gives them). Archived
 * and temporary chats and the ids in `hidden` are left out.
 */
export function buildDrawerItems(
  conversations: readonly ConversationView[],
  now: number,
  labels: SectionLabels,
  hidden?: ReadonlySet<string>,
): DrawerItem[] {
  const visible = conversations.filter(
    conversation =>
      !conversation.archived &&
      !conversation.temporary &&
      !hidden?.has(conversation.id),
  );
  const items: DrawerItem[] = [];
  const pinned = visible.filter(conversation => conversation.pinned);
  if (pinned.length > 0) {
    items.push({kind: 'header', key: 'header-pinned', title: labels.pinned});
    for (const conversation of pinned) {
      items.push({kind: 'chat', key: conversation.id, conversation});
    }
  }
  let current = '';
  for (const conversation of visible) {
    if (conversation.pinned) {
      continue;
    }
    const group = groupOf(conversation.updatedAt, now, labels);
    if (group.key !== current) {
      current = group.key;
      items.push({
        kind: 'header',
        key: `header-${group.key}`,
        title: group.title,
      });
    }
    items.push({kind: 'chat', key: conversation.id, conversation});
  }
  return items;
}

/** "November" in the phone's language; the locale file is the fallback. */
export function monthName(month: number, year: number): string {
  try {
    const name = new Date(year, month, 1).toLocaleDateString(undefined, {
      month: 'long',
    });
    // Engines without Intl answer with a full date; use the fallback then.
    if (name && !/\d/.test(name)) {
      return name.charAt(0).toUpperCase() + name.slice(1);
    }
  } catch {
    // Fall through.
  }
  return FALLBACK_MONTHS[month] ?? '';
}

const FALLBACK_MONTHS = [
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
