// GET /v1/toolkits (src/toolkits.ts): the live app list from Composio's toolkit listing (mock: test/mock-composio.ts
// DEFAULT_CATALOG, three a page), the build-catalog.py rules, the 6 h cache, ETag/304, the per-install limit and
// RELAY_ALLOWED_TOOLKITS.
import { afterEach, describe, expect, it } from "vitest";
import type { ListedToolkit } from "../src/composio.js";
import { authKind, CATALOG_TTL_SECONDS, compactToolkits, currentCatalog, etagMatches, type Catalog } from "../src/toolkits.js";
import { INSTALL_B, startHarness, type Harness } from "./harness.js";

let h: Harness | undefined;
afterEach(async () => {
  await h?.close();
  h = undefined;
});

const listCalls = (hh: Harness) => hh.mock.log.filter((l) => l.path === "/api/v3.1/toolkits");
const tk = (over: Partial<ListedToolkit>): ListedToolkit => ({
  slug: "x", name: "X", description: "", logo: "", categories: [], authSchemes: [], managedAuthSchemes: [], noAuth: false, tools: 1, ...over,
});

describe("GET /v1/toolkits", () => {
  it("answers the connectable toolkits, compact, read from every page", async () => {
    h = await startHarness();
    const r = await h.call("/v1/toolkits");
    expect(r.status).toBe(200);
    expect(r.headers.get("content-type")).toBe("application/json");
    expect(r.headers.get("cache-control")).toBe("private, max-age=3600");
    expect(r.headers.get("etag")).toMatch(/^"[0-9a-f]{32}"$/);
    const body = (await r.json()) as Catalog;
    expect(Number.isNaN(Date.parse(body.generated))).toBe(false);
    // Left out: devonly (developer OAuth app), empty (no tools), oldthing (deprecated), "Bad Slug!", notion_mcp
    // (the plain one signs in in the browser too) and stripe (its MCP listing has browser sign-in, it has not).
    expect(body.toolkits.map((t) => [t.slug, t.auth])).toEqual([
      ["acme_crm", "apikey"], ["basicapp", "other"], ["gmail", "oauth"], ["hackernews", "none"], ["notion", "oauth"],
      ["slack", "oauth"], ["stripe_mcp", "oauth"],
    ]);
    const by = Object.fromEntries(body.toolkits.map((t) => [t.slug, t]));
    expect(by.gmail).toEqual({
      slug: "gmail", name: "Gmail", description: "Gmail is Google's email service. It has spam protection.",
      categories: ["Email", "Communication"], auth: "oauth", logo: "https://logos.composio.dev/api/gmail",
    });
    expect(by.acme_crm!.description.length).toBeLessThanOrEqual(200);
    expect(by.acme_crm!.description.startsWith("Acme CRM is a powerful platform that helps teams track deals.")).toBe(true);
    expect(by.slack!.logo).toBe(""); // not https
    expect(Object.keys(by.slack!).sort()).toEqual(["auth", "categories", "description", "logo", "name", "slug"]);

    const calls = listCalls(h);
    expect(calls).toHaveLength(5); // 13 rows, three a page
    expect(calls.every((c) => c.auth)).toBe(true);
    expect(calls[0]!.query).toEqual({ type: "native", include_deprecated: "false", sort_by: "alphabetically", limit: "500" });
    expect(calls[1]!.query?.cursor).toBeTruthy();
    expect(h.mock.sessions.size).toBe(0); // no ToolRouter session for a catalogue read
  });

  it("is read from Composio once and then served from memory to every install; If-None-Match → 304", async () => {
    h = await startHarness();
    const first = await h.call("/v1/toolkits");
    const etag = first.headers.get("etag")!;
    const body = await first.text();
    const other = await h.call("/v1/toolkits", { install: INSTALL_B });
    expect(await other.text()).toBe(body);
    expect(listCalls(h)).toHaveLength(5);

    const same = await h.call("/v1/toolkits", { headers: { "if-none-match": etag } });
    expect(same.status).toBe(304);
    expect(await same.text()).toBe("");
    expect(same.headers.get("etag")).toBe(etag);
    expect((await h.call("/v1/toolkits", { headers: { "if-none-match": `W/${etag}` } })).status).toBe(304);
    expect((await h.call("/v1/toolkits", { headers: { "if-none-match": '"something-else"' } })).status).toBe(200);
    expect(listCalls(h)).toHaveLength(5);
  });

  it("is read again after 6 h; an unchanged list keeps its ETag, a changed one gets another; a failed read keeps the old list", async () => {
    h = await startHarness();
    let now = 1_800_000_000_000;
    const a = await currentCatalog(h.ctx, () => now);
    now += (CATALOG_TTL_SECONDS - 1) * 1000;
    expect(await currentCatalog(h.ctx, () => now)).toBe(a);
    now += 2000;
    const b = await currentCatalog(h.ctx, () => now);
    expect(listCalls(h)).toHaveLength(10);
    expect(b.etag).toBe(a.etag);
    expect((JSON.parse(b.body) as Catalog).generated).not.toBe((JSON.parse(a.body) as Catalog).generated);

    now += (CATALOG_TTL_SECONDS + 1) * 1000;
    h.mock.catalog = [...h.mock.catalog, { slug: "brandnew", name: "Brand New", auth_schemes: ["API_KEY"], description: "Just launched." }];
    const c = await currentCatalog(h.ctx, () => now);
    expect(c.etag).not.toBe(a.etag);
    expect((JSON.parse(c.body) as Catalog).toolkits.map((t) => t.slug)).toContain("brandnew");

    now += (CATALOG_TTL_SECONDS + 1) * 1000;
    h.mock.failCatalog = true;
    expect(await currentCatalog(h.ctx, () => now)).toBe(c);
  });

  it("Composio down and nothing cached → 502 relay.upstream; an empty listing is a failure too", async () => {
    h = await startHarness();
    h.mock.failCatalog = true;
    const r = await h.call("/v1/toolkits");
    expect(r.status).toBe(502);
    expect(await r.json()).toEqual({ code: "relay.upstream" });
    h.mock.failCatalog = false;
    h.mock.catalog = [];
    expect((await h.call("/v1/toolkits")).status).toBe(502);
  });

  it("needs the install headers; 30 an hour per install, then 429 with Retry-After", async () => {
    h = await startHarness();
    expect((await h.call("/v1/toolkits", { install: null })).status).toBe(400);
    for (let i = 0; i < 30; i++) expect((await h.call("/v1/toolkits")).status).toBe(200);
    const over = await h.call("/v1/toolkits");
    expect(over.status).toBe(429);
    expect(await over.json()).toEqual({ code: "relay.rateLimited" });
    expect(Number(over.headers.get("retry-after"))).toBeGreaterThan(0);
    expect((await h.call("/v1/toolkits", { install: INSTALL_B })).status).toBe(200);
  });

  it("RELAY_ALLOWED_TOOLKITS narrows the list", async () => {
    h = await startHarness({ RELAY_ALLOWED_TOOLKITS: "gmail, Slack, devonly, nosuchapp" });
    const body = (await (await h.call("/v1/toolkits")).json()) as Catalog;
    expect(body.toolkits.map((t) => t.slug)).toEqual(["gmail", "slack"]);
  });

  it("stub key → 503 before any Composio call", async () => {
    h = await startHarness({ COMPOSIO_API_KEY: "dev-not-a-key" });
    expect((await h.call("/v1/toolkits")).status).toBe(503);
    expect(h.mock.log).toHaveLength(0);
  });
});

describe("rules", () => {
  it("authKind follows build-catalog.py", () => {
    expect(authKind(tk({ authSchemes: ["OAUTH2"], managedAuthSchemes: ["OAUTH2"] }))).toBe("oauth");
    expect(authKind(tk({ authSchemes: ["oauth2"], managedAuthSchemes: ["oauth2"] }))).toBe("oauth");
    expect(authKind(tk({ authSchemes: ["DCR_OAUTH"] }))).toBe("oauth");
    expect(authKind(tk({ authSchemes: ["OAUTH2"] }))).toBeNull();
    expect(authKind(tk({ authSchemes: ["OAUTH2", "API_KEY"] }))).toBe("apikey");
    expect(authKind(tk({ authSchemes: ["BEARER_TOKEN"] }))).toBe("apikey");
    expect(authKind(tk({ authSchemes: ["BASIC_WITH_JWT"] }))).toBe("other");
    expect(authKind(tk({ authSchemes: ["NO_AUTH"] }))).toBe("none");
    expect(authKind(tk({ noAuth: true }))).toBe("none");
    expect(authKind(tk({ authSchemes: ["SERVICE_ACCOUNT"] }))).toBeNull();
    expect(authKind(tk({}))).toBeNull();
  });

  it("compactToolkits: duplicates once, sorted by slug, categories de-duplicated", () => {
    const out = compactToolkits(
      [tk({ slug: "b", authSchemes: ["API_KEY"], categories: ["A", " A ", "B"] }), tk({ slug: "a", authSchemes: ["API_KEY"] }), tk({ slug: "B", authSchemes: ["BASIC"] })],
      "*",
    );
    expect(out.map((t) => [t.slug, t.auth, t.categories])).toEqual([["a", "apikey", []], ["b", "apikey", ["A", "B"]]]);
  });

  it("etagMatches", () => {
    expect(etagMatches(null, '"a"')).toBe(false);
    expect(etagMatches('"b", W/"a"', '"a"')).toBe(true);
    expect(etagMatches("*", '"a"')).toBe(true);
    expect(etagMatches('"b"', '"a"')).toBe(false);
  });
});
