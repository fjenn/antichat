// AT-255 c5 (relay half): MCP request 61 within a minute → 429 + Retry-After + {code:"relay.rateLimited"}
// (in-memory limiter, no Upstash). Plus the other §8.4 windows and the global circuit breaker.
import { afterEach, describe, expect, it } from "vitest";
import { countToolCalls, MemorySlidingWindow, retryAfterSeconds } from "../src/ratelimit.js";
import { MemoryKV } from "../src/store.js";
import { INSTALL_A, INSTALL_B, startHarness, type Harness } from "./harness.js";

let h: Harness | undefined;
afterEach(async () => {
  await h?.close();
  h = undefined;
});

const LIST = { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} };

describe("MCP 60/min per install", () => {
  it("request 61 → 429 with Retry-After and relay.rateLimited; other installs unaffected", async () => {
    h = await startHarness();
    expect(h.ctx.kv).toBeInstanceOf(MemoryKV);
    for (let i = 1; i <= 60; i++) {
      const r = await h.rpc(INSTALL_A, LIST);
      expect(r.status, `request ${i}`).toBe(200);
      await r.text();
    }
    const r61 = await h.rpc(INSTALL_A, LIST);
    expect(r61.status).toBe(429);
    const ra = Number(r61.headers.get("retry-after"));
    expect(ra).toBeGreaterThanOrEqual(1);
    expect(ra).toBeLessThanOrEqual(60);
    expect(await r61.json()).toEqual({ code: "relay.rateLimited" });
    const other = await h.rpc(INSTALL_B, LIST);
    expect(other.status).toBe(200);
  });

  it("RELAY_TEST_MCP_PER_MIN lowers the limit outside production", async () => {
    h = await startHarness({ RELAY_TEST_MCP_PER_MIN: "1" });
    expect((await h.rpc(INSTALL_A, LIST)).status).toBe(200);
    expect((await h.rpc(INSTALL_A, LIST)).status).toBe(429);
  });
});

describe("other windows", () => {
  it("global daily cap → 503 relay.overCapacity on tools/call", async () => {
    h = await startHarness({ RELAY_GLOBAL_DAILY_CAP: "2" });
    const call = { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "COMPOSIO_SEARCH_TOOLS", arguments: { queries: [{ use_case: "find my unread emails from this week" }] } } };
    expect((await h.rpc(INSTALL_A, call)).status).toBe(200);
    expect((await h.rpc(INSTALL_B, call)).status).toBe(200);
    const r = await h.rpc(INSTALL_A, call);
    expect(r.status).toBe(503);
    expect(await r.json()).toEqual({ code: "relay.overCapacity" });
  });

  it("link attempts 10/h per install", async () => {
    h = await startHarness();
    const link = () => h!.call("/v1/connections/link", { method: "POST", body: JSON.stringify({ toolkit: "gmail" }), headers: { "content-type": "application/json" } });
    for (let i = 0; i < 10; i++) expect((await link()).status).toBe(200);
    const r = await link();
    expect(r.status).toBe(429);
    expect(r.headers.get("retry-after")).toBeTruthy();
  });

  it("new install IDs per network 20/h", async () => {
    h = await startHarness();
    const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
    for (let n = 1; n <= 20; n++) expect((await h.call("/v1/session", { method: "POST", install: id(n) })).status).toBe(200);
    const r = await h.call("/v1/session", { method: "POST", install: id(21) });
    expect(r.status).toBe(429);
    expect(await r.json()).toEqual({ code: "relay.rateLimited" });
  });
});

describe("in-memory sliding window", () => {
  it("weights the previous window like Ratelimit.slidingWindow", async () => {
    let now = 120_000; // start of a 1-minute window
    const kv = new MemoryKV(() => now);
    const lim = new MemorySlidingWindow(kv, "rl:t", 10, 60_000, () => now);
    for (let i = 0; i < 10; i++) expect((await lim.limit("u")).success).toBe(true);
    expect((await lim.limit("u")).success).toBe(false);
    now += 60_000 + 30_000; // halfway into the next window: 10 * 0.5 = 5 still count
    for (let i = 0; i < 5; i++) expect((await lim.limit("u")).success).toBe(true);
    const r = await lim.limit("u");
    expect(r.success).toBe(false);
    expect(retryAfterSeconds(r.reset, now)).toBe(30);
    expect(Object.keys(await kv.dump()).every((k) => k.startsWith("rl:t:u:"))).toBe(true);
  });

  it("counts tools/call in single and batch JSON-RPC bodies", () => {
    expect(countToolCalls(JSON.stringify({ method: "tools/call" }))).toBe(1);
    expect(countToolCalls(JSON.stringify([{ method: "tools/call" }, { method: "tools/list" }, { method: "tools/call" }]))).toBe(2);
    // M7.T16 review #12: each inner slug of a MULTI_EXECUTE batch counts.
    const batch = { method: "tools/call", params: { name: "COMPOSIO_MULTI_EXECUTE_TOOL", arguments: { tools: [{ tool_slug: "A" }, { tool_slug: "B" }, { tool_slug: "C" }] } } };
    expect(countToolCalls(JSON.stringify(batch))).toBe(3);
    expect(countToolCalls(JSON.stringify([batch, { method: "tools/call", params: { name: "COMPOSIO_SEARCH_TOOLS" } }]))).toBe(4);
    expect(countToolCalls("not json")).toBe(0);
  });
});
