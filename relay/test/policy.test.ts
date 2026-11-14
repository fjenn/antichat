// Policy and config rules (M7.T10 step 5; architecture §8.3): production refuses COMPOSIO_BASE_URL, runs per
// instance without Upstash (release 2), ignores (and logs) RELAY_TEST_MCP_PER_MIN; toolkit allow-list; min version; forget.
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildContext } from "../src/handler.js";
import { deriveUserId } from "../src/identity.js";
import { belowMinVersion, ConfigError, DEFAULT_TOOLKITS, loadConfig, toolkitAllowed } from "../src/policy.js";
import { MemoryKV, UpstashKV } from "../src/store.js";
import { INSTALL_A, runFullSession, startHarness, testEnv, type Harness } from "./harness.js";

const PROD = {
  VERCEL_ENV: "production",
  COMPOSIO_API_KEY: "placeholder-not-a-real-key",
  INSTALL_ID_HMAC_SECRET: "p".repeat(64),
  UPSTASH_REDIS_REST_URL: "https://example-upstash.invalid",
  UPSTASH_REDIS_REST_TOKEN: "placeholder-token",
};

let h: Harness | undefined;
afterEach(async () => {
  await h?.close();
  h = undefined;
  vi.restoreAllMocks();
});

describe("production config", () => {
  it("accepts a complete production env and uses Upstash (no network at construction)", () => {
    const cfg = loadConfig(PROD);
    expect(cfg.production).toBe(true);
    expect(cfg.allowedToolkits).toEqual(DEFAULT_TOOLKITS);
    expect(buildContext(PROD).kv).toBeInstanceOf(UpstashKV);
  });

  it("refuses COMPOSIO_BASE_URL in production", () => {
    expect(() => loadConfig({ ...PROD, COMPOSIO_BASE_URL: "http://127.0.0.1:4010" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...PROD, COMPOSIO_ALLOW_INSECURE_HTTP: "1" })).toThrow(ConfigError);
  });

  it("production runs per instance without Upstash (logged once); uses Upstash when set", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const noUp = { ...PROD, UPSTASH_REDIS_REST_TOKEN: undefined };
    expect(loadConfig(noUp).upstash).toBeUndefined();
    expect(buildContext(noUp).kv).toBeInstanceOf(MemoryKV);
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(log.mock.calls[0]?.[0]))).toEqual({ route: "config", status: 200, latency_ms: 0, uid8: null, code: "relay.limitsPerInstance" });
    log.mockClear();
    expect(buildContext(PROD).kv).toBeInstanceOf(UpstashKV);
    expect(buildContext({ ...PROD, VERCEL_ENV: "preview", UPSTASH_REDIS_REST_URL: undefined }).kv).toBeInstanceOf(MemoryKV);
    expect(log).not.toHaveBeenCalled(); // the notice is production-only
  });

  it("requires an HMAC secret everywhere", () => {
    expect(() => loadConfig({ ...testEnv(), INSTALL_ID_HMAC_SECRET: "short" })).toThrow(/INSTALL_ID_HMAC_SECRET/);
  });

  it("ignores RELAY_TEST_MCP_PER_MIN in production and logs it as an error", () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const cfg = loadConfig({ ...PROD, RELAY_TEST_MCP_PER_MIN: "1" });
    expect(cfg.limits.mcpPerMin).toBe(60);
    expect(err).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(err.mock.calls[0]?.[0]))).toEqual({ route: "config", status: 500, latency_ms: 0, uid8: null, code: "relay.testOverrideIgnored" });
    expect(loadConfig({ ...testEnv(), RELAY_TEST_MCP_PER_MIN: "1" }).limits.mcpPerMin).toBe(1);
  });

  it("a misconfigured deployment answers 500 relay.misconfigured, never calls Composio", async () => {
    h = await startHarness();
    const { setContext } = await import("../src/handler.js");
    const prev = process.env.VERCEL_ENV;
    setContext(undefined);
    process.env.VERCEL_ENV = "production"; // process.env has no Upstash and no secret
    vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const r = await h.call("/v1/session", { method: "POST" });
      expect(r.status).toBe(500);
      expect(await r.json()).toEqual({ code: "relay.misconfigured" });
    } finally {
      if (prev === undefined) delete process.env.VERCEL_ENV;
      else process.env.VERCEL_ENV = prev;
      setContext(h.ctx);
    }
    expect(h.mock.log).toHaveLength(0);
  });
});

describe("allow-list and versions", () => {
  it("toolkit allow-list", () => {
    const cfg = loadConfig(testEnv({ RELAY_ALLOWED_TOOLKITS: "gmail,slack" }));
    expect(toolkitAllowed(cfg, "gmail")).toBe(true);
    expect(toolkitAllowed(cfg, "github")).toBe(false);
    expect(toolkitAllowed(cfg, "../x")).toBe(false);
    expect(toolkitAllowed(loadConfig(testEnv({ RELAY_ALLOWED_TOOLKITS: "*" })), "anything")).toBe(true);
  });

  it("link to a toolkit outside the allow-list → 400 relay.badRequest; non-loopback callback refused", async () => {
    h = await startHarness({ RELAY_ALLOWED_TOOLKITS: "gmail" });
    const post = (b: unknown) => h!.call("/v1/connections/link", { method: "POST", body: JSON.stringify(b), headers: { "content-type": "application/json" } });
    expect((await post({ toolkit: "github" })).status).toBe(400);
    expect((await post({ toolkit: "gmail", callback_url: "https://evil.example/cb" })).status).toBe(400);
    const ok = await post({ toolkit: "gmail", callback_url: "antichat://connections/done" });
    expect(ok.status).toBe(200);
    const body = (await ok.json()) as { url: string; id: string };
    expect(body.url).toContain("/link/");
    expect(body.id).toMatch(/^ca_/);
  });

  it("belowMinVersion", () => {
    expect(belowMinVersion(null, "0")).toBe(false);
    expect(belowMinVersion("0.7.0", "0.7")).toBe(false);
    expect(belowMinVersion("0.6.9", "0.7")).toBe(true);
    expect(belowMinVersion("1.0 (12)", "0.9.9")).toBe(false);
    expect(belowMinVersion(null, "1.0")).toBe(true);
    expect(belowMinVersion("garbage", "1.0")).toBe(true);
  });
});

describe("connections + forget", () => {
  it("lists allowed toolkits and connections; DELETE only own ids; forget clears Composio + sess:*", async () => {
    h = await startHarness();
    await runFullSession(h);
    const link = await h.call("/v1/connections/link", { method: "POST", body: JSON.stringify({ toolkit: "slack" }), headers: { "content-type": "application/json" } });
    const { id } = (await link.json()) as { id: string };
    const list = (await (await h.call("/v1/connections")).json()) as { toolkits: string[]; connections: { id: string; toolkit: string; status: string }[] };
    expect(list.toolkits).toEqual(DEFAULT_TOOLKITS);
    expect(list.connections).toEqual([{ id, toolkit: "slack", status: "INITIATED" }]);

    const other = await h.call(`/v1/connections/${id}`, { method: "DELETE", install: "b1b2c3d4-e5f6-4a7b-9c8d-0e1f2a3b4c5d" });
    expect(other.status).toBe(404);
    expect(h.mock.accounts.has(id)).toBe(true);

    const f = await h.call("/v1/forget", { method: "POST" });
    expect(f.status).toBe(200);
    expect(await f.json()).toEqual({ ok: true });
    expect(h.mock.accounts.size).toBe(0);
    const userA = deriveUserId(h.ctx.cfg.hmacSecret, INSTALL_A);
    expect([...h.mock.sessions.values()].some((s) => s.userId === userA)).toBe(false);
    expect(await h.ctx.kv.get(`sess:${userA}`)).toBeNull();
  });
});
