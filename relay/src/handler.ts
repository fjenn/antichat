// Shared request pipeline for every api/v1 route: config → kill switch → stub key → client version →
// install identity → route handler → one structured log line. Errors are JSON {code} bodies (architecture §8.4).
import { Redis } from "@upstash/redis";
import { cachedSession, SdkGateway, storeSession, type ComposioGateway } from "./composio.js";
import { deriveUserId, installIdFrom, networkKey } from "./identity.js";
import { logConfigError, logConfigNotice, logRequest, uid8 } from "./log.js";
import { belowMinVersion, ConfigError, loadConfig, type RelayConfig } from "./policy.js";
import { makeLimiters, retryAfterSeconds, type Limiters, type LimitResult } from "./ratelimit.js";
import { MemoryKV, UpstashKV, type KV } from "./store.js";
import type { CatalogCache } from "./toolkits.js";

export type RelayContext = {
  cfg: RelayConfig;
  kv: KV;
  limiters: Limiters;
  /** GET /v1/toolkits: the list kept in this instance's memory (src/toolkits.ts). */
  catalog: CatalogCache;
  /** Only built when a real (non-stub) key is configured. */
  gateway(): ComposioGateway;
};

export type ErrorCode =
  | "relay.notConfigured"
  | "relay.rateLimited"
  | "relay.overCapacity"
  | "relay.disabled"
  | "relay.updateRequired"
  | "relay.badRequest"
  | "relay.notFound"
  | "relay.upstream"
  | "relay.misconfigured";

let current: RelayContext | undefined;

export function buildContext(env: Record<string, string | undefined> = process.env, gateway?: ComposioGateway): RelayContext {
  const cfg = loadConfig(env);
  let kv: KV;
  let limiters: Limiters;
  if (cfg.upstash) {
    const redis = new Redis({ url: cfg.upstash.url, token: cfg.upstash.token });
    kv = new UpstashKV(redis);
    limiters = makeLimiters(cfg, { redis });
  } else {
    if (cfg.production) logConfigNotice("relay.limitsPerInstance");
    const mem = new MemoryKV();
    kv = mem;
    limiters = makeLimiters(cfg, { memory: mem });
  }
  let gw = gateway;
  return {
    cfg,
    kv,
    limiters,
    catalog: {},
    gateway() {
      if (!gw) {
        if (!cfg.composioKey) throw new Error("not configured");
        gw = new SdkGateway(cfg.composioKey, cfg.composioBaseUrl);
      }
      return gw;
    },
  };
}

/** The process-wide context (built from process.env on first use). Tests install their own. */
export function getContext(): RelayContext {
  if (!current) current = buildContext();
  return current;
}

export function setContext(ctx: RelayContext | undefined) {
  current = ctx;
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

export function fail(status: number, code: ErrorCode, headers: Record<string, string> = {}): Response {
  return json(status, { code }, headers);
}

export function rateLimited(r: LimitResult): Response {
  return fail(429, "relay.rateLimited", { "retry-after": String(retryAfterSeconds(r.reset)) });
}

export type Caller = { ctx: RelayContext; userId: string; net: string };

type Options = { auth: boolean };

export function route(
  name: string,
  opts: Options,
  handler: (req: Request, caller: Caller | { ctx: RelayContext }) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    const t0 = performance.now();
    let userId: string | null = null;
    let res: Response;
    try {
      let ctx: RelayContext;
      try {
        ctx = getContext();
      } catch (e) {
        if (!(e instanceof ConfigError)) throw e;
        logConfigError("relay.misconfigured");
        res = fail(500, "relay.misconfigured");
        return res;
      }
      if (!opts.auth) {
        res = await handler(req, { ctx });
        return res;
      }
      const cfg = ctx.cfg;
      if (cfg.disabled) return (res = fail(503, "relay.disabled"));
      if (!cfg.composioKey) return (res = fail(503, "relay.notConfigured"));
      if (belowMinVersion(req.headers.get("x-antichat-version"), cfg.minClientVersion)) {
        return (res = fail(426, "relay.updateRequired"));
      }
      const installId = installIdFrom(req.headers);
      if (!installId) return (res = fail(400, "relay.badRequest"));
      userId = deriveUserId(cfg.hmacSecret, installId);
      res = await handler(req, { ctx, userId, net: networkKey(cfg.hmacSecret, req.headers) });
      return res;
    } catch {
      // Upstream (Composio) or store failure. Nothing about the request or the error text is logged.
      res = fail(502, "relay.upstream");
      return res;
    } finally {
      logRequest({ route: name, status: res!.status, latency_ms: performance.now() - t0, uid8: uid8(userId) });
    }
  };
}

export function isCaller(c: Caller | { ctx: RelayContext }): c is Caller {
  return "userId" in c;
}

/**
 * The caller's ToolRouter session: the cached `sess:<userId>` or a new one. A create counts against the
 * per-install session limit and, when this install has no session yet, the per-network new-ID limit.
 */
export async function ensureSession(c: Caller): Promise<{ sid: string; url: string; fresh?: true } | Response> {
  const { ctx, userId } = c;
  const hit = await cachedSession(ctx.kv, userId);
  if (hit) return hit;
  const ids = await ctx.limiters.newid.limit(c.net);
  if (!ids.success) return rateLimited(ids);
  const s = await ctx.limiters.session.limit(userId);
  if (!s.success) return rateLimited(s);
  return { ...(await storeSession(ctx.kv, ctx.gateway(), ctx.cfg, userId)), fresh: true };
}
