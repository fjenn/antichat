// The relay's only persistent state (M7.T10 step 7, R-255 AC6): `sess:<userId>` (ToolRouter session id + MCP URL,
// 1 h TTL) and the rate-limiter counters (`rl:*`). Upstash Redis in production; an in-memory map in dev/test
// (production refuses to start without Upstash, see policy.ts). No message content is ever written here.
import { Redis } from "@upstash/redis";

export interface KV {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttlSeconds: number): Promise<void>;
  del(key: string): Promise<void>;
  /** Key names (and, for the memory store, values) for scripts/dump-keys.ts. */
  dump(): Promise<Record<string, string>>;
}

type Entry = { value: string; expiresAt: number };

export class MemoryKV implements KV {
  readonly map = new Map<string, Entry>();
  constructor(private now: () => number = Date.now) {}

  private live(key: string): Entry | undefined {
    const e = this.map.get(key);
    if (!e) return undefined;
    if (e.expiresAt <= this.now()) {
      this.map.delete(key);
      return undefined;
    }
    return e;
  }
  async get(key: string) {
    return this.live(key)?.value ?? null;
  }
  async set(key: string, value: string, ttlSeconds: number) {
    this.map.set(key, { value, expiresAt: this.now() + ttlSeconds * 1000 });
  }
  async del(key: string) {
    this.map.delete(key);
  }
  /** Atomic-enough increment for the single-process limiter. */
  incr(key: string, by: number, ttlSeconds: number): number {
    const e = this.live(key);
    const next = (e ? Number(e.value) : 0) + by;
    this.map.set(key, { value: String(next), expiresAt: e?.expiresAt ?? this.now() + ttlSeconds * 1000 });
    return next;
  }
  peek(key: string): number {
    const e = this.live(key);
    return e ? Number(e.value) : 0;
  }
  async dump() {
    const out: Record<string, string> = {};
    for (const k of [...this.map.keys()].sort()) {
      const e = this.live(k);
      if (e) out[k] = e.value;
    }
    return out;
  }
}

export class UpstashKV implements KV {
  constructor(readonly redis: Redis) {}
  async get(key: string) {
    const v = await this.redis.get<string>(key);
    return v == null ? null : typeof v === "string" ? v : JSON.stringify(v);
  }
  async set(key: string, value: string, ttlSeconds: number) {
    await this.redis.set(key, value, { ex: ttlSeconds });
  }
  async del(key: string) {
    await this.redis.del(key);
  }
  /** Key names with their Redis type only: values of limiter keys are counters, sess:* values are not printed. */
  async dump() {
    const out: Record<string, string> = {};
    let cursor: string | number = 0;
    do {
      const [next, keys]: [string | number, string[]] = await this.redis.scan(cursor, { count: 500 });
      for (const k of keys) out[k] = await this.redis.type(k);
      cursor = next;
    } while (String(cursor) !== "0");
    return Object.fromEntries(Object.entries(out).sort(([a], [b]) => a.localeCompare(b)));
  }
}
