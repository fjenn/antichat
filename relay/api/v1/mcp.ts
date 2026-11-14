// POST/GET/DELETE /v1/mcp — Streamable-HTTP MCP pass-through to the install's ToolRouter session (M7.T10 step 3).
// Tool permission is enforced in the app before a call is sent (architecture §8.2); the relay only meters.
import { dropSession, targetFor } from "../../src/composio.js";
import { ensureSession, fail, isCaller, rateLimited, route, type Caller } from "../../src/handler.js";
import { forward } from "../../src/proxy.js";
import { countToolCalls } from "../../src/ratelimit.js";

const MAX_BODY = 1 << 20;

async function handle(method: "GET" | "POST" | "DELETE", req: Request, c: Caller): Promise<Response> {
  const { ctx, userId } = c;
  const r = await ctx.limiters.mcp.limit(userId);
  if (!r.success) return rateLimited(r);

  let body: string | null = null;
  if (method === "POST") {
    body = await req.text();
    if (Buffer.byteLength(body) > MAX_BODY) return fail(413, "relay.badRequest");
    const calls = countToolCalls(body);
    if (calls > 0) {
      const g = await ctx.limiters.global.limit("all", calls);
      if (!g.success) return fail(503, "relay.overCapacity");
      const e = await ctx.limiters.exec.limit(userId, calls);
      if (!e.success) return rateLimited(e);
    }
  }

  const s = await ensureSession(c);
  if (s instanceof Response) return s;
  // A new ToolRouter session (cache miss: TTL, or a cold instance when the store is per instance) cannot know the
  // client's Mcp-Session-Id: answer 404 so the client re-initializes (MCP Streamable HTTP; the app's transport
  // maps it to sessionExpired) instead of sending a stale id upstream.
  if (s.fresh && req.headers.get("mcp-session-id")) return fail(404, "relay.notFound");
  const target = await targetFor(ctx.gateway(), s);
  const res = await forward(method, req.headers, body, target, req.signal);
  // An expired/unknown upstream session: forget the cache so the next request creates a fresh one.
  if (res.status === 404 || res.status === 401) await dropSession(ctx.kv, userId, s.sid);
  return res;
}

const make = (m: "GET" | "POST" | "DELETE") =>
  route("mcp", { auth: true }, async (req, c) => {
    if (!isCaller(c)) throw new Error("unreachable");
    return handle(m, req, c);
  });

export const POST = make("POST");
export const GET = make("GET");
export const DELETE = make("DELETE");
