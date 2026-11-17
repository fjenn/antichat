// GET /v1/toolkits: the apps a person can connect right now, straight from Composio (no publishing step on our
// side). The rules are those of tools/composio/build-catalog.py, which builds the app's bundled, curated snapshot:
//   * left out: a slug the relay would not link, "deprecated" in the name or description, no tools, a toolkit that
//     only works with an OAuth app the developer would have to register, and the second listing of an app Composio
//     has twice (`x` and `x_mcp`: the one with browser sign-in is kept, then the plain one);
//   * `auth`: "oauth" (Composio-managed OAuth or DCR: sign in in the browser), "apikey", "other" (basic), "none"
//     (no sign-in utilities: sent, and the app shows only the ones its curated list includes).
// Hand curation (summaries, our categories, the exclude list) stays in the app.
// The list is the same for every install. It is kept ~6 h in this instance's memory and, when Upstash is
// configured, under `cat:toolkits` (public catalogue data, nothing about any user). A failed refresh answers the
// previous list when there is one.
import { createHash } from "node:crypto";
import type { ListedToolkit } from "./composio.js";
import type { RelayContext } from "./handler.js";
import { toolkitSlugOk } from "./policy.js";

export type AuthKind = "oauth" | "apikey" | "none" | "other";
export type Toolkit = { slug: string; name: string; description: string; categories: string[]; auth: AuthKind; logo: string };
export type Catalog = { generated: string; toolkits: Toolkit[] };
type Entry = { body: string; etag: string; at: number };
export type CatalogCache = { entry?: Entry; pending?: Promise<Entry> };

export const CATALOG_TTL_SECONDS = 6 * 3600;
export const CATALOG_KEY = "cat:toolkits";
/** Enough for the app's one-line summary (first sentence, 45 characters); keeps the answer near 0.5 MB. */
const DESCRIPTION_MAX = 200;

/** build-catalog.py `auth_kind`; null = a user cannot connect it through the relay. */
export function authKind(t: ListedToolkit): AuthKind | null {
  const a = new Set(t.authSchemes.map((s) => s.toUpperCase()));
  const managed = t.managedAuthSchemes.map((s) => s.toUpperCase());
  const oauth = (s: string) => s === "OAUTH2" || s === "OAUTH1";
  if (a.has("DCR_OAUTH") || (managed.some(oauth) && [...a].some(oauth))) return "oauth";
  if (a.has("API_KEY") || a.has("BEARER_TOKEN")) return "apikey";
  if (a.has("BASIC") || a.has("BASIC_WITH_JWT")) return "other";
  if ((a.size === 1 && a.has("NO_AUTH")) || (a.size === 0 && t.noAuth)) return "none";
  return null;
}

function clean(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function clip(s: string, max: number): string {
  if (s.length <= max) return s;
  const cut = s.slice(0, max);
  const sp = cut.lastIndexOf(" ");
  return sp > max / 2 ? cut.slice(0, sp) : cut;
}

/** The compact list from Composio's raw one; `allowed` = RELAY_ALLOWED_TOOLKITS when it narrows. */
export function compactToolkits(raw: ListedToolkit[], allowed: string[] | "*"): Toolkit[] {
  const usable = new Map<string, { t: ListedToolkit; kind: AuthKind }>();
  for (const t of raw) {
    const slug = t.slug.toLowerCase();
    const kind = authKind(t);
    if (!toolkitSlugOk(slug) || usable.has(slug) || kind === null || t.tools <= 0) continue;
    if (`${t.name} ${t.description}`.toLowerCase().includes("deprecated")) continue;
    usable.set(slug, { t, kind });
  }
  const twins = new Set<string>();
  for (const [slug, mcp] of usable) {
    const base = slug.endsWith("_mcp") ? usable.get(slug.slice(0, -4)) : undefined;
    // No-sign-in listings take no part (build-catalog.py `usable`): the app decides about those.
    if (!base || mcp.kind === "none" || base.kind === "none") continue;
    twins.add(mcp.kind === "oauth" && base.kind !== "oauth" ? slug.slice(0, -4) : slug);
  }
  const out: Toolkit[] = [];
  for (const [slug, { t, kind }] of usable) {
    if (twins.has(slug) || (allowed !== "*" && !allowed.includes(slug))) continue;
    out.push({
      slug,
      name: clip(clean(t.name), 80) || slug,
      description: clip(clean(t.description), DESCRIPTION_MAX),
      categories: [...new Set(t.categories.map(clean).filter(Boolean))].slice(0, 8),
      auth: kind,
      logo: /^https:\/\//i.test(t.logo) && t.logo.length <= 300 ? t.logo : "",
    });
  }
  return out.sort((a, b) => (a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0));
}

/** The ETag follows the list alone, not the time it was read: an unchanged list stays a 304 after a refresh. */
function entryOf(toolkits: Toolkit[], at: number): Entry {
  const etag = `"${createHash("sha256").update(JSON.stringify(toolkits)).digest("hex").slice(0, 32)}"`;
  const catalog: Catalog = { generated: new Date(at).toISOString(), toolkits };
  return { body: JSON.stringify(catalog), etag, at };
}

function parseEntry(raw: string | null): Entry | undefined {
  if (!raw) return undefined;
  try {
    const v = JSON.parse(raw) as Partial<Entry>;
    return typeof v.body === "string" && typeof v.etag === "string" && typeof v.at === "number" ? { body: v.body, etag: v.etag, at: v.at } : undefined;
  } catch {
    return undefined;
  }
}

/** The current list: memory, then the shared store, then Composio (one read at a time per instance). */
export async function currentCatalog(ctx: RelayContext, now: () => number = Date.now): Promise<Entry> {
  const cache = ctx.catalog;
  const fresh = (e: Entry | undefined) => e !== undefined && now() - e.at < CATALOG_TTL_SECONDS * 1000;
  if (fresh(cache.entry)) return cache.entry!;
  if (cache.pending) return cache.pending;
  cache.pending = (async () => {
    if (ctx.cfg.upstash) {
      const shared = parseEntry(await ctx.kv.get(CATALOG_KEY).catch(() => null));
      if (fresh(shared)) return (cache.entry = shared!);
    }
    try {
      const toolkits = compactToolkits(await ctx.gateway().listToolkits(), ctx.cfg.allowedToolkits);
      // Composio never lists nothing: an empty answer is a failure, not a catalogue.
      if (toolkits.length === 0) throw new Error("empty toolkit list");
      const entry = entryOf(toolkits, now());
      cache.entry = entry;
      if (ctx.cfg.upstash) await ctx.kv.set(CATALOG_KEY, JSON.stringify(entry), CATALOG_TTL_SECONDS).catch(() => {});
      return entry;
    } catch (e) {
      if (cache.entry) return cache.entry;
      throw e;
    }
  })();
  try {
    return await cache.pending;
  } finally {
    cache.pending = undefined;
  }
}

/** True when `If-None-Match` names `etag` (weak or strong, or `*`). */
export function etagMatches(header: string | null, etag: string): boolean {
  if (!header) return false;
  return header.split(",").some((v) => {
    const t = v.trim();
    return t === "*" || t === etag || t === `W/${etag}`;
  });
}
