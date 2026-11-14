// MCP pass-through (architecture §8.1/§8.2, M7.T10 step 3). Forwards the app's Streamable-HTTP request to the
// session's MCP URL with the server-side Composio headers and streams the body back. Only MCP protocol headers
// cross in either direction; upstream credentials, cookies and auth challenges never reach the app.
import type { McpTarget } from "./composio.js";

/** Request headers the app may send upstream (everything else, incl. X-AntiChat-*, stays at the relay). */
const FORWARD_REQUEST = ["accept", "content-type", "mcp-session-id", "mcp-protocol-version", "last-event-id"];
/** Response headers the app may see. An allow-list, so x-api-key / set-cookie / www-authenticate etc. are dropped. */
const FORWARD_RESPONSE = ["content-type", "mcp-session-id", "mcp-protocol-version", "cache-control", "retry-after"];

export function upstreamHeaders(req: Headers, target: McpTarget): Headers {
  const h = new Headers();
  for (const name of FORWARD_REQUEST) {
    const v = req.get(name);
    if (v !== null) h.set(name, v);
  }
  for (const [k, v] of Object.entries(target.headers)) h.set(k, v);
  return h;
}

export function downstreamHeaders(up: Headers): Headers {
  const h = new Headers();
  for (const name of FORWARD_RESPONSE) {
    const v = up.get(name);
    if (v !== null) h.set(name, v);
  }
  h.set("x-accel-buffering", "no");
  return h;
}

export type ProxyFetch = (url: string, init: RequestInit) => Promise<Response>;

/**
 * Sends one MCP request upstream. `body` is the already-read request body (POST) or null (GET/DELETE).
 * Redirects are not followed: the credential must only ever go to the session's own origin.
 */
export async function forward(
  method: "GET" | "POST" | "DELETE",
  reqHeaders: Headers,
  body: string | null,
  target: McpTarget,
  signal?: AbortSignal,
  doFetch: ProxyFetch = fetch,
): Promise<Response> {
  const up = await doFetch(target.url, {
    method,
    headers: upstreamHeaders(reqHeaders, target),
    body: method === "POST" ? (body ?? "") : undefined,
    redirect: "manual",
    signal,
  });
  if (up.status >= 300 && up.status < 400) {
    await up.body?.cancel();
    return new Response(JSON.stringify({ code: "relay.upstream" }), {
      status: 502,
      headers: { "content-type": "application/json" },
    });
  }
  return new Response(up.body, { status: up.status, headers: downstreamHeaders(up.headers) });
}
