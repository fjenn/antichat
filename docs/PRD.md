# AntiChat PRD (master)

**Version:** 1.1 (Phase 11c dry-run fixes, RL-006), 2026-10-30. **Owner:** the lead agent. **Status:** G3 waived for this run (D-007); executability dry-run done ([`11-prd-review/dry-run.md`](research/11-prd-review/dry-run.md), RL-006).
**This file is the master.** It indexes what is built, in what order, and how "done" is proven. Detail lives in the research packet, linked here and never copied. Task-level instructions live in [`docs/prd/M0.md` … `M10.md`](prd/README.md) (written Phase 11b, dry-run reviewed Phase 11c).
**Plan and method:** [`docs/PLAN.md`](PLAN.md) v4b. **Decisions:** [`DECISIONS.md`](research/DECISIONS.md) D-001…D-014. Where this PRD and a decision disagree, the later-dated decision wins and the PRD gets an amendment (§1.4).

---

## 1. Purpose and how to use this PRD

### 1.1 Who this is for
A build agent with **no conversation context**. Everything needed is in this repository: this PRD, the milestone files in `docs/prd/`, and the research packet in `docs/research/`. If you find yourself guessing at behaviour, the packet has the answer (search by ID: `grep -rn "R-285" docs/`), or it is a real ambiguity, which you record as an amendment (§1.4) and resolve with the rule there.

### 1.2 Read order (first session)
1. This file, §1–§7 (≈ 30 min).
2. [`docs/prd/README.md`](prd/README.md): the task scheme and milestone progress table.
3. [`research/STATUS.md`](research/STATUS.md): where the build is now.
4. [`research/DECISIONS.md`](research/DECISIONS.md): D-001 (fixed product decisions), D-005/D-006 (safety: no filters except ChildSafetyCheck), D-007 (autonomy, downloads, Composio relay), D-009/D-012 (assemble, fallbacks F1/F2, switch rule), D-013/D-014 (engine process model, M0 Proof).
5. [`research/02-target/VISION.md`](research/02-target/VISION.md) §0–§1 (the product), then [`nfr.md`](research/02-target/nfr.md) (every number).
6. [`research/10-architecture/DIGEST.md`](research/10-architecture/DIGEST.md), then `architecture.md`, `environment.md`, `test-strategy.md`.
7. The milestone file you are about to execute, top to bottom, then each task's linked P-### patch section and screen spec.

### 1.3 Packet map

| Need | Where |
|---|---|
| What the product is, personas, journeys | `research/02-target/VISION.md` §0, §1.4 (personas Sam, Priya, Max, Riley); `02-target/DIGEST.md` |
| Requirements and acceptance criteria | `research/registry/requirements.json` (source of truth: `acceptance_criteria`, `components`, `tests`, `milestone`); prose in `02-target/requirements.md` |
| Numbers (every budget) | `research/02-target/nfr.md` (the only place numbers live); tiers in `02-target/hardware-tiers.md` §2 |
| Settings layout | `research/02-target/settings-map.md`; VISION §2.33 |
| Reference behaviour (ChatGPT/Claude) | `research/01-reference/` (`interaction-specs.md` IS-#, `ux-principles.md`, `copy-reference.md`, screen catalogs) |
| Components and data flows | `research/03-components/components.md`, `data-flows.md`, `registry/components.json` |
| Engines | `research/04-engines/engines.md` + DIGEST |
| Base decision and fallbacks | `research/05-fork/selection.md` (§6 F1, §9 spikes, §11 D-012 basis) |
| Models (pins, matrix, sizes) | `research/06-models/model-matrix.md` (§1 pins, §2 matrix, §4 sizes, §9 Evil chat, §10 ChildSafetyCheck detectors) |
| Gaps (what we build) | `research/08-gaps/gaps.md`, `registry/gaps.json` (each gap has `milestone`) |
| Patches (what we reuse, from where, at which commit) | `research/09-patches/patches-*.md`, `registry/patches.json`, search logs in `09-patches/search-logs/` |
| Architecture, repo layout, modules, XPC, schema, relay | `research/10-architecture/architecture.md` (§9.2 every P → module, §9.3 canonical pins) |
| Upstream/vendoring | `research/10-architecture/upstream.md` |
| Toolchain, bootstrap, fixtures, stub models, make targets | `research/10-architecture/environment.md` |
| CI, signing, notarization, DMG, Sparkle, catalog, hosting, release checklist | `research/10-architecture/ci-release.md` (§8 checklist) |
| Design tokens, components, copy, screens, parity rubric | `research/10-architecture/design-system/` (`tokens.md`, `components.md`, `copy-deck.md`, `screens.md` S-00…S-25, `parity-rubric.md`) |
| Tests, severity, triage | `research/10-architecture/test-strategy.md` |
| Risks | `research/registry/risks.json`, `02-target/risks.md` |
| Open questions | `research/QUESTIONS.md` |

### 1.4 Rules (binding during the build)
1. **Evidence (PLAN §1.1).** Every claim in a commit, STATUS line, spike report or amendment cites its source: a command and its output file under `build/`, a screenshot path, `repo@sha:path:line`, or a URL with access date. Unsourced claims are tagged `[INFERENCE]` or `[ASSUMPTION]`. An AT "passes" only with its output artefact committed or attached (`build/at/<AT-ID>/<date>.log`, `build/perf/report.json`, `build/visual/<version>/…`).
2. **Change control (PLAN §1.7).** Every deviation from this PRD or a milestone file is recorded in [`docs/PRD-AMENDMENTS.md`](PRD-AMENDMENTS.md) (create it on the first amendment) with: ID `A-###`, date, task, what, why, evidence, impact (R/NFR/screen/milestone), class.
   - **Minor (amend and continue):** an implementation detail, an equivalent library swap, a task reorder, a pin bump inside the conformance suite, a P2 deferred to post-v1. No requirement, NFR budget or user-visible behaviour changes.
   - **Major (stop and ask):** changing an R (text, priority, acceptance criteria), the UX of a screen in `screens.md`, a model pick in `model-matrix.md`, the base (D-009 → F1/F2), or an NFR budget; or a milestone that still fails its ATs after **3 fix attempts**. Record the amendment as `proposed`, finish every task that does not depend on it, then ask (§1.5).
   - Every task lists its known failure modes and fallback, not only its rollback. Using a documented fallback is minor unless the fallback itself changes an R, model, base or budget.
3. **Commit per task.** One task `M#.T##` = one or more commits on `main` (or a short-lived branch merged after review), the last one titled `M#.T##: <task title>` and listing the ATs run and their result. Commits end with the attribution line required by the session. Never commit secrets, the private ChildSafetyCheck calibration fixtures or personal data.
4. **STATUS updates.** After each task: one line in `docs/research/STATUS.md` under "Build" (task, result, AT IDs, commit). After each milestone: the progress table in `docs/prd/README.md` (status, date, AT pass count, parity score, NFR summary) and a milestone digest in `docs/prd/M#-report.md`.
5. **Per-milestone loop (PLAN Phase 12):** implement → run the ATs → launch the app → computer-use visual QA scored on the parity rubric → NFR checks → independent code review (`/code-review` at high effort) → independent bug triage (test-strategy §11) → commit → STATUS/PRD progress.
6. **Upstream separation.** Our code only in `App/`, `Packages/`, `relay/`, `site/`, `catalog/`, `tools/`. Upstream only under `Vendor/`, `Binaries/`, `Runtimes/`; every edit to upstream carries `// ANTICHAT-PATCH: UP-###` and a row in `Vendor/UPSTREAM_PATCHES.md` (architecture §1, upstream §3).
7. **No filters (D-005/D-006, R-241).** No code anywhere blocks, rewrites or warns about content, except `Packages/ChildSafetyCheck/`, imported only by `MediaOutputGate.swift`. The R-241 audit (test-strategy §9) runs on every commit from M1 on.
8. **Downloads.** Clones and model weights proceed without per-batch confirmation inside the 400 GB budget (D-003, D-007). Anonymous Hugging Face only, pinned commits, never gated repos (D-007). Spending money needs explicit user confirmation (PLAN §1.8).

### 1.5 When to stop and ask (the only cases)
1. **Permission blocks of the Q-007 type:** the sandbox, an auto-mode classifier or macOS refuses cloning, building, running code, a network call or a computer-use grant the task needs. Write the exact command and error into `QUESTIONS.md`, continue with any task that does not need it, then ask.
2. **Credentials or human-only steps** (§9): Developer ID + notarytool, Composio API key, test account and relay secrets in Vercel, `gh`/Vercel logins, the production key ceremony, the `ghrunner` user, domain and inboxes, the private ChildSafetyCheck calibration proxies, the one-time macOS/computer-use grants, the optional Office for Mac install, the lawyer review. Each §9 row names a "meanwhile" path; only the private calibration proxies gate a milestone exit (M4).
   - **Never wait for a password or a system dialog (RL-006).** `sudo` is not a G0 credential: probe once with `sudo -n true`; every sudo leg (dnctl/pfctl throttle, tcpdump, fs_usage, purge, pmset, powermetrics, BlackHole install) has a non-sudo path in its milestone file that is authoritative, and a skipped leg is logged `not run: permission`, not `blocked`. Keychain-backed tools use key files (`--ed-key-file`), never the login Keychain, until the M10 ceremony. The agent never clicks Allow on a TCC prompt and never signs in to an account.
3. **Major amendments** (§1.4 rule 2).

Anything else, decide with evidence, record it (amendment or DECISIONS entry), and continue. The build never waits for a reply to a non-blocking question; it uses the documented default (`QUESTIONS.md`).

---

## 2. Product summary, scope, personas

**Summary:** see [VISION §0](research/02-target/VISION.md) (one page). In one line: ChatGPT on your Mac, minus the cloud. A free, open-source, account-free macOS 26 app (Apple Silicon) in one chat window that routes to local models for chat, voice, pictures and video, with optional web search and connectors, an opt-in uncensored Evil Mode, no filters except a local child-safety check on generated media, shipped as a signed, notarized, self-updating DMG (D-001, D-005, D-006).

**Personas:** Sam (Air M2 16 GB), Priya (Air M4 24 GB), Max (Pro M4 Max 64 GB), Riley (Pro M5 Pro 48 GB): [VISION §0, §1.4](research/02-target/VISION.md); [02-target DIGEST §2](research/02-target/DIGEST.md).

**In scope (v1):** every active P0 and P1 requirement in §3 (160), across the four packs (Chat, Voice, Photo, Video), each in Normal and Evil mode, plus the platform (onboarding, models, updates, privacy, storage, release). Capability list with priorities: [VISION §2](research/02-target/VISION.md) and [02-target DIGEST §5](research/02-target/DIGEST.md).

**P2 (8 requirements):** "later" per VISION's legend. They are listed in §3 with a target milestone and an AT so they can be pulled in if that milestone's exit criteria are met early; otherwise deferring them is a minor amendment.

**Out of scope (v1):** [VISION §4](research/02-target/VISION.md) non-goals: coding agents, agent mode/computer use, accounts/sync/share links, other platforms and the App Store, paid tiers/ads/telemetry, any filter beyond D-006, parental controls, deep research and scheduled tasks, live canvas editors, advanced image tools (LoRA import, ControlNet), voice cloning, training, plugin store/custom GPTs, a local API server (S-08), RLHF data collection, video understanding. Also out: the in-app "macOS too old" screen (D-014: the system refusal is used).

**Defaults applied for open founder questions:** Q-008 D-009 assemble; Q-009 (a) Evil Photo/Video use the Normal media models in v1 (catalog `evil` slots point at Normal entries); Evil tagline "Unfiltered. No lectures."; web search on by default with a visible switch (D-007).

---

## 3. Requirements index

**Source of truth:** `research/registry/requirements.json`. Each active requirement now carries `"tests": ["AT-<number>"]` and `"milestone"`. This table is generated from it; if they disagree, the registry wins and the table is regenerated.
**Rules:**
- **AT-IDs:** every requirement R-### has at least one acceptance test **AT-###** (same number), defined in the milestone file of the milestone that delivers it. A requirement may have more (AT-###a, AT-###b). The AT encodes the requirement's `acceptance_criteria` exactly; it may add, never drop, a criterion.
- **Milestone rule:** each gap G has exactly one owning milestone (§7, `gaps.json` `milestone`). A requirement is delivered in the milestone where all its gaps are done, i.e. the latest of its gaps' milestones, **or later** when its acceptance criteria need features from a later milestone. Those exceptions are marked ¹ and listed under the table.
- **Superseded (not built, no AT):** R-212 (['R-211']), R-213 (['R-241', 'R-285']), R-214 (['R-285']), R-215 (['R-285']), R-216 (['R-285']).

**Counts per milestone:**

| Milestone | P0 | P1 | P2 (stretch) | Total R | Gaps owned | Gap estimate (pw, L) |
|---|---|---|---|---|---|---|
| [M0](prd/M0.md) | 0 | 0 | 0 | 0 | 2 | 2.25 |
| [M1](prd/M1.md) | 28 | 3 | 0 | 31 | 15 | 30.25 |
| [M2](prd/M2.md) | 21 | 5 | 0 | 26 | 10 | 25.75 |
| [M3](prd/M3.md) | 8 | 3 | 0 | 11 | 5 | 9.25 |
| [M4](prd/M4.md) | 9 | 4 | 0 | 13 | 6 | 16.25 |
| [M5](prd/M5.md) | 6 | 3 | 0 | 9 | 4 | 11.75 |
| [M6](prd/M6.md) | 9 | 7 | 0 | 16 | 7 | 16.25 |
| [M7](prd/M7.md) | 19 | 6 | 1 | 26 | 7 | 10.5 |
| [M8](prd/M8.md) | 8 | 12 | 5 | 25 | 7 | 12 |
| [M9](prd/M9.md) | 2 | 1 | 2 | 5 | 1 | 1.5 |
| [M10](prd/M10.md) | 6 | 0 | 0 | 6 | 4 | 4.5 |
| **Total** | **116** | **44** | **8** | **168** | **68** | **140.25** |

| R | Title | Pri | Pack | Components | Gaps | Milestone | AT |
|---|---|---|---|---|---|---|---|
| R-001 | Main window layout and empty state | P0 | chat | C-001 | G-001 | [M1](prd/M1.md) | AT-001 |
| R-002 | Composer | P0 | chat | C-001, C-002 | G-001 | [M1](prd/M1.md) | AT-002 |
| R-003 | Send → stream → done turn flow | P0 | chat | C-002, C-005, C-030, C-031 | G-002 | [M1](prd/M1.md) | AT-003 |
| R-004 | Stop and interrupted-response notice | P0 | chat | C-002, C-005 | G-002 | [M1](prd/M1.md) | AT-004 |
| R-005 | Response actions and regenerate with versions | P0 | chat | C-002, C-030, C-031 | G-003 | [M1](prd/M1.md) | AT-005 |
| R-006 | Edit a message and branch a conversation | P0 | chat | C-002, C-031 | G-003 | [M1](prd/M1.md) | AT-006 |
| R-007 | Think harder and reasoning display | P0 | chat | C-003, C-030 | G-007 | [M1](prd/M1.md) | AT-007 |
| R-008 | Markdown, code and math rendering | P0 | chat | C-030 | G-004 | [M1](prd/M1.md) | AT-008 |
| R-009 | Context window management | P0 | chat | C-002, C-003 | G-008 | [M1](prd/M1.md) | AT-009 |
| R-010 | Auto titles and live sidebar status | P0 | chat | C-001, C-002 | G-002 | [M1](prd/M1.md) | AT-010 |
| R-011 | Sidebar and chat management | P0 | chat | C-001, C-031 | G-001 | [M1](prd/M1.md) | AT-011 |
| R-012 | Command palette and search | P0 | chat | C-001, C-019, C-031 | G-005 | [M1](prd/M1.md) | AT-012 |
| R-013 | + menu, slash and @ menus, tool chips | P0 | chat | C-001, C-004, C-026 | G-006 | [M1](prd/M1.md) | AT-013 |
| R-014 | Follow-ups while generating | P1 | chat | C-002 | G-002 | [M1](prd/M1.md) | AT-014 |
| R-016 | Artifacts side panel | P1 | chat | C-029 | G-025 | [M6](prd/M6.md) ¹ | AT-016 |
| R-017 | File output cards and files in chat | P0 | chat | C-027, C-029, C-042 | G-025 | [M6](prd/M6.md) ¹ | AT-017 |
| R-018 | File tools: local Python sandbox for analysis and editing | P1 | chat | C-028 | G-027 | [M6](prd/M6.md) | AT-018 |
| R-019 | Export or share a single chat | P1 | chat | C-032 | G-058 | [M8](prd/M8.md) | AT-019 |
| R-020 | Attach files | P0 | chat | C-001, C-018 | G-019, G-067 | [M6](prd/M6.md) | AT-020 |
| R-021 | Image understanding | P0 | chat | C-005, C-017 | G-022 | [M6](prd/M6.md) | AT-021 |
| R-022 | Local media and file library | P0 | platform | C-042 | G-026 | [M5](prd/M5.md) | AT-022 |
| R-030 | Image generation in chat with intent detection | P0 | photo | C-004, C-013 | G-013, G-041 | [M4](prd/M4.md) | AT-030 |
| R-031 | Image progress with real percentage and live preview | P0 | photo | C-013, C-015 | G-041, G-044 | [M4](prd/M4.md) | AT-031 |
| R-032 | Image result card, variants and viewer | P0 | photo | C-013, C-029, C-042 | G-042 | [M4](prd/M4.md) | AT-032 |
| R-033 | Edit images by text, with versions | P0 | photo | C-013 | G-041, G-042 | [M4](prd/M4.md) | AT-033 |
| R-034 | Image editor tools | P1 | photo | C-013, C-029 | G-042 | [M4](prd/M4.md) | AT-034 |
| R-035 | Image templates gallery | P2 | photo | C-013 | — | [M9](prd/M9.md) | AT-035 |
| R-036 | Think harder for images | P1 | photo | C-003, C-013 | G-041 | [M4](prd/M4.md) | AT-036 |
| R-040 | Video generation in chat (eligible Macs) | P0 | video | C-004, C-014 | G-045 | [M5](prd/M5.md) | AT-040 |
| R-050 | Dictation in the composer | P0 | voice | C-010, C-012 | G-036 | [M3](prd/M3.md) | AT-050 |
| R-051 | System-wide dictation hotkey | P1 | voice | C-010, C-036 | G-040 | [M8](prd/M8.md) | AT-051 |
| R-052 | Spoken conversation | P0 | voice | C-002, C-010, C-011, C-012 | G-037, G-068 | [M3](prd/M3.md) | AT-052 |
| R-053 | Voice settings | P0 | voice | C-011, C-033 | G-038 | [M3](prd/M3.md) | AT-053 |
| R-054 | Read aloud | P0 | voice | C-011 | G-038, G-068 | [M3](prd/M3.md) | AT-054 |
| R-055 | Voice hotkey and start-with-voice | P2 | voice | C-012, C-036 | — | [M8](prd/M8.md) | AT-055 |
| R-056 | Audio file transcription | P1 | voice | C-010, C-018 | G-036 | [M3](prd/M3.md) | AT-056 |
| R-057 | Tools during voice | P1 | voice | C-012, C-026 | G-037 | [M3](prd/M3.md) | AT-057 |
| R-060 | Memory | P1 | chat | C-020 | G-035 | [M8](prd/M8.md) | AT-060 |
| R-061 | Reference past chats | P2 | chat | C-019, C-020 | — | [M8](prd/M8.md) | AT-061 |
| R-062 | Custom instructions and response style | P0 | chat | C-003, C-033 | G-007 | [M1](prd/M1.md) | AT-062 |
| R-063 | Memory import and export | P2 | chat | C-020, C-032 | — | [M8](prd/M8.md) | AT-063 |
| R-064 | Projects | P1 | chat | C-021 | G-035 | [M8](prd/M8.md) | AT-064 |
| R-080 | Web search | P0 | chat | C-022 | G-028 | [M7](prd/M7.md) | AT-080 |
| R-081 | Connections (Composio + MCP) | P0 | chat | C-023, C-024 | G-030, G-033 | [M7](prd/M7.md) | AT-081 |
| R-082 | Skills: add, enable, disable, use | P0 | chat | C-025 | G-034 | [M7](prd/M7.md) | AT-082 |
| R-090 | Incognito chat never written to disk | P0 | platform | C-002, C-031 | G-014 | [M1](prd/M1.md) | AT-090 |
| R-091 | Privacy & Data settings page | P0 | platform | C-033, C-040 | G-056 | [M8](prd/M8.md) ¹ | AT-091 |
| R-092 | Import ChatGPT and Claude exports | P1 | platform | C-032 | G-058 | [M8](prd/M8.md) | AT-092 |
| R-093 | Full export of AntiChat data | P0 | platform | C-032 | G-058 | [M8](prd/M8.md) | AT-093 |
| R-094 | Locked chats | P2 | platform | C-001, C-031 | — | [M9](prd/M9.md) | AT-094 |
| R-100 | Settings window structure | P0 | platform | C-033 | G-016 | [M1](prd/M1.md) | AT-100 |
| R-101 | Appearance and comfort settings | P0 | platform | C-001, C-033 | G-016 | [M1](prd/M1.md) | AT-101 |
| R-102 | UI language | P1 | platform | C-001, C-033 | G-017 | [M9](prd/M9.md) | AT-102 |
| R-103 | Keyboard shortcuts | P0 | platform | C-033, C-036 | G-016 | [M1](prd/M1.md) | AT-103 |
| R-104 | Native app menus and windows | P0 | platform | C-001 | G-001 | [M1](prd/M1.md) | AT-104 |
| R-105 | Menu bar item | P1 | platform | C-036 | G-040 | [M8](prd/M8.md) | AT-105 |
| R-106 | Global quick panel | P1 | platform | C-036 | G-040 | [M8](prd/M8.md) | AT-106 |
| R-107 | Screenshot and window attach | P2 | platform | C-018, C-036 | — | [M8](prd/M8.md) | AT-107 |
| R-108 | Notifications | P1 | platform | C-035 | G-063 | [M8](prd/M8.md) | AT-108 |
| R-109 | Just-in-time permissions | P0 | platform | C-001, C-036 | G-065 | [M8](prd/M8.md) ¹ | AT-109 |
| R-110 | Deep links | P2 | platform | C-001 | — | [M8](prd/M8.md) | AT-110 |
| R-200 | Hardware detection and tiers | P0 | platform | C-008 | G-049, G-067 | [M2](prd/M2.md) | AT-200 |
| R-201 | Onboarding (4 screens) | P0 | platform | C-039 | G-053 | [M2](prd/M2.md) | AT-201 |
| R-202 | Pack management after onboarding | P0 | platform | C-006, C-039 | G-053 | [M2](prd/M2.md) | AT-202 |
| R-203 | Fast first chat | P0 | platform | C-007, C-039, C-PERF | G-051, G-053 | [M2](prd/M2.md) | AT-203 |
| R-204 | Model download manager | P0 | platform | C-007 | G-051, G-067 | [M2](prd/M2.md) | AT-204 |
| R-205 | Storage dashboard, remove everything, uninstall | P0 | platform | C-007, C-033 | G-055 | [M8](prd/M8.md) | AT-205 |
| R-206 | Memory-pressure orchestration across models | P0 | platform | C-009 | G-011, G-067 | [M2](prd/M2.md) | AT-206 |
| R-207 | Power, thermal and yielding to other apps | P1 | platform | C-009 | G-011 | [M2](prd/M2.md) | AT-207 |
| R-208 | Crash and stream recovery | P0 | platform | C-002, C-005, C-031 | G-010 | [M1](prd/M1.md) | AT-208 |
| R-209 | Offline guarantee and optional online features | P0 | platform | C-040 | G-056 | [M2](prd/M2.md) | AT-209 |
| R-210 | Evil mode placement and visual frame | P0 | platform | C-001, C-041 | G-054 | [M2](prd/M2.md) | AT-210 |
| R-211 | Evil activation: disclaimer, 18+ and consent gate | P0 | platform | C-039, C-041 | G-054 | [M2](prd/M2.md) | AT-211 |
| R-217 | Legal and trust pages | P0 | platform | C-033, C-038 | G-062 | [M10](prd/M10.md) | AT-217 |
| R-218 | Diagnostics with zero telemetry by default | P0 | platform | C-037 | G-057 | [M8](prd/M8.md) | AT-218 |
| R-219 | App updates via Sparkle | P0 | platform | C-034 | G-060 | [M10](prd/M10.md) | AT-219 |
| R-220 | Signed model catalog, separate from app updates | P0 | platform | C-006, C-034 | G-050 | [M2](prd/M2.md) | AT-220 |
| R-221 | Felt-speed targets | P0 | platform | C-PERF | G-064 | [M9](prd/M9.md) ¹ | AT-221 |
| R-222 | Automatic model selection with hidden override | P0 | platform | C-006, C-008 | G-050 | [M2](prd/M2.md) | AT-222 |
| R-223 | Accessibility | P0 | platform | C-001 | G-017 | [M9](prd/M9.md) | AT-223 |
| R-041 | Video job card with real progress | P0 | video | C-014, C-015 | G-044, G-045 | [M5](prd/M5.md) | AT-041 |
| R-042 | Video keeps running in background and notifies | P0 | video | C-015, C-035 | G-044, G-063 | [M8](prd/M8.md) | AT-042 |
| R-043 | Animate a picture (image-to-video) | P1 | video | C-014 | G-045 | [M5](prd/M5.md) | AT-043 |
| R-044 | Video presets instead of parameters | P1 | video | C-014 | G-045 | [M5](prd/M5.md) | AT-044 |
| R-045 | Inline video player and Library | P0 | video | C-029, C-042 | G-026, G-047 | [M5](prd/M5.md) | AT-045 |
| R-046 | Video eligibility and honest estimates | P0 | video | C-006, C-008, C-014 | G-046 | [M5](prd/M5.md) | AT-046 |
| R-224 | Add a chat model by Hugging Face ID (Advanced) | P1 | platform | C-006, C-007 | G-050, G-051 | [M2](prd/M2.md) | AT-224 |
| R-225 | Install from the DMG and first launch | P0 | platform | C-038 | G-061 | [M10](prd/M10.md) | AT-225 |
| R-226 | Uninstall AntiChat completely | P0 | platform | C-007, C-033 | G-055 | [M8](prd/M8.md) | AT-226 |
| R-227 | Evil variants in onboarding and later: size, disk check, readiness | P0 | platform | C-006, C-039, C-041 | G-053 | [M2](prd/M2.md) | AT-227 |
| R-228 | Fresh-information hint when web search is off | P0 | chat | C-004 | G-013 | [M7](prd/M7.md) ¹ | AT-228 |
| R-229 | Engine adapter contract | P0 | chat | C-005 | G-009, G-068 | [M1](prd/M1.md) | AT-229 |
| R-230 | Cache-stable system prompt | P0 | chat | C-003, C-PERF | G-007 | [M1](prd/M1.md) | AT-230 |
| R-231 | Reliable local tool calling | P0 | chat | C-003, C-005 | G-009, G-068 | [M1](prd/M1.md) | AT-231 |
| R-232 | Tool-loop bounds | P0 | chat | C-002 | G-012 | [M1](prd/M1.md) | AT-232 |
| R-233 | Non-destructive context compaction | P0 | chat | C-002, C-003 | G-008 | [M1](prd/M1.md) | AT-233 |
| R-234 | Per-message provenance | P1 | chat | C-002, C-031 | G-003 | [M1](prd/M1.md) | AT-234 |
| R-235 | Layered router with a fallback intent check | P0 | chat | C-004 | G-013 | [M2](prd/M2.md) | AT-235 |
| R-236 | No chat-model reload after media on constrained Macs | P0 | photo | C-009 | G-011 | [M4](prd/M4.md) ¹ | AT-236 |
| R-237 | Image understanding fallback for text-only chat models | P1 | chat | C-017 | G-022 | [M6](prd/M6.md) | AT-237 |
| R-238 | Install card instead of a made-up answer | P0 | chat | C-004, C-039 | G-013, G-053 | [M2](prd/M2.md) | AT-238 |
| R-239 | Same-family Evil variants | P0 | platform | C-006, C-041 | G-050 | [M2](prd/M2.md) | AT-239 |
| R-240 | Evil tone clause and lecture rate | P1 | platform | C-003, C-041 | G-054 | [M2](prd/M2.md) | AT-240 |
| R-241 | No harness filters | P0 | platform | C-016, C-041 | G-048 | [M7](prd/M7.md) ¹ | AT-241 |
| R-242 | Topic memory written through a tool | P1 | chat | C-020 | G-035 | [M8](prd/M8.md) | AT-242 |
| R-243 | Frozen memory snapshot per chat | P1 | chat | C-003, C-020 | G-007, G-035 | [M8](prd/M8.md) | AT-243 |
| R-244 | Hybrid local chat search | P0 | chat | C-019 | G-005, G-066 | [M2](prd/M2.md) | AT-244 |
| R-245 | Project context vs retrieval switch | P1 | chat | C-019, C-021 | G-035 | [M8](prd/M8.md) | AT-245 |
| R-246 | Background memory review is propose-only | P1 | chat | C-020 | G-035 | [M8](prd/M8.md) | AT-246 |
| R-247 | Incognito leaves no index | P0 | platform | C-019, C-031 | G-014 | [M2](prd/M2.md) ¹ | AT-247 |
| R-248 | Keyless default web search | P0 | chat | C-022 | G-028, G-067 | [M7](prd/M7.md) | AT-248 |
| R-249 | Local page extraction and ranking | P0 | chat | C-022 | G-028, G-067 | [M7](prd/M7.md) | AT-249 |
| R-250 | Citation integrity | P0 | chat | C-022, C-030 | G-028 | [M7](prd/M7.md) | AT-250 |
| R-251 | Bring-your-own search provider | P1 | chat | C-022, C-033 | G-029 | [M7](prd/M7.md) | AT-251 |
| R-252 | Opt-in hosted search fallback | P2 | chat | C-022 | — | [M7](prd/M7.md) | AT-252 |
| R-253 | Search engine settings via the signed catalog | P0 | chat | C-006, C-022 | G-029, G-050 | [M7](prd/M7.md) | AT-253 |
| R-254 | Web search latency | P0 | chat | C-022, C-PERF | G-028, G-064 | [M7](prd/M7.md) | AT-254 |
| R-255 | Composio connectors via AntiChat's account (relay) | P0 | chat | C-024 | G-033 | [M7](prd/M7.md) | AT-255 |
| R-256 | Per-action permissions inside Composio meta tools | P0 | chat | C-024, C-026 | G-033 | [M7](prd/M7.md) | AT-256 |
| R-257 | Remote MCP sign-in (OAuth 2.1) | P0 | chat | C-023 | G-031, G-067 | [M7](prd/M7.md) | AT-257 |
| R-258 | MCP spec compatibility | P1 | chat | C-023 | G-030 | [M7](prd/M7.md) | AT-258 |
| R-259 | Local MCP server sandbox | P1 | platform | C-023 | G-032 | [M7](prd/M7.md) | AT-259 |
| R-260 | Tool change review | P1 | chat | C-023, C-026 | G-030 | [M7](prd/M7.md) | AT-260 |
| R-261 | Agent Skills format compatibility | P0 | chat | C-025 | G-034 | [M7](prd/M7.md) | AT-261 |
| R-262 | Skills progressive disclosure | P0 | chat | C-003, C-025 | G-034 | [M7](prd/M7.md) | AT-262 |
| R-263 | Skill activation quality | P1 | chat | C-004, C-025 | G-034 | [M7](prd/M7.md) | AT-263 |
| R-264 | Create a skill by chatting | P1 | chat | C-025 | G-034 | [M7](prd/M7.md) | AT-264 |
| R-265 | Skills never run scripts silently | P0 | platform | C-025, C-028 | G-027, G-034 | [M7](prd/M7.md) | AT-265 |
| R-266 | Load tools when needed | P0 | chat | C-004, C-026 | G-012 | [M7](prd/M7.md) ¹ | AT-266 |
| R-267 | Unavailable online tools are invisible to the model | P0 | chat | C-026, C-040 | G-012, G-056 | [M7](prd/M7.md) ¹ | AT-267 |
| R-268 | Tools page and per-chat tool toggles | P0 | chat | C-026, C-033 | G-006 | [M7](prd/M7.md) ¹ | AT-268 |
| R-269 | Prefix-cache-friendly tool block | P1 | chat | C-003, C-026, C-PERF | G-007 | [M1](prd/M1.md) | AT-269 |
| R-270 | Read the whole document or say it used excerpts | P0 | chat | C-002, C-018 | G-019 | [M6](prd/M6.md) | AT-270 |
| R-271 | OCR for scans and image text | P0 | chat | C-018 | G-020 | [M6](prd/M6.md) | AT-271 |
| R-272 | Spreadsheet questions via a local SQL tool | P0 | chat | C-018 | G-021 | [M6](prd/M6.md) | AT-272 |
| R-273 | Create PDF, Word and Excel files | P0 | chat | C-027 | G-023, G-067 | [M6](prd/M6.md) | AT-273 |
| R-274 | Charts from data | P0 | chat | C-027, C-029 | G-024 | [M6](prd/M6.md) | AT-274 |
| R-275 | Presentations | P1 | chat | C-027 | G-023 | [M6](prd/M6.md) | AT-275 |
| R-276 | Edit an uploaded Office file in place | P1 | chat | C-027, C-028 | G-023, G-027 | [M6](prd/M6.md) | AT-276 |
| R-277 | File preview, save and drag-out | P0 | chat | C-029, C-042 | G-025 | [M6](prd/M6.md) ¹ | AT-277 |
| R-278 | File-aware suggestions | P1 | chat | C-001, C-018 | G-019 | [M6](prd/M6.md) | AT-278 |
| R-279 | Warm documents across follow-ups | P1 | chat | C-005, C-018 | G-011, G-019 | [M6](prd/M6.md) | AT-279 |
| R-280 | Echo cancellation and speaker-safe conversation | P0 | voice | C-012 | G-037 | [M3](prd/M3.md) | AT-280 |
| R-281 | Basic voice before the Voice pack lands | P1 | voice | C-010, C-011 | G-036 | [M3](prd/M3.md) | AT-281 |
| R-282 | Sentence-streamed speech with spoken-span truncation | P0 | voice | C-011, C-012 | G-037, G-038 | [M3](prd/M3.md) | AT-282 |
| R-283 | Two-stage end-of-turn detection | P0 | voice | C-012 | G-037 | [M3](prd/M3.md) | AT-283 |
| R-284 | Speech-recognition language routing | P0 | voice | C-010 | G-039 | [M3](prd/M3.md) | AT-284 |
| R-285 | Child-safety check on photo and video outputs (D-006) | P0 | platform | C-016 | G-048 | [M4](prd/M4.md) | AT-285 |
| R-286 | Image tool contract and memory handoff | P0 | photo | C-009, C-013 | G-011, G-041 | [M4](prd/M4.md) | AT-286 |
| R-287 | AI-generated mark and generation metadata | P0 | photo | C-013, C-014 | G-043 | [M4](prd/M4.md) | AT-287 |
| R-288 | Image variants | P1 | photo | C-013 | G-041 | [M4](prd/M4.md) | AT-288 |
| R-289 | Image upscale | P1 | photo | C-013 | G-041 | [M4](prd/M4.md) | AT-289 |
| R-290 | Video plan card with calibrated estimate | P0 | video | C-008, C-014 | G-046 | [M5](prd/M5.md) | AT-290 |
| R-291 | Durable one-at-a-time GPU job queue | P0 | video | C-015 | G-044 | [M4](prd/M4.md) | AT-291 |
| R-292 | Video sound track where supported | P1 | video | C-014 | G-045 | [M5](prd/M5.md) | AT-292 |
| R-293 | Content-addressed model store with exact 'frees X GB' | P0 | platform | C-007 | G-052 | [M2](prd/M2.md) | AT-293 |
| R-294 | Automatic model updates with rollback | P0 | platform | C-006, C-007, C-034 | G-052 | [M2](prd/M2.md) | AT-294 |
| R-295 | Embedding model installed with Chat | P1 | platform | C-006, C-019 | G-066 | [M2](prd/M2.md) | AT-295 |
| R-296 | Message tree storage | P0 | platform | C-031 | G-003 | [M1](prd/M1.md) | AT-296 |
| R-297 | Outbound network policy gate | P0 | platform | C-040 | G-056 | [M2](prd/M2.md) | AT-297 |
| R-298 | Starter model kept as a fallback | P1 | platform | C-006, C-009 | G-011, G-050 | [M2](prd/M2.md) | AT-298 |
| R-299 | Type before the model is ready | P0 | platform | C-001, C-002, C-PERF | G-002 | [M1](prd/M1.md) | AT-299 |
| R-300 | Catalog licence and anonymous-download rule | P0 | platform | C-006 | G-050, G-051 | [M2](prd/M2.md) | AT-300 |
| R-301 | Database migrations and local backups | P0 | platform | C-031 | G-059 | [M8](prd/M8.md) | AT-301 |
| R-302 | Draft autosave | P0 | chat | C-001, C-031 | G-015 | [M1](prd/M1.md) | AT-302 |
| R-303 | Help, What's new and first-use tips | P0 | platform | C-001, C-038 | G-018 | [M10](prd/M10.md) | AT-303 |
| R-304 | Website and hosting | P0 | platform | C-038 | G-062 | [M10](prd/M10.md) | AT-304 |
| R-305 | Signed, notarized release pipeline | P0 | platform | C-038 | G-061 | [M10](prd/M10.md) | AT-305 |

¹ **Delivered later than its gaps, with the reason:**
- **R-016** → M6: panel content is document/chart artifacts (M6).
- **R-017** → M6: needs produced files (G-023, M6).
- **R-091** → M8: page lists import/export/delete-all/crash opt-in (M8).
- **R-109** → M8: Accessibility permission comes with global dictation (G-040, M8).
- **R-221** → M9: AC spans voice/image/video/first-chat; instrumentation (G-064) lands M1, budgets re-checked every milestone.
- **R-228** → M7: [Turn on web search] opens the R-080 consent (M7); NFR-U12.
- **R-236** → M4: image turn (G-041, M4).
- **R-241** → M7: AC3 safe-search option belongs to web search (M7); audit runs in CI from M1.
- **R-247** → M2: AC includes embedding jobs (G-066, M2).
- **R-266** → M7: needs 40 real tools (M7).
- **R-267** → M7: needs online tools (M7).
- **R-268** → M7: lists search/connector/skill tools (M7).
- **R-277** → M6: AC covers all 8 file formats (M6).

**Other test families (defined in the milestone files):**

| Family | Meaning | Defined in |
|---|---|---|
| AT-### | requirement R-### acceptance | the R's milestone file |
| AT-NFR-<id> (e.g. AT-NFR-U1, AT-NFR-C1) | one NFR line from `nfr.md`, measured per test-strategy §6/§7 | the first milestone that checks it (§4); later milestones re-run it by ID |
| AT-M0-## | M0 spike gate | `M0.md` |
| AT-VQ-M# | the milestone's computer-use visual QA run, scored on the parity rubric | each milestone file |
| AT-FA-## | final acceptance suite (PLAN Phase 12), clean macOS account | `M10.md` |

---

## 4. NFR budgets

**All numbers:** [`nfr.md`](research/02-target/nfr.md). They are published-evidence hypotheses until M0 measures the stack on this Mac (M5 Max 128 GB, tier caps emulated per test-strategy §6). M0 replaces "hypothesis" with "measured" in `07-spikes/` reports; changing a budget is a **major** amendment.
**How they are measured:** test-strategy §6 (perf smoke, ≥ 20 runs, p50/p95, `build/perf/report.json`), §7 (offline/privacy), §8 (install). Regression > 5% vs the previous milestone is an S2 bug; > 25% on a ★ metric (U1, U2, C1, C2, V1, P1, M5) is S1.
**Not measured:** NFR-F3/F4/F5 (superseded by D-005/D-006); NFR-F8 Evil refusal benchmark (waived by D-011; R-240 uses lawful fixtures only); NFR-SEC6 becomes "no local API listener exists" (S-08), asserted by `lsof` in M1.

| Milestone | NFRs first checked here (AT-NFR-…) | Re-run |
|---|---|---|
| M0 | measured smoke (spike evidence, not yet gates): C1, C1b, C2, C4, M1, M3, M5, V1, P1, P2, VID1, F1, F2, F6, F7, C7, R1 | — |
| M1 | U1, U2, U4, U5, U6, U7, U8, U10, U11, C1, C1b, C2, C3, C4, C5, C6, S2, S4, R3, PR3, SEC6, B1 | — |
| M2 | U3, M1, M2, M4, M5, R1, R4, R5, D2, D3, D4, D5, D6, D9, S5, C7, PR1 (Offline-only run, test-strategy §7.1–7.3), SEC2, SEC7 | M1 set |
| M3 | V1, V1b, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11 | U2, U5, C1, R1, R4 |
| M4 | P1, P2, P3, P4, P5, M3, F1, F2, F6, F7, B2, B4 | R1, R4, R5, M4 |
| M5 | VID1, VID2, VID3, F9, B3, B5 | P1, F7, R1, M4 |
| M6 | SEC3 (File tools sandbox) and C4/C5 on real documents | C1, R1 |
| M7 | U12, SEC4, SEC5, PR1 default-settings capture (test-strategy §7.4) | PR1 offline run |
| M8 | U9, D7, D8, PR2, PR4 | PR3, S2 |
| M9 | A1, A2, A3, A4, A5, A6, S1, S3 (8 h soak), R2; **full re-run of every NFR** (`make perf test-offline`) | all |
| M10 | D1, SEC1, PR5 | install/upgrade/uninstall suite, full perf on the release build |

---

## 5. Model matrix summary

**Detail and pins:** [`model-matrix.md`](research/06-models/model-matrix.md) (§1 Normal pins by full commit, all `gated: False`; §9.2 Evil chat pins; §10 detectors). Summary: [06-models DIGEST](research/06-models/DIGEST.md).

| Role | T0 8 GB | T1 16 GB | T2 24/32/36 | T3 48/64 | T4 96/128+ |
|---|---|---|---|---|---|
| Starter (all tiers) | Qwen3.5-0.8B MLX 4-bit, 0.65 GB; stays as title/router alias and memory fallback (R-298) | | | | |
| Chat Normal (MLX) | Qwen3.5-2B @4 | Qwen3.5-9B @4 (4B on M1–M3 base) | 9B @4 / Gemma 4 26B-A4B @4 / Qwen3.6-35B-A3B @4 | 35B-A3B @4 / @6 | 35B-A3B @8 / Qwen3.5-122B-A10B @4 |
| Chat Evil | Qwen3.5-2B Heretic GGUF | Qwen3.5-9B Heretic GGUF | 9B Heretic / Gemma-4-26B Heretic MLX / Qwen3.6-35B Heretic MLX | Qwen3.6-35B Heretic MLX 4/6-bit | 8-bit / Qwen3.5-122B Heretic GGUF |
| Embeddings | Qwen3-Embedding-0.6B 4-bit DWQ | ← | + Qwen3-Reranker-0.6B | ← | ← |
| STT | Parakeet Ultra (ANE) + WhisperKit turbo for non-EU languages | + Parakeet EOU (live English) | ← | ← | ← |
| VAD / turn | Silero + smart-turn v3.2 | ← | ← | ← | ← |
| TTS | Kokoro-82M Core ML (AVSpeechSynthesizer if the memory fit fails, D-010) | ← | + PocketTTS (non-cloning) finalist | + Qwen3-TTS option | ← |
| Image (sd-server) | dimmed | FLUX.2-klein-4B Q4 | klein Q8; Z-Image-Turbo on S4 | + Qwen-Image-Edit-2511 + Lightning | ← |
| Video | dimmed | dimmed | FastMetal-5B-QAD (T2V) + Wan2.2-5B GGUF (I2V) | + LTX-2.3 q4 (sound) | + FastMetal-14B |
| Evil Photo/Video | Q-009 default (a): same as Normal | | | | |
| ChildSafetyCheck | Freepik/nsfw_image_detector + iitolstykh/mivolo_v2 (ONNX) + Apple Vision; ≈ 0.31 GB; rule in model-matrix §10 | | | | |

Download sizes per pack and tier: model-matrix §4 (NFR-D3 excludes Video, D-010). Finalists are confirmed or replaced in M0 (model-matrix §6, §9.5); a pick change is a major amendment.

---

## 6. Architecture summary

**Detail:** [`architecture.md`](research/10-architecture/architecture.md); one-screen view in [10-architecture DIGEST §1](research/10-architecture/DIGEST.md).
- **Base:** D-009/D-012 "assemble": our SwiftUI shell + pinned packages + a vendored Osaurus subset (`Vendor/osaurus@2922745`, ≥ 87 files) + design ports. Fallbacks F1 (pruned Osaurus hard fork) and F2 (Jan thin fork) fit the same layout (architecture §10). The D-012 switch rule is evaluated in M0/M1 (§7).
- **Repo:** one root SwiftPM package `AntiChatKit` with one module per group (Foundation, EngineProtocol, Network, Storage, Platform, Knowledge, Tools, Harness, Design, UI, Engines, EngineHost); `Packages/ChildSafetyCheck/` is a separate package with one importer. Thin Xcode project. Import graph enforced in CI (architecture §3).
- **Processes:** AntiChat.app (UI, sole DB writer, all HTTP through `NetworkGate`) · AntiChatEngine.xpc (MLX LLM/VLM/embeddings, FluidAudio, WhisperKit, scheduler, job runner, MediaOutputGate + ChildSafetyCheck; no network; restart ≤ 5 s) · `llama-server` child (`--no-models-autoload`, unix socket, `--no-webui --offline`, D-013) · `sd-server` child (D-013) · video-runtime Python child (signed download) · AntiChatFileTools.xpc (P1) · sandboxed local MCP servers (P1).
- **Data:** GRDB WAL `antichat.sqlite` (message tree, parts, artifacts, media jobs, memory, projects, permissions, installs/catalog, network activity); FTS5 + sqlite-vec in the same file; backup before migration; incognito in memory.
- **Online pieces:** Hugging Face pinned commits; signed catalog + Sparkle appcast (Vercel static); Composio relay on Vercel (`/v1/{health,session,mcp,connections,forget}`, D-007), the only AntiChat-run server.
- **Pins:** architecture §9.3 / 10-architecture DIGEST §2 (two SHA conflicts settled in M0.T01 by the peeled-tag rule).
- **Environment:** Xcode 27.1, Swift 6, Node 24, Python 3.13 + 3.12, uv, mise; `tools/bootstrap.sh` (environment §3); stub models and fixtures (environment §4–§5); make targets (environment §8).
- **CI/release:** self-hosted runner on this Mac + ubuntu for lint/relay/site; `SIGNING_MODE=adhoc|dev|devid`; inside-out signing; Sparkle 2.10.1; catalog keys A/B (ci-release).
- **Design system:** tokens, ~70 components, copy deck, 25 screens, parity rubric (design-system/).

### 6.1 Build conventions settled by the dry-run (RL-006; these win over older packet text)
1. **Test targets:** the XCUITest bundle is `AntiChatUITests` (`App/UITests`, scheme `AntiChat-UITests`); the SwiftPM test target of the UI module is `AntiChatUIModuleTests` (`Packages/UI/Tests/AntiChatUIModuleTests`), so the two never clash. App-hosted integration tests are `AntiChatIntegrationTests` (`App/IntegrationTests`, scheme `AntiChat-IntegrationTests`, created in M1.T02).
2. **Import graph:** a module may `import` another only if it is reachable along architecture §3 edges (transitive closure). `Package.swift` lists, per target, the §3 edges **plus** every transitively reachable module that target imports directly (Swift 6 explicit-module builds need direct dependencies); `tools/ci/import-graph.py` fails on any import or dependency outside the closure. Adding a module not reachable today needs a new §3 edge (architecture change, major if it alters a process boundary). Harness never imports Platform/Network: it declares protocols, conformances live in AntiChatUI (M2 conventions).
3. **Make arguments:** `FILTER=A,B` is expanded to one filter per item and the target fails when 0 tests ran; `TIER=` names a model set (`min|T0|T1|T3|evil-T1|…`), `CAP=` a hardware cap (`T2-24`, `T3-48`, …); `make test-visual SCRIPTS="a b"`; `make test-offline STEP=<step>`; check modes are `CHECK=1`, never `--check`; `SIGNING_MODE=adhoc|dev|devid` (not `SIGNING=`); `make perf METRIC=<one id> TIER=<one tier>` (loop for several).
4. **`-FakeHardware` aliases:** T0→`t0-m1-8`, T1→`t1-m2-16`, T2/T2-24→`t2-m4-24`, T3/T3-48→`t3-m4pro-48`, T3-64→`t3-m4max-64`, T4→`t4-m5max-128` (M2.T01 fixtures). Every DEBUG launch option is registered once in `AntiChatFoundation/Debug/LaunchOptions.swift` (M1 convention 10); DEBUG-only options never run on a Release build.
5. **Image engine binary:** `sd-server` child process from sd.cpp `e239e4b` (D-013); any packet mention of `sdcpp.xcframework` means this binary.
6. **`Runtimes/<name>/`** holds only lock inputs and lockfiles of downloadable runtimes; our Python code lives in `Packages/<Group>/Python/…` and build/launcher scripts in `tools/runtime/` (PRD §1.4 rule 6).
7. **Who creates shared tooling:** `antichat-cli` (M2.T10), `antichat-bench chat` (M1.T05), `catalog/dev.yaml` (M1.T02), `ScriptedImageEngine` (M2.T13), `ScriptedVoice` (M3.T03), `tools/visual/capture.sh` (M1.T09), voice fixtures (M3.T15), `photos-cc0`/OCR fixtures (M0.T01/T04). A tool, test, script or perf key named by an AT is created by the task that defines the AT unless a row here names an earlier owner.

---

## 7. Milestone plan

**Order (D-014):** M0 Proof → M1 … M10. Each milestone is independently verifiable: its exit criteria run on a build of that milestone alone. The safety floor (ChildSafetyCheck, R-285) ships in M4 **before** any generated image can be displayed.
**Effort baseline:** ≈ 140 pw of gap work (D-012, `gaps.json` point estimates, confidence L ±25%) plus M0 spikes and the per-milestone QA loop. Counts per milestone are in §3.

### 7.0 Gap ownership (every G in exactly one milestone)

| G | Title | Size | Risk | pw | P | Milestone |
|---|---|---|---|---|---|---|
| G-001 | Chat shell: window, sidebar, chat management, native menus | L | M | 5 | P-shell-01 | M1 |
| G-002 | Turn flow: TurnController, streaming states, stop/interrupt, queueing, titles | M | M | 2 | P-shell-02 | M1 |
| G-003 | Message tree, versions, branches, provenance | M | L | 1.5 | P-shell-03 | M1 |
| G-004 | Streaming Markdown / code / math renderer | M | M | 1.5 | P-shell-04 | M1 |
| G-005 | ⌘K palette and full-text chat search | M | L | 1.5 | P-shell-05 | M1 |
| G-006 | Composer + / slash / @ menus, tool chips, tools page | M | L | 1.5 | P-shell-06 | M1 |
| G-007 | Harness prompt layer: cache-stable composer, instructions, think-harder, memory snapshot | M | M | 2 | P-shell-07 | M1 |
| G-008 | Context management and non-destructive compaction | M | M | 1.5 | P-shell-08 | M1 |
| G-009 | Engine adapter contract + conformance suite (mlx-swift-lm, llama-server) | M | M | 2 | P-shell-09 | M1 |
| G-010 | XPC engine helper + llama-server child supervision + crash recovery | L | H | 3.5 | P-shell-10 | M1 |
| G-011 | Scheduler / memory orchestrator across engines | L | H | 4 | P-shell-11 | M2 |
| G-012 | Tool loop bounds, tool registry, permissions, load-when-needed | M | M | 1.5 | P-shell-12 | M1 |
| G-013 | Router: pre-router, fallback intent check, install cards, freshness hint | L | H | 4 | P-shell-13 | M2 |
| G-014 | Incognito chats that never touch disk | M | M | 1.5 | P-shell-14 | M1 |
| G-015 | Draft autosave | S | L | 0.75 | P-shell-15 | M1 |
| G-016 | Settings window, appearance, shortcuts | L | L | 3 | P-shell-16 | M1 |
| G-017 | Accessibility and localisation | M | M | 1.5 | P-shell-17 | M9 |
| G-018 | Help, What's new, first-use tips | S | L | 0.75 | P-shell-18 | M10 |
| G-019 | File intake + whole-vs-excerpt rule | M | M | 2 | P-files-tools-01 | M6 |
| G-020 | OCR for scanned PDFs and images | S | L | 0.75 | P-files-tools-02 | M6 |
| G-021 | Spreadsheet SQL tool (DuckDB) | M | M | 1.5 | P-files-tools-03 | M6 |
| G-022 | Image understanding wiring and text-only fallback | M | M | 1.5 | P-files-tools-04 | M6 |
| G-023 | File output tools (PDF, DOCX, XLSX, PPTX) with versions | M | M | 2 | P-files-tools-05 | M6 |
| G-024 | Charts: Vega-Lite spec with a native renderer | M | M | 1.5 | P-files-tools-06 | M6 |
| G-025 | File cards, Quick Look preview, drag-out, artifacts panel | L | M | 4 | P-files-tools-07 | M4 |
| G-026 | Media and file library | M | L | 1.5 | P-files-tools-08 | M5 |
| G-027 | File tools: sandboxed Python runtime (P1) | XL | H | 7 | P-files-tools-09 | M6 |
| G-028 | Web search pipeline: engines, citations, latency | M | M | 2 | P-files-tools-10 | M7 |
| G-029 | Search provider catalog + bring-your-own provider | S | L | 0.75 | P-files-tools-11 | M7 |
| G-030 | MCP connections UI, curated servers, tool-change review | M | M | 2 | P-files-tools-12 | M7 |
| G-031 | MCP OAuth: AntiChat CIMD + tests | S | L | 0.75 | P-files-tools-13 | M7 |
| G-032 | Local MCP stdio server sandbox (P1) | M | M | 1.5 | P-files-tools-14 | M7 |
| G-033 | Composio relay + client + per-action permissions | M | M | 2 | P-files-tools-15 | M7 |
| G-034 | Skills: loader, progressive disclosure, activation, authoring | M | L | 1.5 | P-files-tools-16 | M7 |
| G-035 | Memory and projects (P1) | L | M | 4 | P-media-01 | M8 |
| G-036 | Dictation, recordings, audio-file transcription, basic voice | M | L | 1.5 | P-media-02 | M3 |
| G-037 | Voice session: AEC, two-stage turn detection, barge-in | L | H | 4 | P-media-03 | M3 |
| G-038 | TTS: Kokoro read aloud, sentence streaming, voice settings | M | M | 1.5 | P-media-04 | M3 |
| G-039 | STT language routing with WhisperKit | M | M | 1.5 | P-media-05 | M3 |
| G-040 | Global dictation hotkey, menu bar item, quick panel (P1) | M | M | 1.5 | P-media-06 | M8 |
| G-041 | Image engine wrapper over sd.cpp (generate, edit, variants, upscale) | L | M | 4 | P-media-07 | M4 |
| G-042 | Image result card, viewer, versions, editor tools | L | M | 4 | P-media-08 | M4 |
| G-043 | AI-generated mark and metadata | S | L | 0.75 | P-media-09 | M4 |
| G-044 | Durable media job runner | M | M | 2 | P-media-10 | M4 |
| G-045 | Video engine: FastMetal runtime + sd.cpp video (I2V, sound) | XL | H | 8 | P-media-11 | M5 |
| G-046 | Video eligibility, estimates and plan card | M | M | 1.5 | P-media-12 | M5 |
| G-047 | Inline video player | S | L | 0.75 | P-media-13 | M5 |
| G-048 | ChildSafetyCheck package and no-filter audit | M | H | 1.5 | P-media-14 | M4 |
| G-049 | Hardware tiers T0–T4 / S1–S4 | S | L | 0.75 | P-platform-01 | M2 |
| G-050 | Signed model catalog and catalog-driven selection | L | M | 4 | P-platform-02 | M2 |
| G-051 | Download manager layer | M | M | 2 | P-platform-03 | M2 |
| G-052 | Content-addressed store and model updates with rollback | M | M | 1.5 | P-platform-04 | M2 |
| G-053 | Onboarding, pack manager, Evil variants | L | M | 4.5 | P-platform-05 | M2 |
| G-054 | Evil mode manager: frame, consent, tone | M | M | 1.5 | P-platform-06 | M2 |
| G-055 | Storage dashboard, remove everything, uninstall | M | L | 1.5 | P-platform-07 | M8 |
| G-056 | Offline guarantee, outbound gate, privacy page | M | H | 2 | P-platform-08 | M2 |
| G-057 | Diagnostics with zero telemetry | M | L | 1.5 | P-platform-09 | M8 |
| G-058 | Import / export | M | M | 2 | P-platform-10 | M8 |
| G-059 | Database migrations and backups | S | L | 0.75 | P-platform-11 | M8 |
| G-060 | Sparkle integration UI | S | L | 0.75 | P-platform-12 | M10 |
| G-061 | Release pipeline: inside-out signing, notarisation, DMG | M | M | 1.5 | P-platform-13 | M10 |
| G-062 | Website and legal pages | M | M | 1.5 | P-platform-14 | M10 |
| G-063 | Notifications | S | L | 0.75 | P-platform-15 | M8 |
| G-064 | Felt-speed instrumentation and budgets | M | M | 1.5 | P-shell-19 | M1 |
| G-065 | Just-in-time permissions | S | L | 0.75 | P-shell-20 | M3 |
| G-066 | Embedding model and semantic search | M | M | 1.5 | P-media-15 | M2 |
| G-067 | Donor extraction closure and vendoring infrastructure | M | H | 1.5 | P-platform-16 | M0 |
| G-068 | Package pin reconciliation | S | M | 0.75 | P-platform-17 | M0 |

**Dependencies that point forward, and how they are met (the registry `dependencies` field is unchanged):**
- G-041, G-045, G-027, G-057 → G-061 (signing/symbols): met by the **M0.T12 early slice** of G-061: `tools/release/sign.sh` inside-out ad-hoc signing + `verify-signing`, used for every embedded binary from M1. G-061 itself (DMG, notarization, appcast, CI release) closes in M10.
- G-050, G-031, G-033 → G-062 (hosting of catalog, CIMD, relay): met by **dev hosting** in M2/M7: `make site-dev` + a Vercel preview deployment of `site/` static files (catalog test-key feed, CIMD JSON) and `make relay-dev` / a relay preview with the stub key. Production domain and pages close in M10.
- G-048 → G-045: reversed in practice. M4 builds ChildSafetyCheck with the video frame sampler (≥ 2 fps + first/last + every preview, NFR-F9) unit-tested on stub frames; M5 wires the real video path into it and re-runs AT-285.
- G-025 → G-023: M4 builds file cards, Quick Look preview, drag-out and the side panel against fixture files and image results; M6 connects produced documents (R-016, R-017, R-277 close in M6).
- The R-241 audit script (part of G-048) runs in CI from M1 with a stub `ChildSafetyCheck` package, so no filter can creep in before M4.

### Milestone template
Each milestone below gives: **goal; requirements (R); gaps (G) and patches (P); entry criteria; exit criteria (ATs + NFR checks + visual QA score); dependencies; references.** The common exit block applies to every milestone and is not repeated:
> **Common exit:** every listed AT passes with its artefact; the NFR set of §4 for this milestone passes (and earlier sets show no regression > 5%); `make test audit` green; R-241 audit green; independent `/code-review` (high) findings fixed or filed; independent triage: **zero open S0/S1**, every S2 has an owner; visual QA (AT-VQ-M#) scored blind by two agents on the parity rubric with every listed screen at its bar (★ ≥ 4.5 with L, V, C ≥ 4; others ≥ 4.0; no dimension < 3); STATUS + `docs/prd/README.md` progress updated; milestone report committed.

---

### M0 — Proof (Phase 7 spikes as gated tasks; D-014)
- **Goal:** prove on real code, on this Mac, every High-risk assumption the plan rests on, before building product code. Each task is a timeboxed spike with a pass/fail gate and a documented fallback; spike code lives on `spike/*` branches and is promoted to `main` only through code review when it is production-grade (otherwise it is evidence only). Every spike writes `docs/research/07-spikes/S-<n>-<slug>.md` (question, method, result, evidence, PRD impact) and a row in `registry/spikes.json`.
- **Requirements:** — (no requirement closes here; gates are spike ATs)
- **Gaps:** G-067, G-068 · **Patches:** P-platform-16, P-platform-17
- **Entry:** Q-007 cleared (clone/build/run allowed in `~/AntiChat`); Xcode 27.1 installed; ≥ 150 GB free disk.
- **Tasks and gates:**

| Task | Spike | Gate (AT) | Fallback if it fails |
|---|---|---|---|
| M0.T01 | Repo scaffold + **bootstrap a clean checkout** (environment §3, §7): root package, thin Xcode project, `tools/bootstrap.sh`, stub models, fixtures repo skeleton, `make test-unit`; settle the swift-sdk and KeyboardShortcuts SHA conflicts by peeled tag (K-NEW-ARCH-4) and pin Kanna (K-NEW-ARCH-2) | **AT-M0-01:** `git clone . /tmp/antichat-clean && cd /tmp/antichat-clean && tools/bootstrap.sh --ci --tier min` exits 0 in < 25 min (re-run < 5 min); `build/bootstrap.log` committed as `07-spikes/bootstrap-run.md`; `make pins-verify` green | pin back to the last resolving tag (minor amendment); if Xcode 27.1 is unavailable, record the installed version and ask (permission/tooling) |
| M0.T02 | **Osaurus extraction closure** (S-1, G-067): vendor the ≥ 87-file closure into `Vendor/osaurus@2922745/` with vendir, `VENDORED.json` allow-list, D-01…D-15 deviations removed, ported Osaurus unit tests passing | **AT-M0-02:** `make build test-unit` with the vendored targets; ported tests green; `tools/ci/vendored-allowlist.py` passes; effort ≤ 10 working days | > 20 days or a blocking coupling → D-012 F1 trigger: **major amendment, ask** |
| M0.T03 | **Vendor-sync rehearsal replaying ≥ 6 months** of upstream (upstream §7): start from an osaurus SHA ≥ 6 months before `2922745`, apply our patches, then bump month by month to `2922745` with `make vendor-bump` (3-way `git merge-file`) | **AT-M0-03:** ≥ 6 monthly bumps replayed; every `ANTICHAT-PATCH: UP-###` marker survives; patch-lint + build + vendored tests green after each bump; median ≤ 1 day per bump; log `07-spikes/S-1-vendor-sync.md` | reduce the vendored surface (port instead of vendor for the worst files, minor); if > 2 days per bump median, record the yearly cost in the D-012 re-run (M0.T13) |
| M0.T04 | **Engine adapters** (S-3, S-4, G-009/G-010 prototype): `EngineProtocol` over mlx-swift-lm `f5b0677` in the XPC helper, and `llama-server` b11669 in router mode (`--no-models-autoload`, unix socket, `--no-webui --offline`); **speed smoke** with `antichat-bench chat` at T1 and T3 caps; vmlx-swift comparison (S-4); K-NEW-MOD-5 model-family support | **AT-M0-04:** NFR-C1/C1b/C2/C4/M1 measured for the T1 and T3 default models and the starter (report in `build/perf/`); XPC decode within 3% of in-process; helper `kill -9` → restart ≤ 5 s with the UI alive; `lsof` shows no TCP listener from llama-server; S-4 verdict recorded (switch only if ≥ 15% win) | a model family mlx-swift-lm can't run → its GGUF via llama-server (minor); NFR miss → next smaller catalog model for that tier (major: model change) ; XPC overhead > 3% → larger batch window (16 ms/8 tok → 33 ms/16 tok), else F2 trigger (major) |
| M0.T05 | **Voice round-trip** (K-022, K-NEW-ARCH-5, D-010): FluidAudio 0.18.0 Parakeet + Silero/smart-turn + Kokoro in the helper, VPIO capture | **AT-M0-05:** NFR-V1 p50 measured with fixture audio through a virtual device at T1 and T3 caps; Kokoro peak RSS recorded vs the T0/T1 budget; microphone TCC prompt attributed to AntiChat when capture runs in the XPC service | Kokoro doesn't fit T0/T1 → AVSpeechSynthesizer there (D-010, minor); TCC attribution wrong → capture in the app and stream PCM to the helper (minor) |
| M0.T06 | **sd-server image + memory handoff** (S-5, R-236, D-013): `sd-server` child from sd.cpp `e239e4b`, FLUX.2-klein-4B Q4 at 768²; scheduler prototype unloads/reloads the LLM | **AT-M0-06:** NFR-P1/P2 measured (S-class scaled); LLM unload ≤ 1 s and reload ≤ NFR-M1 at the T1 cap; on the T2 cap the chat model is not evicted; preview + cancel work | Draw Things gRPCServerCLI or mflux (engines §1, major only if the model changes) |
| M0.T07 | **Video runtime** (K-NEW-ENG-5, G-045 prototype): python-build-standalone 3.12 + FastVideo `d9e6c3e` as a signed downloadable runtime; FastMetal-5B-QAD T2V; Wan2.2-5B I2V via sd.cpp | **AT-M0-07:** one 480p clip at the T3 cap with step callbacks; NFR-VID1 measured and S-scaled; the runtime zip's nested Mach-Os pass `codesign --verify --strict` (ad-hoc) | ltx-2-mlx or sd.cpp `generate_video` only (minor); if no runtime meets NFR-VID1 on T2, video eligibility moves up a tier (major) |
| M0.T08 | **ChildSafetyCheck latency/accuracy on lawful proxies** (K-019, K-036; model-matrix §10): detectors via onnxruntime 1.24.2 CoreML EP + Apple Vision; calibration sets are adult-NSFW vs SFW proxies and non-sexual faces with ground-truth ages, kept private to the runner, **never any sexual image of a minor** (R-285 AC7) | **AT-M0-08:** NFR-F1, F2, F6 on the proxy sets and F7 (≤ 300 ms p95 per image at T1 cap); fail-closed on detector error; report `07-spikes/S-8-child-safety.md` | add the second signals (Marqo-384, SigLIP2 age bins) and recalibrate thresholds (minor); F7 miss → run detectors on ANE/batched, check only final + sampled previews at ≥ 2 fps (minor); accuracy miss after both → major (detector change) |
| M0.T09 | **Evil swap** (NFR-C7, D-011): Normal MLX 9B ↔ Evil Qwen3.5-9B Heretic GGUF (llama-server) at T1; `evil-quality-smoke-40` (lawful prompts only) | **AT-M0-09:** NFR-C7 measured; Evil tool-call validity ≥ 90% on `agentic-30`; vision kept (mmproj) on one fixture | another published Heretic build of the same base (model-matrix §9 alternates; major if outside the matrix) |
| M0.T10 | **First-chat starter path** (K-017, NFR-M5): starter 0.8B through swift-huggingface `199277c` + our chunked/verified layer, Network Link Conditioner 50 and 10 Mbps | **AT-M0-10:** download start → first token p50 within NFR-M5 at both speeds (onboarding UI time excluded until M2); resume after a forced disconnect re-fetches ≤ 1 chunk | parallel ranged GETs (C-007), Xet off (already) (minor) |
| M0.T11 | **ChatGPT export import** (G-058 prototype, P-platform-10): ChatGPT `conversations.json` mapping tree and Claude export → message tree with branches | **AT-M0-11:** importer prototype round-trips `fixtures/chats/exports/*` (synthetic exports built from the documented schemas, since no real sample exists, D-004) with every branch and the active path preserved | a flattened active-path import with a notice (major: changes R-092 behaviour) |
| M0.T12 | **Signing ad-hoc** (S-6) + **licence check** (S-7); early slice of G-061 | **AT-M0-12:** `SIGNING_MODE=adhoc make build-release` signs inside-out (app, XPC, llama-server, sd-server, runtime zip); `codesign --verify --deep --strict` and `spctl -a -vv` (expected: rejected only for "unnotarized") recorded; a test-key Sparkle appcast validates with `sign_update --verify`; licences recorded in `VENDORED.json` | dev signing identity (Apple Development) instead of ad-hoc (minor) |
| M0.T13 | **D-012 switch rule:** re-run `selection.md` §11 with the measured S-1 factor (and S-3/S-5 results) | **AT-M0-13:** the recomputed 3-year totals written into `selection.md` §11 and a DECISIONS entry; switch only if A exceeds F1-R by > 20% | switching base = **major, ask** |

- **Exit:** AT-M0-01…13 pass, or their fallback is adopted with an amendment; `07-spikes/` reports written; `spikes.json` filled; G-067 and G-068 closed; NFR hypotheses in `nfr.md` annotated "measured M0" where measured (numbers unchanged unless a major amendment is approved).
- **Dependencies:** none (first milestone). The S-2 shell-parity check runs as M1.T01 (the second half of the D-012 rule).
- **References:** selection §9; upstream §7; environment §3–§7; model-matrix §6, §9.5, §10; test-strategy §3.2, §6.

### M1 — Shell, design system, text chat, harness
- **Goal:** a native, ChatGPT-shaped AntiChat that chats with a local text model in Normal mode: window, sidebar, composer, streaming, stop, regenerate/versions, edit/branch, Markdown/code/math, ⌘K, settings window shell, incognito, drafts, crash recovery; the harness (cache-stable prompt layer, compaction, tool loop with scripted tools); the design system (tokens, components, copy deck) and felt-speed instrumentation. Models come from a dev list (`catalog/dev.yaml`, `make models-dev TIER=T1`) until the signed catalog lands in M2.
- **Requirements:** R-001, R-002, R-003, R-004, R-005, R-006, R-007, R-008, R-009, R-010, R-011, R-012, R-013, R-014 (P1), R-062, R-090, R-100, R-101, R-103, R-104, R-208, R-229, R-230, R-231, R-232, R-233, R-234 (P1), R-269 (P1), R-296, R-299, R-302
- **Gaps:** G-001, G-002, G-003, G-004, G-005, G-006, G-007, G-008, G-009, G-010, G-012, G-014, G-015, G-016, G-064 · **Patches:** P-shell-01, P-shell-02, P-shell-03, P-shell-04, P-shell-05, P-shell-06, P-shell-07, P-shell-08, P-shell-09, P-shell-10, P-shell-12, P-shell-14, P-shell-15, P-shell-16, P-shell-19
- **Entry:** M0 exit; base decision confirmed by AT-M0-13.
- **First task, M1.T01 S-2 shell parity checkpoint (≤ 2 weeks):** R-001…R-006, R-008, R-012 working on mlx-swift-lm, streaming at engine speed, idle RSS ≤ 200 MB. If our shell costs more than 2× the G-001…G-006 estimate, the D-012 rule says F1 keeping the Osaurus shell: **major, ask**.
- **Exit:** requirement ATs AT-001, AT-002, AT-003, AT-004, AT-005, AT-006, AT-007, AT-008, AT-009, AT-010, AT-011, AT-012, AT-013, AT-014, AT-062, AT-090, AT-100, AT-101, AT-103, AT-104, AT-208, AT-229, AT-230, AT-231, AT-232, AT-233, AT-234, AT-269, AT-296, AT-299, AT-302; NFR set M1 (§4); AT-VQ-M1 with `vq-02-first-chat`, `vq-03-edit-versions`, `vq-09` (incognito part), `vq-10` (General, Appearance, Shortcuts sections): ★ S-05, S-08, S-09, S-18 ≥ 4.5; S-07, S-21 (those sections), S-24, S-25 (interrupted, engine-crash states) ≥ 4.0; hard checks H1, H2, H5, H6, H8; snapshot tests for every component state built so far.
- **Dependencies:** M0.
- **References:** screens S-05, S-07, S-08, S-09, S-18, S-21, S-24, S-25; tokens.md, components.md, copy-deck.md; interaction-specs IS-1…IS-7; architecture §4–§7.

### M2 — Hardware tiers, catalog, downloads, onboarding, Evil mode manager
- **Goal:** AntiChat knows the Mac, installs the right models from a signed catalog with resumable, verified, deduplicated downloads, opens chat in about 2 minutes through the 4-screen onboarding, and offers Evil Mode (frame, consent, per-chat lock, tone sentence). Also lands the multi-engine scheduler, the router with install cards, the embedding model, and the outbound network gate with Offline only (every byte from here on goes through `NetworkGate`).
- **Requirements:** R-200, R-201, R-202, R-203, R-204, R-206, R-207 (P1), R-209, R-210, R-211, R-220, R-222, R-224 (P1), R-227, R-235, R-238, R-239, R-240 (P1), R-244, R-247, R-293, R-294, R-295 (P1), R-297, R-298 (P1), R-300
- **Gaps:** G-011, G-013, G-049, G-050, G-051, G-052, G-053, G-054, G-056, G-066 · **Patches:** P-shell-11, P-shell-13, P-platform-01, P-platform-02, P-platform-03, P-platform-04, P-platform-05, P-platform-06, P-platform-08, P-media-15
- **Entry:** M1 exit; dev hosting for the test-key catalog (`make site-dev` or a Vercel preview, §7.0).
- **Exit:** requirement ATs AT-200, AT-201, AT-202, AT-203, AT-204, AT-206, AT-207, AT-209, AT-210, AT-211, AT-220, AT-222, AT-224, AT-227, AT-235, AT-238, AT-239, AT-240, AT-244, AT-247, AT-293, AT-294, AT-295, AT-297, AT-298, AT-300; NFR set M2; AT-VQ-M2 with `vq-01-onboarding` (no-internet, disk-short, Evil on/off) and `vq-09` (Evil part): ★ S-01…S-04 ≥ 4.5 (H3 on art, H7 size honesty, truthful availability on T0–T4 fixtures via `-FakeHardware`); S-06, S-21 Capabilities/Packs & Models ≥ 4.5 (Capabilities bar), install cards ≥ 4.0; journeys 1, 7, 10 green.
- **Dependencies:** M1.
- **References:** screens S-00…S-04, S-06, S-21; VISION §1.2 (onboarding copy verbatim), §2.17, §2.19; hardware-tiers §2, §5, §6; model-matrix §1–§4, §9; ci-release §6.3 (catalog); architecture §5.

### M3 — Voice
- **Goal:** dictation in the composer, spoken conversation with echo cancellation, two-stage end-of-turn, barge-in with spoken-span truncation, read aloud, voice settings, STT language routing, audio-file transcription, basic voice before the pack lands, and just-in-time microphone permission.
- **Requirements:** R-050, R-052, R-053, R-054, R-056 (P1), R-057 (P1), R-280, R-281 (P1), R-282, R-283, R-284
- **Gaps:** G-036, G-037, G-038, G-039, G-065 · **Patches:** P-media-02, P-media-03, P-media-04, P-media-05, P-shell-20
- **Entry:** M2 exit (Voice pack installable).
- **Exit:** requirement ATs AT-050, AT-052, AT-053, AT-054, AT-056, AT-057, AT-280, AT-281, AT-282, AT-283, AT-284; NFR set M3; AT-VQ-M3 with `vq-08-voice`: ★ S-16 ≥ 4.5 (NFR-V1 for the tier, barge-in ≤ 200 ms), S-17 ≥ 4.0; journey 11 green with ScriptedVoice and with real models at T1/T3 caps.
- **Dependencies:** M2. **After M3:** upstream sync rehearsal #1 (PLAN Phase 12), run as M4.T00.
- **References:** screens S-16, S-17; VISION §2.14; model-matrix §2.2–§2.3; engines §1 (VAD/turn/AEC); nfr §3.

### M4 — ChildSafetyCheck and Photo
- **Goal:** first, `Packages/ChildSafetyCheck/` and `MediaOutputGate` (one call site, one category, fail closed, previews included); only then the Photo pack: image generation in chat with intent routing, real progress and live preview, result card, variants, viewer, edit by text with versions, editor tools, upscale, AI-generated mark, durable one-at-a-time GPU job queue, no chat reload after media on constrained Macs; file cards / Quick Look / drag-out infrastructure (G-025) used by image results.
- **Ordering rule (safety floor):** no task may route a generated image or preview to the UI until AT-285 and the R-241 call-site audit pass on that build. Tasks are ordered M4.T00 (sync rehearsal) → ChildSafetyCheck → MediaOutputGate → job runner → image engine → UI.
- **Requirements:** R-030, R-031, R-032, R-033, R-034 (P1), R-036 (P1), R-236, R-285, R-286, R-287, R-288 (P1), R-289 (P1), R-291
- **Gaps:** G-025, G-041, G-042, G-043, G-044, G-048 · **Patches:** P-files-tools-07, P-media-07, P-media-08, P-media-09, P-media-10, P-media-14
- **Entry:** M3 exit; AT-M0-06 and AT-M0-08 results available.
- **Exit:** requirement ATs AT-030, AT-031, AT-032, AT-033, AT-034, AT-036, AT-236, AT-285, AT-286, AT-287, AT-288, AT-289, AT-291; NFR set M4; ChildSafetyCheck calibration report (F1/F2/F6/F7) attached; AT-VQ-M4 with `vq-05-image` (incl. the blocked variant via ScriptedImageEngine): ★ S-11 ≥ 4.5 (real % every step, first preview ≤ NFR-P2, never > 3 s without a UI change); S-13 ≥ 4.0 (remove background ≤ 1.5 s on S1); journey 5 green.
- **Dependencies:** M3 (for ordering only; technically M2).
- **References:** screens S-11, S-13, S-25; VISION §2.15, §2.18; model-matrix §2.2, §10; test-strategy §2 (ChildSafetyCheck unit rules), §9; D-006, D-013.

### M5 — Video
- **Goal:** video generation in chat on eligible Macs: plan card with a calibrated estimate, background job with real progress, inline player and Library, animate a picture (I2V), presets, sound where supported; every frame path through ChildSafetyCheck at ≥ 2 fps + first/last + every preview (NFR-F9).
- **Requirements:** R-022, R-040, R-041, R-043 (P1), R-044 (P1), R-045, R-046, R-290, R-292 (P1)
- **Gaps:** G-026, G-045, G-046, G-047 · **Patches:** P-files-tools-08, P-media-11, P-media-12, P-media-13
- **Entry:** M4 exit; video runtime from AT-M0-07.
- **Exit:** requirement ATs AT-022, AT-040, AT-041, AT-043, AT-044, AT-045, AT-046, AT-290, AT-292; AT-285 re-run on real video; NFR set M5; AT-VQ-M5 with `vq-06-video` at the T3 cap: S-12, S-19 ≥ 4.0 (NFR-VID2, job survives window close); journey 6 green except the completion notification (R-042 closes in M8).
- **Dependencies:** M4.
- **References:** screens S-12, S-19; VISION §2.16; model-matrix §2.2, §4 (video sizes, D-010); D-013, D-014 (≥ 2 fps).

### M6 — Files in and out, charts
- **Goal:** attach and understand PDF, Office, scans (OCR), images (vision, with a fallback for text-only models), spreadsheets (local SQL tool); whole-document-or-say-excerpts rule; create PDF, Word, Excel and slides; charts from data (Vega-Lite, native render); artifacts side panel, file cards and Quick Look for all 8 formats; Python File tools sandbox (P1).
- **Requirements:** R-016 (P1), R-017, R-018 (P1), R-020, R-021, R-237 (P1), R-270, R-271, R-272, R-273, R-274, R-275 (P1), R-276 (P1), R-277, R-278 (P1), R-279 (P1)
- **Gaps:** G-019, G-020, G-021, G-022, G-023, G-024, G-027 · **Patches:** P-files-tools-01, P-files-tools-02, P-files-tools-03, P-files-tools-04, P-files-tools-05, P-files-tools-06, P-files-tools-09
- **Entry:** M5 exit (ordering); G-025 from M4.
- **Exit:** requirement ATs AT-016, AT-017, AT-018, AT-020, AT-021, AT-237, AT-270, AT-271, AT-272, AT-273, AT-274, AT-275, AT-276, AT-277, AT-278, AT-279; NFR set M6; AT-VQ-M6 with `vq-07-files`: ★ S-14 ≥ 4.5 (error on the tile, real reading %), S-15 ≥ 4.0 (drag-out to Finder/Mail); journey 4 green.
- **Dependencies:** M4 (G-025), M2 (G-066 embeddings for retrieval).
- **References:** screens S-14, S-15; VISION §2.12–§2.13; patches-files-tools.md P-files-tools-01…09.

### M7 — Web search, connectors, skills, tools page
- **Goal:** free keyless web search with local extraction, ranking and honest citations; bring-your-own and catalog-driven providers; MCP connections with OAuth 2.1 and tool-change review; Composio connectors through the AntiChat relay with per-action permissions; local MCP server sandbox (P1); skills (Agent Skills format, progressive disclosure, never silent scripts, create by chatting); the Tools page with per-chat toggles and load-when-needed; the fresh-information hint; the R-241 audit's full scope (safe-search option off by default).
- **Requirements:** R-080, R-081, R-082, R-228, R-241, R-248, R-249, R-250, R-251 (P1), R-252 (P2), R-253, R-254, R-255, R-256, R-257, R-258 (P1), R-259 (P1), R-260 (P1), R-261, R-262, R-263 (P1), R-264 (P1), R-265, R-266, R-267, R-268
- **Gaps:** G-028, G-029, G-030, G-031, G-032, G-033, G-034 · **Patches:** P-files-tools-10, P-files-tools-11, P-files-tools-12, P-files-tools-13, P-files-tools-14, P-files-tools-15, P-files-tools-16
- **Entry:** M6 exit; relay preview deployable (`make relay-dev`; real Composio key optional, §9).
- **Exit:** requirement ATs AT-080, AT-081, AT-082, AT-228, AT-241, AT-248, AT-249, AT-250, AT-251, AT-253, AT-254, AT-255, AT-256, AT-257, AT-258, AT-259, AT-260, AT-261, AT-262, AT-263, AT-264, AT-265, AT-266, AT-267, AT-268 (P2 stretch, not exit-blocking: AT-252); NFR set M7; relay E2E against a mocked Composio with the mock key (`relay/.env.test`; the stub key only yields 503) (and against real Composio when `COMPOSIO_API_KEY` and a user-provided test account are set, otherwise recorded not run); AT-VQ-M7 with `vq-04-search` online + offline: S-10 ≥ 4.0 (zero citation pills without a fetched source), S-21 Tools & Connections and Search sections ≥ 4.0; journey 12 green.
- **Dependencies:** M2 (gate, catalog), M1 (tool loop).
- **References:** screens S-10, S-21; VISION §2.8–§2.11; architecture §8 (relay); patches-files-tools.md P-files-tools-10…16.

### M8 — Memory, projects, import/export, privacy, storage, diagnostics, notifications, quick panel
- **Goal:** memory (visible writes, topic tool, frozen snapshot, propose-only review), projects with their own instructions and files, import of ChatGPT/Claude exports and full export, the Privacy & Data page, storage dashboard with Remove everything and Uninstall, diagnostics with zero telemetry and Report a problem, database migrations and backups, notifications, the global dictation hotkey, menu bar item and quick panel, and just-in-time permissions across all cases.
- **Requirements:** R-019 (P1), R-051 (P1), R-055 (P2), R-060 (P1), R-061 (P2), R-063 (P2), R-064 (P1), R-091, R-092 (P1), R-093, R-105 (P1), R-106 (P1), R-107 (P2), R-108 (P1), R-109, R-110 (P2), R-205, R-218, R-042, R-226, R-242 (P1), R-243 (P1), R-245 (P1), R-246 (P1), R-301
- **Gaps:** G-035, G-040, G-055, G-057, G-058, G-059, G-063 · **Patches:** P-media-01, P-media-06, P-platform-07, P-platform-09, P-platform-10, P-platform-11, P-platform-15
- **Entry:** M7 exit.
- **Exit:** requirement ATs AT-019, AT-051, AT-060, AT-064, AT-091, AT-092, AT-093, AT-105, AT-106, AT-108, AT-109, AT-205, AT-218, AT-042, AT-226, AT-242, AT-243, AT-245, AT-246, AT-301 (P2 stretch, not exit-blocking: AT-055, AT-061, AT-063, AT-107, AT-110); NFR set M8; `make test-install` (remove everything, uninstall, re-install) green in a Tart VM or fresh user (ci-release §9 fallback); AT-VQ-M8 with `vq-10-settings` (Privacy & Data, Storage, Personalization, Notifications) and `vq-11-failures`: S-20, S-22, S-23 ≥ 4.0; S-21 Privacy & Data and Storage ≥ 4.5; journeys 13, 15, 16 green; journey 6 completion notification green.
- **Dependencies:** M7 (tools for memory), M5 (video notification).
- **References:** screens S-20, S-21, S-22, S-23, S-25; VISION §2.4, §2.6, §2.21–§2.26; test-strategy §8.

### M9 — Polish against the parity rubric; performance; accessibility and localisation
- **Goal:** the whole app at the parity release bar, every NFR re-measured, accessibility (VoiceOver, keyboard, contrast, system settings) and localisation (String Catalogs; UI language), 8-hour soak, energy and swap budgets, plus any P2 pulled in. Upstream sync rehearsal #2 (PLAN Phase 12, before M10) runs as the last M9 task.
- **Requirements:** R-035 (P2), R-094 (P2), R-102 (P1), R-221, R-223
- **Gaps:** G-017 · **Patches:** P-shell-17
- **Entry:** M8 exit.
- **Exit:** requirement ATs AT-102, AT-221, AT-223 (P2 stretch, not exit-blocking: AT-035, AT-094); full `make perf test-offline test-install` green; NFR set M9; AT-VQ-M9: the **full** `make test-visual` (vq-01…vq-14), parity release bar: all ★ screens pass, ≥ 90% of the others, none < 3.5, every failing non-★ screen has an S2/S3 bug with an owner; Accessibility Inspector audit 0 warnings on primary screens (H4); one VoiceOver walkthrough per journey (NFR-A6).
- **Dependencies:** M1–M8.
- **References:** parity-rubric.md; test-strategy §5, §6; nfr §1–§11.

### M10 — Release pipeline, Sparkle, website, DMG (notarization pending credentials)
- **Goal:** a release candidate that a stranger can download and use: inside-out signed build, DMG with the brand background, Sparkle 2.10.1 updates with phased rollout, signed model catalog with production keys, website with help, legal and trust pages, appcast, CIMD and security.txt, What's new and first-use tips; the final acceptance suite on a clean macOS account. Until the user provides credentials, everything runs with `SIGNING_MODE=adhoc`, builds are labelled `UNNOTARIZED`, and the dev feed is used; notarization, stapling, production keys and production deploys are the last step (§9).
- **Requirements:** R-217, R-219, R-225, R-303, R-304, R-305
- **Gaps:** G-018, G-060, G-061, G-062 · **Patches:** P-shell-18, P-platform-12, P-platform-13, P-platform-14
- **Entry:** M9 exit.
- **Exit:** requirement ATs AT-217, AT-219, AT-225, AT-303, AT-304, AT-305; NFR set M10; release checklist [`ci-release.md` §8](research/10-architecture/ci-release.md) items 1–16 green (17–20 human, §9); **final acceptance AT-FA-01…14** on a clean macOS user or Tart VM: (01) download from the website, Gatekeeper passes; (02) onboarding; (03) fast first chat (NFR-M5); (04) offline chat; (05) dictation and voice conversation; (06) image, then video; (07) Evil mode; (08) the safety floor fires (ScriptedImageEngine blocked fixture, never real prohibited content); (09) import a ChatGPT export; (10) crash recovery; (11) relaunch keeps history; (12) appcast update N-1 → N; (13) uninstall cleans up (zero-files test); (14) low-RAM tier run if hardware is available (otherwise recorded as not run, D-003). AT-FA-01 and -12 pass in their ad-hoc form until credentials exist, then re-run as devid.
- **Ship rule:** zero open S0/S1 bugs (PLAN "zero open P0/P1 bugs"), every milestone's exit criteria still green on the release build.
- **Dependencies:** M0–M9.
- **References:** ci-release.md (all), screens S-21 (About/Updates), VISION §2.20, §2.29, §2.31–§2.32; adr-distribution.md.

---

## 8. Definition of done, bugs, release

**Task done:** every AT in the task passes with committed artefacts; the visual QA script for the touched screens was run and its findings triaged; unit/integration tests for new code exist (coverage targets test-strategy §2); `make test audit` green; no new upstream edit without an `UP-###` row; copy uses copy-deck keys; amendments recorded; commit `M#.T##: …`; STATUS line written.
**Milestone done:** the milestone's exit block plus the common exit (§7 template).
**Product done (v1):** M10 exit, including AT-FA-01…14, with notarization done once credentials exist.

**Bug severity and triage:** S0–S4 definitions, modifiers, SLAs and the independent triage agent: [`test-strategy.md` §10–§11](research/10-architecture/test-strategy.md). The builder never sets or lowers its own bugs' severity. Release gate: zero open S0/S1; S2 needs an owner and a known-issue note.
**Release checklist:** [`ci-release.md` §8](research/10-architecture/ci-release.md) (20 items; 17–20 are human, §9).

---

## 9. Human-only steps and what to do meanwhile

| Step | Needed by | Who | Meanwhile (never blocks the build) |
|---|---|---|---|
| **Q-007 permission:** allow cloning, building and running code in `~/AntiChat` (approve the prompt, or an allow rule) | M0 (all code) | user | Only documentation work is possible. M0 cannot start; this is the one hard block. Record it in QUESTIONS and ask. |
| **Composio API key + relay secrets** (`COMPOSIO_API_KEY`, `INSTALL_ID_HMAC_SECRET`, Upstash vars) set in Vercel (D-007, architecture §8.3) | M7 real-connector E2E; M10 release item 19 | user | Stub key `dev-not-a-key`: the app shows "Connections aren't available yet."; the relay E2E runs against a mocked Composio with `relay/.env.test` (`test-mock-key`); MCP connectors work fully. |
| **Developer ID Application cert + notarytool keychain profile** (D-003, Q-003) | M10 notarization (release items 10, 17) | user | `SIGNING_MODE=adhoc` (or Apple Development) everywhere; builds labelled `UNNOTARIZED`; dev appcast feed; AT-FA-01/-12 in ad-hoc form. Give the user the exact commands from ci-release §3–§4. |
| **Production key ceremony** (Sparkle Ed25519, catalog keys A/B; offline custody) | M10 (item 18) | user | Test keys from fixtures; a Release build refuses to compile with test keys, so release builds wait. |
| **`ghrunner` macOS user + auto-login** (K-NEW-ARCH-3) | nightly/self-hosted CI | user (admin) | Run the same make targets locally on this Mac from the build session. There is no fresh test user (Q-002). |
| **Tart clean-macOS image** (no human step) | install tests (M8.T11), final acceptance (M10.T09) | agent | `tart clone ghcr.io/cirruslabs/macos-tahoe-vanilla:<pinned>` (prebuilt, no Setup Assistant; tag and digest recorded in `image.lock`, `[ASSUMPTION]` until pulled); controlled with `tart exec`/SSH. If Tart or the pull is refused → §1.5 case 1, record "not run". |
| **Private ChildSafetyCheck calibration proxies** at `~/AntiChatPrivateFixtures/csc/{nudity,age}` (`labels.csv`, `ages.csv`; lawful proxies only: adult-only NSFW vs SFW, and non-sexual age-labelled faces, R-285 AC7; layout M0.T08) | M0.T08 accuracy part (F1/F2/F6); **M4 exit** (calibration report) | user, or an explicit user authorisation for the agent to assemble them from named public SFW age benchmarks plus lawful adult-only sets | AT-M0-08 runs F7 + fail-closed; F1/F2/F6 `[PENDING-PRIVATE]`; M4 builds and tests everything else, but **M4 cannot exit** and no generated image is routed to the UI outside tests until the calibration report passes. Ask at build start (Q-### written by M0.T08). |
| **One-time macOS and computer-use grants** for the build/QA session: Accessibility, Input Monitoring, Screen Recording, Notifications, Microphone for the runner and the AntiChat dev build; Automation (System Events); computer-use `request_access` for AntiChat, Finder, TextEdit, Preview, Notes, System Settings, Accessibility Inspector, Numbers/Pages/Keynote (and Office), browser at read tier. Optional: an Apple Development identity (free Apple ID in Xcode) so grants survive rebuilds (`SIGNING_MODE=dev`). | M3, M6, M8, M9, every AT-VQ | user, once | Preflight records which grants exist; missing grant → that sub-step `not run: perm` + Q-007 entry; the AT is not passed and is listed at exit (M8 conventions). |
| **Microsoft Word/Excel/PowerPoint for Mac** (optional; unlicensed view-only suffices, no purchase) | M6 AT-273 check 5, AT-275 check 1c | user (admin / Apple ID) | Office columns `not run (Q-M6-01)`; iWork and all other checks run. |
| **Composio test account** (`COMPOSIO_TEST_ACCOUNT` in `relay/.env.local`, browser sign-in) | M7 real-connector E2E (optional), M10 item 19 | user | Mocked E2E with `relay/.env.test` (`test-mock-key`, `COMPOSIO_BASE_URL` → mock); real E2E recorded "not run (human)"; never exit-blocking. |
| **`gh auth` + public repo, `vercel login` (preview protection off)** | M10 hosting (AT-304, AT-305 check 6, AT-FA-01/-12 on real URLs) | user, in the single pre-M10 credential handoff below | Local `feed-server.py` host for site/feed (M10 "Hosting and accounts before the human steps"); `vercel dev` only when `vercel whoami` exits 0, else `relay/scripts/local-server.ts`; GitHub items `pending (public repo)`. |
| **Public repo, domain, support/abuse/security inboxes, legal entity** (Q3, D-007) | M10 (site, CIMD URL, bundle id) | user | Local git; placeholder bundle id `app.antichat.AntiChat`; Vercel preview URLs for site/CIMD/catalog. |
| **Lawyer review** (K-035…K-038, K-040, K-041, K-055, K-059, K-060) | before public release | user + lawyer | Ship the honest copy from the copy deck; list the open legal K's in the M10 report. |

**Pre-M10 credential handoff (RL-006).** Q-003 (user) moved Developer ID + notarytool to release time, so rubric M4 ("all credentials at G0") is met by one scheduled handoff at M10 entry instead of G0, an exception the user must confirm. In that one session the user provides: Developer ID cert (`security find-identity -v -p codesigning`), notary profile `antichat-notary` (`xcrun notarytool history --keychain-profile antichat-notary`), the key ceremony, `gh auth status` + public repo, `vercel whoami`, domain and inboxes (`Config/Endpoints.plist`), Composio/relay env. The agent checks each with the command shown and never waits mid-build for any of them.

---

## 10. Traceability status and what Phase 11b/11c add
- `python3 tools/trace-check.py --phase 11`: every P0/P1 requirement now has a component and an AT; every gap has a patch. Phase 11b dispositioned every K in `risks.json` (§11); `--phase 11` passes with no violations. (The check now skips superseded requirements, which by definition have no AT.)
- **Phase 11b:** write `docs/prd/M0.md` … `M10.md` (task scheme in `docs/prd/README.md`), defining every AT listed here with exact commands and visual QA scripts.
- **Phase 11c:** the executability dry-run agent (zero blocking ambiguities, rubric 11 M3) and the trace reviewer; findings into `REVIEW-LOG.md`.

---

## 11. Risks register summary

**Source of truth:** [`registry/risks.json`](research/registry/risks.json) (rendered in [`02-target/risks.md`](research/02-target/risks.md)). Phase 11b (2026-10-30) dispositioned every open risk: **60 total, 0 open, 51 accepted, 9 closed, 9 flagged for the lawyer.** An accepted risk is owned by the milestone below: its `validated_by` ATs confirm the assumption or trip it; a trip uses the fallback in that milestone's task table (a fallback that changes an R, model, base or budget is a major amendment, §1.4). Each milestone report (`docs/prd/M#-report.md`) states the result for the risks it owns.

### 11.1 Accepted risks by owner milestone

| Milestone | Risk | Title | Validated by | Lawyer |
|---|---|---|---|---|
| M0 | K-002 | Metal recommendedMaxWorkingSetSize fraction per RAM size is ~2/3 at <=16 GB rising to ~84… | AT-M0-04, AT-200 |  |
| M0 | K-004 | Two-axis model selection (RAM tier x speed class; step down when predicted decode <15 tok… | AT-M0-04, AT-222 |  |
| M0 | K-005 | T0 (8 GB) Chat: ~2B dense @4-bit, 8K context, ~2.3 GB resident, >=20 tok/s | AT-M0-04, AT-222, AT-221 |  |
| M0 | K-006 | T1 (16-18 GB) Chat: ~9B @4-bit 16K on >=120 GB/s chips, ~4B @4-bit on M1/M2/M3 base | AT-M0-04, AT-M0-05, AT-222 |  |
| M0 | K-007 | T2 (24-36 GB) Chat: ~9B @8-bit (24-32 GB) / ~35B-A3B MoE @4-bit (36 GB, tight) | AT-M0-04, AT-222, AT-221 |  |
| M0 | K-008 | T3 (48-64 GB) Chat: ~35B-A3B MoE @4-bit (48) / @6-bit (64) with 64K context, image model… | AT-M0-04, AT-M0-06 |  |
| M0 | K-009 | T4 Chat: ~35B-A3B @8-bit (96 GB) / ~122B-A10B @4-bit (128 GB+, 73 GB resident) | AT-M0-04, AT-221 |  |
| M0 | K-010 | Voice classes per tier fit 0.6-1.7 GB and STT/VAD on Neural Engine (Core ML) keeps GPU fr… | AT-M0-05, AT-284 |  |
| M0 | K-011 | Photo: T0 dimmed; T1 distilled ~4B DiT int4 at 768-1024 px peaks <=7 GB | AT-M0-06, AT-NFR-P1 |  |
| M0 | K-013 | Video: T1 dimmed (480p to be tested); T2 distilled ~5B INT8 peak ~9.5 GiB, 720p clip ~3.5… | AT-M0-07, AT-046 |  |
| M0 | K-014 | Video T3/T4: LTX-2.3-class audio+video (q4 ~12 GB tier; bf16 42-66 GB) feasible and licen… | AT-M0-07, AT-292 |  |
| M0 | K-015 | Image/video time scales as C / pp512 (C~25-32k image 1024px 4-step; ~110-145k video 81 fr… | AT-M0-06, AT-M0-07, AT-290 |  |
| M0 | K-017 | Fast first chat: ~0.8B (0.65 GB) model + optional Apple Foundation Models bridge gives fi… | AT-M0-10, AT-203, AT-NFR-M5 |  |
| M0 | K-019 | Child-safety check detectors (NSFW classifier + Apple Vision person/face + apparent-age e… | AT-M0-08, AT-285 |  |
| M0 | K-020 | LLM unload/reload around image/video jobs on T1-T2 and cold loads meet NFR-M1/M3 (mmap +… | AT-M0-06, AT-236 |  |
| M0 | K-022 | T1 voice round-trip <=1.5 s p50 achievable with ANE STT + 4-9B LLM + Kokoro-class TTS and… | AT-M0-05, AT-NFR-V1 |  |
| M0 | K-044 | Slow connections (<25 Mbps) miss the 2-minute first-chat target | AT-M0-10, AT-203 |  |
| M0 | K-045 | MLX/Metal version pitfalls: metal4.0 JIT failure on older macOS, M5 accelerators need 26.… | AT-M0-01, AT-M0-04 |  |
| M0 | K-046 | Abliteration degrades small models disproportionately; Evil quality at T0/T1 may be unacc… | AT-M0-09, AT-239 |  |
| M0 | K-048 | Child-safety check adds latency or false positives on adult content that make Photo/Video… | AT-M0-08, AT-285, AT-NFR-F6, AT-NFR-F7 |  |
| M0 | K-049 | Notarization/hardened-runtime issues with embedded runtimes (Python, Metal JIT) or downlo… | AT-M0-12, AT-M0-07, AT-305 |  |
| M0 | K-NEW-GAP-1 | Osaurus donor extraction closure (64 files + >=23 support files) and whether swift-sdk 0.… | AT-M0-02, AT-257 |  |
| M0 | K-NEW-GAP-3 | Can sd.cpp LTX-2 (init/end image, audio VAE) replace ltx-2-mlx for Normal I2V + sound? | AT-M0-07, AT-043, AT-292 |  |
| M2 | K-003 | OS headroom constants per tier (3.5 GB at 8 GB ... 16 GB at 128 GB) leave macOS and typic… | AT-M0-06, AT-206, AT-NFR-M4, AT-NFR-R2 |  |
| M2 | K-012 | Photo T2-T4 classes (8-bit 4B DiT / ~6B distilled DiT / bf16) with Apache/MIT-licensed de… | AT-M0-12, AT-300 |  |
| M2 | K-030 | Abliterated/uncensored HF repos vanish, get gated or disabled after adoption | AT-220, AT-294 |  |
| M2 | K-031 | Hugging Face rate limits/outage or gated repos requiring tokens break account-free downlo… | AT-204, AT-300 |  |
| M2 | K-034 | Catalog manifest key compromise, rollback or freeze attack | AT-220 |  |
| M2 | K-040 | Licence incompatibility or redistribution breach of mirrored weights (non-commercial FLUX… | AT-M0-12, AT-300, AT-217 | yes |
| M2 | K-043 | Memory pressure from other heavy apps causes swap storms or OOM during generation | AT-206, AT-NFR-M4 |  |
| M2 | K-047 | Disk exhaustion on 256 GB Macs, especially with Evil doubling chat weights | AT-NFR-D2, AT-227, AT-205 |  |
| M2 | K-054 | Unknown or new chips (MacBook Neo A18 Pro, M6, future M7) misclassified by tier/speed tab… | AT-200, AT-220 |  |
| M2 | K-059 | Evil image/video LoRAs or finetunes may have been trained on illegal or non-consensual ma… | AT-300, AT-285 | yes |
| M4 | K-036 | Child-safety check failure: Photo/Video output of sexual content involving minors - crimi… | AT-M0-08, AT-285, AT-FA-08 | yes |
| M4 | K-038 | EU AI Act Art. 50(2) machine-readable marking of generated audio/image/video/text applies… | AT-287 | yes |
| M5 | K-021 | Fanless Macs (Air, Neo) throttle 25-40% after ~10 min sustained inference, stretching vid… | AT-207, AT-NFR-B3, AT-290 |  |
| M5 | K-053 | Battery drain and heat on laptops during voice/image/video use draw complaints | AT-207, AT-NFR-B1, AT-NFR-B2, AT-NFR-B3, AT-NFR-B5 |  |
| M6 | K-042 | Long-input TTFT on S1 chips (prefill ~110-200 tok/s) makes 4K-token documents take 20-40 s | AT-NFR-C5, AT-270, AT-NFR-C4 |  |
| M7 | K-051 | Code execution or MCP tools escape sandbox or are steered by prompt injection | AT-018, AT-NFR-SEC3, AT-259, AT-260, AT-265, AT-NFR-SEC4, AT-NFR-SEC5 |  |
| M8 | K-050 | Opt-in crash reports leak prompt or file content | AT-218, AT-NFR-PR2 |  |
| M9 | K-052 | Glass/art-heavy onboarding and UI fail WCAG 2.2 AA contrast or Reduce Transparency | AT-223, AT-NFR-A6, AT-VQ-M2 |  |
| M10 | K-032 | Apple revokes Developer ID or notarization (or terminates account) e.g. after press frami… | AT-305, AT-219 |  |
| M10 | K-033 | Sparkle EdDSA private key lost or compromised | AT-219 |  |
| M10 | K-035 | UK offence of making/supplying a 'purported intimate image generator' (Crime and Policing… | AT-217, AT-287 | yes |
| M10 | K-037 | Non-consensual intimate imagery of real people created with AntiChat and published by use… | AT-217, AT-287 | yes |
| M10 | K-041 | Hosting/CDN/website/GitHub provider deplatforms us over uncensored or NSFW-capable weights | AT-304 | yes |
| M10 | K-055 | 'Near-0% refusal' and 'never says no' claims are inaccurate for packs with a floor or for… | AT-211, AT-217, AT-304 | yes |
| M10 | K-060 | Age-assurance duties (UK Online Safety Act Part 5; EU/member-state rules) may require mor… | AT-211, AT-217 | yes |
| — (accepted RL-004, user decision D-005/D-006) | K-039 | Evil chat gives serious harmful assistance (weapons, malware); liability, host/CDN AUP an… | — | |
| — (accepted RL-004, user decision D-005/D-006) | K-057 | Video models with an audio track (LTX-2.3 class) can generate sexual audio involving mino… | — | |
| — (accepted RL-004, user decision D-005/D-006) | K-058 | Real-person rule: prompts naming a private individual plus a sexual image request; AntiCh… | — | |

**Closed (decision or evidence):** K-016 (Evil disk: Chat needs a full second weight copy; Photo/Vide…); K-018 (Minimum macOS 26.0 (Tahoe): excludes no Apple-silicon hardw…); K-023 (Product-spec photo target (<=30 s mid tier) is not achievab…); K-024 (Update-check default conflicts: D-001 auto-update vs produc…); K-056 (Upstream repo content changes under the same name (force-pu…); K-061 (GPL source lets third parties build AntiChat forks with the…); K-062 (The starter chat needs the safety text guard before its fir…); K-NEW-GAP-2 (Exact pins: FluidAudio 0.14.x (D-009) vs >=0.18 (KokoroAne,…); K-NEW-GAP-4 (Vega-Lite renderer for R-274: Swift Charts translation vs o…). Reasons in each entry's `resolution`.

### 11.2 Lawyer list (before public release, §9)

Accepted for the build; must be reviewed by a human lawyer before the M10 public release. List them, with the review outcome, in the M10 report.

| Risk | Question for the lawyer |
|---|---|
| K-035 | does Photo (incl. real-photo edit) fall under the UK 'purported intimate image generator' offence, and are these steps 'all reasonable steps'? |
| K-036 | adequacy of an output-only detector check and of the GPL-fork / trademark statement for UK/US CSAM-generator offences. |
| K-037 | exposure under the TAKE IT DOWN Act and state deepfake laws for a local tool with no hosting. |
| K-038 | is IPTC/C2PA metadata without an invisible watermark sufficient under Art. 50(2), and is chat text marking required for a local tool? |
| K-040 | LTX-2 Community License revenue cap and AUP vs Evil mode; CC-BY attribution form. |
| K-041 | confirm GitHub/Vercel AUPs allow an uncensored-model client; name a backup host. |
| K-055 | consumer-protection wording of 'near-zero refusals' / 'unfiltered'. |
| K-059 | base-model training-data provenance duty for distributed image/video weights. |
| K-060 | does UK OSA Part 5 or EU/national law (DSA, France SREN) apply to a local serverless app; if yes, the founder chooses geo-limited Evil or third-party age estimation (major amendment). |

Also for the same review (already accepted by the user, D-005): K-039 (Evil chat harmful assistance: liability and Terms wording).
