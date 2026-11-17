// GET /v1/toolkits → {generated, toolkits:[{slug, name, description, categories, auth, logo}]}: every app Composio
// offers that a person can connect (src/toolkits.ts), so the app's directory follows Composio without an app update
// or a publishing step. The same answer for every install, kept ~6 h; `ETag` + `If-None-Match` → 304.
// 30 requests/h per install; no ToolRouter session is created.
import { isCaller, rateLimited, route } from "../../src/handler.js";
import { currentCatalog, etagMatches } from "../../src/toolkits.js";

export const GET = route("toolkits", { auth: true }, async (req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  const r = await c.ctx.limiters.catalog.limit(c.userId);
  if (!r.success) return rateLimited(r);
  const entry = await currentCatalog(c.ctx);
  const headers = { etag: entry.etag, "cache-control": "private, max-age=3600" };
  if (etagMatches(req.headers.get("if-none-match"), entry.etag)) return new Response(null, { status: 304, headers });
  return new Response(entry.body, { status: 200, headers: { "content-type": "application/json", ...headers } });
});
