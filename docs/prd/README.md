# PRD milestone files

**Master:** [`../PRD.md`](../PRD.md) (read §1 first). This folder holds one file per milestone with every task in executable detail. **Status:** all milestone files written (Phase 11b) and dry-run reviewed (Phase 11c, RL-006, `../research/11-prd-review/dry-run.md`).

## 1. Milestone files

| File | Milestone | Status | Date | ATs passed | Parity (★ min / others min) | NFR summary |
|---|---|---|---|---|---|---|
| `M0.md` | Proof: Phase 7 spikes as gated tasks (D-014) | **done, exit conditional: AT-VQ-M0 pending (Q-021, folded into M9.T08)** — all tasks T00–T15 done; report [`M0-report.md`](M0-report.md) | 2026-10-30 | 14/16 (AT-M0-00…13 pass, AT-M0-08 pass-partial; AT-VQ-M0 + AT-M0-EXIT pending) | n/a (no product screen) | 17 NFRs measured (smoke), 7 within target, 8 partial, 1 miss (P2), 1 pending (F1) |
| `M1.md` | Shell, design system, text chat, harness | **done**; T26b / T27 folded into M9.T05 / M9.T08 (D-025); XCUITest pending (Q-015); no separate M1 report | 2026-10-30 | | | |
| `M2.md` | Hardware tiers, catalog, downloads, onboarding, Evil mode manager | done (2026-11-04) | AT-238 100/100 pack match; AT-VQ-M2 captured (scoring → M9.T08) | XCUITest pending (Q-015) | NFR-D4 real at T1; M5 1 run 110.2 s | |
| `M3.md` | Voice | **done, exit conditional** (2026-11-09): AT-280 AC1 owner step (M3-owner-steps.md), AT-280 AC3 off-leg re-run, XCUITest pending (Q-015) — report [`M3-report.md`](M3-report.md) | 2026-11-09 | | | |
| `M4.md` | ChildSafetyCheck and Photo | **done** (2026-11-09): T01–T13, T15, T16 done; review fixes merged; Photo in `ModelPack.shipped`; XCUITest pending (Q-015); blind scoring → M9.T08 — report [`M4-report.md`](M4-report.md) | 2026-11-09 | | | |
| `M5.md` | Video | **done with pending legs** (M5.T14, 2026-11-08); VID2 needs an owner decision (A-M0-T07c); A-M5-13 owner to confirm — report [`M5-report.md`](M5-report.md) | 2026-11-08 | AT-285 real video pass; in-process legs of every M5 AT pass; XCUITest pending (Q-015) | AT-VQ-M5 pending (M9.T08) | VID1 p50 45.5 s (proxy); VID2 open (A-M0-T07c); VID3 1 memory miss |
| `M6.md` | Files in and out, charts | **done, exit conditional** (M6.T21, 2026-11-09): XCUITest legs + H4 (Q-015), owner sitting for drag-out and Pages / Keynote (Q-M6-02), Office (Q-M6-01, optional) — report [`M6-report.md`](M6-report.md) | 2026-11-09 | every runnable M6 AT passes (AT-274 20/20, AT-276 3/3 reps, AT-NFR-SEC3 80/80 Debug + Release adhoc + Developer ID); AT-278 → M11 | AT-VQ-M6 captured (20 PNGs, H7 pass); blind scoring → M9.T08 | C4 T1 2,771 tok/s (≥ 150); C5 real reading %; SEC3 bystander ≤ 1.20 s |
| `M7.md` | Web search, connectors (MCP + Composio relay), skills, tools page | **in progress, exit conditional**: AT-250 c2 (T1 0.866 / T3 0.875 vs ≥ 0.90), T1 search latency 45.6 s, AT-266 c2 fixed on `m7/bars` (not merged), R-235 owner decision — report [`M7-report.md`](M7-report.md) | 2026-11-09 | | | |
| `M8.md` | Memory, projects, import/export, privacy, storage, diagnostics, notifications, quick panel | **in progress: exit conditional** (T01–T14 and T16 close work done on `integration/m0`; owner grants pending: XCUITest Q-015, AT-VQ-M8, real notification and permission dialogs). Report: [`M8-report.md`](M8-report.md) | 2026-11-08 | every owner-free AT passes, incl. AT-226 + AT-NFR-D7 (Tart VM), PR3, S2; XCUITest + AT-VQ-M8 pending | pending (AT-VQ-M8; scoring → M9.T08) | D7, D8, PR2, PR3, PR4, S2 pass; U9 deferred to M9.T05 |
| `M9.md` | Polish vs parity rubric, performance, accessibility and localisation | **done, exit conditional** (M9.T10, 2026-11-13, RC): AT-102 strict, test-offline, test-install pass on the RC; AT-NFR-S3 8-h run failed on hangs only (launch-policy cause, fixed), 2-h confirmation soak pass, no 8-h re-run (owner); blind VQ re-score misses the looks bar (not gating, owner 2026-11-12); pending: UI suite re-run on the RC, AT-NFR-S1, AT-NFR-R2, `make audit` / R-241, owner VoiceOver + Full Keyboard Access + native l10n review — report [`M9-report.md`](M9-report.md) | 2026-11-13 | AT-102, AT-221, AT-223 parts 1 and 3 pass; AT-223 part 2 (KeyboardOnly) owner-blocked; AT-273 145/150 first pass (normaliser fix re-run pending), images 15/15 | builder-scorer: ★ min 4.50 / others min 4.28; blind re-score: ★ 2/11, others ≈ 55 % (looks only, not gating) | T05 round 66: pass U6, U10, U11, C2 T1, F7_VIDEO T4/T3, PR1; miss U2, U5, VID1 T4, VID2 T4, B5 (S2); S3 2-h pass |
| `M10.md` | Release pipeline, Sparkle, website, DMG (notarization pending credentials) | **blocked (Q-003)**: T01–T09 and T11 RC close done (2026-11-13); signed release NOT built (needs the owner's production keys, `tools/release/KEYS.md`); T10 waits on the owner (keys ceremony, RB-1, RB-2, legal K-060, DMG size doc; M10-owner-steps.md); ad-hoc try-out build 1655 on the Desktop — report [`M10-report.md`](M10-report.md) | 2026-11-13 | AT-FA-01…14 pass in the dev form (2026-11-09); devid forms pending T10; RC: test-offline, test-install, AT-102, AT-220, AT-109, AT-100, AT-229 pass; UI suite re-run pending | see M9 (blind re-score not gating) | see M9; DMG size doc pending (owner) |

Status values: `not written` → `ready` (written and dry-run reviewed) → `in progress` → `done` (exit criteria met, report `M#-report.md` committed) or `blocked` (with the QUESTIONS/amendment ID). The build agent updates this table at the end of each milestone (PRD §1.4 rule 4).

Each milestone file starts with a header that copies **by reference** (IDs, not text) the milestone's goal, R, G, P, entry and exit criteria from PRD §7, then lists its tasks.

## 2. Task IDs

- **Format:** `M<milestone>.T<two digits>`, e.g. `M0.T01`, `M4.T07`, `M10.T12`. Numbering follows execution order inside the milestone; `T00` is reserved for a milestone's preparatory step (e.g. the upstream sync rehearsal in M4.T00).
- **Never reused.** A dropped task keeps its ID with status `dropped` and an amendment ID. An inserted task takes the next free number and states `after: M#.T##`.
- **Size:** a task is 0.5–5 working days. Split anything larger.
- **One task → one closing commit** titled `M#.T##: <title>` (PRD §1.4 rule 3).

## 3. Required fields for every task

Every task has all of these headings, in this order. A field that truly does not apply says `none` and why.

```markdown
### M#.T## <title>
- **Status:** ready | in progress | done | blocked (<Q/A id>) | dropped (<A id>)
- **Requirements / gaps:** R-###, … · G-###, …  (from PRD §3 / §7)

#### Inputs
What must exist before starting: earlier tasks (M#.T##), files, fixtures (`fixtures/…`), models (catalog id + pin), tools, decisions (D-###), screen specs (S-##), copy keys.

#### Files / modules
Paths created or changed, by module (architecture §1–§2), e.g. `Packages/Harness/Sources/AntiChatHarness/TurnController.swift`. Upstream paths only with the `UP-###` row they add.

#### Patches (P-IDs)
P-### used, with source@commit and integration mode (dependency / vendored / ported / reference), linking the `09-patches/` section. "Custom" only with its search log.

#### Steps
Numbered, exact, executable without guessing: commands, code locations, configuration values, the copy-deck keys used. Numbers come from `nfr.md` by ID, never retyped.

#### Acceptance tests
One block per AT:
- **AT-ID** (AT-###, AT-NFR-…, AT-M0-##, AT-VQ-M#, AT-FA-##) and the requirement/NFR criterion it encodes.
- **Command(s):** exact, copy-pasteable (e.g. `make test-unit FILTER=TurnControllerTests`, `make perf METRIC=U2 TIER=T1`, `xcodebuild test -scheme AntiChat-UITests -only-testing:…`).
- **Pass condition:** measurable, with the artefact path (`build/at/<AT-ID>/…`, `build/perf/report.json` key).
- **Visual QA script:** the `tools/visual/vq-##-*.md` runbook and the steps for the touched screens (screen S-##, states, light/dark, captures), plus the parity bar from `parity-rubric.md` §3. `none` only for tasks with no UI.

#### Definition of done
Task-specific additions to PRD §8 "Task done".

#### Known failure modes & fallback
Each likely failure (from the gap's `risk_note`, spike results, K-IDs) → how it shows → the documented fallback → whether using it is a minor or major amendment (PRD §1.4 rule 2).

#### Rollback
How to undo safely: the commits to revert, migrations to reverse (with the pre-migration backup), catalog entries to pull, feature flags to turn off, vendored bumps to revert (`make vendor-bump NAME= REF=<previous>`).
```

## 4. Acceptance-test ID families (see PRD §3)

| Family | Example | Defined in |
|---|---|---|
| Requirement | `AT-285` for R-285 (more: `AT-285a`, `AT-285b`) | the requirement's milestone file (`milestone` in `registry/requirements.json`) |
| NFR | `AT-NFR-U2`, `AT-NFR-C1` | the first milestone that checks it (PRD §4); later milestones re-run it by ID |
| Spike gate | `AT-M0-08` | `M0.md` |
| Visual QA run | `AT-VQ-M4` | each milestone file (its scripts, screens and bars) |
| Final acceptance | `AT-FA-01` … `AT-FA-14` | `M10.md` |

`registry/requirements.json` lists each requirement's ATs in `tests`; if a milestone file adds `AT-###a`, add it there too, then run `python3 tools/trace-check.py --phase 11`.
