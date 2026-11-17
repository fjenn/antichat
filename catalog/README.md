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

## Directory catalogues: skills (self-updating from a public index) and apps (live from the relay)

The skills of Settings › Skills are listed in `skills-index.json` (per skill: title, summary, category, source,
licence, the commit its files are pinned to, and the size and SHA-256 of every file). It is not served from the
site and it is not signed.

**Where it comes from.** A small public repository, `fjenn/antichat-skills-index`, holds the file and the tooling
that makes it (`tools/skills/` here is the source; `tools/skills/export-index-repo.sh` copies it there, `--check`
reports drift). Its workflow (`refresh.yml`, weekly and on demand, no secrets) runs `refresh.py`:

1. `build-index.py --refresh` regenerates the index at every source's newest commit. Skills curated in
   `overrides.json` follow their source. A skill that now breaks an automatic rule or matches an unsafe-text
   pattern is dropped. A skill that is new upstream (neither curated nor listed under `known`) is included only
   when it passes the automatic filters, with a derived title, summary and category; the job summary lists it.
2. The result is refused, and nothing is committed, when the generator failed, the index lost more than 10% of
   its skills, a skill breaks the importer's rules or points outside the source repositories, or any file
   downloaded from the URL the app would use does not have the listed size and hash.
3. Otherwise the new `skills-index.json` is committed. An unchanged index gives the same bytes and no commit.

**What the app does** (`DirectoryCatalogs.swift`). It ships a copy and fetches the file from
`Config/Endpoints.plist` `SkillsIndexURL` (raw.githubusercontent.com) through the gate (category `.catalog`,
conditional requests): when the user opens Settings › Skills with a copy a day old, and from then on once a day in
the background. An install that never opened that page asks for nothing. Never in Offline only. A download is used
only when it is under 4 MB, passes the strict schema, has a later `generated` day than the index in use, names only
files on raw.githubusercontent.com under one of the three source repositories compiled into the app (each at a
40-hex commit, relative paths without `..`), and has at least half as many skills as the bundled index. Any failure
keeps the current index, silently.

**Why there is no signature.** The signed scheme this replaces needed the owner's offline key and a site deploy for
every refresh, so the list did not move between app updates. The model catalogue keeps its signature: it decides
what is downloaded and run without a review step. The skills list is trusted on something else:

1. it comes from the owner's GitHub repository over TLS;
2. it can only name files in the three source repositories compiled into the app, each pinned to a commit (GitHub
   also serves fork commits under the parent repository's name, so this narrows what a tampered index could list;
   the next three points do not depend on it);
3. every file is checked against the index's size and SHA-256 at install;
4. nothing is installed without the review sheet, which shows the whole skill;
5. a skill's scripts run only in the sandbox, after their own approval.

`make skills-index` runs the same refresh here, for the copy the next app build ships (`DRY=1`: validate only).

The apps of Settings › Connections are not published at all. The app ships a curated snapshot
(`composio-catalog.json`: summaries, categories, popular ranks, logos; refreshed at release time with
`tools/composio/build-catalog.py`) and every install asks the relay which apps exist right now (`GET /v1/toolkits`,
`relay/README.md`; at most once a day: when the user opens Settings › Connections or a Connect card, and in the background only
once an app is connected; never in Offline only).
`LiveAppCatalog.swift` merges the two: the relay's list decides which apps show, a curated entry wins, and a new app
gets a derived summary, a mapped category and its logo from `logos.composio.dev` (kept in `Catalog/Logos/`, 16 MB cap).
