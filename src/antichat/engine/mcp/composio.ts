/**
 * Composio's meta-tools, made usable for a small local model. Port of the
 * Mac's `SlugPermission`:
 *
 *   - only search, schemas and execute are offered; remote workbench, bash
 *     and connection-management tools of the session are never registered
 *     (connecting is the app's own `connect_app` card);
 *   - the execute schema is cut to `tools[].tool_slug` + `arguments`, and
 *     `sync_response_to_workbench` is forced false so results come back
 *     inline;
 *   - slugs that run code on Composio's side are refused with a fixed result;
 *   - each inner slug is judged read or write on its own (tag hints learned
 *     from search results, else the verb rule).
 */
import {appTitle, type AppRef} from './apps';
import {isWriteAction, nameWords, type WriteHints} from './verbs';

export const COMPOSIO_SEARCH = 'COMPOSIO_SEARCH_TOOLS';
export const COMPOSIO_SCHEMAS = 'COMPOSIO_GET_TOOL_SCHEMAS';
export const COMPOSIO_EXECUTE = 'COMPOSIO_MULTI_EXECUTE_TOOL';
export const OFFERED_META_TOOLS = [
  COMPOSIO_SEARCH,
  COMPOSIO_SCHEMAS,
  COMPOSIO_EXECUTE,
];

export const SEARCH_PARAMETERS = {
  type: 'object',
  properties: {
    query: {
      type: 'string',
      description:
        'What to do, in English, naming the app (e.g. "list unread gmail emails")',
      minLength: 1,
    },
  },
  required: ['query'],
};

export const SCHEMAS_PARAMETERS = {
  type: 'object',
  properties: {
    tool_slugs: {
      type: 'array',
      items: {type: 'string'},
      description: 'Action names from the search, e.g. ["GMAIL_SEND_EMAIL"]',
    },
  },
  required: ['tool_slugs'],
};

export const EXECUTE_PARAMETERS = {
  type: 'object',
  properties: {
    tools: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          tool_slug: {type: 'string'},
          arguments: {type: 'object'},
        },
        required: ['tool_slug', 'arguments'],
      },
    },
  },
  required: ['tools'],
};

export const UNAVAILABLE_RESULT =
  'This tool is not available. The earlier results are complete and already here: answer the user from them now, without calling another tool.';

/** Slugs that run code remotely or are Composio's own meta tools. */
export function isRemoteExecution(slug: string): boolean {
  const words = new Set(nameWords(slug));
  return (
    words.has('composio') ||
    ['workbench', 'bash', 'python', 'shell', 'codeinterpreter', 'sandbox'].some(
      word => words.has(word),
    )
  );
}

export interface InnerCall {
  slug: string;
  arguments: Record<string, unknown>;
}

/** The inner calls of an execute call, slugs upper-cased. null = malformed. */
export function innerCalls(args: Record<string, unknown>): InnerCall[] | null {
  const tools = args.tools;
  if (!Array.isArray(tools) || tools.length === 0) {
    return null;
  }
  const out: InnerCall[] = [];
  for (const item of tools) {
    const slug = (item?.tool_slug ?? item?.slug ?? item?.name) as unknown;
    if (typeof slug !== 'string' || !slug.trim()) {
      return null;
    }
    const inner = item.arguments ?? item.args ?? {};
    out.push({
      slug: slug.trim().toUpperCase(),
      arguments:
        inner && typeof inner === 'object' && !Array.isArray(inner)
          ? (inner as Record<string, unknown>)
          : {},
    });
  }
  return out;
}

/** An execute call as it is sent: only the inner calls, results inline. */
export function executeArguments(calls: InnerCall[]): Record<string, unknown> {
  return {
    tools: calls.map(call => ({
      tool_slug: call.slug,
      arguments: call.arguments,
    })),
    sync_response_to_workbench: false,
  };
}

/** `GMAIL_SEND_EMAIL` → {app: "Gmail", action: "Send email"}. */
export function displaySlug(
  slug: string,
  directory: AppRef[] = [],
): {app: string; action: string; toolkit: string} {
  const parts = slug.toLowerCase().split('_').filter(Boolean);
  const toolkit = parts[0] ?? slug.toLowerCase();
  const action = parts.slice(1).join(' ');
  return {
    toolkit,
    app: appTitle(toolkit, directory),
    action: action.charAt(0).toUpperCase() + action.slice(1),
  };
}

/** Tag hints per slug, learned from search results (memory only). */
export class HintCache {
  private readonly hints = new Map<string, WriteHints>();

  get(slug: string): WriteHints | undefined {
    return this.hints.get(slug.toUpperCase());
  }

  set(slug: string, hints: WriteHints): void {
    this.hints.set(slug.toUpperCase(), hints);
  }

  /** Reads every `{slug|tool_slug|toolSlug, tags|annotations}` object. */
  learn(value: unknown, depth = 0): void {
    if (depth > 8 || value === null || typeof value !== 'object') {
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(item => this.learn(item, depth + 1));
      return;
    }
    const node = value as Record<string, any>;
    const slug = node.tool_slug ?? node.toolSlug ?? node.slug;
    if (typeof slug === 'string') {
      const flags = {...node, ...(node.annotations ?? {})};
      const tags = new Set(
        (Array.isArray(node.tags) ? node.tags : []).map((tag: unknown) =>
          String(tag).toLowerCase(),
        ),
      );
      const has = (name: string) =>
        flags[name] === true || tags.has(name.toLowerCase());
      const hints: WriteHints = {
        readOnly: has('readOnlyHint'),
        create: has('createHint'),
        update: has('updateHint'),
        destructive: has('destructiveHint'),
      };
      if (Object.values(hints).some(Boolean)) {
        this.set(slug, hints);
      }
    }
    Object.values(node).forEach(item => this.learn(item, depth + 1));
  }
}

export const isWriteSlug = (slug: string, cache?: HintCache): boolean =>
  isWriteAction(slug, cache?.get(slug));

const describeSchema = (schema: any): string => {
  const properties = schema?.properties ?? {};
  const required = new Set<string>(schema?.required ?? []);
  const names = Object.keys(properties);
  if (names.length === 0) {
    return '';
  }
  // Required first; a long schema is cut, the schemas tool has the rest.
  names.sort((a, b) => Number(required.has(b)) - Number(required.has(a)));
  const shown = names.slice(0, 8).map(name => {
    const type = properties[name]?.type;
    return `${name}${required.has(name) ? '*' : ''}${
      typeof type === 'string' ? `: ${type}` : ''
    }`;
  });
  return ` Arguments (* required): ${shown.join(', ')}${
    names.length > shown.length ? ', …' : ''
  }.`;
};

/** The first of `keys` set on `node`: Composio answers in snake_case today, the older SDK shape was camelCase. */
const field = (node: any, ...keys: string[]): any => {
  if (!node || typeof node !== 'object') {
    return undefined;
  }
  for (const key of keys) {
    if (node[key] !== undefined) {
      return node[key];
    }
  }
  return undefined;
};

/** `GMAIL_SEND_EMAIL` → `gmail`, or the schema's own toolkit. */
const toolkitOf = (slug: string, schema: any): string => {
  const own = field(schema, 'toolkit');
  const named = typeof own === 'string' ? own : field(own, 'slug', 'name');
  return String(named ?? slug.split('_')[0] ?? slug).toLowerCase();
};

/**
 * A search result as a small model can read it: the actions with their
 * arguments, which apps are connected, and what to call next. Composio's
 * answer is several kilobytes of planning advice; the tool-result cap would
 * cut it in the middle. Unparseable text is passed on unchanged.
 *
 * Actions of an app that is not connected are dropped while any action of a
 * connected app was found (a search for Gmail often also returns a Drive
 * action); `missing` is set only when nothing found can run.
 */
export function condenseSearchResult(
  text: string,
  directory: AppRef[] = [],
): {text: string; missing: string[]} {
  let parsed: any;
  try {
    parsed = JSON.parse(text);
  } catch {
    return {text, missing: []};
  }
  const body = parsed?.data ?? parsed;
  const schemas: Record<string, any> =
    field(body, 'tool_schemas', 'toolSchemas') ?? {};
  const rawResults = field(body, 'results');
  const results: any[] = Array.isArray(rawResults) ? rawResults : [];
  const slugs: string[] = [];
  const add = (slug: unknown) => {
    if (typeof slug === 'string' && !slugs.includes(slug)) {
      slugs.push(slug);
    }
  };
  for (const result of results) {
    [
      ...(field(result, 'primary_tool_slugs', 'primaryToolSlugs') ?? []),
      ...(field(result, 'related_tool_slugs', 'relatedToolSlugs') ?? []),
    ].forEach(add);
  }
  Object.keys(schemas).forEach(add);
  const found = slugs.filter(slug => !isRemoteExecution(slug));
  if (found.length === 0) {
    return {
      text: 'No action found for that. Tell the user this is not available, or search again with other words.',
      missing: [],
    };
  }
  const rawStatuses = field(
    body,
    'toolkit_connection_statuses',
    'toolkitConnectionStatuses',
  );
  const statuses: any[] = Array.isArray(rawStatuses) ? rawStatuses : [];
  const notConnected = new Set(
    statuses
      .filter(
        status =>
          field(status, 'has_active_connection', 'hasActiveConnection') ===
            false && field(status, 'toolkit'),
      )
      .map(status => String(field(status, 'toolkit')).toLowerCase()),
  );
  const runnable = found.filter(
    slug => !notConnected.has(toolkitOf(slug, schemas[slug])),
  );
  const usable = (runnable.length ? runnable : found).slice(0, 6);
  const missing = runnable.length
    ? []
    : [...new Set(usable.map(slug => toolkitOf(slug, schemas[slug])))].filter(
        toolkit => notConnected.has(toolkit),
      );
  const lines = usable.map(slug => {
    const schema = schemas[slug];
    const description = String(field(schema, 'description') ?? '')
      .replace(/\s+/g, ' ')
      .slice(0, 140);
    return `- ${slug}: ${description}${describeSchema(
      field(schema, 'input_schema', 'inputSchema'),
    )}`;
  });
  const next = missing.length
    ? `Not connected: ${missing
        .map(slug => appTitle(slug, directory))
        .join(', ')}. Call connect_app with the app's name first.`
    : `Run one with ${COMPOSIO_EXECUTE}: {"tools":[{"tool_slug":"<NAME>","arguments":{…}}]}.`;
  return {
    text: `Actions found:\n${lines.join('\n')}\n${next}`,
    missing,
  };
}
