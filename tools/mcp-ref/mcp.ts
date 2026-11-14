// M7.T07 (R-257, AT-257): an OAuth-protected MCP server (Streamable HTTP, spec 2025-11-25) plus the reference
// authorization server (as.ts) in one process. Dev/test only; never shipped.
//   node tools/mcp-ref/mcp.ts --port P [--as-port Q] [--issued-file F] [--token-ttl S] [--pasted-client-id ID]
//        [--no-cimd] [--no-dcr] [--bad-state] [--bad-iss] [--plain-pkce] [--no-pkce] [--bad-redirect]
// The MCP endpoint is http://127.0.0.1:P/mcp. Without a valid token it answers 401 with
// `WWW-Authenticate: Bearer resource_metadata=…` (RFC 9728 §5.1); an expired or unknown token adds
// `error="invalid_token"`. Protected-resource metadata lives at /.well-known/oauth-protected-resource[/mcp].
// One tool: `whoami` (read-only) returns the client id the token was issued to.
import { createServer } from "node:http";
import { parseArgs } from "node:util";
import { checkToken, startAS, tokens } from "./as.ts";

const { values: a } = parseArgs({
  options: {
    port: { type: "string" }, "as-port": { type: "string" }, "issued-file": { type: "string" }, "token-ttl": { type: "string" },
    "pasted-client-id": { type: "string" },
    "no-cimd": { type: "boolean" }, "no-dcr": { type: "boolean" }, "bad-state": { type: "boolean" }, "bad-iss": { type: "boolean" },
    "plain-pkce": { type: "boolean" }, "no-pkce": { type: "boolean" }, "bad-redirect": { type: "boolean" },
  },
});
const port = Number(a.port ?? 39_500);
const asPort = Number(a["as-port"] ?? port + 1);
const { issuer } = startAS({
  port: asPort, noCIMD: !!a["no-cimd"], noDCR: !!a["no-dcr"], badState: !!a["bad-state"], badIss: !!a["bad-iss"],
  plainPKCE: !!a["plain-pkce"], noPKCE: !!a["no-pkce"], badRedirect: !!a["bad-redirect"],
  tokenTTL: Number(a["token-ttl"] ?? 3600), pastedClientID: a["pasted-client-id"] ?? "antichat-pasted",
  publishedCIMD: "https://antichat.app/oauth/mcp-client-metadata.json", issuedFile: a["issued-file"],
});

const base = `http://127.0.0.1:${port}`;
const resource = `${base}/mcp`;
const prm = `${base}/.well-known/oauth-protected-resource/mcp`;
const versions = ["2025-11-25", "2025-06-18", "2025-03-26"];

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", base);
  if (req.method === "GET" && url.pathname.startsWith("/.well-known/oauth-protected-resource")) {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ resource, authorization_servers: [issuer], scopes_supported: ["mcp:tools"], bearer_methods_supported: ["header"] }));
  }
  if (url.pathname !== "/mcp") { res.writeHead(404); return res.end(); }
  const auth = checkToken(req.headers.authorization, resource);
  if (auth !== "ok") {
    const err = auth === "invalid" ? `, error="invalid_token"` : "";
    res.writeHead(401, { "WWW-Authenticate": `Bearer resource_metadata="${prm}", scope="mcp:tools"${err}` });
    return res.end();
  }
  if (req.method === "GET") { res.writeHead(405); return res.end(); }
  if (req.method === "DELETE") { res.writeHead(200); return res.end(); }
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  const msg = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (msg.id === undefined) { res.writeHead(202); return res.end(); }  // notification
  const token = tokens.get(/^Bearer (.+)$/.exec(req.headers.authorization ?? "")![1])!;
  let result: unknown;
  switch (msg.method) {
    case "initialize": {
      const asked = msg.params?.protocolVersion;
      result = { protocolVersion: versions.includes(asked) ? asked : versions[0], capabilities: { tools: {} },
                 serverInfo: { name: "oauth-ref", version: "1.0.0" } };
      break;
    }
    case "ping": result = {}; break;
    case "tools/list":
      result = { tools: [{ name: "whoami", description: "Returns the OAuth client this request was authorized for.",
                           inputSchema: { type: "object", properties: {} }, annotations: { readOnlyHint: true } }] };
      break;
    case "tools/call":
      result = { content: [{ type: "text", text: `client=${token.client_id}` }], isError: false };
      break;
    default:
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "Method not found" } }));
  }
  res.writeHead(200, { "Content-Type": "application/json", "Mcp-Session-Id": "oauth-ref-session" });
  res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }));
}).listen(port, "127.0.0.1", () => console.log(`mcp-ref oauth: ${resource} (AS ${issuer})`));
