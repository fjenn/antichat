// M7.T07 (R-257, AT-257): reference OAuth 2.1 authorization server for the MCP OAuth tests. Dev/test only; never
// shipped. Node ≥ 24 (type stripping), node: modules only, no dependencies.
//   RFC 8414 metadata (/.well-known/oauth-authorization-server), CIMD (client_id = an HTTPS URL whose JSON document
//   the AS fetches; draft-ietf-oauth-client-id-metadata-document), RFC 7591 DCR (/register), PKCE S256 (RFC 7636),
//   `iss` in the authorization response (RFC 9207), RFC 8707 resource binding, refresh-token rotation.
// Test mode (always on here; documented [ASSUMPTION], M7.md §0.1): the CIMD URL may be http://127.0.0.1 / localhost
// (the local `site/public` server), and the fetched document may name the published URL as its client_id.
// /authorize auto-approves (no login page): it answers 302 to the redirect URI at once.
// Test hooks: POST /revoke-all (forget every token), POST /expire-access (expire every access token now; refresh
// tokens stay valid), GET /log.
// Toggles (negative tests): --no-cimd, --no-dcr, --bad-state, --bad-iss, --plain-pkce, --no-pkce, --bad-redirect.
import { createHash, randomBytes } from "node:crypto";
import { appendFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

export type ASOptions = {
  port: number;
  noCIMD: boolean;
  noDCR: boolean;
  badState: boolean;
  badIss: boolean;
  plainPKCE: boolean;
  noPKCE: boolean;
  badRedirect: boolean;
  tokenTTL: number;
  pastedClientID: string;
  publishedCIMD: string;
  issuedFile?: string;
};

type Client = { client_id: string; redirect_uris: string[]; client_name?: string; kind: "cimd" | "dcr" | "pasted" };
type Grant = { client_id: string; redirect_uri: string; challenge: string; method: string; resource: string; scope: string; used: boolean; tokens: string[] };
export type TokenInfo = { client_id: string; resource: string; scope: string; expires: number; kind: "access" | "refresh" };

export const tokens = new Map<string, TokenInfo>();
export const log: string[] = [];

const b64url = (b: Buffer) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const random = (prefix: string) => prefix + b64url(randomBytes(24));

function json(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers });
  res.end(JSON.stringify(body));
}

async function body(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

function isLoopback(u: URL) {
  return u.hostname === "127.0.0.1" || u.hostname === "localhost" || u.hostname === "[::1]";
}

/// RFC 8252 §7.3: a loopback redirect matches whatever its port; everything else matches exactly.
function redirectAllowed(registered: string[], given: string): boolean {
  let g: URL;
  try { g = new URL(given); } catch { return false; }
  return registered.some((r) => {
    if (r === given) return true;
    try {
      const u = new URL(r);
      return u.protocol === "http:" && isLoopback(u) && isLoopback(g) && u.hostname === g.hostname && u.pathname === g.pathname;
    } catch { return false; }
  });
}

export function startAS(o: ASOptions) {
  const issuer = `http://127.0.0.1:${o.port}`;
  const clients = new Map<string, Client>();
  clients.set(o.pastedClientID, { client_id: o.pastedClientID, kind: "pasted", redirect_uris: ["antichat://oauth/callback", "http://127.0.0.1/callback"] });
  const grants = new Map<string, Grant>();

  function issue(t: TokenInfo, grant?: Grant) {
    const access = random("at_");
    const refresh = random("rt_");
    tokens.set(access, t);
    tokens.set(refresh, { ...t, kind: "refresh", expires: Date.now() + 86_400_000 });
    grant?.tokens.push(access, refresh);
    if (o.issuedFile) appendFileSync(o.issuedFile, `${access}\n${refresh}\n`);
    return { access_token: access, token_type: "Bearer", expires_in: o.tokenTTL, refresh_token: refresh, scope: t.scope };
  }

  async function resolveClient(id: string): Promise<Client | { error: string }> {
    const known = clients.get(id);
    if (known) return known;
    let u: URL;
    try { u = new URL(id); } catch { return { error: "unknown client_id" }; }
    if (o.noCIMD) return { error: "client_id metadata documents not supported" };
    if (!(u.protocol === "https:" || (u.protocol === "http:" && isLoopback(u)))) return { error: "CIMD URL must be https" };
    if (u.pathname === "/" || u.pathname === "") return { error: "CIMD URL needs a path" };
    // The document fetch is the AS calling the client's web server: a network failure there (refused, reset, timed
    // out — seen under host load against the test's static server) is the client's metadata being unreachable, so
    // it is `invalid_client` (400) after up to 3 tries, never an AS `server_error` (500).
    let doc: Record<string, unknown> | undefined;
    let lastError = "";
    for (let attempt = 1; attempt <= 3 && !doc; attempt++) {
      try {
        const r = await fetch(u, { redirect: "error", signal: AbortSignal.timeout(5000) });
        if (!r.ok) return { error: `CIMD fetch ${r.status}` };
        doc = (await r.json()) as Record<string, unknown>;
      } catch (e) {
        lastError = String(e);
        log.push(`cimd fetch failed (attempt ${attempt}): ${lastError}`);
        if (attempt < 3) await new Promise((done) => setTimeout(done, 200 * attempt));
      }
    }
    if (!doc) return { error: `CIMD fetch failed: ${lastError}` };
    // The document's client_id must be its own URL (test mode: or the published URL it mirrors).
    if (doc.client_id !== id && !(doc.client_id === o.publishedCIMD && isLoopback(u))) return { error: "CIMD client_id mismatch" };
    if (doc.token_endpoint_auth_method !== "none") return { error: "CIMD must be a public client" };
    const c: Client = { client_id: id, kind: "cimd", client_name: String(doc.client_name ?? ""), redirect_uris: (doc.redirect_uris as string[]) ?? [] };
    log.push(`cimd ${id} ${c.client_name}`);
    clients.set(id, c);  // fetched once per server life (one flow re-authorizes with the same client_id)
    return c;
  }

  const metadata = () => {
    const m: Record<string, unknown> = {
      issuer,
      authorization_endpoint: `${issuer}/authorize`,
      token_endpoint: `${issuer}/token`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      authorization_response_iss_parameter_supported: true,
      client_id_metadata_document_supported: !o.noCIMD,
      scopes_supported: ["mcp:tools"],
    };
    if (!o.noDCR) m.registration_endpoint = `${issuer}/register`;
    if (o.plainPKCE) m.code_challenge_methods_supported = ["plain"];
    else if (!o.noPKCE) m.code_challenge_methods_supported = ["S256"];
    return m;
  };

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", issuer);
    log.push(`${req.method} ${url.pathname}`);
    try {
      if (req.method === "GET" && url.pathname.startsWith("/.well-known/oauth-authorization-server")) return json(res, 200, metadata());
      if (req.method === "GET" && url.pathname.startsWith("/.well-known/openid-configuration")) return json(res, 404, { error: "not_found" });

      if (req.method === "POST" && url.pathname === "/register") {
        if (o.noDCR) return json(res, 404, { error: "not_found" });
        const r = JSON.parse(await body(req)) as Record<string, unknown>;
        const uris = (r.redirect_uris as string[]) ?? [];
        if (uris.length === 0) return json(res, 400, { error: "invalid_redirect_uri" });
        const c: Client = { client_id: random("dcr_"), kind: "dcr", client_name: String(r.client_name ?? ""), redirect_uris: uris };
        clients.set(c.client_id, c);
        log.push(`dcr ${c.client_id} ${c.client_name}`);
        return json(res, 201, { client_id: c.client_id, client_name: c.client_name, redirect_uris: uris, token_endpoint_auth_method: "none",
                                grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] });
      }

      if (req.method === "GET" && url.pathname === "/authorize") {
        const q = url.searchParams;
        const c = await resolveClient(q.get("client_id") ?? "");
        if ("error" in c) {
          log.push(`reject invalid_client: ${c.error}`);
          return json(res, 400, { error: "invalid_client", error_description: c.error });
        }
        const redirect = q.get("redirect_uri") ?? "";
        // A bad redirect_uri is never redirected to (RFC 6749 §4.1.2.1): the AS answers with an error page.
        if (!redirectAllowed(c.redirect_uris, redirect)) {
          log.push(`reject invalid_request: redirect_uri not registered (${redirect})`);  // OAuthNegativeTests checks this
          return json(res, 400, { error: "invalid_request", error_description: "redirect_uri not registered" });
        }
        if (q.get("response_type") !== "code") return json(res, 400, { error: "unsupported_response_type" });
        const challenge = q.get("code_challenge") ?? "";
        const method = q.get("code_challenge_method") ?? "plain";
        if (!challenge) return json(res, 400, { error: "invalid_request", error_description: "PKCE required" });
        if (method !== "S256" && !(o.plainPKCE && method === "plain")) return json(res, 400, { error: "invalid_request", error_description: "S256 required" });
        log.push(`authorize ${c.kind} method=${method}`);
        const code = random("code_");
        grants.set(code, { client_id: c.client_id, redirect_uri: redirect, challenge, method, resource: q.get("resource") ?? "",
                           scope: q.get("scope") ?? "mcp:tools", used: false, tokens: [] });
        const to = new URL(o.badRedirect ? redirect.replace("/callback", "/elsewhere") : redirect);
        to.searchParams.set("code", code);
        to.searchParams.set("state", o.badState ? `${q.get("state") ?? ""}-tampered` : (q.get("state") ?? ""));
        to.searchParams.set("iss", o.badIss ? "https://evil.example" : issuer);
        res.writeHead(302, { Location: to.toString() });
        return res.end();
      }

      if (req.method === "POST" && url.pathname === "/token") {
        const f = new URLSearchParams(await body(req));
        const grantType = f.get("grant_type");
        if (grantType === "authorization_code") {
          const code = f.get("code") ?? "";
          const g = grants.get(code);
          if (!g) return json(res, 400, { error: "invalid_grant", error_description: "unknown code" });
          if (g.used) {  // OAuth 2.1 §4.1.3: a replayed code fails and revokes what it issued
            for (const t of g.tokens) tokens.delete(t);
            log.push("replay rejected");
            return json(res, 400, { error: "invalid_grant", error_description: "code already used" });
          }
          g.used = true;
          if (f.get("client_id") !== g.client_id) return json(res, 400, { error: "invalid_grant", error_description: "client mismatch" });
          if (f.get("redirect_uri") !== g.redirect_uri) return json(res, 400, { error: "invalid_grant", error_description: "redirect_uri mismatch" });
          const verifier = f.get("code_verifier") ?? "";
          const expected = g.method === "S256" ? b64url(createHash("sha256").update(verifier).digest()) : verifier;
          if (!verifier || expected !== g.challenge) return json(res, 400, { error: "invalid_grant", error_description: "PKCE verification failed" });
          const resource = f.get("resource") ?? g.resource;
          if (g.resource && resource !== g.resource) return json(res, 400, { error: "invalid_target" });
          log.push(`token code ${g.client_id}`);
          return json(res, 200, issue({ client_id: g.client_id, resource, scope: g.scope, expires: Date.now() + o.tokenTTL * 1000, kind: "access" }, g));
        }
        if (grantType === "refresh_token") {
          const rt = f.get("refresh_token") ?? "";
          const t = tokens.get(rt);
          if (!t || t.kind !== "refresh" || t.client_id !== f.get("client_id")) return json(res, 400, { error: "invalid_grant" });
          tokens.delete(rt);  // rotation
          log.push(`token refresh ${t.client_id}`);
          return json(res, 200, issue({ ...t, kind: "access", expires: Date.now() + o.tokenTTL * 1000 }));
        }
        return json(res, 400, { error: "unsupported_grant_type" });
      }

      if (req.method === "POST" && url.pathname === "/revoke-all") {  // test hook: forces refresh failure
        tokens.clear();
        return json(res, 200, { ok: true });
      }
      if (req.method === "POST" && url.pathname === "/expire-access") {  // test hook: every access token is now past its expiry
        for (const t of tokens.values()) if (t.kind === "access") t.expires = 0;
        return json(res, 200, { ok: true });
      }
      if (req.method === "GET" && url.pathname === "/log") return json(res, 200, log);
      json(res, 404, { error: "not_found" });
    } catch (e) {
      log.push(`server_error ${req.method} ${url.pathname}: ${String(e)}`);  // visible in /log and the test output
      console.error(`as.ts server_error ${req.method} ${url.pathname}: ${String(e)}`);
      json(res, 500, { error: "server_error", error_description: String(e) });
    }
  });
  server.listen(o.port, "127.0.0.1");
  return { server, issuer };
}

/// The protected resource's view: a valid, unexpired access token bound to `resource`.
export function checkToken(header: string | undefined, resource: string): "ok" | "missing" | "invalid" {
  const m = /^Bearer (.+)$/.exec(header ?? "");
  if (!m) return "missing";
  const t = tokens.get(m[1]);
  if (!t || t.kind !== "access" || t.expires < Date.now() || (t.resource && t.resource !== resource)) return "invalid";
  return "ok";
}
