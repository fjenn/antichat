// Rate limits (architecture §8.4, M7.T10 step 5; K-NEW-C024-2). Sliding windows via @upstash/ratelimit 2.2.0 on
// Upstash Redis in production; in dev/test (no Upstash vars) an in-memory sliding window with the same algorithm
// (weighted previous + current fixed window) and the same key shape `<prefix>:<identifier>:<window>`.
import { Ratelimit } from "@upstash/ratelimit";
import type { Redis } from "@upstash/redis";
import type { RelayConfig } from "./policy.js";
import { MemoryKV } from "./store.js";

export type LimitResult = { success: boolean; limit: number; remaining: number; reset: number };

export interface Limiter {
  limit(identifier: string, rate?: number): Promise<LimitResult>;
}

export type LimiterName = "mcp" | "exec" | "session" | "link" | "newid" | "global";
export type Limiters = Record<LimiterName, Limiter>;

type Spec = { tokens: number; windowMs: number; window: `${number} ${"m" | "h"}` };

const MIN = 60_000;
const HOUR = 60 * MIN;

export function specs(cfg: RelayConfig): Record<LimiterName, Spec> {
  const l = cfg.limits;
  return {
    mcp: { tokens: l.mcpPerMin, windowMs: MIN, window: "1 m" },
    exec: { tokens: l.executionsPerDay, windowMs: 24 * HOUR, window: "24 h" },
    session: { tokens: l.sessionsPerHour, windowMs: HOUR, window: "1 h" },
    link: { tokens: l.linksPerHour, windowMs: HOUR, window: "1 h" },
    newid: { tokens: l.newIdsPerIpPerHour, windowMs: HOUR, window: "1 h" },
    global: { tokens: l.globalDailyCap, windowMs: 24 * HOUR, window: "24 h" },
  };
}

/** Same algorithm as Ratelimit.slidingWindow (upstash/ratelimit-js src/single.ts), single process. */
export class MemorySlidingWindow implements Limiter {
  constructor(
    private kv: MemoryKV,
    private prefix: string,
    private tokens: number,
    private windowMs: number,
    private now: () => number = Date.now,
  ) {}

  async limit(identifier: string, rate = 1): Promise<LimitResult> {
    const now = this.now();
    const cur = Math.floor(now / this.windowMs);
    const curKey = `${this.prefix}:${identifier}:${cur}`;
    const prevKey = `${this.prefix}:${identifier}:${cur - 1}`;
    const ttl = Math.ceil((this.windowMs * 2) / 1000);
    const weight = 1 - (now % this.windowMs) / this.windowMs;
    const used = Math.floor(this.kv.peek(prevKey) * weight) + this.kv.peek(curKey);
    const reset = (cur + 1) * this.windowMs;
    if (used + rate > this.tokens) {
      return { success: false, limit: this.tokens, remaining: 0, reset };
    }
    this.kv.incr(curKey, rate, ttl);
    return { success: true, limit: this.tokens, remaining: this.tokens - used - rate, reset };
  }
}

class UpstashLimiter implements Limiter {
  constructor(private rl: Ratelimit) {}
  async limit(identifier: string, rate = 1): Promise<LimitResult> {
    const r = await this.rl.limit(identifier, { rate });
    return { success: r.success, limit: r.limit, remaining: r.remaining, reset: r.reset };
  }
}

export function makeLimiters(cfg: RelayConfig, backend: { redis: Redis } | { memory: MemoryKV }, now?: () => number): Limiters {
  const s = specs(cfg);
  const out = {} as Limiters;
  for (const name of Object.keys(s) as LimiterName[]) {
    const sp = s[name];
    out[name] =
      "redis" in backend
        ? new UpstashLimiter(
            new Ratelimit({
              redis: backend.redis,
              limiter: Ratelimit.slidingWindow(sp.tokens, sp.window),
              prefix: `rl:${name}`,
              analytics: false,
            }),
          )
        : new MemorySlidingWindow(backend.memory, `rl:${name}`, sp.tokens, sp.windowMs, now);
  }
  return out;
}

/** Seconds until the window resets (Retry-After), at least 1. */
export function retryAfterSeconds(reset: number, now = Date.now()): number {
  return Math.max(1, Math.ceil((reset - now) / 1000));
}

/** Number of executions in a JSON-RPC message or batch (0 for anything unparsable): one per `tools/call`, and one per
 * inner slug of a `COMPOSIO_MULTI_EXECUTE_TOOL` batch (M7.T16 review #12: a batch must not count as one call). */
export function countToolCalls(body: string): number {
  if (!body) return 0;
  let msg: unknown;
  try {
    msg = JSON.parse(body);
  } catch {
    return 0;
  }
  const items = Array.isArray(msg) ? msg : [msg];
  let n = 0;
  for (const m of items) {
    if (!m || typeof m !== "object" || (m as { method?: unknown }).method !== "tools/call") continue;
    const params = (m as { params?: { name?: unknown; arguments?: { tools?: unknown } } }).params;
    const inner = params?.name === "COMPOSIO_MULTI_EXECUTE_TOOL" ? params.arguments?.tools : undefined;
    n += Array.isArray(inner) && inner.length > 0 ? inner.length : 1;
  }
  return n;
}
