# catalog/

Sources of the signed model catalog (`make catalog` → `build/catalog/catalog.json`, schema 2, blueprint E §E.2.2).

| File | What |
|---|---|
| `models.yaml` | model entries (repo, commit, files, licence) — M2.T04 |
| `assignments.yaml` | tier × speed class cells, roles, tone sentence — M2.T04 |
| `catalog.lock.json` | what Hugging Face reported per key at its commit |
| `search-engines.yaml` | keyless web search engines → `search_engines` — M7.T01 |
| `mcp-curated.yaml` | the "Popular connections" MCP servers → `mcp_curated` — M7.T06 |
| `schema/catalog-v2.schema.json` | the manifest schema |
| `schema/search-engines.schema.json` | the `search_engines` section schema |
| `dev.yaml`, `dev-catalog.json` | the M1 dev catalog (not signed, Debug only) |

## `search_engines` (M7.T01, R-253, G-029)

`catalog-tool build` copies `search-engines.yaml` `engines` verbatim into `catalog.json` `search_engines`; it is
signed with the rest of the catalog (keys A or B, NFR-SEC7) and validated by `tools/ci/catalog-schema-check.py`.
The app applies an entry only after the catalog verified, by `id`, and only for an engine this build compiles
(`EngineRegistry.allCompiled`): the catalog can disable an engine or change its URL template or XPaths without an
app update, but can never add one (no Google, AT-248 c2). A bad signature keeps the last good catalog, so the engine
set does not change (`catalog.badSignature`).

| Field | Meaning |
|---|---|
| `id` | engine id (`duckduckgo`, `brave`, `mojeek`, `startpage`, `wikipedia`, `bing`) |
| `name` | display name (the consent sheet lists the enabled names) |
| `enabled` | in the default race; Bing ships `false` |
| `kind` | `html` (scraped page) or `declarative` (JSON API) |
| `parser` | `osaurus-ddg`, `osaurus-brave`, `osaurus-bing` (vendored Osaurus parsers), `xpath`, `declarative`; must match the build's parser for that id |
| `url_template` | `{q}` = percent-encoded query words, `{lang}` = result language |
| `xpaths` | `xpath` engines: ddgs `items`, `title`, `href`, `body` (XPath 1.0) |
| `endpoint`, `url_from_title` | `declarative` engines: vendored `SearchEndpoint` (query params, response key paths); hit URL built from the title |
| `safe_param` | the engine's own parameter for `off` / `on` (`k=v`, empty = none). The app sends `off` unless the user turns "Safe search results" on (settings-map §7; same in both modes) |
| `drop_url_prefixes` | hits starting with these are dropped (Startpage's google.com redirects) |
| `min_app_version` | older apps ignore the entry and keep their default |

Only the query words leave the Mac; no AntiChat server is in the search path.

## `mcp_curated` (M7.T06, R-081 AC4, G-030)

`catalog-tool build` copies `mcp-curated.yaml` `servers` verbatim into `catalog.json` `mcp_curated` (signed, validated
by `catalog/schema/mcp-curated.schema.json`: ≥ 10 entries, https only). The app's Connections directory shows the
verified list (else its built-in copy of the same ids). Display-only: nothing connects until the user adds one. A
server added from a *verified* entry gets one trust input: its `readOnlyHint` tools start on Always allow.

| Field | Meaning |
|---|---|
| `id` | stable id (`mcp_server.curated_id`) |
| `name`, `tagline`, `icon`, `category` | the directory card (SF Symbol icon) |
| `url` | the Streamable HTTP endpoint |
| `auth` | `none`, `token` (pasted bearer, Keychain) or `oauth` (OAuth 2.1, M7.T07) |
| `cimd_only` | sign-in works only with AntiChat's client metadata document; hidden until it is published |
| `help_url` | where to get a token |
