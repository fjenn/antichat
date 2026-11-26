/**
 * The app directory as the Connectors screen browses it: a Popular row, then
 * every app under one friendly category. Composio tags its ~1,700 toolkits
 * with ~100 raw categories; they fold into the groups below, and each app
 * sits in the group of its first category that has one.
 */
import type {Toolkit} from '../../engine/mcp/relay';

/** Shown first, in this order, when the directory has them. */
export const POPULAR_SLUGS = [
  'gmail',
  'googlecalendar',
  'googledrive',
  'notion',
  'slack',
  'github',
  'outlook',
  'googlesheets',
  'googledocs',
  'microsoft_teams',
  'linear',
  'jira',
  'asana',
  'dropbox',
  'one_drive',
  'trello',
  'hubspot',
  'zoom',
  'figma',
  'calendly',
];

export interface DirectoryGroup {
  id: string;
  title: string;
  categories: string[];
}

export const GROUPS: DirectoryGroup[] = [
  {
    id: 'communication',
    title: 'Communication',
    categories: [
      'email',
      'team chat',
      'communication',
      'phone & sms',
      'video conferencing',
      'notifications',
      'transactional email',
      'call tracking',
    ],
  },
  {
    id: 'productivity',
    title: 'Productivity',
    categories: [
      'productivity',
      'notes',
      'task management',
      'calendar',
      'scheduling & booking',
      'time tracking software',
      'bookmark managers',
      'ai meeting assistants',
    ],
  },
  {
    id: 'files',
    title: 'Files & documents',
    categories: [
      'documents',
      'file management & storage',
      'spreadsheets',
      'signatures',
      'documents & ocr',
      'content & files',
      'ai document extraction',
    ],
  },
  {
    id: 'projects',
    title: 'Project management',
    categories: [
      'project management',
      'team collaboration',
      'product management',
    ],
  },
  {
    id: 'sales',
    title: 'Sales & CRM',
    categories: [
      'crm',
      'sales & crm',
      'contact management',
      'people & contact data',
      'company data',
      'ai sales tools',
    ],
  },
  {
    id: 'marketing',
    title: 'Marketing',
    categories: [
      'marketing automation',
      'marketing',
      'email newsletters',
      'social media marketing',
      'ads & conversion',
      'seo & ai visibility',
      'drip emails',
      'url shortener',
      'reviews',
      'customer appreciation',
      'webinars',
      'event management',
      'social media accounts',
      'social & creator data',
    ],
  },
  {
    id: 'finance',
    title: 'Finance & commerce',
    categories: [
      'accounting',
      'payment processing',
      'ecommerce',
      'commerce',
      'proposal & invoice management',
      'taxes',
      'fundraising',
      'market data',
    ],
  },
  {
    id: 'support',
    title: 'Support & HR',
    categories: [
      'customer support',
      'support',
      'hr talent & recruitment',
      'human resources',
      'forms & surveys',
    ],
  },
  {
    id: 'data',
    title: 'Analytics & data',
    categories: [
      'analytics',
      'business intelligence',
      'dashboards',
      'web scraping & browser',
      'web search & research',
      'ai web scraping',
    ],
  },
  {
    id: 'design',
    title: 'Design & media',
    categories: [
      'images & design',
      'video & audio',
      'media generation',
      'video generation',
      'audio & speech',
      'transcription',
    ],
  },
  {
    id: 'ai',
    title: 'AI',
    categories: [
      'artificial intelligence',
      'ai agents',
      'ai models',
      'ai content generation',
      'ai chatbots',
      'ai assistants',
      'ai safety compliance detection',
    ],
  },
  {
    id: 'developer',
    title: 'Developer tools',
    categories: [
      'developer tools',
      'databases',
      'server monitoring',
      'it operations',
      'security & identity tools',
      'app builder',
      'website builders',
      'website & app building',
      'internet of things',
      'model context protocol',
    ],
  },
  {
    id: 'lifestyle',
    title: 'Lifestyle & learning',
    categories: [
      'lifestyle & entertainment',
      'news & lifestyle',
      'education',
      'online courses',
      'gaming',
      'fitness',
      'places & weather',
      'legal & public records',
    ],
  },
];

const OTHER: DirectoryGroup = {id: 'other', title: 'Other', categories: []};

const byCategory = new Map<string, DirectoryGroup>();
GROUPS.forEach(group =>
  group.categories.forEach(category => byCategory.set(category, group)),
);

/** Too broad to place an app when it has a more telling category. */
const GENERIC = new Set(['model context protocol', 'productivity']);

export function groupOf(toolkit: Toolkit): DirectoryGroup {
  const categories = toolkit.categories.map(c => c.toLowerCase());
  const pick = (allowGeneric: boolean) =>
    categories
      .filter(category => allowGeneric || !GENERIC.has(category))
      .map(category => byCategory.get(category))
      .find(Boolean);
  return pick(false) ?? pick(true) ?? OTHER;
}

export type DirectoryRow =
  | {
      kind: 'header';
      key: string;
      id: string;
      title: string;
      count: number;
      expanded: boolean;
    }
  | {kind: 'app'; key: string; toolkit: Toolkit};

export interface Directory {
  popular: Toolkit[];
  /** Groups that have apps, in display order, with their sizes. */
  groups: {id: string; title: string; count: number}[];
  /** The flat list rows: headers and apps, for one group or all. */
  rows: DirectoryRow[];
}

const byName = (a: Toolkit, b: Toolkit) =>
  a.name.localeCompare(b.name, undefined, {sensitivity: 'base'});

const popularRank = (toolkit: Toolkit) => {
  const index = POPULAR_SLUGS.indexOf(toolkit.slug);
  return index === -1 ? POPULAR_SLUGS.length : index;
};

/** Well-known apps lead their group; the rest follow by name. */
const byRank = (a: Toolkit, b: Toolkit) =>
  popularRank(a) - popularRank(b) || byName(a, b);

/**
 * Builds the browse view. `group` narrows the rows to one group (no header);
 * without it every group is listed under its title. With `expanded`, only the
 * groups in it list their apps; the others show just their header.
 */
export function buildDirectory(
  toolkits: readonly Toolkit[],
  group: string | null = null,
  expanded?: ReadonlySet<string>,
): Directory {
  const listed = toolkits.filter(toolkit => toolkit.auth !== 'none');
  const bySlug = new Map(listed.map(toolkit => [toolkit.slug, toolkit]));
  const popular = POPULAR_SLUGS.map(slug => bySlug.get(slug)).filter(
    (toolkit): toolkit is Toolkit => Boolean(toolkit),
  );
  const buckets = new Map<string, Toolkit[]>();
  for (const toolkit of listed) {
    const id = groupOf(toolkit).id;
    const bucket = buckets.get(id);
    if (bucket) {
      bucket.push(toolkit);
    } else {
      buckets.set(id, [toolkit]);
    }
  }
  const ordered = [...GROUPS, OTHER]
    .filter(item => buckets.has(item.id))
    .map(item => ({
      ...item,
      apps: buckets.get(item.id)!.sort(byRank),
    }));
  const rows: DirectoryRow[] = [];
  for (const item of ordered) {
    if (group && item.id !== group) {
      continue;
    }
    const open = !!group || !expanded || expanded.has(item.id);
    if (!group) {
      rows.push({
        kind: 'header',
        key: `group-${item.id}`,
        id: item.id,
        title: item.title,
        count: item.apps.length,
        expanded: open,
      });
    }
    if (!open) {
      continue;
    }
    item.apps.forEach(toolkit =>
      rows.push({kind: 'app', key: toolkit.slug, toolkit}),
    );
  }
  return {
    popular,
    groups: ordered.map(item => ({
      id: item.id,
      title: item.title,
      count: item.apps.length,
    })),
    rows,
  };
}
