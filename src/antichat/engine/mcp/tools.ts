/**
 * Connector tools in the tool engine. Everything registers as a `deferred`,
 * `online` tool: the model does not see a schema until `search_tools` finds
 * it, and the selection drops all of them while the device is offline.
 *
 *   connect_app                  shows the Connect card (harness-answered)
 *   COMPOSIO_SEARCH_TOOLS        find an action in the connected apps
 *   COMPOSIO_GET_TOOL_SCHEMAS    full arguments of an action
 *   COMPOSIO_MULTI_EXECUTE_TOOL  run actions; writes wait for approval
 *   <server>_<tool>              each tool of a custom MCP server
 *
 * The three Composio tools exist only while at least one app is connected.
 * Their names are Composio's own because its results refer to them.
 */
import {reaction} from 'mobx';

import {activateTools} from '../tools/chips';
import {toolCatalog, type ToolCatalog} from '../tools/catalog';
import {currentTurn} from '../tools/turnState';
import type {AntichatTool, ToolContext, ToolOutput} from '../tools/types';
import {KNOWN_APPS} from './apps';
import {McpError, type McpToolInfo} from './client';
import {
  COMPOSIO_EXECUTE,
  COMPOSIO_SCHEMAS,
  COMPOSIO_SEARCH,
  EXECUTE_PARAMETERS,
  HintCache,
  SCHEMAS_PARAMETERS,
  SEARCH_PARAMETERS,
  UNAVAILABLE_RESULT,
  condenseSearchResult,
  displaySlug,
  executeArguments,
  innerCalls,
  isRemoteExecution,
  isWriteSlug,
} from './composio';
import {APPROVAL_TIMEOUT_MS, DENIED_RESULT} from './permissions';
import type {ConnectorsStore, CustomServer} from './store';
import {isWriteAction, nameWords} from './verbs';

export const CONNECT_APP = 'connect_app';
const WAITS_FOR_USER_MS = APPROVAL_TIMEOUT_MS + 60_000;

const chatOf = (context: ToolContext): string | undefined =>
  currentTurn()?.chatId ?? context.turnId;

const failure = (error: unknown): ToolOutput => ({
  isError: true,
  text:
    error instanceof McpError && error.code === 'cancelled'
      ? 'Cancelled.'
      : `The app could not be reached (${
          error instanceof Error ? error.message : 'unknown error'
        }). Tell the user it did not work.`,
});

/** The card the chat draws for `connect_app` (drawn by `ui/connectors`). */
export interface ConnectAppCardData {
  type: 'connect_app';
  slug: string | null;
  name: string;
  direct: boolean;
}

export function createConnectAppTool(store: ConnectorsStore): AntichatTool {
  return {
    name: CONNECT_APP,
    description:
      'Shows the user a Connect button to sign in to an app like Gmail, GitHub or Slack; call it when they ask to log in or connect, or when a task needs an app that is not connected.',
    parameters: {
      type: 'object',
      properties: {
        app: {type: 'string', description: "The app's name, e.g. Gmail"},
      },
      required: ['app'],
    },
    kind: 'online',
    tier: 'deferred',
    keywords: [
      'connect',
      'login',
      'log in',
      'sign in',
      'account',
      'email',
      'inbox',
      'calendar',
      'drive',
      ...KNOWN_APPS.flatMap(app => app.names),
    ],
    triggers: ['connect', 'log in', 'sign in'],
    example: {app: 'Gmail'},
    normalize: args => {
      const app = args.app ?? args.name ?? args.toolkit ?? args.service;
      return app === undefined ? args : {app: String(app)};
    },
    async execute(args) {
      const name = String(args.app ?? '').trim();
      if (!name) {
        return {isError: true, text: 'Say which app to connect.'};
      }
      const card = store.showCard(name);
      if (!card) {
        return {
          text: `${name} is already connected. Use the connected-app tools to find and run the action.`,
        };
      }
      const data: ConnectAppCardData = {
        type: 'connect_app',
        slug: card.slug,
        name: card.name,
        direct: false,
      };
      return {
        text: `A Connect button for ${card.name} is now shown to the user. Nothing else can be done until they press it.`,
        // Not in M8's `RichCard` union yet: the chat UI draws it with
        // `ui/connectors/ConnectAppCard` once it knows the type.
        card: data as unknown as ToolOutput['card'],
      };
    },
  };
}

/** Composio's results shrunk: per inner call the data or the error. */
export function condenseExecuteResult(text: string): string {
  try {
    const parsed = JSON.parse(text);
    const results = parsed?.data?.results;
    if (!Array.isArray(results)) {
      return text;
    }
    return JSON.stringify(
      results.map((result: any) => ({
        action: result?.tool_slug,
        ...(result?.response?.error || result?.error
          ? {error: result?.response?.error ?? result?.error}
          : {result: result?.response?.data ?? result?.response ?? null}),
      })),
    );
  } catch {
    return text;
  }
}

export function createComposioTools(
  store: ConnectorsStore,
  hints = new HintCache(),
): AntichatTool[] {
  const apps = store.connectedSlugs.map(slug => store.title(slug));
  const named = apps.slice(0, 4).join(', ');
  const keywords = [
    ...store.connectedSlugs,
    ...apps,
    ...KNOWN_APPS.filter(app =>
      store.connectedSlugs.includes(app.slug),
    ).flatMap(app => [...app.names, ...app.kinds]),
    'app',
    'apps',
    'connected',
    'account',
  ];
  const mcp = () => store.relayMcp();

  const search: AntichatTool = {
    name: COMPOSIO_SEARCH,
    description: `Find actions in the user's connected apps (${named}), such as reading email, listing events or sending a message. Call this first, then run the action it returns.`,
    parameters: SEARCH_PARAMETERS,
    kind: 'online',
    tier: 'deferred',
    keywords: [...keywords, 'find', 'actions'],
    timeoutMs: 45_000,
    example: {query: 'list unread gmail emails'},
    normalize: (args, context) => {
      const first = Array.isArray(args.queries) ? args.queries[0] : undefined;
      const query =
        args.query ??
        (first as any)?.use_case ??
        args.use_case ??
        args.q ??
        context.userText;
      return query === undefined ? args : {query: String(query)};
    },
    async execute(args, context) {
      try {
        const result = await mcp().callTool(
          COMPOSIO_SEARCH,
          {queries: [{use_case: String(args.query)}]},
          context.signal,
        );
        if (result.isError) {
          return {isError: true, text: result.text.slice(0, 600)};
        }
        try {
          hints.learn(JSON.parse(result.text));
        } catch {}
        const condensed = condenseSearchResult(result.text, store.directory);
        activateTools(
          chatOf(context),
          condensed.missing.length
            ? [CONNECT_APP]
            : [COMPOSIO_SCHEMAS, COMPOSIO_EXECUTE],
        );
        return {text: condensed.text};
      } catch (error) {
        return failure(error);
      }
    },
  };

  const schemas: AntichatTool = {
    name: COMPOSIO_SCHEMAS,
    description:
      'Get the full argument list of connected-app actions found by COMPOSIO_SEARCH_TOOLS, before running one.',
    parameters: SCHEMAS_PARAMETERS,
    kind: 'online',
    tier: 'deferred',
    keywords: ['arguments', 'schema', 'parameters'],
    timeoutMs: 45_000,
    example: {tool_slugs: ['GMAIL_SEND_EMAIL']},
    normalize: args => {
      const slugs = args.tool_slugs ?? args.slugs ?? args.tool_slug;
      return {
        tool_slugs: (Array.isArray(slugs) ? slugs : slugs ? [slugs] : []).map(
          slug => String(slug).toUpperCase(),
        ),
      };
    },
    async execute(args, context) {
      try {
        const result = await mcp().callTool(
          COMPOSIO_SCHEMAS,
          {tool_slugs: args.tool_slugs},
          context.signal,
        );
        return {text: result.text, isError: result.isError};
      } catch (error) {
        return failure(error);
      }
    },
  };

  const execute: AntichatTool = {
    name: COMPOSIO_EXECUTE,
    description: `Run actions in the user's connected apps (${named}), e.g. send an email or list events. Use action names from COMPOSIO_SEARCH_TOOLS.`,
    parameters: EXECUTE_PARAMETERS,
    kind: 'online',
    tier: 'deferred',
    keywords: [...keywords, 'run', 'send', 'create', 'do'],
    // A write waits for the user's answer on the approval sheet.
    timeoutMs: WAITS_FOR_USER_MS,
    example: {
      tools: [{tool_slug: 'GMAIL_FETCH_EMAILS', arguments: {max_results: 5}}],
    },
    normalize: args =>
      !args.tools && (args.tool_slug || args.slug)
        ? {
            tools: [
              {
                tool_slug: args.tool_slug ?? args.slug,
                arguments: args.arguments ?? {},
              },
            ],
          }
        : args,
    async execute(args, context) {
      const calls = innerCalls(args);
      if (!calls) {
        return {
          isError: true,
          text: 'Pass {"tools":[{"tool_slug":"<ACTION NAME>","arguments":{…}}]}.',
        };
      }
      if (calls.some(call => isRemoteExecution(call.slug))) {
        return {text: UNAVAILABLE_RESULT};
      }
      for (const call of calls) {
        const shown = displaySlug(call.slug, store.directory);
        const shownArguments = {...call.arguments};
        if (shownArguments.user_id === 'me') {
          delete shownArguments.user_id;
        }
        const allowed = await store.permissions.allow(
          {
            key: `composio:${call.slug}`,
            app: shown.app,
            action: shown.action,
            arguments: shownArguments,
            write: isWriteSlug(call.slug, hints),
          },
          context.signal,
        );
        if (!allowed) {
          return {text: DENIED_RESULT};
        }
      }
      try {
        const result = await mcp().callTool(
          COMPOSIO_EXECUTE,
          executeArguments(calls),
          context.signal,
        );
        return {
          text: condenseExecuteResult(result.text),
          isError: result.isError,
          // Mail bodies, pages, messages: other people's words.
          untrusted: true,
        };
      } catch (error) {
        return failure(error);
      }
    },
  };

  return [search, schemas, execute];
}

/** A catalogue-safe name: `<server>_<tool>`, at most 64 characters. */
export function serverToolName(server: {id: string}, tool: string): string {
  const prefix = server.id.replace(/[^a-zA-Z0-9]+/g, '_').slice(0, 20);
  return `${prefix}_${tool.replace(/[^a-zA-Z0-9_]+/g, '_')}`.slice(0, 64);
}

const humanize = (name: string): string => {
  const text = nameWords(name).join(' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
};

export function createServerTools(
  store: ConnectorsStore,
  server: CustomServer,
): AntichatTool[] {
  if (server.state !== 'connected') {
    return [];
  }
  return server.tools.map((info: McpToolInfo): AntichatTool => {
    const annotations = (info.annotations ?? {}) as Record<string, unknown>;
    const write = isWriteAction(info.name, {
      readOnly: annotations.readOnlyHint === true,
      destructive: annotations.destructiveHint === true,
    });
    const schema =
      info.inputSchema && typeof info.inputSchema === 'object'
        ? {...info.inputSchema}
        : {type: 'object', properties: {}};
    delete (schema as Record<string, unknown>).$schema;
    return {
      name: serverToolName(server, info.name),
      description: `${server.name}: ${
        info.description?.trim() || humanize(info.name)
      }`,
      parameters: schema,
      kind: 'online',
      tier: 'deferred',
      keywords: [server.name, ...nameWords(info.name)],
      timeoutMs: write ? WAITS_FOR_USER_MS : 60_000,
      async execute(args, context) {
        const allowed = await store.permissions.allow(
          {
            key: `mcp:${server.id}:${info.name}`,
            app: server.name,
            action: humanize(info.name),
            arguments: args,
            write,
          },
          context.signal,
        );
        if (!allowed) {
          return {text: DENIED_RESULT};
        }
        try {
          const result = await store
            .clientFor(server)
            .callTool(info.name, args, context.signal);
          return {text: result.text, isError: result.isError, untrusted: true};
        } catch (error) {
          if (error instanceof McpError && error.code === 'unauthorized') {
            store.markServerSignedOut(server.id);
            return {
              isError: true,
              text: `${server.name} needs a new sign-in. Tell the user to open Settings › Connectors.`,
            };
          }
          return failure(error);
        }
      },
    };
  });
}

/**
 * Keep the catalogue in step with the store. Returns the function that
 * removes every connector tool again.
 */
export function registerConnectorTools(
  store: ConnectorsStore,
  catalog: ToolCatalog = toolCatalog,
): () => void {
  let registered: string[] = [];
  const hints = new HintCache();
  const sync = () => {
    const tools = [
      createConnectAppTool(store),
      ...(store.connectedSlugs.length ? createComposioTools(store, hints) : []),
      ...store.servers.flatMap(server => createServerTools(store, server)),
    ];
    const names = new Set(tools.map(tool => tool.name));
    registered
      .filter(name => !names.has(name))
      .forEach(name => catalog.unregister(name));
    tools.forEach(tool => catalog.register(tool));
    registered = [...names];
  };
  const stop = reaction(() => store.revision, sync, {fireImmediately: true});
  return () => {
    stop();
    registered.forEach(name => catalog.unregister(name));
    registered = [];
  };
}

/** A status line for the transcript: the app's name, never a slug. */
export function connectorToolLabel(
  name: string,
  args: Record<string, unknown> = {},
  store?: ConnectorsStore,
): string | null {
  if (name === CONNECT_APP) {
    return 'Offering to connect an app';
  }
  if (name === COMPOSIO_SEARCH || name === COMPOSIO_SCHEMAS) {
    return 'Looking through your apps';
  }
  if (name === COMPOSIO_EXECUTE) {
    const calls = innerCalls(args);
    if (!calls) {
      return 'Using your apps';
    }
    const shown = displaySlug(calls[0].slug, store?.directory);
    return isWriteSlug(calls[0].slug)
      ? `Using ${shown.app}`
      : `Checking ${shown.app}`;
  }
  const server = store?.servers.find(item =>
    name.startsWith(serverToolName(item, '')),
  );
  return server ? `Using ${server.name}` : null;
}
