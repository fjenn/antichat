// POST /v1/forget — delete this install's Composio state: every connected account of its user, the ToolRouter
// session and the cached sess:<userId> ("Remove everything", uninstall). Limiter counters expire on their own.
import { cachedSession, dropSession } from "../../src/composio.js";
import { ensureSession, isCaller, json, route } from "../../src/handler.js";

export const POST = route("forget", { auth: true }, async (_req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  const { ctx, userId } = c;
  const gw = ctx.gateway();
  const had = await cachedSession(ctx.kv, userId);
  const s = had ?? (await ensureSession(c));
  if (s instanceof Response) return s;
  for (const conn of await gw.connections(s.sid)) await gw.disconnect(conn.id);
  await gw.deleteSession(s.sid);
  await dropSession(ctx.kv, userId, s.sid);
  return json(200, { ok: true });
});
