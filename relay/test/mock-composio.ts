// Local mock of the Composio backend for relay tests and `make relay-dev` (M7.T10, AT-255). Implements the REST calls
// @composio/core 0.27.0 (via @composio/client 2.0.0-rc.19) makes for the relay's flows, read from
// node_modules/@composio/core/src/models/{ToolRouter,ToolRouterSession}.ts, lib/toolRouterSessionDelete.ts and
// @composio/client dist/session-*.mjs:
//   POST   /api/v3.1/tool_router/session                 composio.create(userId, {...})
//   GET    /api/v3.1/tool_router/session/{sid}           composio.use(sid)
//   GET    /api/v3.1/tool_router/session/{sid}/toolkits  session.toolkits()
//   POST   /api/v3.1/tool_router/session/{sid}/link      session.authorize(toolkit)
//   DELETE /api/v3.1/tool_router/session/{sid}           composio.sessions.delete(sid)
//   DELETE /api/v3.1/connected_accounts/{id}             composio.connectedAccounts.delete(id)
// plus session.mcp.url = <base>/tool_router/{sid}/mcp, a Streamable-HTTP MCP endpoint that replays
// fixtures/web/mcp/composio-*.jsonl, and <base>/link/{id}, a local "hosted auth" page that activates the
// connection and redirects to the callback URL. Loopback only; no network.
//
// Run standalone: npx tsx test/mock-composio.ts [--port 4010]
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const MOCK_KEY = "test-mock-key";

type FixtureLine = { request: { method: string; params?: { name?: string; arguments?: { tools?: { tool_slug?: string }[] } } }; response: Record<string, unknown> | null };
type Account = { id: string; userId: string; toolkit: string; status: "INITIATED" | "ACTIVE"; callback?: string };
type Sess = { sid: string; userId: string; toolkits: string[] | undefined; mcpSession?: string };

export type MockLogEntry = { method: string; path: string; auth: boolean; rpc?: string };

export type MockComposio = {
  url: string;
  port: number;
  log: MockLogEntry[];
  sessions: Map<string, Sess>;
  accounts: Map<string, Account>;
  /** Mark a linked account ACTIVE (what the hosted auth page does). */
  activate(id: string): void;
  /** All string values found in the fixture responses (for "no content stored" assertions). */
  fixturePhrases(): string[];
  close(): Promise<void>;
};

export function fixturesDir(): string {
  if (process.env.ANTICHAT_FIXTURES) return resolve(process.env.ANTICHAT_FIXTURES);
  const here = dirname(fileURLToPath(import.meta.url));
  return resolve(here, "../../fixtures");
}

export function loadFixtureLines(dir = fixturesDir()): FixtureLine[] {
  const out: FixtureLine[] = [];
  for (const f of ["composio-gmail-readonly.jsonl", "composio-gmail-send.jsonl"]) {
    const text = readFileSync(join(dir, "web/mcp", f), "utf8");
    for (const l of text.split("\n")) if (l.trim()) out.push(JSON.parse(l) as FixtureLine);
  }
  return out;
}

function matchKey(m: FixtureLine["request"]): string {
  const name = m.params?.name ?? "";
  const slug = m.params?.arguments?.tools?.[0]?.tool_slug ?? "";
  return [m.method, name, slug].join("|");
}

function collectStrings(v: unknown, out: Set<string>) {
  if (typeof v === "string") {
    out.add(v);
    if (v.startsWith("{")) {
      try {
        collectStrings(JSON.parse(v), out);
      } catch {
        /* plain text */
      }
    }
  } else if (Array.isArray(v)) v.forEach((x) => collectStrings(x, out));
  else if (v && typeof v === "object") Object.values(v).forEach((x) => collectStrings(x, out));
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((ok, bad) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => ok(Buffer.concat(chunks).toString("utf8")));
    req.on("error", bad);
  });
}

function send(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(body === undefined ? "" : JSON.stringify(body));
}

export async function startMockComposio(opts: { port?: number; apiKey?: string; fixtures?: string } = {}): Promise<MockComposio> {
  const apiKey = opts.apiKey ?? MOCK_KEY;
  const lines = loadFixtureLines(opts.fixtures);
  const byKey = new Map<string, FixtureLine>();
  for (const l of lines) if (!byKey.has(matchKey(l.request))) byKey.set(matchKey(l.request), l);
  const sessions = new Map<string, Sess>();
  const accounts = new Map<string, Account>();
  const log: MockLogEntry[] = [];
  let base = "";

  const sessionBody = (s: Sess) => ({
    session_id: s.sid,
    mcp: { type: "http", url: `${base}/tool_router/${s.sid}/mcp` },
    config: { user_id: s.userId, toolkits: s.toolkits ? { enable: s.toolkits } : undefined, manage_connections: { enable: true } },
    config_version: 1,
    warnings: [],
    tool_router_tools: ["COMPOSIO_SEARCH_TOOLS", "COMPOSIO_MULTI_EXECUTE_TOOL", "COMPOSIO_MANAGE_CONNECTIONS"],
  });

  const toolkitItem = (a: Account) => ({
    slug: a.toolkit,
    name: a.toolkit.charAt(0).toUpperCase() + a.toolkit.slice(1),
    meta: { logo: `${base}/logos/${a.toolkit}.png` },
    is_no_auth: false,
    connected_account: {
      id: a.id,
      status: a.status,
      auth_config: { id: `ac_mock_${a.toolkit}`, auth_scheme: "OAUTH2", is_composio_managed: true },
    },
  });

  async function rest(req: IncomingMessage, res: ServerResponse, path: string) {
    const m = req.method ?? "GET";
    let mm: RegExpExecArray | null;
    if (m === "POST" && path === "/api/v3.1/tool_router/session") {
      const body = JSON.parse((await readBody(req)) || "{}") as { user_id?: string; toolkits?: { enable?: string[] } | string[] };
      if (!body.user_id) return send(res, 400, { error: { message: "user_id required" } });
      const tk = Array.isArray(body.toolkits) ? body.toolkits : body.toolkits?.enable;
      const s: Sess = { sid: "trs_" + randomBytes(6).toString("hex"), userId: body.user_id, toolkits: tk };
      sessions.set(s.sid, s);
      return send(res, 201, sessionBody(s));
    }
    if ((mm = /^\/api\/v3\.1\/tool_router\/session\/([^/]+)(\/[a-z_]+)?$/.exec(path))) {
      const s = sessions.get(decodeURIComponent(mm[1] ?? ""));
      if (!s) return send(res, 404, { error: { message: "session not found" } });
      const sub = mm[2];
      if (!sub && m === "GET") return send(res, 200, sessionBody(s));
      if (!sub && m === "DELETE") {
        sessions.delete(s.sid);
        return send(res, 200, { session_id: s.sid, deleted: true });
      }
      if (sub === "/toolkits" && m === "GET") {
        const items = [...accounts.values()].filter((a) => a.userId === s.userId).map(toolkitItem);
        return send(res, 200, { items, next_cursor: null, total_pages: 1, current_page: 1, total_items: items.length });
      }
      if (sub === "/link" && m === "POST") {
        const body = JSON.parse((await readBody(req)) || "{}") as { toolkit?: string; callback_url?: string };
        const a: Account = { id: "ca_" + randomBytes(6).toString("hex"), userId: s.userId, toolkit: body.toolkit ?? "", status: "INITIATED", callback: body.callback_url };
        accounts.set(a.id, a);
        return send(res, 200, { connected_account_id: a.id, redirect_url: `${base}/link/${a.id}`, link_token: "lt_" + a.id });
      }
    }
    if ((mm = /^\/api\/v3\.1\/connected_accounts\/([^/]+)$/.exec(path)) && m === "DELETE") {
      const id = decodeURIComponent(mm[1] ?? "");
      if (!accounts.delete(id)) return send(res, 404, { error: { message: "not found" } });
      return send(res, 200, { success: true });
    }
    return send(res, 404, { error: { message: `mock: no route ${m} ${path}` } });
  }

  async function mcp(req: IncomingMessage, res: ServerResponse, sid: string) {
    const s = sessions.get(sid);
    if (!s) return send(res, 404, { error: "unknown session" });
    // Headers an upstream could send that the relay must never pass to the app.
    const leak = { "set-cookie": "composio_session=secret; HttpOnly", "www-authenticate": "Bearer realm=composio", "x-api-key": apiKey };
    const m = req.method ?? "GET";
    if (m === "GET") return send(res, 405, { error: "SSE stream not offered" }, leak);
    if (m === "DELETE") {
      s.mcpSession = undefined;
      return send(res, 200, {}, leak);
    }
    const msg = JSON.parse((await readBody(req)) || "null") as FixtureLine["request"] & { id?: number | string };
    log[log.length - 1]!.rpc = msg?.method;
    const hit = msg ? byKey.get(matchKey(msg)) : undefined;
    const sessionHeader: Record<string, string> = {};
    if (msg?.method === "initialize") {
      s.mcpSession = "mcp_" + randomBytes(6).toString("hex");
      sessionHeader["mcp-session-id"] = s.mcpSession;
    } else if (s.mcpSession && req.headers["mcp-session-id"] !== s.mcpSession) {
      return send(res, 400, { jsonrpc: "2.0", id: msg?.id ?? null, error: { code: -32000, message: "bad mcp-session-id" } });
    }
    if (!hit) {
      return send(res, 200, { jsonrpc: "2.0", id: msg?.id ?? null, error: { code: -32601, message: "not in fixture" } }, { ...leak, ...sessionHeader });
    }
    if (hit.response === null) {
      res.writeHead(202, { ...leak, ...sessionHeader });
      return res.end();
    }
    const body = { ...hit.response, id: msg.id };
    const accept = String(req.headers.accept ?? "");
    if (accept.includes("text/event-stream") && !accept.includes("application/json")) {
      res.writeHead(200, { "content-type": "text/event-stream", ...leak, ...sessionHeader });
      res.end(`event: message\ndata: ${JSON.stringify(body)}\n\n`);
      return;
    }
    return send(res, 200, body, { ...leak, ...sessionHeader });
  }

  function linkPage(res: ServerResponse, id: string) {
    const a = accounts.get(id);
    if (!a) return send(res, 404, { error: "unknown link" });
    a.status = "ACTIVE";
    if (a.callback) {
      const u = new URL(a.callback);
      u.searchParams.set("status", "success");
      u.searchParams.set("connected_account_id", a.id);
      res.writeHead(302, { location: u.toString() });
      return res.end();
    }
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(`<!doctype html><title>Mock Composio</title><p>Connected ${a.toolkit} (mock). You can close this tab.</p>`);
  }

  const server: Server = createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const path = url.pathname;
    const auth = req.headers["x-api-key"] === apiKey;
    log.push({ method: req.method ?? "GET", path, auth });
    const done = (p: unknown) =>
      Promise.resolve(p).catch(() => {
        if (!res.headersSent) send(res, 500, { error: "mock failure" });
      });
    let mm: RegExpExecArray | null;
    if ((mm = /^\/link\/([^/]+)$/.exec(path))) return void done(linkPage(res, mm[1] ?? ""));
    if (!auth) return send(res, 401, { error: { message: "invalid api key" } });
    if ((mm = /^\/tool_router\/([^/]+)\/mcp$/.exec(path))) return void done(mcp(req, res, mm[1] ?? ""));
    return void done(rest(req, res, path));
  });

  await new Promise<void>((ok) => server.listen(opts.port ?? 0, "127.0.0.1", ok));
  const addr = server.address();
  const port = typeof addr === "object" && addr ? addr.port : 0;
  base = `http://127.0.0.1:${port}`;

  return {
    url: base,
    port,
    log,
    sessions,
    accounts,
    activate(id) {
      const a = accounts.get(id);
      if (a) a.status = "ACTIVE";
    },
    fixturePhrases() {
      const set = new Set<string>();
      for (const l of lines) collectStrings(l.response, set);
      return [...set].filter((s) => s.length >= 12);
    },
    close: () =>
      new Promise<void>((ok) => {
        server.closeAllConnections();
        server.close(() => ok());
      }),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const i = process.argv.indexOf("--port");
  const port = i > 0 ? Number(process.argv[i + 1]) : 4010;
  startMockComposio({ port }).then((m) => process.stdout.write(`mock composio on ${m.url}\n`));
}
