// DELETE /v1/connections/<id> — disconnect one linked account of this install (M7.T10 step 4). The id must be one
// of this user's own connections; anything else is 404 (no cross-install deletes).
import { ensureSession, fail, isCaller, json, route } from "../../../src/handler.js";

function idFrom(req: Request): string {
  const last = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "";
  return decodeURIComponent(last);
}

export const DELETE = route("connections.delete", { auth: true }, async (req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  const id = idFrom(req);
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(id)) return fail(400, "relay.badRequest");
  const s = await ensureSession(c);
  if (s instanceof Response) return s;
  const gw = c.ctx.gateway();
  const mine = await gw.connections(s.sid);
  if (!mine.some((m) => m.id === id)) return fail(404, "relay.notFound");
  await gw.disconnect(id);
  return json(200, { ok: true });
});
