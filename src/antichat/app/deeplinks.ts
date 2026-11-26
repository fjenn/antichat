/**
 * Deep-link router, placeholder. M13 owns the real table (widgets, share
 * extension, App Intents); M1 fixes the shape and the two routes the shell
 * itself has, so links have one way in from the start.
 *
 *   antichat://chat            new chat
 *   antichat://chat/<id>       open a chat
 *   antichat://settings        settings
 *   antichat://dev/backend/fake?rate=60   debug builds: in-memory backend
 *   antichat://dev/backend/real           debug builds: the real engine
 *   antichat://dev/auto/script60          debug builds: unattended checks
 *
 * `pocketpal://` is accepted too: it is the scheme the native projects
 * register until the rebrand of the release build.
 */
export type DeepLink =
  | {route: 'chat'; conversationId: string | null; prompt?: string}
  | {route: 'settings'}
  | {
      route: 'dev';
      backend: 'fake' | 'real';
      fake?: {tokensPerSecond?: number; firstTokenMs?: number};
    }
  /** Debug builds: run the unattended chat checks (`ui/chat/auto.ts`). */
  | {route: 'auto'; source: string};

const SCHEMES = ['antichat:', 'pocketpal:'];

export function parseDeepLink(url: string): DeepLink | null {
  const match = /^([a-z][a-z0-9+.-]*:)\/\/([^?#]*)(?:\?([^#]*))?/i.exec(url);
  if (!match || !SCHEMES.includes(match[1].toLowerCase())) {
    return null;
  }
  const parts = match[2].split('/').filter(Boolean);
  // Android registers only `pocketpal://hub/…` so far: `hub` is a prefix.
  if (parts[0]?.toLowerCase() === 'hub') {
    parts.shift();
  }
  const [head, ...rest] = parts;
  const query = new Map(
    (match[3] ?? '')
      .split('&')
      .filter(Boolean)
      .map(pair => {
        const [key, value = ''] = pair.split('=');
        return [decode(key), decode(value)] as [string, string];
      }),
  );
  switch (head?.toLowerCase()) {
    case 'chat':
      return {
        route: 'chat',
        conversationId: rest[0] ? decode(rest[0]) : null,
        prompt: query.get('q') || undefined,
      };
    case 'settings':
      return {route: 'settings'};
    case 'dev': {
      if (rest[0]?.toLowerCase() === 'auto' && rest[1]) {
        return {route: 'auto', source: rest[1]};
      }
      const backend = rest[1]?.toLowerCase();
      if (
        rest[0]?.toLowerCase() !== 'backend' ||
        (backend !== 'fake' && backend !== 'real')
      ) {
        return null;
      }
      const rate = Number(query.get('rate'));
      const first = Number(query.get('first'));
      const fake = {
        ...(rate > 0 ? {tokensPerSecond: rate} : {}),
        ...(query.has('first') && first >= 0 ? {firstTokenMs: first} : {}),
      };
      return {
        route: 'dev',
        backend,
        fake: Object.keys(fake).length > 0 ? fake : undefined,
      };
    }
    default:
      return null;
  }
}

function decode(value: string): string {
  try {
    return decodeURIComponent(value.replace(/\+/g, ' '));
  } catch {
    return value;
  }
}
