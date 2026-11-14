// GET /v1/health — liveness + version, no auth (architecture §8.2).
import { json, route } from "../../src/handler.js";
import { RELAY_VERSION } from "../../src/policy.js";

export const GET = route("health", { auth: false }, async () => json(200, { ok: true, version: RELAY_VERSION }));
