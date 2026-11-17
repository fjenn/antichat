// Composio access (architecture §8.1, M7.T10 steps 2 and 4; P-files-tools-15). @composio/core 0.27.0:
// composio.create(userId, {toolkits, manageConnections: true, mcp: true}) → ToolRouter session with an MCP URL.
//
// Storage rule (R-255 AC6): Upstash holds `sess:<userId>` = {sid, url} only. The MCP credential headers that the
// SDK attaches to session.mcp are kept in process memory, and on a cold instance are re-derived by the SDK
// (`composio.use(sid, {mcp: true})`), so the Composio key is never written to the store and never leaves the relay.
import { Composio } from "@composio/core";
import type { RelayConfig } from "./policy.js";
import { DEFAULT_TOOLKITS } from "./policy.js";
import type { KV } from "./store.js";

export const DEFAULT_COMPOSIO_URL = "https://backend.composio.dev";
export const SESSION_TTL_SECONDS = 3600;

export type McpTarget = { url: string; headers: Record<string, string> };
export type Connection = { id: string; toolkit: string; status: string };
/** One toolkit as Composio lists it (GET /api/v3.1/toolkits), reduced to what src/toolkits.ts reads. */
export type ListedToolkit = {
  slug: string;
  name: string;
  description: string;
  logo: string;
  categories: string[];
  authSchemes: string[];
  managedAuthSchemes: string[];
  noAuth: boolean;
  tools: number;
};

/** The Composio calls the relay makes. The real one wraps the SDK; tests use it against test/mock-composio.ts. */
export interface ComposioGateway {
  createSession(userId: string, toolkits: string[] | "*"): Promise<{ sid: string } & McpTarget>;
  /** MCP url + server-side headers of an existing session. */
  mcpTarget(sid: string): Promise<McpTarget>;
  connections(sid: string): Promise<Connection[]>;
  link(sid: string, toolkit: string, callbackUrl?: string): Promise<{ url: string; id: string }>;
  disconnect(accountId: string): Promise<void>;
  deleteSession(sid: string): Promise<void>;
  /** Every native, non-deprecated toolkit Composio lists (all pages). */
  listToolkits(): Promise<ListedToolkit[]>;
}

export class SdkGateway implements ComposioGateway {
  private sdk: Composio;
  constructor(apiKey: string, baseURL: string | undefined) {
    this.sdk = new Composio({
      apiKey,
      userApiKey: null,
      orgApiKey: null,
      // Always explicit: never the SDK's env / ~/.composio fallbacks.
      baseURL: baseURL ?? DEFAULT_COMPOSIO_URL,
      allowTracking: false,
      disableVersionCheck: true,
    });
  }

  async createSession(userId: string, toolkits: string[] | "*") {
    const s = await this.sdk.create(userId, {
      ...(toolkits === "*" ? {} : { toolkits }),
      manageConnections: true,
      mcp: true,
    });
    return { sid: s.sessionId, url: s.mcp.url, headers: { ...s.mcp.headers } };
  }

  async mcpTarget(sid: string) {
    const s = await this.sdk.use(sid, { mcp: true });
    return { url: s.mcp.url, headers: { ...s.mcp.headers } };
  }

  async connections(sid: string) {
    const s = await this.sdk.use(sid);
    const out: Connection[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 10; page++) {
      const r = await s.toolkits({ isConnected: true, limit: 50, ...(cursor ? { cursor } : {}) });
      for (const it of r.items) {
        const acct = it.connection?.connectedAccount;
        if (acct) out.push({ id: acct.id, toolkit: it.slug, status: acct.status });
      }
      if (!r.cursor) break;
      cursor = r.cursor;
    }
    return out;
  }

  async link(sid: string, toolkit: string, callbackUrl?: string) {
    const s = await this.sdk.use(sid);
    const req = await s.authorize(toolkit, callbackUrl ? { callbackUrl } : undefined);
    return { url: req.redirectUrl ?? "", id: req.id };
  }

  async disconnect(accountId: string) {
    await this.sdk.connectedAccounts.delete(accountId);
  }

  async deleteSession(sid: string) {
    await this.sdk.sessions.delete(sid);
  }

  // The API client under the SDK (`getClient().toolkits.list`), not `sdk.toolkits.get({...})`: that one answers a
  // bare array (no `next_cursor`, so only one page can be read) and has no `type` / `include_deprecated` filter.
  async listToolkits() {
    const client = this.sdk.getClient();
    const out: ListedToolkit[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 50; page++) {
      const r = await client.toolkits.list({
        type: "native",
        include_deprecated: false,
        sort_by: "alphabetically",
        limit: 500,
        ...(cursor ? { cursor } : {}),
      });
      for (const it of r.items) {
        out.push({
          slug: it.slug,
          name: it.name,
          description: it.meta?.description ?? "",
          logo: it.meta?.logo ?? "",
          categories: (it.meta?.categories ?? []).map((c) => c.name),
          authSchemes: it.auth_schemes ?? [],
          managedAuthSchemes: it.composio_managed_auth_schemes ?? [],
          noAuth: it.no_auth === true,
          tools: it.meta?.tools_count ?? 0,
        });
      }
      if (!r.next_cursor) break;
      cursor = r.next_cursor;
    }
    return out;
  }
}

type Cached = { sid: string; url: string };

/** In-process MCP header cache (never persisted). */
const headerCache = new Map<string, McpTarget>();

export function sessKey(userId: string) {
  return `sess:${userId}`;
}

export async function cachedSession(kv: KV, userId: string): Promise<Cached | null> {
  const raw = await kv.get(sessKey(userId));
  if (!raw) return null;
  try {
    const v = JSON.parse(raw) as Partial<Cached>;
    return typeof v.sid === "string" && typeof v.url === "string" ? { sid: v.sid, url: v.url } : null;
  } catch {
    return null;
  }
}

export async function storeSession(kv: KV, gw: ComposioGateway, cfg: RelayConfig, userId: string): Promise<Cached> {
  const s = await gw.createSession(userId, cfg.allowedToolkits);
  headerCache.set(s.sid, { url: s.url, headers: s.headers });
  const v: Cached = { sid: s.sid, url: s.url };
  await kv.set(sessKey(userId), JSON.stringify(v), SESSION_TTL_SECONDS);
  return v;
}

export async function targetFor(gw: ComposioGateway, s: Cached): Promise<McpTarget> {
  const hit = headerCache.get(s.sid);
  if (hit && hit.url === s.url) return hit;
  const t = await gw.mcpTarget(s.sid);
  headerCache.set(s.sid, t);
  return t;
}

export async function dropSession(kv: KV, userId: string, sid?: string) {
  if (sid) headerCache.delete(sid);
  await kv.del(sessKey(userId));
}

export function resetHeaderCache() {
  headerCache.clear();
}

/**
 * `toolkits` of GET /v1/connections: the allow-list when one is set, else the eight apps of the first releases (what
 * app versions up to 0.0.7 show). It does not limit newer apps: with `all` they offer their whole bundled catalog.
 */
export function visibleToolkits(cfg: RelayConfig): string[] {
  return cfg.allowedToolkits === "*" ? DEFAULT_TOOLKITS : cfg.allowedToolkits;
}

/** True when any valid toolkit slug can be linked (no RELAY_ALLOWED_TOOLKITS list). */
export function allToolkits(cfg: RelayConfig): boolean {
  return cfg.allowedToolkits === "*";
}
