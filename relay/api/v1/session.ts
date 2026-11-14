// POST /v1/session — create (or reuse the cached) Composio ToolRouter session for this install (M7.T10 step 2).
// Returns only {ok: true}: the Composio MCP URL and headers never leave the relay.
import { ensureSession, isCaller, json, route } from "../../src/handler.js";

export const POST = route("session", { auth: true }, async (_req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  const s = await ensureSession(c);
  if (s instanceof Response) return s;
  return json(200, { ok: true });
});
