# M7 card: web search, MCP connections, Composio relay, skills, tools page

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M7.md`. This card doesn't repeat task steps. Where it and `M7.md` disagree on a repo fact, the card is right (checked against the tree on 2026-11-04, `integration/m0` = `420d5ff7`).

## What M7 delivers
Free keyless web search in the app process (DuckDuckGo, Brave, Mojeek, Startpage, Wikipedia; no Google), local fetch + extraction + ranking, citation pills that only point at fetched pages, a Sources panel, and the fresh-information hint. Remote MCP connections (token, OAuth 2.1 with the AntiChat CIMD), tool-change review, Composio through the AntiChat Vercel relay with per-slug permissions, Agent Skills (store, progressive disclosure, create by chatting, no silent scripts), and the Tools page with per-chat toggles and load-when-needed. R-241 audit at full scope.
**Exit:** `M7.md` §0 "Exit" row minus AT-251, AT-252 and AT-259 (moved, D-026). Journey 12 must pass.

## Order (chunks, BUILD-ORDER.md)
[T01 T02 T03 T05 T06 T07 T08] → [T10 T11 T12 T13 T14 T15 T16].
Dependencies: T01 → T02 → T03 → T05 · T03 → T14 · T06 → T07, T08, T11, T13 (`PromptDump`) · T10 → T11 · T12 → T13 · everything → T15 → T16.

## D-026 moves and slims that touch M7
- **M7.T04** (BYO + hosted provider, AT-251, AT-252) → M11 A3. The broker's fallback chain ends at Wikipedia; leave a `providers` hook, compile no provider. AT-080 c2 asserts "works with no key"; the BYO half is M11. M7.T16 re-checks "no Google": remove or keep un-compiled the vendored `google_cse` entry of `SearchProviderCatalog.swift`.
- **M7.T09** (local stdio MCP sandbox, AT-259) → M11 A4. AT-081 c4's "local servers sandboxed" leg is recorded `moved (D-026)`. `conn.local.*` keys are not added.
- **Note 6:** **M7.T13 creates `AntiChatPlatform/ProcessLauncher.swift`** (wraps swift-subprocess 1.0.2, `spawnCount`) **and `tools/ci/no-raw-process.py`** (+ allow-list seeded with today's launch sites, wired into `make audit`). Nothing exists yet (`grep -r ProcessLauncher Packages` = 0).
- **M7.T13 eval:** T0 + T1 legs only; T2 leg → M11 B5 (same bars).
- **AT-057** (tools during voice) re-run → M3.T14, not M7.T16.
- **Verification scope (D-025), T16:** keeps every M7 AT, journey 12, `spotcheck-20.csv`, the "zero pills without a fetched source" hard check, headline NFR-U12 and T1 search answer latency. C1/R1 re-runs → M9.T05; blind S-10/S-21 §7–8 scoring → M9.T08. Still required: `make test-unit` + `make audit`, independent `/code-review` (high), running-app check, 1440×900 light+dark captures with H3–H7. T15 is unchanged (security/privacy).

## Repo reality (the PRD text is older than the code)
- **Osaurus search is already vendored** (M0): `Services/Search/{SearchTypes,SearchEngine,NativeSearchBackends,DeclarativeSearchBackend,SearchHTMLHelpers,SearchReadability,…}.swift` + `Models/Configuration/SearchProvider*.swift` are on the allow-list and their sessions are patched to `OsaurusNetworkHooks.session(.search)` (UP-OS-002/003, `AntiChatPlatform/VendorHooks.swift`). T01 step 1 is verify + make the needed types `public` (marker per edit), not a new vendor import. The backends (`DDGScrapeBackend`, `BraveScrapeBackend`, `DeclarativeSearchBackend`, `SearchHTML`) are internal today.
- **Web search on/off is the gate's `.search` category** (`NetworkPolicyStore`, key `net.category.search`, default on; onboarding step 4 already writes it). There is no `Defaults[.webSearchEnabled]`: read/write the policy store; Offline only = `NetworkPolicyStore.offlineOnly`.
- **Proxy test path exists:** `-TestProxy host:port` (`NetworkGate.testProxy` → `connectionProxyDictionary`) and `tools/offline/proxy-logger.py` (M2.T03). T01's `-NetworkGateProxy`/`mitm-recorder.py` reuse them; don't add a second proxy switch.
- **`tier-budgets.json`** is `Packages/Harness/Resources/tier-budgets.json` (resource of `AntiChatHarness`), loader `TierBudgets` in `Harness/Context/DocumentBudget.swift` (section `files` only). `AntiChatTools` can't import Harness: Harness reads the budget and passes numbers into Tools APIs.
- **Package edges:** `AntiChatTools` → Network, Storage, Foundation, OsaurusVendored, MCP (swift-sdk `68300d7`, A-M7-02 already satisfied), EventSource, DuckDB… It does **not** see Platform, where the catalog lives (`CatalogStore`, `CatalogVerifier`, `ModelCatalog` schema 2; unknown top-level keys are ignored). Search engine config: Tools decodes the `search_engines` section from bytes the Platform store already verified; the composition root wires it.
- **HTML parsing:** Kanna is pinned in `tools/ci/pins.json` (`6.1.0`, "when present") but not in `Package.swift`. Foundation `XMLDocument(.documentTidyHTML)` + `nodes(forXPath:)` (libxml2 XPath 1.0, no new dependency) runs the ddgs XPaths verbatim; use it unless a case needs Kanna.
- **trafilatura-swift is not in `Binaries/checksums.json`** (M0.T01 never pinned it). T02 decides: add the binary target, or ship `ReadabilityFallback` (vendored `SearchReadability`) first per its failure-mode row.
- **Tool loop:** `Harness/Tools/{ToolRegistry,PermissionGate,SlashCommandRegistry}.swift`; `SlashCommandRegistry.webSearchEnabled` hides the + menu row until M7 (`-FakeWebSearchEnabled`). SidePanel: `UI/Artifacts/SidePanel.swift`.
- **Copy keys already in the deck:** `set.tools.web(.note)`, `status.searching`, `act.searched`, `network.offlineForSearch`, `search.failed`, `approve.untrusted`, `net.offlineShort`, `onb.4.search.*`. New ones per `M7.md` §0.6.
- **Migrations** end at `v14_files_m6`; parallel M6 branches add more. Name new ones distinctively (`v17_search`, …) and expect renumbering at merge. Provenance is JSON (`message.provenance_json`), so T03 needs no migration.
- **Fixtures are empty:** `fixtures/web/{serp-snapshots,extraction-960,mcp}` hold only `SOURCES.md`; no `fixtures/skills/`; no `search-availability-100`, `citation-qa-100`, `fresh-vs-stable-200`. No `relay/`, no `tools/mcp-ref/`. The owning task creates them (generator in `tools/fixtures/`, `SOURCES.md`, `fixtures.lock.json`) and pushes the submodule.
- **Bench:** subcommands live in `tools/bench/Sources/antichat-bench/*.swift` (pattern `ToolEval.swift`).
- **XCUITest can't start (Q-015):** write UI tests, run the in-process probe path (`tools/at/*-probe.sh`), record the XCUITest leg `pending (Q-015)`.

## Key types (names are contracts)
- **Search (T01):** `EngineRegistry.{enabled, allCompiled}`, `SearchBroker.search(queries:budget:) -> SearchResultSet` (race, dedupe by normalized URL, `engine` provenance, fallback → Wikipedia, `.failed(reason)` only when all fail), `CatalogEngineConfig` (verified `search_engines` overrides, keep last good), `SafeSearch.parameter(for:on:)` (the only search code mentioning safety).
- **Fetch (T02):** `SSRFGuard.check(url)` (re-check every redirect), `PageFetcher.fetch(urls:budget:)`, `NetworkGate.session(for:configuration:)` (ephemeral overload), `Extractor`, `Chunker`, `EvidenceRanker`, `EvidenceBudget.fit(chunks:budget:)`.
- **Turn (T03):** `WebSearchAvailability`, tools `web_search {queries, freshness, category}` / `read_url {url}`, `WebResultsBlock` (`<web_results untrusted="true">`), `UntrustedContextRule`, `CitationValidator` (pill only if `n` ∈ fetched sources), `provenance.sources[] {n,url,title,site,date,favicon_data,snippet,fetched}`.
- **MCP (T06–T08):** `MCPHost`, `MCPConnection`, `MCPToolProxy`, `ToolAnnotations`, `PromptDump`; Composio (T10/T11) via `.relay` only.

## Cross-task rules (break one and a later task fails)
1. **Every byte goes through `NetworkGate`** with a ledger row: `.search` (engines and page fetches), `.mcp`, `.relay`. No new category, no `URLSession` outside `AntiChatNetwork`/vendored hooks.
2. **Web search is an optional cloud toggle:** off-able in Settings, off under Offline only; offline the app stays fully functional and the tools are not offered (R-267). Only search words leave the Mac (consent sheet says so); never chat text, names or files.
3. **No AntiChat server in the search path** (AT-248 c2). The Composio key never ships in the app; it lives in the relay env only.
4. **No filters** (D-005/D-006, R-241): safe search is a user parameter, off by default, same in Normal and Evil. Untrusted marking is provenance + confirmation, not a filter.
5. **Incognito:** no `network_activity` rows, web cache in memory only.
6. **Copy:** every string is a deck key, in the deck and `Localizable.xcstrings` in the same commit, `copy-sync.py` green.

## Per-task essentials and ATs
- **T01** search engines + catalog config + safe search + availability harness. Step 0 copies blueprint B §B1.6/B2.6/B3.6/B4.6 into `tier-budgets.json` (`search`, `tools`, `skills`, `connections`). AT-248 c2 (enabled set = the five, no Google compiled, in-process, recorder hosts = engines + pages only), c3 (`results_nonempty/100 ≥ 0.95` with DDG blocked and with Brave blocked; live = exit evidence, `--replay` = provisional), AT-253 (valid catalog drops Mojeek + new Startpage XPath without relaunch; bad signature changes nothing), `SafeSearchTests` for AT-241 c3.
- **T02** fetch/SSRF/extract/rank/budget. AT-249 c1 (hosts = pages + engines), c2 (mean F1 ≥ 0.85 on `articles-50`; evidence ≤ tier budget in 100% of 200 × T0–T4). SSRF cases ≥ 15 feed AT-NFR-SEC5.
- **T03** `web_search` in the turn. AT-080 c1–c4, AT-248 c1 (T1 p50 ≤ 12 s, ≥ 2 pills per run), AT-250 (100% pills fetched; judged support ≥ 0.90 + `spotcheck-20.csv`, A-M7-05), AT-254 (activity ≤ 300 ms, results ≤ 2.5 s, fetch+extract ≤ 4 s, first token ≤ 8 s T1 / ≤ 5 s T3; a miss is an S2 bug + amendment, not a pass).
- **T05** fresh hint. AT-228 c1–c5, AT-NFR-U12 (no network during the run).
- **T06** MCP core. AT-081 (c4 local leg moved), AT-258 (≥ 3 servers on 2025-11-25; 2026-07-28 profile or `pending PR #314`).
- **T07** OAuth/CIMD. AT-257. **T08** tool change review. AT-260.
- **T10** relay. AT-255 c1, c2-relay, c5-relay, c6. **T11** client. AT-255 c2-app, c3, c4, c5-app; AT-256.
- **T12** skills store. AT-082, AT-261. **T13** disclosure/eval/create/no-spawn. AT-262, AT-263 (T0/T1), AT-264, AT-265.
- **T14** tools page. AT-266, AT-267, AT-268 (also verifies `tier-budgets.json`, adds the no-retype lint).
- **T15** AT-241, AT-NFR-SEC4, AT-NFR-SEC5, AT-NFR-PR1 M7 extension. **T16** AT-VQ-M7, journey 12, report.

## Gotchas
- Live engines may rate-limit this Mac. Record the live failure, pass provisionally on `--replay`, repeat live in M9 (minor). Never loosen the 0.95 bar.
- Scraping ToS grey zone (K-NEW-SEARCH-1) → lawyer list in the M7 report.
- GPU/model runs: `lockf /tmp/antichat-gpu.lock …`. Note load average next to every timing number; never relax a bar because of load.
- Human-only, never blocking: Composio key/test account, Vercel login, CIMD public URL, the 20% citation spot-check (agent proxy meanwhile).
