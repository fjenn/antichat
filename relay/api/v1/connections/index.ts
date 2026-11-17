// GET /v1/connections — this install's linked accounts and what may be linked (M7.T10 step 4): `all: true` = any
// Composio toolkit (the app shows its bundled catalog); `toolkits` = the allow-list, or the first releases' eight apps
// when everything is allowed (app versions up to 0.0.7 read only that field).
import { allToolkits, visibleToolkits } from "../../../src/composio.js";
import { ensureSession, isCaller, json, route } from "../../../src/handler.js";

export const GET = route("connections", { auth: true }, async (_req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  const s = await ensureSession(c);
  if (s instanceof Response) return s;
  const connections = await c.ctx.gateway().connections(s.sid);
  return json(200, { toolkits: visibleToolkits(c.ctx.cfg), all: allToolkits(c.ctx.cfg), connections });
});
