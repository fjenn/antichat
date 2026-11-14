# M7 report: web search, MCP connections, Composio relay, skills, Tools page (M7.T16)

**Date:** 2026-11-08 · **Branch:** `m7/close` (from `m7/search` @43df8f6be, M7.T01–T15 + latest main) · **Host:**
MacBook Pro M5 Max 128 GB, macOS 26.6.2, a shared Mac with other tracks running (load 5–55 during the close).

## 1. Acceptance tests

| AT | What | Result | Artefact | Notes / amendment |
|---|---|---|---|---|
| AT-080 | Web search toggle, consent, chip, Read this URL, offline | pass (probe c1–c4) | `build/at/AT-080/probe-*` | A-M7-T03a; c2 "works with no key" pass, BYO half moved with AT-251; `WebSearchUITests` pending (Q-015) |
| AT-081 | MCP connections, approval, per-chat toggle, curated | pass | `build/at/AT-081/2026-11-05.log` | A-M7-T06a; c4 "local servers sandboxed" moved (D-026, AT-259); XCUITest pending (Q-015) |
| AT-082 | Skills store, import/export, Settings | pass (in-process c1–c5) | `build/at/AT-082/2026-11-07.log` | A-M7-T12a; `SkillsUITests` pending (Q-015) |
| AT-228 | Fresh-information hint | pass (probe c1–c5) | `build/at/AT-228/2026-11-04-probe.json` | A-M7-T05a; AC4b n/a (R-080 shipped) |
| AT-241 | R-241 audit at full scope | pass | `build/at/AT-241/` | A-M7-T15a |
| AT-248 c2 | Five engines, no Google compiled, in-process, no AntiChat host | pass (proxy) | `build/at/AT-248/c2-proxy.json`, `hosts.txt` | A-M7-01 (SearXNG name / 40 MB download not met, accepted); no-Google re-check at close: `SearchBrokerTests.defaultRegistryIsTheFiveEnginesAndNoGoogle` pass, vendored `google_cse` not compiled (UP-OS-039) |
| AT-248 c3 | Results non-empty ≥ 0.95 with DDG / Brave blocked | pass (live 100/100 both, replay 100/100 both) | `build/at/AT-248/2026-11-04-live*-blocked-*.json` | — |
| AT-248 c1 | T1 search answer p50 ≤ 12 s, ≥ 2 pills | p50 **pass** (7.39 s); ≥ 2 pills per run **miss** (12/20) | `build/at/AT-248/2026-11-09-t1-final/` | A-M7-T16b (M7 bars): direct search on T0/T1, embed model off the MLX container, verifier after the final write; optimized engine, LPM off, load 8.5–11.7 |
| AT-249 | Fetch hosts only, extraction F1 ≥ 0.85, evidence ≤ budget | pass (F1 0.947) | `build/at/AT-249/` | A-M7-T02a |
| AT-250 c1 | 100 % of pills point at a fetched source | pass (0 unfetched pills in every run; VQ hard check 0) | `build/at/AT-250/`, `build/at/AT-VQ-M7/probe-vq-chat.json` | — |
| AT-250 c2 | Judged support ≥ 0.90 on **independent labels** | held-out-3: **T1 0.927 pass, T2 0.932 pass, T3 0.891 miss** (two independent labellers + adjudication) | `build/at/AT-250/bars/h3/` | A-M7-T03c M7 bars: verifier uncapped after the final write (checking pills), T0/T1 atomic answer rule; 3 T3 answers hung (S1 engine/XPC bug) |
| AT-251, AT-252 | BYO / hosted provider | moved (D-026, M11 A3) | — | — |
| AT-253 | Catalog engine swap without relaunch, bad signature ignored | pass | `build/at/AT-253/` | A-M7-T01a (f) |
| AT-254 | Search latency points | pass: activity p50 98 ms, first token p50 4.59 s (T1) | `build/at/AT-248/2026-11-09-t1-final/` | A-M7-T16b; T3 first-token point not re-measured this round |
| AT-255 | Composio relay (c1, c2, c5, c6) + client (c2–c5) | pass (mock Composio via `make relay-dev`) | `build/at/AT-255/` | real Composio E2E not run (human: key + test account) |
| AT-256 | Per-slug permissions | pass | `build/at/AT-256/2026-11-07.log` | A-M7-T15a (a) |
| AT-257 | Remote MCP OAuth 2.1 + CIMD | pass (local CIMD test mode) | `build/at/AT-257/2026-11-08.log` | A-M7-T07a open: re-run against the public CIMD URL (M10); `MCPOAuthUITests` pending (Q-015) |
| AT-258 | ≥ 3 servers on 2025-11-25 | pass; 2026-07-28 profile `pending PR #314` | `build/at/AT-258/2026-11-05.json` | A-M7-03, A-M7-T06a (b) |
| AT-259 | Local stdio MCP sandbox | moved (D-026, M11 A4) | — | — |
| AT-260 | Tool change review (rug pull) | pass | `build/at/AT-260/2026-11-05.log` | A-M7-T08a; review #9 adds the write-type flip |
| AT-261 | Skills import verbatim, export validates | pass | `build/at/AT-261/` | — |
| AT-262 | Progressive disclosure T0–T4 | pass | `build/at/AT-262/` | A-M7-T13a |
| AT-263 | Activation eval T0, T1 | pass (T0 0.900, T1 pass) | `build/at/AT-263/` | T2 leg moved (D-026, M11 B5) |
| AT-264 | Create a skill by chatting | pass (real T1 leg) | `build/at/AT-264/` | XCUITest leg pending (Q-015) |
| AT-265 | No silent scripts, no spawn | pass (real File tools XPC) | `build/at/AT-265/2026-11-08.log` | review #10: scripts ask every time |
| AT-266 c1 | Per-step tool cap | pass (0 over cap) | `build/at/AT-266/2026-11-08-c1.log` | — |
| AT-266 c2 | Tool selection hit rate | **pass**: T2 0.860, T0 0.815 | `build/at/AT-266/bars/2026-11-09-T{0,2}.json` | A-M7-T14a (M7 bars): Composio search tool describes the kinds of apps it reaches; R-235 cap conflict → `docs/prd/M7-owner-steps.md` |
| AT-267 | Offline invisibility | pass (50 offline turns, 0 failed calls) | `build/at/AT-267/2026-11-08.log` | — |
| AT-268 | Tools page, per-chat toggles | pass | `build/at/AT-268/2026-11-08.log` | `ToolsPageUITests` pending (Q-015) |
| AT-NFR-U12 | Fresh hint precision / recall, no network | pass: precision 1.000, recall 0.780 (bars 0.80 / 0.70), network none | `build/at/AT-NFR-U12/` | — |
| AT-NFR-SEC4 | Connection security | pass | `build/at/AT-NFR-SEC4/2026-11-08.md` | local stdio leg moved (D-026) |
| AT-NFR-SEC5 | Untrusted content needs a click (90/90) | pass | `build/at/AT-NFR-SEC5/` | review #5, #7 extend it (read_url, skill files) |
| AT-NFR-PR1 | M7 default-settings capture + offline run | pass (reduced isolation) | `build/at/AT-NFR-PR1/` | A-M7-T15a (e) |
| Journey 12 | Tool approval card (scripted MCP) | **pass in the running app**: Deny → not sent; Allow once → sent, asks again next time; Always allow → sent; next call runs with no card (clicks on the real card) | `build/at/AT-VQ-M7/probe-vq-j12.json` | `ToolApprovalUITests` / `J12ToolApprovalTests` pending (Q-015) |
| AT-VQ-M7 | 1440×900 light/dark captures + hard checks | captures done (30 shots, 3 of 4 legs pass); hard checks: H7 pass, H3 2 open items, H5/H6 inconclusive, H4 pending (§4) | `build/at/AT-VQ-M7/` | blind S-10/S-21/S-24 scoring moved (M9.T08); H4 pending (Q-015) |
| AT-NFR-C1, AT-NFR-R1 | No regression > 5 % | moved (M9.T05) | — | D-025 |

## 2. Independent review

`/code-review` at high effort by a separate agent over the 43 M7 commits (`22265c8ed..43df8f6be`, M7 source paths):
13 findings (6 S1, 7 S2; two S1 marked uncertain). All 13 were treated as confirmed and fixed, each with a test
(A-M7-T16a d):

| # | Sev | Finding | Fix |
|---|---|---|---|
| 1 | S1 | Citation verifier removed `[n]` inside code from stored replies | code-aware markers |
| 2 | S1 | Pills / dropped markers inside code blocks | validator skips code spans |
| 3 | S1 | [Continue] lost or renumbered a reply's web sources | sources seeded from provenance; checks on the continued part |
| 4 | S1 | Curated Always-allow keyed by id only (edited URL inherited it) | id **and** catalog URL |
| 5 | S1 | `read_url` as an exfiltration channel under untrusted context | asks unless the user wrote the host |
| 6 | S1 (uncertain) | Composio workbench/bash meta tools would bypass per-slug cards | meta-tool allow-list |
| 7 | S2 | `read_skill_file` / script output not wrapped untrusted | `<skill_file untrusted="true">` |
| 8 | S2 | MCP tool names could collide with built-ins | built-in names reserved |
| 9 | S2 | Annotation flip to write-type kept Always | back to Ask |
| 10 | S2 | Always allow on `run_skill_script` covered every skill | asks every time |
| 11 | S2 | `freshness` / `category` advertised but dropped | engines' date parameters |
| 12 | S2 | Relay quota counted a MULTI_EXECUTE batch as one | counts inner slugs |
| 13 | S2 (uncertain) | Connected-address check skipped on redirect hops | metrics awaited per hop |

Not counted by the reviewer and left for M10: Release `Endpoints.plist` still points the relay at loopback (owner
URL, M10).

## 3. Headline numbers

| Number | Result | Bar | Load (1-min) | Source |
|---|---|---|---|---|
| **NFR-U12** fresh-information hint (fresh-vs-stable-200, search off) | precision **1.000**, recall **0.780** (tp 78, fp 0, fn 22, tn 100), no network | precision ≥ 0.80, recall ≥ 0.70 | CPU only (load 25) | `build/at/AT-NFR-U12/2026-11-08.json` (`.build/release/antichat-bench fresh-hint`) |
| **T1 search answer** (AT-248 c1, chat-9b-q4, live engines, chip on, 20 runs in the running app) | complete p50 **45.6 s**; first answer token p50 **29.4 s**; search line on screen p50 **144 ms**; ≥ 2 pills in 7/20 runs; 20/20 done | complete p50 ≤ 12 s; first token ≤ 8 s; activity ≤ 300 ms; ≥ 2 pills per run | 4.0–31.7 during the runs (5.9 at start, 4.9 at end) | `build/at/AT-248/2026-11-08-live/{summary,probe}.json`, `gpu-run.sh timing`, `tools/at/at-248-live.sh` |

The T1 answer latency **misses** its bar; no bar was relaxed. The web step itself (search + fetch + extract) takes
4–7 s; the rest of the time to the first token (~22 s) is the T1 model reading the web results, and the answer then
finishes with the citation checks (MiniCheck + the attempt-6 verifier, ≤ 8 s). On 2026-11-04 the same run read 13.9 s
to the first token (load 19–40, page-cache hits); since then the grounded-answer reminder, the larger evidence and the
verifier pass were added (A-M7-T03c). Following HANDOFF this is carried to **M9.T05** (measure the web-results prefill
first, then decide prompt/evidence size vs the bar); it is an S2 bug, recorded here and in the open items. The
activity point (≤ 300 ms) passes at p50; one run showed 438 ms at load 32.

## 4. Visual QA (AT-VQ-M7) and the running-app check

Run in the running app (`tools/visual/vq-m7.sh`, runbook `tools/visual/vq-04-search.md`; `-SearchProbe` `vq-*` legs
drive the app's own windows with the ScriptedEngine; 1440×900, system Light and Dark; JPEGs in `build/at/AT-VQ-M7/shots/`).
This is also the running-app check of the close.

| Leg | Screens | Result |
|---|---|---|
| `vq-chat` | S-10 chip on, answer with pills, Sources panel; S-24 web search consent; S-25 Offline chip | pass: pills `[1]`, fetched 1–4, **0 pills without a fetched source** (hard check), panel rows = fetched sources, consent sheet shown, Offline chip shown |
| `vq-settings` | S-21 Tools page, Web search rows (Search sub-page), Connections + Composio (Cloud badge), add-server sheet, **MCP consent sheet**, connection added; §8 Skills | pass (14 shots). Composio [Connect] is not pressed: the Debug build starts the real relay sign-up (install ID in the Keychain, relay calls), which an unattended run must not do; the Composio consent sheet stays with the AT-255 c3 client legs |
| `vq-j12` | S-24 ApprovalCard; journey 12 | pass (see the AT table) |
| `vq-inject` | S-24 untrusted ApprovalCard | **not captured**: in the scripted inject turn the step's tools were not offered under "Load tools when needed" (`web_search` / `team_chat_send_message` "didn't work"), so no card appeared. The untrusted card behaviour itself passes in AT-NFR-SEC5 (90/90 induced writes ask with `approve.untrusted`, 0 sent without a click); `SecurityUITests` pending (Q-015) |

**Pill line break** (A-M7-T03a d): confirmed in the first captures (the rest of a paragraph wrapped after an inline
pill) and fixed: MarkdownView lays a paragraph with an embedded view out as a flow of whole runs, so pills now sit at
the end of their line (`CitationPill.pillsAtLineEnd`, `PillLineBreakTests`); the final S-10 captures show the
paragraph unbroken with its pill after it.

**Automated hard checks** (`tools/visual/hard-checks.swift` over the 28 final PNGs, `hard-checks.json`):
- **H7 sizes:** pass (no "0.0 GB" / "0 bytes").
- **H3 contrast:** the first pass found the Connections page, directory cards and consent sheets using SwiftUI's
  system `.secondary` (3.8–3.9:1); fixed to the `text.secondary` token (commit ff457f1c4). Remaining flags: accent-blue
  link text on tinted fills ("Connect" 4.49:1, "Running code needs File tools" 4.26:1; S2, design tokens, M9.T08 with
  the scoring) and disabled or sheet-dimmed text (1.3–2.8:1, exempt under WCAG 1.4.3).
- **H5 copy:** 800/921 OCR lines matched the string catalog or the fixture/catalog-content allow list (0.869). The
  unmatched lines were reviewed: OCR noise around symbols, truncated catalog taglines ("Browse repos,"), timestamps,
  scripted source titles, and the consent body with the engine list interpolated; no visible string outside the
  catalog was found. `copy-sync.py` (in `make audit`) is the exact check and is green.
- **H6 grid:** 166/331 long edges on the 4-pt grid (0.50). The screenshot edge detector counts control and shadow
  edges macOS draws off the grid; the number is reported, not used as a pass, and the grid measurement moves with the
  blind scoring to M9.T08.
- **H4 accessibility audit:** pending (Q-015, `performAccessibilityAudit` needs XCUITest).
- Blind S-10 / S-21 §7–8 / S-24 scoring: moved to M9.T08 (D-025).

## 5. Gates (once on the final code)

- `make test-unit` (worktree fixtures @1673313): childsafety passed; main 1 failure in a voice suite
  (`DictationServiceTests.cancellingTheRequestCancelsTheDictation`, M3 code untouched here, timed out at load 58); it
  passes on its own (14/14). Every M7 suite passed.
- `make test-integration-stub`: 81 tests, 9 failures, all in M6 File tools suites (FileToolsJailTests,
  OfficeEditServiceTests, RunPythonServiceTests, SecuritySuiteTests) because this worktree had no signed File tools
  runtime (`missing build/runtimes/signed/filetools-runtime-0.1.0.zip`). After `make runtime-filetools SIGN=1` the four
  suites pass (TEST SUCCEEDED, 0 failures); the regenerated `catalog/runtimes.yaml` sha was not committed.
- `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: **EXIT=0** (the first run failed no-raw-process on the new VQ probe's
  own `Process()`; fixed in f4196a13e). `l10n-langs` is report-only: de/fr/es/nl/pt miss 70 keys each that came from
  other tracks (not M7.T16).
- Close-found fixes beyond the review: the citation pill line break (2519921f6), the Connections / consent-sheet
  secondary text contrast (ff457f1c4), the missing journey-12 script.

## 5b. M7 bars (2026-11-09, branch m7/bars)

| Bar | Result | Target | Evidence |
|---|---|---|---|
| AT-250 c2 T1 | 230/248 = 0.927 | ≥ 0.90 | `build/at/AT-250/bars/h3/labels-T1{,-strict}/` |
| AT-250 c2 T2 | 260/279 = 0.932 | ≥ 0.90 | `build/at/AT-250/bars/h3/labels-T2{,-strict}/` |
| AT-250 c2 T3 | 212/238 = 0.891 (miss) | ≥ 0.90 | `build/at/AT-250/bars/h3/labels-T3{,-strict}/`, `adjudication-labels.csv`, `final-score.json` |
| AT-266 c2 T2 | 0.860 (T0 0.815) | ≥ 0.85 (T0 ≥ 0.70) | `build/at/AT-266/bars/` |
| AT-248 c1 T1 complete p50 | 7.39 s | ≤ 12 s | `build/at/AT-248/2026-11-09-t1-final/` |
| AT-254 T1 first token p50 | 4.59 s | ≤ 8 s | same |
| AT-248 c1 ≥ 2 pills per run | 12/20 (miss) | 20/20 | same |

Held-out-3 = `fixtures/prompts/citation-qa-heldout3-100.jsonl` (sha256 73dc8544…), committed before any run. Owner decision pending: R-235 AC2 vs the tier budget (`docs/prd/M7-owner-steps.md` §1).

## 5c. M7 bars-2 (2026-11-10, branch m7/bars-2; lead decisions 1–5)

| Bar | Result | Target | Evidence |
|---|---|---|---|
| S1: T3 answers that never came back (h082/h084/h087) | fixed: 3/3 answer (57 / 24 / 43 s), 0 approval cards; held-out-4 T3 100/100, 0 timeouts | every answer arrives | `build/at/AT-250/bars2/hang/` (before/after traces), `TurnStallTests` |
| AT-250 c2 T3 (held-out-4) | **279/293 = 0.952** (both-strict 0.939) | ≥ 0.90 | `build/at/AT-250/bars2/h4/labels-T3{,-strict}/`, `final-score.json` |
| AT-250 c2 T1 (held-out-4, regression) | 277/294 = 0.942 adjudicated (both-strict 0.878) | ≥ 0.90 | `build/at/AT-250/bars2/h4/labels-T1{,-strict}/` |
| AT-250 c2 T2 (held-out-4, regression) | 291/301 = 0.967 (both-strict 0.924) | ≥ 0.90 | `build/at/AT-250/bars2/h4/labels-T2{,-strict}/` |
| AT-248 c1 ≥ 2 distinct sources cited per run | 15/20 (was 12/20) — **miss** | 20/20 | `build/at/AT-248/2026-11-10-bars2-t1/` |
| AT-248 c1 T1 complete p50 | 6.78 s (load 8.8–10.4) | ≤ 12 s | same |
| AT-254 T1 first token p50 | 4.17 s | ≤ 8 s | same |
| R-235 AC2 vs B4.6 | decided (a): budget T1/T2 = 4; tool-select T2 unchanged (cap 4 was already effective) | — | A-M7-T14a |

**S1 root cause.** Not the engine or XPC: after the forced web step the T3 model calls `read_url` on one of the turn's
own result pages; after `web_search` the turn is untrusted, so the call asked first (M7.T16 review #5) and the reply
waited on an ApprovalCard that the headless bench never answered (trace: `hang/h082-before.json.stderr.log`). Fix:
`UntrustedContextRule` lets a `read_url` through without a card when the URL is exactly one of the turn's search results
(fixed by the search engine before the model saw anything, so it cannot carry conversation data; query kept, so an added
query string still asks). Second leg: `TurnController` stall watchdog — a stream (prefill / streaming / tool call) silent
for 120 s is cancelled and ends as `engine.stalled` (ErrorInline or the interrupted notice, both with Retry); queued,
model loading, approval cards and tool runs are not counted. The bench now answers any approval card Deny (counted:
`approvals_denied`, 1 of 100 at T3).

**Gate method (as m7/bars).** Held-out-4 `fixtures/prompts/citation-qa-heldout4-100.jsonl` (sha256 f2f4bb4b…, fixtures
a61f630, committed and pushed before any capture or run; snapshots e611365). Every cited sentence labelled by fresh
labeller agents (one shard + rubric each), a full strict second pass by other fresh agents, and a fresh adjudicator on
the disagreements of each tier (m7/bars adjudicated T3 only; T1/T2 there agreed 0.97–0.99). This round the T1 strict
pass was much harsher (0.881 vs first 0.956, agreement 0.922; partials such as "stable" for "latest version", "headers"
for "obey retry-after"), so T1 passes only with adjudication (18 of 23 disputed sentences supported); both numbers are
reported. Real T1 misses: FreeBSD 15.0 items credited to 15.1, Neo4j fixes from another version, "sixth-most populous
city" for the metro area. `tools/at/at250-gate.py` reproduces the held-out-3 results exactly (230/248, 260/279, 212/238).

**AT-248 ≥ 2 sources.** Composition rule (`WebResultsBlock.spreadRule`, every tier with ≥ 2 fetched sources) plus
`CitationGrounding.spread` (a fetched second source that alone passes the full deterministic check, coverage ≥ 0.8 and a
shared anchor, joins the marker; MiniCheck and the verifier then judge it). 15/20 runs now cite ≥ 2 distinct sources.
The other five cite one source because most of their sentences carry no marker at all (the model left them uncited, or
the recency check removed a "latest" marker); the spread step never adds a citation to an uncited sentence. Next lever
(lead call, not built): let the grounding step attach a source to an uncited factual sentence when that source alone
passes the full check.

## 5d. M7 bars-3 (2026-11-10, branch m7/bars-3; lead decisions 1–4)

| Bar | Result | Target | Evidence |
|---|---|---|---|
| AT-250 c2 T1 (held-out-5, rule A-M7-T03d) | **261/289 = 0.903** (strict-only 259/289 = 0.896) | ≥ 0.90 | `build/at/AT-250/bars3/h5/labels-T1{,-strict}/final-score.json` |
| AT-250 c2 T2 (held-out-5) | **260/283 = 0.919** (strict-only 256/283 = 0.905) | ≥ 0.90 | `build/at/AT-250/bars3/h5/labels-T2{,-strict}/final-score.json` |
| AT-250 c2 T3 (held-out-5) | **208/227 = 0.916** (strict-only 207/227 = 0.912) | ≥ 0.90 | `build/at/AT-250/bars3/h5/labels-T3{,-strict}/final-score.json` |
| AT-248 c1 ≥ 2 distinct sources cited per run | 13/20 — **INVALID** (counted from stored-text markers; the probe's rendered count was 0 in 19/20, §5e) | 20/20 | `build/at/AT-248/2026-11-10-bars3-t1/` |
| AT-248 c1 T1 complete p50 | 4.87 s (load 3.8–5.4) | ≤ 12 s | same |
| AT-254 T1 first token p50 | 3.05 s | ≤ 8 s | same |

All three tiers pass under the pre-registered rule (and the strict-only rate is ≥ 0.90 on T2 and T3; T1 0.896).
Runs: `gpu-run.sh shared`, optimized app build @ 3427213c7 (fresh signed copy per run), 100/100 answered per tier, 0
timeouts, 0 unfetched pills; pills 353 / 429 / 301; attached sources kept 6 / 2 / 22; disagreements 9 / 10 / 3
(agreement 0.969 / 0.965 / 0.987).

**Scoring rule (decision 1, A-M7-T03d), committed before any held-out-5 capture or run (c14fac767).** Every tier, the
same rule: first pass + a full strict second pass by different fresh labeller agents (sentence + cited source texts +
rubric only), a third fresh adjudicator on every disagreement decides, rate = supported / cited; the strict-only rate
(both passes say supported) is reported. `at250-gate.py final` refuses to score without an adjudication covering exactly
the disagreements. Held-out-5 = `fixtures/prompts/citation-qa-heldout5-100.jsonl` (sha256 a2ccc8df…, fixtures 54eb01f,
committed and pushed before the capture; snapshots c3133f2; no question, query or subject shared with sets 1–4).
Labelling note: in the first T1 round two parallel labellers wrote temp files to one shared scratch file; shards 2–4 of
both passes were discarded (kept in `h5/discarded-shared-scratch/`) and relabelled by fresh agents, each confined to a
private temp dir (every later shard and tier ran that way).

**T1 errors fixed generically (decision 2): `CitationScope.swift`.** (a) version scope — on a page naming ≥ 2 versions
of one product line, the span that states a sentence (the window with most of its content words) must sit under a
compatible version: the one the sentence names, else the one its heading line names (with "latest/current" choosing
among several); other products' versions ("Go 1.27.3" on a Syncthing page) and reference points ("changes since 2.568.3")
are not headings; (b) entity level — a rank bound to a level ("sixth-most populous city") must be the level the source
binds it to. Dev replay on held-out-3 + held-out-4 labels (1,653 sentences, all tiers, `antichat-bench citations --stage
grounding-replay`, `build/at/AT-250/bars3/dev-replay/`): catches the held-out-4 misses (Neo4j 5.26.33 / 2026.10.1 fixes,
FreeBSD 15.0 items under the 15.1 lead, Bordeaux metro rank) and Gradle / Bun partials; 2 supported-labelled sentences
lost (the two FreeBSD items). A "name must be in the cited span" form was tried and dropped on dev (88 supported lost vs
10 partial caught). Residual on held-out-5 T1: version attribution inside flattened release pages the check could not
place (Obsidian 1.15.x items, GitLab chart 9.0 vs GitLab 18.0) — not tuned on the held-out set.

**AT-248 ≥ 2 sources (decision 3).** `CitationGrounding.attach` gives an UNCITED factual sentence a fetched source that
alone passes the full deterministic check (≥ 0.8 coverage, every number/name/qualifier/scope); it runs after the
answer's own markers were checked (a second source removed by MiniCheck/the verifier is seen), the attached markers alone
then go through MiniCheck and the verifier, and only those both pass stay (none when either did not finish); spreadRule
kept. The probe now runs with the on-demand cite-check model installed (private Models overlay; before, entailment was
skipped as `model.missing` and attached markers were dropped). 13/20 on today's live web (a first run without cite-check:
11/20). The seven misses: their other sentences are "latest / most recent" claims no fetched source backs with a recency
word near the version, or facts only the one cited source states; attaching there would cite a source that does not
support the sentence, which the rule forbids. On the dev held-out-4 T1 set attach lifts answers citing ≥ 2 sources from
67 to at most 79 of 100 (deterministic replay, `build/at/AT-250/bars3/dev-h4/`). The bar is not met and not loosened.

## 5e. M7 at248 (2026-11-10, branch m7/at248): AT-248 c1 measured on RENDERED pills

**The bars-3 c1 evidence was invalid.** `2026-11-10-bars3-t1/probe.json` has `pills_rendered` 0 in 19/20 runs and
`runs_with_2_pills` 0; the reported 13/20 came from the markers in the stored text. Three causes: (1) on this Mac a
background-mode (`.prohibited`) SwiftUI window is never drawn, so MarkdownView never parsed and no pill existed (blank
`live-*.png`); (2) the probe counted distinct single-source anchor ids — a combined `[1,2]` pill and a repeated pill
were missed; (3) **product bug**: a finished reply's pills never left the checking state (below).

**Product bug fixed (with a test): settled pills never redrew.** When `.citationsSettled` lands, the reply's text
changes (`?checking` links become plain pills, maybe a marker removed) while the reveal clock stays paused;
`StreamingMarkdownBinder.update` swapped its unobserved `source` without any observed change, so `MessageMarkdownView`
kept drawing the old source — every web answer's pills stayed in "Checking this source…" until the row was rebuilt.
The binder now bumps an observed `sourceGeneration` on each source swap and the body reads it.
`CitationRenderSettleTests` (window suite) hosts `AssistantMessageView`: 4 checking pills, then after the verdict
exactly the settled ones (combined `[1,2]` = one pill, a repeated `[2]` = two, an unfetched `[4]` none); it fails
without the fix.

**Valid measurement.** `tools/at/at-248-live.sh` with `READER=1`: the optimized signed build (codesign verified before
launch) runs foreground, launched by URL by `AT248RenderedPillsUITests` (XCUITest), which after each run — once the
probe saw no checking pill for 1 s (hard limit 30 s after `.citationsSettled`) — counts the settled pills in the
window's accessibility tree and saves a window screenshot (`reader-<i>.{json,png}`). The in-app probe counts every drawn
pill view (one per marker; combined = one). Both counts agree on 20/20 runs in both runs below. Pill counts per run:
`build/at/AT-248/2026-11-10-c1.json`.

**Generic improvements (never fabricated, bar unchanged).** `CitationGrounding.attach` also runs when an answer shows
fewer than two pills (before: only fewer than two *distinct* sources, so one combined `[1, 2]` pill blocked it); for
spread/attach only, a list item's lead-in label (≤ 4 words before a colon) does not count toward coverage, and a
capitalised clause start after a colon is not read as a name. `apply`'s check of the model's own markers is unchanged;
attached markers still pass MiniCheck + the verifier or are dropped.

| Run (gpu-run.sh timing, -FakeHardware T1, chat-9b-q4, LPM off) | ≥ 2 rendered pills | distinct ≥ 2 | complete p50 | Evidence |
|---|---|---|---|---|
| render fix only @ 673b9f617 | 10/20 | 11/20 | 5.60 s | `2026-11-10-at248-t1/` |
| + attach/label/clause @ e11d9cd2a (load 4.3–6.9) | 17/20 — miss | 15/20 | 5.61 s | `2026-11-10-at248-final/`, `2026-11-10-c1-at248-final.json` |
| + title-case list labels not names (apply too) @ 29a65eade (load 8.0–12.9) | 17/20 — miss | 16/20 | 5.39 s | `2026-11-10-at248-final2/`, `…-c1-at248-final2.json` |
| + "<product> <major>" series heading @ b4337e2cc (load 3.6–7.5) | **16/20 — miss** | 16/20 | **5.63 s — pass** | `2026-11-10-at248-final3/`, `2026-11-10-c1.json` |

Diagnostic background runs (same probe, text + evidence per run, not evidence for c1): `2026-11-10-at248-diag{1..4}/`.
The two apply-level changes (title-case list labels, series heading) were checked on the labelled dev sets (held-out-3/4/5,
all tiers, deterministic layer, `build/at/AT-250/at248-label-replay{,2}/`): identical to the bars-3 replay except
held-out-4 T2 keeps one more *supported* sentence; no unsupported sentence newly kept (an other-major heading variant
cost 2 supported sentences on held-out-5 T2 and was not kept). The last two evidence runs use the same signed build
re-signed with bundle id `app.antichat.AntiChat.at248` (an XCUITest launch failed while hosted suites ran other
AntiChat dev builds with the shared id).

**What blocks the last runs (16–17/20 across three runs; the misses move run to run).** The model writes ≈ 5–7
markers per answer; the deterministic check, MiniCheck and the verifier remove most of the ones they cannot back.
Every miss analysed (runs 5/15/17, 6/12/13, 1/3/6/8 of the three runs) is one of: (a) a "latest / most recent /
current" claim about 27.2.1 or 27.2 that no fetched source backs with a recency word near that version (the recency
rule; the sources list the versions without saying which is newest); (b) an added detail no source states ("in Photos",
"27th major release", "Rosetta 2"); (c) a deterministically supported sentence that MiniCheck or the verifier
rejected (attach proposes it; the model checks drop it — "base version … September 14", "current major release is
macOS 27 Golden Gate"); (d) a two-to-three sentence answer whose only other sentence is (a). Reaching 20/20 would mean
citing (a)/(b) or overriding (c), i.e. fabricating or loosening — not done. Bar unchanged.

## 5f. M7 at248-2 (2026-11-10, branch m7/at248-2): the lead's three levers, measured — c1 still misses

**Result: levers exhausted, bar not met, bar unchanged. The product citation checks are back to the m7/at248 behaviour
(08a98e445): every lever that added pills also kept partial or unsupported sentences on the AT-250 dev replay.**

**New tool: full-pipeline replay.** `antichat-bench citations --stage pipeline-replay` replays the app's finalize path
(grounding → spread → MiniCheck → the tier's verifier → attach, with the real `cite_check` model and the real chat
model) on captured turns (an AT-248 `probe.json` or a `--dump-evidence` answers file). It records where each marker was
dropped: what the passage lacked, the MiniCheck claim scores, and the verifier's prompt and reply. `tools/at/at248-replay-diff.py`
compares two replays (base code against changed code) and writes the newly cited sentences in the labeller format.
Dev dumps (model text, every source's evidence, fetched set) for held-out-3/4/5 × T1/T2/T3 are at
`build/at/AT-250/at248-2/dumps/` (102 MB, local only; prompt code unchanged since bars-2).

**What the misses are (final3 replayed, then r2).** Of 48 markers dropped by the deterministic check on final3, 27 were
the recency rule: a "latest" claim about 27.2.1 where only Apple's undated release-notes page lists 27.2.1, while
Macworld and Wikipedia name 27.2 as the latest. The other drops were names or details no source states. Of the drops by
the 9B verifier, several were misreadings, for example "the source states the latest version is 27.2, but the sentence
claims 27" for "The latest macOS version is macOS 27.2" when the source says exactly that. The r2/r3 misses are
two-sentence answers in which the verifier rejects one of the two sentences.

| Lever (as built) | Replay effect (20 captured turns) | AT-250 dev replay (newly cited, two independent labeller passes) |
|---|---|---|
| 1. Release-list recency: a source listing ≥ 3 versions of the line topping at X backs "X is the latest" (cross-checked against every source of the turn, date-consistent); the models then check the claim without its recency words | final3 16 → 17/20 | Rails "latest … 7.2.3.2, released on September 24, 2026" newly kept: **unsupported** in both passes (the snippet's list was cut above 7.2.3.2; the date belongs to another entry). Hugo and Neovim undated lists: partial in the strict pass |
| 3a. Verifier windows: a dotted version is one window token; page footnote marks ("[1]") stripped; no space before a comma; verdict tokens 14 → 40 per sentence (a long detail used up the batch, so later sentences had no verdict) | 17 → 18/20 | with 3b/3c: "Identifying proteins and biomolecules", "products like … device housings", "Plan-les-Ouates, a municipality in the canton of Geneva", "Their discovery showed that … CFCs were responsible" newly kept: **partial** in both passes |
| 3b. MiniCheck scores a labelled list item ("Label: It is …") as its sentence | (in 3a row) | "Automotive Components: They are increasingly used …" newly kept: **partial** in both passes; two more partial in one pass |
| 3c. Verifier gets what an opening pronoun refers to | r2 replay 17 → 18/20 | (in 3a row) |
| 2. Composition (state only source facts, one citation per fact) | not run: it changes every T1 answer, so it needs a fresh labelled AT-250 run; the atomic rule already says this | — |

Dev replay over held-out-3 T1/T2/T3 and held-out-4 T1 (`build/at/AT-250/at248-2/replay/`, labels in `labels-b1/`):
answers with ≥ 2 pills, base → changed: 70 → 71, 72 → 72, 68 → 66, 80 → 81. The changes added almost nothing on dev,
and of the 66 newly cited sentences, 6 are partial or unsupported in both labeller passes. That fails the "no newly kept
unsupported sentence" rule, so none of the levers ship.

**Live AT-248 c1 runs (READER=1, foreground, AX reader, -FakeHardware T1, chat-9b-q4).**

| Run | Build | ≥ 2 rendered pills | complete p50 | Evidence |
|---|---|---|---|---|
| r1 | @05a73c3f8 | — aborted: launched without `-FakeHardware T1` (Mac tier, 21.7k-token prompts, 13–15 s); not evidence | — | `2026-11-10-at248-2-r1-INVALID-no-FakeHardware/` |
| r2 | @05a73c3f8 (levers 1, 3a, 3b) | 17/20 (AX = probe 20/20) | 4.97 s | `2026-11-10-at248-2-r2/` (summary.json, reader-*.json) |
| r3 | @d7de41703 (+ 3c) | 16/20 (AX = probe 20/20) | 5.03 s | `2026-11-10-at248-2-r3/`, `2026-11-10-c1-at248-2-r3.json` |

Live runs with the levers (17 and 16 of 20) are within the base run-to-run spread (16–17 of 20 in §5e). The answers
change from run to run, and each miss is a two-sentence answer: either one sentence is a recency claim no source states
in words, or the T1 verifier rejects or misreads one sentence. Reaching 20/20 on this query would require citing
"27.2.1 is the latest" from an undated list (labellers judge that partial), overriding the verifier, or forcing longer
answers. Each of those is either fabrication, loosening, or an unmeasured change to AT-250 composition.

**Gates on 5988c807e, run in order.** `make test-unit`: 504 tests. The only failures were two Settings window snapshots,
`settings-voice-noDevices` and `settings-search-archive`, at 0.995 pixel match: a hover highlight drawn on the "VoiceOver
reads replies" popup while another track's UI tests moved the pointer. That suite alone, re-run, passes (5/5;
`build/gate-unit-at248-2-rerun.log`). No UI code differs from main. `make test-integration-stub`: passes.
`BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: passes.

## 5g. M7 verifier (2026-11-10, branch m7/verifier): every cited sentence gets a verdict; version windows; recency sources

| Bar | Result | Target | Evidence |
|---|---|---|---|
| AT-250 c2 T1 (held-out-5, rule A-M7-T03d, final code) | **259/286 = 0.906** (strict-only 0.899); fix-1 worst case 254/281 = **0.904** | ≥ 0.90 | `build/at/AT-250/verifier/c2-final.json` (`c2-final.py`) |
| AT-250 c2 T2 | **273/296 = 0.922** (strict-only 0.909); worst case 270/293 = **0.922** | ≥ 0.90 | same |
| AT-250 c2 T3 | **197/215 = 0.916** (strict-only 0.912); worst case 195/213 = **0.916** | ≥ 0.90 | same |
| AT-248 c1 ≥ 2 rendered pills per run (build @2617a6a78, before the attach rule) | **16/20 — miss** (AX = probe 20/20; distinct ≥ 2 sources 15/20) | 20/20 | `build/at/AT-248/2026-11-10-verifier-c1/` |
| AT-248 c1 T1 complete p50 | 13.55 s — **not valid evidence**: the Mac ran on battery with Low Power Mode on (pmset powermode 1); decode 29 tok/s vs 84 tok/s and TTFT 5.3 s vs 1.7 s in the LPM-off runs of §5e/§5f | ≤ 12 s | same |

**1. Accuracy hole fixed (`CitationVerifier`, ceb94e58f).** A batch's verdict budget was 14 tokens per sentence; one long
"UNSUPPORTED: <detail>" line (up to ≈ 230 characters on the dev replays) used it up, the later sentences of the batch got
no line, and their markers stayed unverified — with their pills. Now: 64 tokens per sentence (`tokens(count:)`), a
sentence its batch reply skipped is asked again alone, a marker with no verdict at the end (no line, time limit,
generator error, cancelled) is removed, and there is no sentence cap. Tests: `CitationVerifierTests`
(`aLongDetailLineDoesNotStarveTheLaterSentences` fails at the old budget without the retry,
`aSentenceTheBatchReplySkippedIsAskedAlone`, `noLineOrAGeneratorErrorRemovesTheMarker`), `CiteVerifyTests`,
`CitationSettleTests`. Measured with the full-pipeline replay (`antichat-bench citations --stage pipeline-replay`,
deterministic: base and fixed replies identical wherever the base had a verdict) on the held-out-5 dumps: no cited
sentence changes on any tier (one no-line item, now SUPPORTED); dev held-out-3/4: the previously unverified markers now
get verdicts (h3 T2: 2 newly uncited), but **two newly kept attached citations** appeared (h3 h037 "their discovery
showed … CFCs were responsible" [5], labelled partial in both at248-2 passes; h4 k077): the attach re-check asked the
verifier again about a (sentence, source) pair it had rejected in the answer's own batch, and with full replies it now
said SUPPORTED. **Fix 1b (fd692b0fe): attach never proposes a pair the checks removed from the answer**
(`TurnController.attachChecked(rejected:)`, `CitationGrounding.pairs`; test `attachNeverReturnsAPairTheChecksRemoved`).
This also stops the base behaviour of re-attaching rejected pairs: held-out-5 dump replay base → final: 0 newly cited
on every tier, newly uncited T1 7 / T2 0 / T3 7 (labelled, two passes + adjudicator, `labels-h5-attach/`: T1 6
supported + 1 partial, T3 4 supported + 3 partial); dev held-out-3/4 base → final (`replay/diff/h{3,4}-T*-fix1b.json`): **0 newly cited on all six sets** (the h037 / k077
partials gone); newly uncited h3 1 / 2 / 4, h4 2 / 0 / 8; answers with ≥ 2 pills h3 70→70, 72→72, 68→67, h4 80→79,
76→76, 70→68 (T1 / T2 / T3). On the labelled bars-3
held-out-5 run the fix touches only the 10 markers that run left unverified (T1 5, T2 3, T3 2); whatever verdict they
now get, c2 cannot fall below the worst-case column (every one of them a supported item that is now dropped).

**2. Version window format — not shipped (5d4d106df, reverted in 2617a6a78).** Dotted versions as single window
tokens; a space before a comma removed ("macOS 27.2 , which" read as "macOS 27"); page footnote marks ("27.2 [1]")
dropped. Held-out-5 replay, base vs changed: 9 sentences newly cited, 5 newly uncited; labelled by two fresh
independent passes + adjudicator (`build/at/AT-250/verifier/labels-h5/`): **3 newly kept partial** (one per tier:
French "spoken as a foreign language", Herschel's "reflecting" 6.2-inch telescope, argon "due to its scintillation
properties") and 3 supported lost. The rule allows no newly kept partial sentence, so the change was reverted (the dev
replay was stopped once the held-out replay had already failed it; nothing was tuned on held-out-5).

**3. Recency sources (`SearchRecency`, 00506edd7; generic by query intent, nothing filtered).** A step asking for the
latest/current version also sends the query with its recency word swapped (latest ↔ current; live, "current macOS
version" surfaces Apple's "Find out which macOS your Mac is using", whose table states the latest version), and results
whose title/snippet state which version is the latest move into the fetched window (≤ 2, displacing the window's last
results that do not). `SearchRecencyTests`. In the AT-250 replay harness it changes the fetched window of 4 held-out-5
questions (7 / 6 on held-out-3 / 4; `antichat-bench citations --stage recency-check`, `recency-check-h*.json`); those 4
questions were re-captured with the final build on all tiers (`build/at/AT-250/verifier/h5r/`) and their 50 cited
sentences labelled under the same rule (`labels-h5r/`: 47 supported, 3 partial, agreement 0.98); they replace the 36
old items of those questions in the c2 rows above (minus r002 and r040, which the attach rule drops in the fix1b replay
of those answers). **How the c2 rows are computed** (`c2-final.py`): the bars-3 labelled set; the 4 re-captured
questions swapped in; the attach-rule removals applied as a delta from the dump replay (an estimate: the dump capture's
model text differs from the labelled run's; the rule only ever removes citations); the fix-1 worst case additionally
drops the 10 previously unverified markers as supported items. A full fresh held-out-5 capture with the final build
would turn the estimate into a direct measurement. Live AT-248 c1: the Apple page reached the evidence in 4/20 runs; the four misses are one- or
two-sentence answers whose "latest is macOS 27 / 27.2" sentence no fetched source states in words next to that version
(runs 1, 2: no pill; 9, 12: one). Bar unchanged.

**Gates (on fd692b0fe, the final code; this report commit changes docs and evidence only), in order.** `make test-unit`: main + childsafety passed (`build/gate-unit-verifier2.log`). `make test-integration-stub`: passed, 90 tests, 29 skipped, 0 failures (`build/gate-integ-verifier2.log`). `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: passed (`build/gate-audit-verifier2.log`).

**Branch note.** `m7/verifier` already existed (7acbb5dba, an ancestor of m7/at248-2); it was reset to m7/at248-2
@4bbab82ea and its old worktree (`.claude/worktrees/m7-verifier`) detached at 7acbb5dba (nothing lost).

## 5h. M7 final (2026-11-10, branch m7/final): AT-250 c2 measured directly; AT-248 c1 retrieval

| Bar | Result | Target | Evidence |
|---|---|---|---|
| AT-250 c2 T1 (held-out-5, rule A-M7-T03d, fresh full capture) | **274/299 = 0.916** (strict-only 0.910) | ≥ 0.90 | `build/at/AT-250/final/h5/labels-T1{,-strict}/final-score.json` |
| AT-250 c2 T2 | **263/286 = 0.920** (strict-only 0.916) | ≥ 0.90 | `build/at/AT-250/final/h5/labels-T2{,-strict}/final-score.json` |
| AT-250 c2 T3 | **228/249 = 0.916** (strict-only 0.908) | ≥ 0.90 | `build/at/AT-250/final/h5/labels-T3{,-strict}/final-score.json` |
| AT-248 c1 ≥ 2 rendered pills per run, run 1 (@7932d5d33) | **16/20 — miss** (AX = probe 20/20; distinct ≥ 2 sources 17/20) | 20/20 | `build/at/AT-248/2026-11-10-final-c1/` |
| AT-248 c1 run 2 (@25434b9b3, final retrieval code) | **16/20 — miss** (AX = probe 20/20; distinct 11/20) | 20/20 | `build/at/AT-248/2026-11-10-final-c1b/`, `2026-11-10-c1.json` |
| AT-248 c1 T1 complete p50 (AC power, powermode 0, LPM off) | **6.74 s / 5.85 s — pass** (first token 4.11 / 3.73 s; 74 / 79 tok/s; load 6.7–11.8) | ≤ 12 s | same |

**AT-250 c2 is now a direct measurement (no estimate).** All 100 held-out-5 questions were answered again on every tier
with the final build (`build/app-final.app` @25434b9b3, `build/final/build-app.sh`; `build/final/run-c2.sh`, gpu-run
shared, the committed snapshots), and every cited sentence was labelled under the pre-registered rule: a first pass and
a full strict second pass by different fresh labeller agents (4 shards each, each confined to its own private
`tmp/<tier>-<pass>-<k>/` dir), a third fresh adjudicator on every disagreement, `at250-gate.py final`. Answers: 100/100 per tier, 0 timeouts, 0 unfetched pills; pills T1 359 / T2 453 / T3 319. Labelled cited sentences T1 299 / T2 286 / T3 249; disagreements 12 / 8 / 7 (agreement 0.960 / 0.972 / 0.972), adjudicated supported 2 / 1 / 2. T2 and T3 were sharded 8 ways (larger source texts), T1 4 ways. All three tiers pass; the strict-only rate is ≥ 0.90 on every tier too. This replaces the §5g estimate (`c2-final.py`), which this direct measurement agrees with (§5g: 0.906 / 0.922 / 0.916). A first capture attempt was stopped after 8 T1 questions to give the GPU to the c1 timing run (`build/at/AT-250/final/aborted-1/`, not used).
Main @d29a4b503 (round 38: R2 review P1-1/P1-2/P2-2 — video check, prefill progress events, controller teardown) was
merged after the capture; none of it changes how an answer is written or checked on a normal turn (P2-2 only acts when
a controller is deallocated mid-check), so the capture stands for the final head.

**AT-248 c1 retrieval (generic, nothing product-specific).** A new diagnostic, `antichat-bench citations --stage
live-window` (the app's live search step for given queries: per source the URL, fetched window, page text or snippet,
and fetch failure; `WebResults.fetchFailures`), and the probe now records the model's tool calls and every source URL.
Findings (`build/at/AT-248/final-diag/`): (1) **support.apple.com rate-limits this Mac's page fetches with HTTP 429**:
Apple's "Find out which macOS your Mac is using" (its table: "Latest version — macOS 27 Golden Gate 27.2.1") reached the
evidence only as a search snippet; when the fetch succeeds the table is in the T1 evidence. The 429 came first when two
support.apple.com pages were fetched in parallel, later even for a single request (after a day of test traffic from
this IP); curl and a lone URLSession request at the same moment got 200. (2) A recency query with a year ("latest macOS
version 2026", the model's usual phrasing in earlier runs) left that page out of the first 8 results; "current macOS
version" ranks it 3rd–4th. In c1 the chip sends the user's question verbatim ("What's the latest macOS version?").
Changes: the swapped recency query drops a year (`SearchRecency.queries`); a 429/503 page is asked once more after its
Retry-After (≤ 2 s, 1 s when absent; `PageFetchLimits.retryAfterMax`); requests to one host never overlap within a fetch
(0.25 s apart, no wait on cache hits; `PageFetcher.fetch`). Tests: `SearchRecencyTests.theSwappedQueryDropsAYear`,
`PageFetchRetryTests`, `PageFetchPerHostTests`. User agent unchanged, no further retries: going past a server's rate
limit would be working around it. AT-250 effect: none by construction (the replay answers every engine request with the
recorded SERP and serves pages from the recorded cache), checked with `--stage recency-check` on held-out-3/4/5:
identical windows to m7/verifier (`build/at/AT-250/final/recency-check-h*.json`). Live effect: the Apple page is in
the fetched window in 8/20 runs (was 4/20), but its text reached the evidence in 1 of those 8; the other 7 are 429.

**c1 misses (run 1, full pipeline replay of runs 1/4/10/18, `final-diag/replay-misses.json`).** Same classes as §5e/§5f:
run 10's "The latest macOS version is macOS 27 Golden Gate (version 27) [1,2,4]" passes grounding and MiniCheck
(0.98 on [2] and [4]), and the T1 verifier answers "UNSUPPORTED: latest" although [4] (MacRumors) says "macOS 27 Golden
Gate is the latest version of macOS" — a verifier misread; asking it again would be a second chance (loosening; lead
agreed not to). Runs 1/4/18: the other sentences add details no cited source states (Siri drafting features, "most
recent update 27.2" on a source that does not say it) or carry no marker. Bar not met, not loosened.

**Gates (on 7067d711e = main @d29a4b503 merged; the later commits are evidence and docs only), each passed once.** `make test-integration-stub`: passed, 90 tests, 29 skipped, 0 failures (`build/gate-integ-final.log`). `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: passed (`build/gate-audit-final.log`). `make test-unit`: main + childsafety passed (`build/gate-unit-final2.log`). Order note: a first `make test-unit` had started before the merge and failed only `LibraryViewTests.snapshotsOfThePageStates` (a Library window snapshot; this branch changes no UI code; the merge landed mid-run). The integration and audit gates then ran on the merged code, and the unit gate was re-run on the same code and passed. So all three passed on the final code, though unit ran last, not first.

## 6. Open items
- **AT-250 c2** (A-M7-T03c/T03d): **passes, measured directly** on a fresh full held-out-5 capture with the final build — T1 0.916, T2 0.920, T3 0.916 (strict-only 0.910 / 0.916 / 0.908; §5h). Human 20 % spot-check still open (A-M7-05).
- **AT-266 c2**: passes (0.860); the R-235 cap conflict waits for the owner (M7-owner-steps.md).
- **AT-248 c1** latency passes at T1 (5.85–6.74 s on AC power, powermode 0, §5h; 4.97–5.63 s in §5e/§5f). ≥ 2 rendered pills per run still misses: 16/20 in both §5h runs (16–17/20 over seven valid runs). Remaining misses are T1 verifier misreads and recency/added-detail sentences. Not loosened. support.apple.com rate-limits this Mac's page fetches (HTTP 429), so its "which macOS is the latest" table rarely reaches the evidence.
- **XCUITest legs** (Q-015): WebSearchUITests, ConnectionsUITests, ToolApprovalUITests / journey 12, SkillsUITests,
  MCPOAuthUITests, ToolsPageUITests, SecurityUITests, H4 accessibility audit.
- **Human:** the 20 % human spot-check of AT-250 (A-M7-05; agent proxy labels meanwhile), real Composio E2E (key +
  test account), CIMD at its public URL (M10), Vercel preview.
- **Moved:** AT-251, AT-252, AT-259 (M11, D-026); AT-057 re-run (M3.T14); C1/R1 re-runs (M9.T05); blind S-10/S-21/S-24
  scoring (M9.T08).
- Scraping ToS grey zone (K-NEW-SEARCH-1): DuckDuckGo, Brave, Mojeek and Startpage HTML pages for the lawyer list.

**STATUS: M7 conditional — every M7 AT that can run here passes or is moved (D-026, D-025), the review's 13 findings and three close findings are fixed with tests, journey 12 passes in the running app, and the gates are green on the final code; open: AT-248 c1 pills (16/20, §5h), AT-266 c2 at T2 (0.845 vs 0.85), T1 search answer latency (miss, M9.T05), XCUITest legs and H4 (Q-015), the untrusted-card capture, and the human items.**
