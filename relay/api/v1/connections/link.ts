// POST /v1/connections/link {toolkit[, callback_url]} → {url, id}: the Composio hosted auth URL the app opens in
// the user's browser (M7.T10 step 4). Toolkit must be on RELAY_ALLOWED_TOOLKITS; 10 attempts/h per install.
import { ensureSession, fail, isCaller, json, rateLimited, route } from "../../../src/handler.js";
import { toolkitAllowed } from "../../../src/policy.js";

/** Callback targets the relay passes on: the app's URL scheme or a loopback page (dev/mock). */
function callbackOk(u: string): boolean {
  try {
    const url = new URL(u);
    if (url.protocol === "antichat:") return true;
    return (url.protocol === "http:" || url.protocol === "https:") && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname);
  } catch {
    return false;
  }
}

export const POST = route("connections.link", { auth: true }, async (req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  let body: { toolkit?: unknown; callback_url?: unknown };
  try {
    body = (await req.json()) as typeof body;
  } catch {
    return fail(400, "relay.badRequest");
  }
  const toolkit = typeof body?.toolkit === "string" ? body.toolkit.toLowerCase() : "";
  if (!toolkitAllowed(c.ctx.cfg, toolkit)) return fail(400, "relay.badRequest");
  const cb = body.callback_url;
  if (cb !== undefined && (typeof cb !== "string" || !callbackOk(cb))) return fail(400, "relay.badRequest");

  const r = await c.ctx.limiters.link.limit(c.userId);
  if (!r.success) return rateLimited(r);
  const s = await ensureSession(c);
  if (s instanceof Response) return s;
  const link = await c.ctx.gateway().link(s.sid, toolkit, cb as string | undefined);
  return json(200, link);
});
