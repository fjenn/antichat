/**
 * The apps people connect, as the chat needs them: what each is called and
 * which message is a plain "connect my Gmail". Port of the Mac's
 * `ComposioApps` / `ConnectAppTool.directRequest` (names and slugs only,
 * never message content beyond matching an app name).
 */
export interface KnownApp {
  /** The toolkit slug the relay links. */
  slug: string;
  title: string;
  names: string[];
  /** One-word kinds a model may send instead of the name ("email"). */
  kinds: string[];
}

export const KNOWN_APPS: KnownApp[] = [
  {
    slug: 'gmail',
    title: 'Gmail',
    names: ['gmail', 'google mail'],
    kinds: ['email', 'e mail', 'mail', 'emails', 'inbox'],
  },
  {
    slug: 'googlecalendar',
    title: 'Google Calendar',
    names: ['google calendar', 'googlecalendar', 'gcal'],
    kinds: ['calendar', 'schedule', 'meetings'],
  },
  {
    slug: 'googledrive',
    title: 'Google Drive',
    names: ['google drive', 'googledrive', 'gdrive'],
    kinds: ['drive'],
  },
  {slug: 'slack', title: 'Slack', names: ['slack'], kinds: []},
  {slug: 'notion', title: 'Notion', names: ['notion'], kinds: ['notes']},
  {
    slug: 'github',
    title: 'GitHub',
    names: ['github', 'git hub'],
    kinds: ['repos', 'repositories', 'pull requests'],
  },
  {slug: 'linear', title: 'Linear', names: ['linear'], kinds: ['issues']},
  {slug: 'outlook', title: 'Outlook', names: ['outlook'], kinds: []},
];

/** The apps shown first in the directory. */
export const FEATURED_SLUGS = KNOWN_APPS.map(app => app.slug);

/** Lower-case letters and digits, single spaces. */
export function normalizeText(text: string): string {
  return text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
    .join(' ');
}

export interface AppRef {
  slug: string;
  name: string;
}

/**
 * The app a name means: a known app by name or kind, else an exact match on
 * a directory entry's name or slug.
 */
export function resolveApp(
  name: string,
  directory: AppRef[] = [],
): AppRef | null {
  const wanted = normalizeText(name);
  if (!wanted) {
    return null;
  }
  const squeezed = wanted.replace(/ /g, '');
  const known =
    KNOWN_APPS.find(
      app => app.slug === squeezed || app.names.includes(wanted),
    ) ?? KNOWN_APPS.find(app => app.kinds.includes(wanted));
  if (known) {
    return {slug: known.slug, name: known.title};
  }
  const listed = directory.find(
    app =>
      app.slug === squeezed ||
      normalizeText(app.name) === wanted ||
      normalizeText(app.name).replace(/ /g, '') === squeezed,
  );
  return listed ? {slug: listed.slug, name: listed.name} : null;
}

/** A toolkit slug as a brand name. */
export function appTitle(slug: string, directory: AppRef[] = []): string {
  const lower = slug.toLowerCase();
  return (
    KNOWN_APPS.find(app => app.slug === lower)?.title ??
    directory.find(app => app.slug === lower)?.name ??
    lower.charAt(0).toUpperCase() + lower.slice(1)
  );
}

const VERBS = [
  'connect',
  'link',
  'log in',
  'login',
  'log into',
  'sign in',
  'signin',
  'sign into',
  'hook up',
  'authorize',
  'authenticate',
].sort((a, b) => b.length - a.length);
const LEAD = [
  'please',
  'can you',
  'could you',
  'can i',
  'could i',
  'let me',
  'let s',
  'lets',
  'i want to',
  'i d like to',
  'i would like to',
  'i need to',
  'help me',
  'hey',
  'hi',
  'ok',
  'okay',
  'now',
];
const FILLER = new Set(
  'me my to into in with up the a an account app please now here for this chat you your our us and on'.split(
    ' ',
  ),
);

/**
 * The app of a message that only asks to connect or sign in to one app
 * ("Let me log into GitHub", "connect my gmail account please"). Anything
 * more (a task, two apps, an unknown app) is null: the model decides. Small
 * models tend to answer "I can't log in for you", so the chat shows the
 * Connect card for these without a model step.
 */
export function directConnectRequest(
  text: string | null | undefined,
  directory: AppRef[] = [],
): AppRef | null {
  if (!text || text.length > 80) {
    return null;
  }
  let rest = normalizeText(text);
  for (let stripped = true; stripped; ) {
    stripped = false;
    for (const lead of LEAD) {
      if (rest.startsWith(`${lead} `)) {
        rest = rest.slice(lead.length + 1);
        stripped = true;
      }
    }
  }
  const verb = VERBS.find(candidate => rest.startsWith(`${candidate} `));
  if (!verb) {
    return null;
  }
  const words = rest
    .slice(verb.length + 1)
    .split(' ')
    .filter(word => word && !FILLER.has(word));
  if (words.length === 0 || words.length > 2) {
    return null;
  }
  return resolveApp(words.join(' '), directory);
}
