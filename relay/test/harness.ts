// Test harness: mock Composio + the relay's api/v1 handlers behind scripts/local-server.ts, env from .env.test.
// Used by the vitest suites and by scripts/dump-keys.ts (full mocked session → key dump, AT-255 c6).
import type { Server } from "node:http";
import { join } from "node:path";
import { readEnvFile } from "../scripts/env-file.js";
import { createLocalServer, RELAY_DIR } from "../scripts/local-server.js";
import { resetHeaderCache } from "../src/composio.js";
import { buildContext, setContext, type RelayContext } from "../src/handler.js";
import { MemoryKV } from "../src/store.js";
import { startMockComposio, type MockComposio } from "./mock-composio.js";

export const INSTALL_A = "3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e";
export const INSTALL_B = "a1b2c3d4-e5f6-4a7b-9c8d-0e1f2a3b4c5d";

export type Harness = {
  mock: MockComposio;
  ctx: RelayContext;
  base: string;
  call(path: string, init?: RequestInit & { install?: string | null; version?: string }): Promise<Response>;
  /** JSON-RPC over /v1/mcp, carrying Mcp-Session-Id once the server issued one. */
  rpc(install: string, msg: Record<string, unknown>): Promise<Response>;
  close(): Promise<void>;
};

export function testEnv(overrides: Record<string, string | undefined> = {}): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...readEnvFile(join(RELAY_DIR, ".env.test")) };
  delete env.UPSTASH_REDIS_REST_URL;
  delete env.UPSTASH_REDIS_REST_TOKEN;
  return { ...env, ...overrides };
}

export async function startHarness(overrides: Record<string, string | undefined> = {}): Promise<Harness> {
  const mock = await startMockComposio({ port: 0 });
  const env = testEnv({ COMPOSIO_BASE_URL: mock.url, ...overrides });
  // The SDK reads COMPOSIO_ALLOW_INSECURE_HTTP from the process env (plain-HTTP loopback mock).
  process.env.COMPOSIO_ALLOW_INSECURE_HTTP = "1";
  resetHeaderCache();
  const ctx = buildContext(env);
  setContext(ctx);
  const server: Server = await createLocalServer();
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  const addr = server.address();
  const base = `http://127.0.0.1:${typeof addr === "object" && addr ? addr.port : 0}`;
  const mcpSessions = new Map<string, string>();

  const call: Harness["call"] = (path, init = {}) => {
    const { install = INSTALL_A, version = "0.7.0", headers, ...rest } = init;
    const h = new Headers(headers);
    if (install) h.set("x-antichat-install", install);
    h.set("x-antichat-version", version);
    h.set("user-agent", `AntiChat/${version}`);
    return fetch(base + path, { ...rest, headers: h });
  };

  return {
    mock,
    ctx,
    base,
    call,
    async rpc(install, msg) {
      const headers: Record<string, string> = {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "mcp-protocol-version": "2025-11-25",
      };
      const sid = mcpSessions.get(install);
      if (sid) headers["mcp-session-id"] = sid;
      const r = await call("/v1/mcp", { method: "POST", body: JSON.stringify(msg), headers, install });
      const got = r.headers.get("mcp-session-id");
      if (got) mcpSessions.set(install, got);
      return r;
    },
    async close() {
      setContext(undefined);
      server.closeAllConnections();
      await new Promise<void>((ok) => server.close(() => ok()));
      await mock.close();
    },
  };
}

/** The fixture conversation (readonly + send) driven through the relay, plus every connections route. */
export async function runFullSession(h: Harness, install = INSTALL_A): Promise<Record<string, number>> {
  const statuses: Record<string, number> = {};
  const note = async (name: string, r: Response) => {
    statuses[name] = r.status;
    await r.text();
  };
  await note("health", await h.call("/v1/health", { install: null }));
  await note("session", await h.call("/v1/session", { method: "POST", install }));
  await note("initialize", await h.rpc(install, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "AntiChat", version: "0.7.0" } } }));
  await note("initialized", await h.rpc(install, { jsonrpc: "2.0", method: "notifications/initialized" }));
  await note("tools/list", await h.rpc(install, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }));
  await note("search", await h.rpc(install, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "COMPOSIO_SEARCH_TOOLS", arguments: { queries: [{ use_case: "find my unread emails from this week" }] } } }));
  await note("fetch", await h.rpc(install, { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "COMPOSIO_MULTI_EXECUTE_TOOL", arguments: { tools: [{ tool_slug: "GMAIL_FETCH_EMAILS", arguments: { query: "is:unread newer_than:7d", max_results: 10 } }] } } }));
  await note("send", await h.rpc(install, { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "COMPOSIO_MULTI_EXECUTE_TOOL", arguments: { tools: [{ tool_slug: "GMAIL_SEND_EMAIL", arguments: { recipient_email: "reader@example.com", subject: "Moss sample results", body: "The moss sample from the north wall came back healthy." } }] } } }));
  const link = await h.call("/v1/connections/link", { method: "POST", install, body: JSON.stringify({ toolkit: "gmail" }), headers: { "content-type": "application/json" } });
  statuses["link"] = link.status;
  const { url, id } = (await link.json()) as { url: string; id: string };
  await note("hosted-auth", await fetch(url, { redirect: "manual" }));
  await note("connections", await h.call("/v1/connections", { install }));
  await note("disconnect", await h.call(`/v1/connections/${id}`, { method: "DELETE", install }));
  await note("mcp-delete", await h.call("/v1/mcp", { method: "DELETE", install }));
  return statuses;
}

export function isMemory(kv: unknown): kv is MemoryKV {
  return kv instanceof MemoryKV;
}
