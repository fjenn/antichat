// No-login dev adapter (M7.md §0.1 item 2): node:http on http://127.0.0.1:3000 (PORT overrides) mounting the same
// api/v1/* handlers Vercel runs. Env: the process env, over relay/.env.local (make-env.ts) or, when that file does
// not exist, relay/.env.test. With RELAY_LOCAL_MOCK=1 (set in .env.test) it also starts test/mock-composio.ts on
// RELAY_MOCK_PORT (default 4010) and points COMPOSIO_BASE_URL at it, so the app's integration-stub tests run with
// no Composio account and no network. Refuses to start when the config is invalid (production rules included).
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";
import { readEnvFile } from "./env-file.js";

type Handler = (req: Request) => Promise<Response>;
type Module = Partial<Record<"GET" | "POST" | "DELETE", Handler>>;

const here = dirname(fileURLToPath(import.meta.url));
export const RELAY_DIR = resolve(here, "..");

async function routes(): Promise<{ match: RegExp; mod: Module }[]> {
  const imp = (p: string) => import(join(RELAY_DIR, "api/v1", p)) as Promise<Module>;
  return [
    { match: /^\/v1\/health$/, mod: await imp("health.ts") },
    { match: /^\/v1\/session$/, mod: await imp("session.ts") },
    { match: /^\/v1\/mcp$/, mod: await imp("mcp.ts") },
    { match: /^\/v1\/forget$/, mod: await imp("forget.ts") },
    { match: /^\/v1\/toolkits$/, mod: await imp("toolkits.ts") },
    { match: /^\/v1\/connections$/, mod: await imp("connections/index.ts") },
    { match: /^\/v1\/connections\/link$/, mod: await imp("connections/link.ts") },
    { match: /^\/v1\/connections\/[^/]+$/, mod: await imp("connections/[id].ts") },
  ];
}

function toRequest(req: IncomingMessage, origin: string, signal: AbortSignal): Request {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (Array.isArray(v)) v.forEach((x) => headers.append(k, x));
    else if (v !== undefined) headers.set(k, v);
  }
  if (!headers.has("x-forwarded-for")) headers.set("x-forwarded-for", req.socket.remoteAddress ?? "127.0.0.1");
  const method = req.method ?? "GET";
  const hasBody = method !== "GET" && method !== "HEAD";
  return new Request(new URL(req.url ?? "/", origin), {
    method,
    headers,
    body: hasBody ? (Readable.toWeb(req) as ReadableStream) : undefined,
    duplex: "half",
    signal,
  } as RequestInit);
}

async function writeResponse(res: ServerResponse, r: Response) {
  const headers: Record<string, string> = {};
  r.headers.forEach((v, k) => (headers[k] = v));
  res.writeHead(r.status, headers);
  if (!r.body) return void res.end();
  const reader = r.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    res.write(value);
  }
  res.end();
}

/** HTTP server over the api/v1 handlers. Call after process.env holds the relay config. */
export async function createLocalServer(): Promise<Server> {
  const table = await routes();
  return createServer((req, res) => {
    const ac = new AbortController();
    res.on("close", () => ac.abort());
    const origin = `http://${req.headers.host ?? "127.0.0.1"}`;
    const path = new URL(req.url ?? "/", origin).pathname;
    const hit = table.find((t) => t.match.test(path));
    const h = hit?.mod[(req.method ?? "GET") as "GET" | "POST" | "DELETE"];
    const answer = h
      ? h(toRequest(req, origin, ac.signal))
      : Promise.resolve(new Response(JSON.stringify({ code: hit ? "relay.badRequest" : "relay.notFound" }), {
          status: hit ? 405 : 404,
          headers: { "content-type": "application/json" },
        }));
    answer.then((r) => writeResponse(res, r)).catch(() => {
      if (!res.headersSent) res.writeHead(500);
      res.end();
    });
  });
}

async function main() {
  const local = join(RELAY_DIR, ".env.local");
  const file = existsSync(local) ? local : join(RELAY_DIR, ".env.test");
  for (const [k, v] of Object.entries(readEnvFile(file))) if (process.env[k] === undefined) process.env[k] = v;

  if (process.env.RELAY_LOCAL_MOCK === "1") {
    const { startMockComposio } = await import("../test/mock-composio.js");
    const mock = await startMockComposio({ port: Number(process.env.RELAY_MOCK_PORT ?? 4010) });
    process.env.COMPOSIO_BASE_URL = mock.url;
    process.stdout.write(`relay-dev: mock Composio on ${mock.url}\n`);
  }

  const { loadConfig, ConfigError } = await import("../src/policy.js");
  try {
    loadConfig();
  } catch (e) {
    if (e instanceof ConfigError) {
      process.stderr.write(`relay-dev: refusing to start: ${e.reason}\n`);
      process.exit(1);
    }
    throw e;
  }
  const port = Number(process.env.PORT ?? 3000);
  const server = await createLocalServer();
  server.listen(port, "127.0.0.1", () =>
    process.stdout.write(`relay-dev: http://127.0.0.1:${port} (env ${file.endsWith(".env.local") ? ".env.local" : ".env.test"})\n`),
  );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) void main();
