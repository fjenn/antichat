# AntiChat Composio relay

Vercel (Node 24, `iad1`, `maxDuration` 300 s) pass-through between the AntiChat app and Composio ToolRouter MCP
sessions (M7.T10, R-255, D-007). It is the only AntiChat-run server. The Composio credential exists only in this
project's Vercel environment variables: never in the app, never in this repo, never in the store.

## Environment
Variables, purposes and dev values: `docs/research/10-architecture/architecture.md` §8.3 (`COMPOSIO_API_KEY`,
`INSTALL_ID_HMAC_SECRET`, `UPSTASH_REDIS_REST_URL`/`_TOKEN`, `RELAY_ALLOWED_TOOLKITS`, `RELAY_MIN_CLIENT_VERSION`,
`RELAY_GLOBAL_DAILY_CAP`, `RELAY_DISABLED`). Set by the owner in Vercel, never by the build. Rules enforced in
`src/policy.ts`:
- `COMPOSIO_API_KEY=dev-not-a-key` (or unset) → every route except `/v1/health` answers `503 relay.notConfigured`
  before any Composio call.
- Production (`VERCEL_ENV=production`) refuses to start when `COMPOSIO_BASE_URL` or `COMPOSIO_ALLOW_INSECURE_HTTP`
  is set; `RELAY_TEST_MCP_PER_MIN` is ignored there (logged).
- Without both Upstash variables (dev/test, and production since release 2: A-R2-RELAY, owner decision) the store and
  limiter are in memory, **per instance**: every per-install limit and `RELAY_GLOBAL_DAILY_CAP` (production: 2000) hold
  per warm instance, not globally, and reset on a cold start. Production logs `relay.limitsPerInstance` once per
  instance. A cold instance also loses `sess:<userId>`: the next request creates a new ToolRouter session (the
  connections belong to the Composio user id and survive), and `/v1/mcp` answers 404 `relay.notFound` to the app's
  stale `Mcp-Session-Id` so it re-initializes. Setting the Upstash variables restores shared limits.
- `RELAY_DISABLED=1` is the kill switch.
- Test-only: `COMPOSIO_BASE_URL` (mock), `COMPOSIO_ALLOW_INSECURE_HTTP=1` (plain-HTTP loopback mock),
  `RELAY_TEST_MCP_PER_MIN`, `RELAY_LOCAL_MOCK=1` + `RELAY_MOCK_PORT` (local-server starts the mock).

## API (app contract, M7.T11)
Every route except `/v1/health` needs `X-AntiChat-Install: <UUIDv4>`, `X-AntiChat-Version`, `User-Agent: AntiChat/<ver>`.
| Route | Answer |
|---|---|
| `GET /v1/health` | `{ok:true, version}` |
| `POST /v1/session` | `{ok:true}` (creates or reuses the ToolRouter session; no Composio URL/headers) |
| `POST/GET/DELETE /v1/mcp` | Streamable-HTTP pass-through (session created on demand; `Mcp-Session-Id` both ways) |
| `GET /v1/connections` | `{toolkits:[…], connections:[{id, toolkit, status}]}` |
| `POST /v1/connections/link` `{toolkit[, callback_url]}` | `{url, id}` (Composio hosted auth URL) |
| `DELETE /v1/connections/<id>` | `{ok:true}` (own connections only, else 404 `relay.notFound`) |
| `POST /v1/forget` | `{ok:true}` (disconnects all, deletes the session and `sess:<userId>`) |

Errors are `{code}`: 400 `relay.badRequest`, 426 `relay.updateRequired`, 429 `relay.rateLimited` (+ `Retry-After`),
503 `relay.notConfigured` / `relay.disabled` / `relay.overCapacity`, 502 `relay.upstream`, 500 `relay.misconfigured`.
Limits (architecture §8.4): MCP 60/min, tool calls 500/24 h, session creates 10/h, link attempts 10/h per install;
new install IDs 20/h per IP (/64); `RELAY_GLOBAL_DAILY_CAP` tool calls/24 h overall.

State (R-255 AC6): only `sess:<userId>` (`{sid, url}`, 1 h) and limiter counters `rl:*`. Logs: one JSON line per
request with `{route, status, latency_ms, uid8}`, nothing else.

## Local
- `make relay-test` — `npm ci --ignore-scripts && npm test` (vitest; mock Composio from `test/mock-composio.ts`
  replaying `fixtures/web/mcp/composio-*.jsonl`; needs the fixtures submodule).
- `make relay-dev` — `vercel dev` if the CLI is logged in, else `scripts/local-server.ts` on `http://127.0.0.1:3000`
  (`PORT` overrides) with `.env.local` (`npm run make-env`; add `-- --mock` for the mock) or `.env.test` (mock).
- `npm run dump-keys` — store dump after a full mocked session (Upstash `SCAN` when its variables are set).
- `npm run typecheck`.

## Deploy (human only)
`cd relay && npx vercel deploy` (preview) only when `npx vercel whoami` succeeds; production is promoted manually in
the release checklist (ci-release §8). Rollback: `vercel rollback` or `RELAY_DISABLED=1`.
