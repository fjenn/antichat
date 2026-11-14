// AT-255 c2 (relay half): tools/list is proxied to the (mock) Composio session MCP URL with server-side headers;
// upstream auth headers never reach the app. Plus the stub-key / kill-switch / version gates.
import { afterEach, describe, expect, it } from "vitest";
import { downstreamHeaders, upstreamHeaders } from "../src/proxy.js";
import { INSTALL_A, runFullSession, startHarness, type Harness } from "./harness.js";

let h: Harness | undefined;
afterEach(async () => {
  await h?.close();
  h = undefined;
});

describe("MCP pass-through", () => {
  it("proxies initialize + tools/list to the mock and strips upstream credentials", async () => {
    h = await startHarness();
    const init = await h.rpc(INSTALL_A, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "AntiChat", version: "0.7.0" } } });
    expect(init.status).toBe(200);
    expect(init.headers.get("mcp-session-id")).toMatch(/^mcp_/);
    await init.text();
    const r = await h.rpc(INSTALL_A, { jsonrpc: "2.0", id: 7, method: "tools/list", params: {} });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { id: number; result: { tools: { name: string }[] } };
    expect(body.id).toBe(7);
    expect(body.result.tools.map((t) => t.name)).toEqual([
      "COMPOSIO_SEARCH_TOOLS", "COMPOSIO_GET_TOOL_SCHEMAS", "COMPOSIO_MANAGE_CONNECTIONS", "COMPOSIO_MULTI_EXECUTE_TOOL",
    ]);
    for (const leaked of ["set-cookie", "www-authenticate", "x-api-key"]) expect(r.headers.get(leaked)).toBeNull();
    const mcpCalls = h.mock.log.filter((l) => l.path.endsWith("/mcp"));
    expect(mcpCalls.map((l) => l.rpc)).toEqual(["initialize", "tools/list"]);
    expect(mcpCalls.every((l) => l.auth)).toBe(true); // relay attached the server-side key
  });

  it("a cold instance (session cache lost) answers 404 to a stale Mcp-Session-Id, then the client re-initializes", async () => {
    h = await startHarness();
    const initMsg = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "AntiChat", version: "0.7.0" } } };
    const init = await h.rpc(INSTALL_A, initMsg);
    expect(init.status).toBe(200);
    await init.text();
    // A cold instance: the per-instance store lost `sess:<userId>`; the app still holds its Mcp-Session-Id.
    for (const k of Object.keys(await h.ctx.kv.dump())) if (k.startsWith("sess:")) await h.ctx.kv.del(k);
    const stale = await h.rpc(INSTALL_A, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    expect(stale.status).toBe(404);
    expect(await stale.json()).toEqual({ code: "relay.notFound" });
    const again = await h.call("/v1/mcp", { method: "POST", install: INSTALL_A, headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify(initMsg) });
    expect(again.status).toBe(200);
  });

  it("a full mocked session (fixture readonly + send, connections, link, disconnect) succeeds", async () => {
    h = await startHarness();
    const s = await runFullSession(h);
    for (const [name, status] of Object.entries(s)) {
      expect([200, 202, 302], name).toContain(status);
    }
  });

  it("header allow-lists: app headers stay at the relay, only MCP headers come back", () => {
    const up = upstreamHeaders(
      new Headers({ "x-antichat-install": INSTALL_A, "content-type": "application/json", "mcp-session-id": "m1", cookie: "a=b", authorization: "Bearer app" }),
      { url: "http://x", headers: { "x-api-key": "server-side" } },
    );
    expect(up.get("x-antichat-install")).toBeNull();
    expect(up.get("cookie")).toBeNull();
    expect(up.get("authorization")).toBeNull();
    expect(up.get("x-api-key")).toBe("server-side");
    expect(up.get("mcp-session-id")).toBe("m1");
    const down = downstreamHeaders(new Headers({ "content-type": "text/event-stream", "x-api-key": "k", "set-cookie": "c", "x-composio-trace": "t" }));
    expect([...down.keys()].sort()).toEqual(["content-type", "x-accel-buffering"]);
  });

  it("/v1/session never returns Composio URLs or headers", async () => {
    h = await startHarness();
    const text = await (await h.call("/v1/session", { method: "POST" })).text();
    expect(JSON.parse(text)).toEqual({ ok: true });
    expect(text).not.toContain(h.mock.url);
    expect(text).not.toContain("test-mock-key");
  });
});

describe("gates", () => {
  it("dev-not-a-key → 503 relay.notConfigured before any Composio call", async () => {
    h = await startHarness({ COMPOSIO_API_KEY: "dev-not-a-key" });
    for (const [path, method] of [["/v1/session", "POST"], ["/v1/mcp", "POST"], ["/v1/connections", "GET"], ["/v1/forget", "POST"], ["/v1/connections/link", "POST"], ["/v1/connections/ca_1", "DELETE"]] as const) {
      const r = await h.call(path, { method, body: method === "GET" || method === "DELETE" ? undefined : "{}" });
      expect(r.status, path).toBe(503);
      expect(await r.json()).toEqual({ code: "relay.notConfigured" });
    }
    expect(h.mock.log).toHaveLength(0);
    const health = await h.call("/v1/health", { install: null });
    expect(await health.json()).toEqual({ ok: true, version: "1.0.0" });
  });

  it("RELAY_DISABLED=1 → 503 relay.disabled (kill switch)", async () => {
    h = await startHarness({ RELAY_DISABLED: "1" });
    const r = await h.call("/v1/mcp", { method: "POST", body: "{}" });
    expect(r.status).toBe(503);
    expect(await r.json()).toEqual({ code: "relay.disabled" });
    expect(h.mock.log).toHaveLength(0);
  });

  it("client below RELAY_MIN_CLIENT_VERSION → 426 relay.updateRequired", async () => {
    h = await startHarness({ RELAY_MIN_CLIENT_VERSION: "0.8.0" });
    const old = await h.call("/v1/session", { method: "POST", version: "0.7.9 (412)" });
    expect(old.status).toBe(426);
    expect(await old.json()).toEqual({ code: "relay.updateRequired" });
    const ok = await h.call("/v1/session", { method: "POST", version: "0.8.0 (500)" });
    expect(ok.status).toBe(200);
  });
});
