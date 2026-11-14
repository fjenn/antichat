// GET /v1/connections — the toolkits the app may offer and this install's linked accounts (M7.T10 step 4).
import { visibleToolkits } from "../../../src/composio.js";
import { ensureSession, isCaller, json, route } from "../../../src/handler.js";

export const GET = route("connections", { auth: true }, async (_req, c) => {
  if (!isCaller(c)) throw new Error("unreachable");
  const s = await ensureSession(c);
  if (s instanceof Response) return s;
  const connections = await c.ctx.gateway().connections(s.sid);
  return json(200, { toolkits: visibleToolkits(c.ctx.cfg), connections });
});
