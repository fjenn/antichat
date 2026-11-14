# M11 "after v1": candidate list (proposal for the owner, D-025)

**Status:** decided: see D-026. (The proposal text below is kept for the record. All of A, B1, B3, B4, B5, C and D were approved; B2 was rejected.)
**Test used:** "Would a normal ChatGPT user notice it is missing in v1?" If the answer was "maybe", the item stayed in v1.
**Never touched:** ChildSafetyCheck (D-006) and everything around `MediaOutputGate`, the code-execution sandbox (M6.T15–T19), Sparkle auto-updates (M10.T03), and every data-loss protection (backups, migrations, autosave, atomic installs, uninstall correctness).
**Effort** below means agent-schedule days from the milestone task tables (rough; M8/M9 tasks have no table estimate, so I estimated those).

---

## A. Stretch tasks to move

| # | ID | What it is, in plain words | Why a v1 user won't miss it | Saves | Confidence |
|---|---|---|---|---|---|
| A1 | **M8.T15** (whole) | Extras already marked P2 "only if time": voice-session hotkey, "Reference chat history", import/export of memories, Screenshot / Attach window, `antichat://` links | Each was already marked "only if time". Memory itself (M8.T02–T03) stays. The closest call is **R-061 "reference past chats"**: ChatGPT has it, but few users know it exists, and memory covers the common case. Screenshots can still be pasted or dragged in. | ~5 d | high (R-061: medium) |
| A2 | **M9.T07** (whole) | Image templates gallery and locked chats (P2) | Already P2. ChatGPT doesn't lock individual chats. Templates are a nice-to-have. | ~3 d | high |
| A3 | **M7.T04** (whole) | Bring your own search provider with an API key (Brave, Tavily, Kagi…), plus the P2 hosted search fallback (R-252) | Normal users never paste API keys. Built-in keyless search (M7.T01–T03) stays, with the engine-availability harness. The risk: if free engines get blocked, nothing hosted backs them up. The catalog can still add engines without an app release. | 1.5 d | high (R-252), medium-high (R-251) |
| A4 | **M7.T09** (whole) | Running local MCP servers (node/uv programs) in a sandbox on the Mac (R-259, P1) | ChatGPT supports only remote connectors. Local stdio servers are a developer and power-user feature. Remote MCP, OAuth, tool-change review and Composio all stay. **Contract to keep:** M7.T13 must create `ProcessLauncher` + `no-raw-process.py` itself (today only T09 creates them). | 3 d | medium-high |
| A5 | **M2.T07**, sub-item "Add by Hugging Face ID" (R-224, P1) | Pasting any HF repo ID under Advanced to download an untested model | ChatGPT users don't pick models from Hugging Face. The rest of the Advanced override UI, Reset to recommended, keep-alive and allow-over-budget (R-222, P0) all stay. | ~2 d | high |
| A6 | **M4.T14** (whole) | "Make 4" image variants and the ×4 upscaler (R-288, R-289, P1) | ChatGPT has neither. Users regenerate or ask again. It also skips one extra model download (`img-upscale`). The image half of NFR-B4 (battery ask before big batches) goes with it. The video half stays in M5. | 3 d | medium-high |
| A7 | **M4.T15**, part (R-034, P1) | Move: Markup pen/shapes/text, Sketch canvas, Comment pins, Resize/outpaint. **Keep:** Erase (select an area and remove it) and Remove background. | This follows R-034's own cut order: pins and outpaint go first, then Markup, while Erase and Remove background are kept. Sketch isn't in the cut order, but ChatGPT has no sketch canvas. Editing by text (M4.T13, P0) stays. | ~3 d | medium (Sketch: medium-low) |
| A8 | **M4.T07**, sub-item "Think harder for images" (R-036, P1) | A visible planning step before an image is generated | Users don't ask for it. The prompt rewrite (R-030 AC3) still gives good prompts. | ~0.5 d | medium |
| A9 | **M8.T14**, sub-item "Dictate in any app" (R-051, P1) | A global hotkey that types dictation into other apps (Wispr-style) | ChatGPT's Mac app doesn't do this, and you build it separately as Wispr Bro. **Keep in v1:** the just-in-time permission matrix (R-109, P0) from the same task. | ~3 d | medium-high |
| A10 | **M6.T14** (whole) | File-type suggestion chips after an upload ("Summarise / Extract tables…") (R-278, P1) | Neither ChatGPT nor Claude shows these. Users type the request. The general empty-state chips (M2.T20) stay. Small cost: on T0 Macs, typed requests rely on the small model's tool choice. | 1.5 d | medium |

**Total A:** about 25.5 days. Six whole tasks (M8.T15, M9.T07, M7.T04, M7.T09, M4.T14, M6.T14) plus four sub-items.

**Near-misses I considered and kept in v1:**
- **M3.T04** basic voice before the Voice pack lands: without it, the mic is dead right after onboarding.
- **M3.T05** WhisperKit for languages outside Parakeet's 25: without it, Japanese, Chinese or Arabic dictation would come out as garbage.
- **M3.T12** echo cancellation: voice on laptop speakers depends on it.
- **M5.T04** "Animate a picture", **M5.T07** sound on video and **M5.T13** Library: current consumer video and image apps all have these.
- **M6.T11** PowerPoint, **M6.T20** editing an uploaded Office file and **M6.T15–T19** run-code: everyday "make me a deck" and "fix my spreadsheet" requests.
- **M7.T08** tool-change review: security against connector rug-pulls.
- **M7.T13** "create a skill by chatting": Claude has it, and you asked for skills.
- **M8.T06** ChatGPT/Claude import: it's how people switch.
- **M8.T13** menu bar + quick panel: ChatGPT has ⌥Space.
- **M8.T12** notifications, **M9.T04** five UI languages, **M2.T14** Performance picker (cheap), **M2.T15** warm Evil variant and **M2.T17** Touch ID for Evil (P0 consent).
- **M2.T16** reranker on T2+: M7 page ranking uses it too.

---

## B. Simplifications (v1 keeps a correct, safe, user-identical version)

| # | Where | v1 keeps | Moves to M11 | Why it's safe | Saves | Confidence |
|---|---|---|---|---|---|---|
| B1 | **M2.T02** network swizzle | `NetworkGate` sessions with categories, `GateURLProtocol` on every gate session, package hooks (HubClient session, swift-sdk transport config, FluidAudio offline, Sparkle delegate), the `URLSession(` lint, forbidden-deps, no-background-session, and the whole Offline-only proof (deny-outbound sandbox + 30-min capture, AT-209/AT-NFR-PR1) | The ObjC swizzle of `NSURLSessionConfiguration` (`GateObjC`, ported from Wormholy) and `SwizzleCoverageTests`. A new `InjectionCoverageTests` takes their place and lists every session creator in `Package.resolved`. | Every dependency we ship gets its session injected, and the deny sandbox catches any leak at test time. **Condition:** if T02 finds a dependency that builds its own session and can't be injected, the swizzle stays in v1. | ~1 d | medium |
| B2 | **M2.T11** model auto-updates | Revocation handling: a revoked model shows `model.revoked` with [Download replacement], goes through the normal T09 queue, and the slot flips in one transaction (T10). The `model_install.previous_manifest_sha` column stays. | Silent background same-slot upgrades, the idle-moment swap, the rollback window on a failed first load, the >2 GB ask, the "Update models automatically" row, and the `catalog-upgrade*` fixtures | v1 ships with the newest catalog, so there's nothing to upgrade until a later catalog exists. A later app version (delivered by Sparkle) brings the full T11 before any upgrade is published. **Caveat: R-294 is P0** and R-220 AC2 points at it, so this one needs your explicit yes. If you're unsure, keep it. | ~2.5 d | medium |
| B3 | **M2.T23** router calibration | `router-300` (6 languages, blind-reviewed labels), threshold fitting, fallback re-ask + "Create this as an image?" chip, full-stack precision/recall bar at T1 and the T2-24 cap, `media-100` + two-judge check in T24 | The "model alone" baseline report (no bar), the optional constrained-JSON intent check (stays as the documented fallback if the bar is missed) and the nightly CI bench | The user-facing bar (≥ 95% precision / ≥ 90% recall for the full stack) is unchanged. Only the extra reporting goes. | ~1 d | medium-high |
| B4 | **M4.T00** upstream sync rehearsal #1 | M9.T09 (rehearsal before release), which must fix what it finds | The whole task. D-025 already dropped it; this just files its spec under M11. | Already decided in D-025 | 2 d | high |
| B5 | **M7.T13** skills activation eval | The eval at T0 and T1 with the same bar | The T2 leg (the T2-24 default is the same `chat-9b-q4` as T1) | Same model, so the leg adds no information. T2-32/36 models get covered in the M9 full pass. | ~0.3 d | medium |

**Infrastructure I checked and kept as specced (unsure, or cheap and protective):**
- **M2.T05 catalog expiry and revocation:** a few lines each, behind NFR-SEC7. They protect against a stale or compromised catalog.
- **M2.T13 KV snapshot after an image job:** without it, long chats on T1/T2 answer more slowly after an image.
- **M2.T16 `semantic-2k` recall set:** generating it is cheaper with the T1 model, which is an implementation choice, not a move.
- **M7.T06 MCP 2026-07-28 profile:** servers may need it by launch.
- **M4.T02 calibration:** ChildSafetyCheck.
- **M6 golden-file and eval sets:** these encode the file-quality bars.
- **M8.T01 backups:** data loss.
- **M8.T11 install/remove harness:** M10 reuses it.
- **M10.T04 key ceremony.**

---

## C. Per-milestone verification tasks (slimmed per D-025)

**Rule for all of them:** keep every AT the milestone defines, including the per-task NFR ATs at their primary tier, plus the full suite (`make test-unit`, `make audit`), an independent `/code-review` (high), a check in the running app, and the headline speed numbers. The report shrinks to the AT table plus one STATUS line.
**Moves to M9** (M9.T05 full NFR pass, M9.T08 parity scoring):
- re-runs of earlier milestones' NFR sets and `compare.py`
- second-tier repeats (T0/T2/T3) of numbers already measured at T1
- 1180×820 and Reduce Motion/Transparency capture repeats
- the two-blind-scorer rubric scoring and its third-agent tiebreak

Each milestone still captures its new screens (1440×900, light + dark) and runs the automated hard checks: H3 contrast, H4 accessibility audit, H5 copy sync, H6 grid, H7 sizes.

| Task | Keeps (ATs + headline numbers) | Moves to M9 |
|---|---|---|
| **M2.T25** + **M2.T26** | Last legs that needed later tasks (AT-209 AC2 destinations, AT-NFR-PR1 incl. the 30-min capture, AT-220 part 2, AT-NFR-D2); real T1 install bytes vs S-02 sizes (D3/D4); journeys 1/7/10; vq-01/09/10/02/11 captures + H3/H5/H6/H7 + truthful availability across the hardware fixtures. Headline: **NFR-M5 at 50 Mbps (T1), M1 (T1), C7 (T1), U3 (T1)** | M1-set re-run + `compare.py`; M5 at 10 Mbps; M1 at T3; the release-build C1R/C2R/C15R pass; blind scoring of S-01…S-04, S-06, S-21 |
| **M3.T14** | All M3 ATs; offline journeys 2 + 11; vq-08 captures; hard checks barge-in ≤ 200 ms and V1. Headline: **V1, V3, V5 at T1** | T3/T0/S-scaled repeats of V1–V11; U2/U5/C1/R1/R4 re-runs; blind scoring of S-16/S-17 |
| **M4.T16** | All M4 ATs, **AT-285 and the ChildSafetyCheck calibration report in full (untouched)**, r241 audit, journey 5 (scripted + one real T1 run), offline journeys, the gate-bypass review checklist. Headline: **P1, P2, M3 at T1** | T3 repeats; R1/R4/R5/M4 re-runs; blind scoring of S-11/S-13 |
| **M5.T14** | All M5 ATs, **AT-285 on real video (untouched)**, journey 6, offline + `lsof` check, gate-bypass checklist. Headline: **VID1, VID2, VID3-cancel at T3** | P1/F7/R1/M4 re-runs; blind scoring of the video screens |
| **M6.T21** | All M6 ATs, **AT-NFR-SEC3 (sandbox security, untouched)**, journey 4, Office-app open checks. Headline: **C4 at T1 on `text-10p.pdf`, C5 reading %** | C4 per-tier repeats; C1/R1 re-runs; blind scoring of S-14/S-15 |
| **M7.T15** | Unchanged (R-241 full audit, SEC4, SEC5, PR1 default-settings capture: security and privacy) | — |
| **M7.T16** | All M7 ATs, journey 12, AT-250 spot-check file, the "zero pills without a fetched source" hard check. Headline: **NFR-U12 and search answer latency at T1** | C1/R1 re-runs; blind scoring of S-10/S-21 §7–8. The AT-057 voice re-run moves to M3.T14, since voice comes later in the new order. |
| **M8.T16** | All M8 ATs, **PR3 and S2 re-runs (privacy and data loss, untouched)**, install suite `remove-everything,uninstall,reinstall`, journeys 6/13/15/16. Headline: **M8's first-checked NFRs (U9, D7, D8, PR2, PR4) at T1** | Blind scoring of S-20…S-23 and the S-21 sections |

Estimated saving: about 13 days across these 9 tasks.

---

## D. Build order after M2

I checked the dependencies in each task's Inputs / "after:" fields and the milestone Entry rows.

**Proposed order:** M2 → **owner try-out** → M6 (with M4.T10/T11 pulled forward) → M7 → M8 core → M3 → M4 → M5 → M8 rest → M9 → M10.

**Blockers and how each is resolved:**
1. **M6 needs M4.T10 (file cards, Quick Look, drag-out) and M4.T11 (side panel, versions, sandboxed web preview).** Both are image-independent infrastructure: T10 lists image job results only as test fixtures, so CC0 photos work instead. **Move both to the front of the M6 chunk.** M7's Sources panel also uses the side panel, which is fine because it's earlier now.
2. **M6 audio attachments need M3's `TranscribeFile` (R-056).** In M6, M4A uploads get a tile, but transcription shows as pending until Voice arrives. The AT-020 audio leg and the M4A column of AT-277 close in **M3.T06** (minor amendment).
3. **M6.T13 "Show in Library" needs M5.T13.** The action stays hidden until the Library exists, and the AT-277 Library column closes in M5.T13 (56/64 → 64/64).
4. **M6.T16 says "generalise M5.T01's runtime installer".** Invert it: M6.T16 builds the generic `RuntimeInstaller` + `catalog/runtimes.yaml` + `sign-runtime.sh`, and M5.T01 adopts them.
5. **M7.T16 re-runs AT-057 (tools during voice).** That moves to M3.T14, which then gets real web search for free.
6. **M7.T13 relies on M7.T09 for `ProcessLauncher`.** If A4 is approved, T13 creates it.
7. **M8 core before voice** (my recommendation; veto if you want strict D-025): memory, projects, import/export, diagnostics, storage and uninstall (M8.T01–T07, T09–T11) don't need voice or media. Two things go later: M8.T08 (Privacy page) uses the permission service vendored in M3, and M8.T12–T14 use voice and job events. Doing **M8.T01 (migrations + backups)** early also protects your try-out chats.
8. **Try-out caveat:** Debug builds erase the database when the schema changes (`eraseDatabaseOnSchemaChange`). Give the owner a Release-config build, and say plainly that chats may not survive until M8.T01.

**Chunks** (one agent each, in sequence, on one branch; counts assume A and B are approved):

| # | Chunk | Tasks |
|---|---|---|
| 1 | M2 base | M2.T01, T02, T03, T04, T05, T06 |
| 2 | M2 downloads | M2.T08, T09, T10, T07, T11 |
| 3 | M2 scheduler | M2.T12, T13, T14, T15, T17 |
| 4 | M2 onboarding | M2.T16, T18, T19, T20, T21 |
| 5 | M2 router + close | M2.T22, T23, T24, T25, T26 |
| — | **pause: owner try-out** | |
| 6 | Files in | M4.T10, M4.T11, M6.T01, T02, T03, T04 |
| 7 | Files understand/out | M6.T05, T06, T07, T08, T09, T10 |
| 8 | Files out + runtime | M6.T11, T12, T13, T15, T16 |
| 9 | Code sandbox + close | M6.T17, T18, T19, T20, T21 |
| 10 | Search + MCP | M7.T01, T02, T03, T05, T06, T07, T08 |
| 11 | Relay + skills + close | M7.T10, T11, T12, T13, T14, T15, T16 |
| 12 | Memory + projects | M8.T01, T02, T03, T04, T05 |
| 13 | Data + storage | M8.T06, T07, T09, T10, T11 |
| 14 | Voice core | M3.T01, T15, T02, T03, T04, T05, T06 |
| 15 | Voice conversation | M3.T07, T08, T09, T10, T11, T12, T13, T14 |
| 16 | Photo core | M4.T01, T02, T03, T04, T05, T06 |
| 17 | Photo UX + close | M4.T07, T08, T09, T12, T13, T15, T16 |
| 18 | Video engine | M5.T01, T02, T03, T04, T05, T06, T07 |
| 19 | Video UX + close | M5.T08, T09, T10, T11, T12, T13, T14 |
| 20 | Mac integration + close | M8.T08, T12, T13, T14, T16 |
| 21 | Accessibility + l10n + perf | M9.T01, T02, T03, T04, T05 |
| 22 | Soak, parity, sync, exit | M9.T06, T08, T09, T10 |
| 23 | Release build + site | M10.T01, T02, T03, T04, T05, T06 |
| 24 | Release close | M10.T07, T08, T09, T11 (+ T10 when credentials arrive) |

Chunks 10–11 have 7 tasks each because M7 tasks are small (1.5–3 d). Chunks 22 and 24 have 4 each because M9.T08 and M10.T09 are large.

---

## E. Savings summary

| | Before | After (if A + B are approved) |
|---|---|---|
| Tasks M2–M10 | **146** | **139** in v1 (7 whole tasks to M11: M8.T15, M9.T07, M7.T04, M7.T09, M4.T14, M6.T14, M4.T00) |
| Sub-items moved inside kept tasks | — | 8 (M2.T07 HF ID, M2.T11 auto-update, M2.T02 swizzle, M2.T23 extras, M4.T15 part, M4.T07 Think harder, M8.T14 global dictation, M7.T13 T2 leg) |
| Agent runs | 146 (one per task) | **24 chunks** |
| Agent-schedule days | ≈ 540 | ≈ 495 (A ≈ 25.5 d + B ≈ 6.8 d + C ≈ 13 d ≈ **45 d, ~8%**) |
| ATs leaving the v1 exit lists | — | AT-224, AT-288, AT-289, AT-036, AT-251, AT-252*, AT-259, AT-278, AT-051, AT-055*, AT-061*, AT-063*, AT-107*, AT-110*, AT-035*, AT-094* (*already stretch); AT-034 narrowed to Erase + Remove background; AT-294 narrowed to revocation (B2) |

The day savings are modest, about 8%. The larger token savings come from D-025's working method: chunks, a shared build cache, short cards and no per-task paperwork. This list is deliberately conservative.

---

## F. Upstream holds from the M9.T09 real sync (2026-11-10, approved by the lead)

The real sync (`sync/t09`, evidence in `docs/research/07-spikes/S-1-vendor-sync.md` "T09 real sync") took osaurus 0.25.33, FluidAudio 0.18.3 and the SwiftPM minors. These upstream moves were held for after v1:

| Upstream | Held at → available | Why held | What M11 must do |
|---|---|---|---|
| **osaurus 1.0.0** (`15d4089`, tagged 2026-11-10) | 0.25.33 `66c3dde` | (1) The trial `make vendor-bump NAME=osaurus REF=1.0.0` conflicts in 13 hunks across 3 files: `OnboardingComponents.swift` (10), `OnboardingDesign.swift` (1) and `MemoryPressureResponder.swift` (2). (2) `Keychain.swift` and `KeychainQueryHelpers.swift` merge *cleanly*, but they wrap every `kSecAttrService` in `SpaceKeychainScope.service(_:)`. That type is outside our closure (closure growth), and it re-scopes the keychain service names, so credentials already stored under `app.antichat.search` (UP-OS-033) would become unreachable without a migration. That is too risky right before release. (3) 24 of the 38 watch (ported) files changed upstream, and each one needs a review against its port. The only user-visible gain is the Bing `ck/a` click-URL unwrap in `NativeSearchBackends.swift`. | Port the onboarding design system into `AntiChatUI/Onboarding` (M9.md fallback). Keep ours for `MemoryPressureResponder` (UP-OS-008). Either strip `SpaceKeychainScope` with a new UP row that keeps the service name as is, or write and test a keychain migration. Review the 24 watch deltas. Consider de-listing the unused `SeatbeltSandbox`. Estimate: 1 day. |
| **FastVideo** `4deb3a5` | `d9e6c3e` | The only allow-listed change is `fastvideo/envs.py`, a typed env-var registry refactor plus CUDA/PAN2 variables. It contains no security or correctness fix on our MLX path: `wan22_sample.py` and `wan_vae.py` (UP-FV-001/002) are unchanged. The video runtime zip embeds the FastVideo tree, its `ORIGIN` and a per-file sha manifest (`tools/runtime/build_video_runtime.py`), so the bump forces video-runtime 0.3.4 plus a catalog v15 re-record. That would land on top of the v14 re-record from `deps/sd-xcode272`. | Bump together with the next video-runtime rebuild. Fix the hard-coded `FastVideo@<short>` paths in `build_video_runtime.py`, `test_parity.py` and the `antichat_video` citations, then re-run the R-040 parity check. |
| sqlite-vec v0.1.10 | v0.1.9 | Only alphas upstream. The fixes after our pin (int8 NEON, hamming, DiskANN) are on paths we never take (`float[1024]`). | Bump when v0.1.10 is stable. |
| stable-diffusion.cpp `32d516c` | `e239e4b` | No image QA regression points at the Metal group-norm fix. It needs `make binaries`. | Take it with the next helper rebuild. |
| swift-crypto 5.x | 4.5.2 | swift-huggingface and swift-transformers cap the range at `<5.0.0`. GHSA-jwv7 is in `_CryptoExtras`, which we don't link. | Re-check when either package raises its cap. |
| npm `image-size` 1.2.1 | — | Two HIGH DoS advisories, but the package is not in the shipped browser bundle. | Add an `overrides` entry at the next `make vendor-js`. |
| speech-swift, CommandPaletteKit, TUFF, ltx-2-mlx, agent-squad, LetsMove, mlx-swift, swift-syntax | current pins | No allow-listed change, or no newer release. | Re-run `make vendor-report` at the next sync. |

---

## G. Upstream issues to file (M9.T03 accessibility audit, 2026-11-11)

### sindresorhus/KeyboardShortcuts: the recorder's clear button is orphaned in the accessibility tree

Pinned at 3.1.0 (`772133d`). Local evidence: `tools/a11y/repros/searchfield-cancel-cell-swap.swift`. The XCUITest audit does not report this orphan (checked 2026-11-11 with the a11y-axstate helper), so no audit ignore exists for it; it still hides the clear button from VoiceOver. Issue text, ready to paste:

> **Recorder: clear button reachable via AXClearButton but missing from AXChildren (accessibility audit "Parent/Child mismatch")**
>
> `RecorderCocoa` removes its search field's cancel-button cell (`cancelButtonCell = nil`) and later restores it (`showsCancelButton`). On macOS 26, after that swap the field still reports the button through `AXClearButton`, but its `AXChildren` no longer list it (0 children). XCUITest's `performAccessibilityAudit()` reports this as a "Parent/Child mismatch" with no element, and VoiceOver users can't reach the button by navigating the field's children.
>
> Repro without the package: an `NSSearchField` with a value, `searchButtonCell = nil`, `cancelButtonCell = nil`, then restore the saved cell → `AXClearButton` is set, `AXChildren` is empty. Leaving the cancel cell untouched lists it correctly.
>
> Possible fixes: hide the cancel button without swapping the cell (e.g. keep the cell and toggle its visibility / `isEnabled`), or override `accessibilityChildren()` on `RecorderCocoa` to include the cancel button when shown, (posting `.layoutChanged` after restoring the cell did not refresh the children in our test).

### Open repro question: which ProgressViews make the audit report element-less Parent/Child issues

The M9.T03 exact count adds one element-less "Parent/Child mismatch" per AppKit-backed progress indicator on the in-app helper evidence alone (a14: Settings › Capabilities 3 pack-row bars, Storage 1 busy spinner; `progressIndicator` in `tools/a11y/audit-ignores.yml`). The standalone repro (`tools/a11y/repros/labels-hidden-switch-parentchild.swift`, `progress 3`) showed none: three `ProgressView(value: 0.3)` linear, small, in a grouped Form. Differences to try in M11: `total:` other than 1, the indeterminate spinner, a ProgressView inside a `.contain` group with an identifier (PackRow, StorageView), and an updating value. Likewise only the quick-panel recorder's orphaned clear button counts, not the Shortcuts section's (a12). Once isolated, narrow both terms to the proven trigger, or fix it in the product.

---

## H. Performance follow-ups from M9.T05 (owner decisions via the lead, 2026-11-11)

Both items ship in v1 as known characteristics; the bars are unchanged. Amendments: A-M9-T05-AT254c, A-M9-T05-V2c.

| Item | v1 state | What M11 must do | Evidence |
|---|---|---|---|
| **AT-254 T3 evergreen queries: lever 3 (incremental prefill)** | AT-254 T3 is judged on the availability set (rows 1–20): cold p50 4.36 s ≤ 5 s. Evergreen "what is / history of" queries (rows 41–60) take ≈ 7.3 s: Wikipedia-class pages arrive in < 1 s and fill the 10k evidence budget, so the first token is prefill-bound (~11.2k tokens at ~2.45k tok/s ≈ 4.5 s, plus search 0.75, fetch 1.06, rank 0.89 s). | Build lever 3: start prefilling the system prompt, the question and the evidence chunks that are already ranked while later pages are still fetched and ranked (append to the KV cache in rank order; re-rank only the tail). Estimated saving ≤ 1.9 s → ≈ 5.4–5.8 s on rows 41–60. Gate: AT-250 c2 T3 held-out-5 stays ≥ 0.90 under A-M7-T03d; AT-254 rows 1–60 cold, ≥ 2 pills. | `build/at/AT-254/t3-deadline/NOTE-t3b.txt`; A-M9-T05b |
| **NFR-V2 T3 endpointing: re-test with conversational turns and a turn-1-mini port** | Ships at ≈ 0.93 s p50 (bar ≤ 450 ms) with smart-turn v3.2 and the A-M9-T05-V2 rules (`openEnd` on, `sentenceStable` off); V4 ≤ 2 % per bed. | (1) Record a conversational end-of-turn fixture set (spoken questions and replies, not read passages: those pause 384–544 ms after finished sentences and force the 900 ms check), with V4 beds. (2) Port p99lab turn-1-mini (Apache-2.0, 5.4 M params, streaming ONNX → Core ML or ONNX Runtime) behind the turn-model slot and re-score every pause with `tools/voice/turn-rescore.py`. (3) Re-tune the early-end rules on the new set. Ship only if V2 T3 endpointing improves with V4 ≤ 2 % per bed and V1b unchanged. | A-M9-T05-V2, A-M9-T05-V2b; `build/perf/runs/20261111T125837Z-V2-T3.json`; `tools/voice/turn-replay.py` |

### Spec gap: ⌘K page and command actions without a requirement (A-Q015-r6-kb, lead 2026-11-11)

v1 ships the palette actions R-012 AC2 lists (New chat, New incognito chat, Open settings pages, Switch chat, searchable
settings rows, Toggle sidebar). `tools/a11y/keyboard-paths.yml` also expects 22 paths (16 actions) reached by "⌘K → type
a page or command name → Return": Library, Projects (rename / delete / add file), New project, Export chat, Move to
project, Attach, Branch, Continue in normal, Legal, What's new, Report a problem, Uninstall, Import, Restore, Clean up,
System report. No R/AC names them as palette actions; each is keyboard-reachable today through a menu or a Settings row
(R-223 AC2 / NFR-A3 hold). **M11:** decide whether to add them to R-012 AC2 and `ActionsProvider` (opening the sheet,
not just revealing the Settings row). Until then, `KeyboardOnlyTests` should not count these 22 paths as failures.
Evidence: the A-Q015-r6-kb row; `f060978eb`.
