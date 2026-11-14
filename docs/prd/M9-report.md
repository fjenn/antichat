# M9 report

> **M9.T10 exit report, 2026-11-13 (branch `docs/final-reports`).** First drafted 2026-11-12 on `docs/m9-exit-prep`
> from main `5e66e7d18`; this version records the exit on the release candidate (RC): main `e8fe19986` plus round 67
> (`45f2bfd09`) plus round 68 (see §0.1). Items that are still open stay marked **`⟦PENDING:<id>⟧`**:
> `grep -n "PENDING:" docs/prd/M9-report.md` lists them, and §15 lists every placeholder with its state. The M9.T09
> section (§9) was written by T09 itself and is unchanged.

## 0. Exit check (PRD §7 M9 + M9.T10)

PRD §7 M9 exit: AT-102, AT-221, AT-223 (P2 stretch, not exit-blocking: AT-035, AT-094); full `make perf test-offline
test-install` green; the M9 NFR set; AT-VQ-M9 (the full `make test-visual`, vq-01…vq-14) at the parity release bar (all
★ screens pass, ≥ 90 % of the others, none < 3.5, every failing non-★ screen has an S2/S3 bug with an owner);
Accessibility Inspector audit 0 warnings on the primary screens (H4); one VoiceOver walkthrough per journey (NFR-A6).
M9.T10 adds: AT-NFR-A1…A6, S1, S3, R2, every earlier AT-NFR re-run, rehearsal evidence, `make audit`, R-241 audit,
`/code-review` (high) on the M9 diff, independent triage.

| Exit item | State (2026-11-13, RC) | Evidence / section |
|---|---|---|
| AT-102 localisation (strict gate) | done at T04 (1195 keys × 5 languages, independent review per language); **strict re-run on the RC: pass**. Native review of the P1 update-copy translations and the "No lectures" copy: owner `⟦PENDING:OWNER-L10N⟧` | §4 |
| AT-221 (contrast, motion, text size, media) | done at T02, in-process + snapshots; XCUITest TextSize/SystemSettings legs in the XCUITest rounds (§10) | §2, §10 |
| AT-223 part 1 (VoiceOver labels / announcements) | done at T01; VoiceOverLabel ×2 pass (r7) | §1, §10 |
| AT-223 part 2 (keyboard only) | KeyboardOnly ×2 **blocked**: owner's Full Keyboard Access + spec gap A-Q015-r6-kb (resolved: recorded spec gap → M11) | §1, §10, §11 |
| AT-223 part 3 (XCUITest accessibility audit, H4) | **0 issues** with 22 signed ignore entries (A-M9-T03a/b) | §3 |
| NFR-A6 VoiceOver walkthrough per journey | owner live check (16 walkthroughs, `tools/a11y/vo-walkthrough.md`), not done `⟦PENDING:T03-VO⟧` | §3 |
| AT-035 / AT-094 (P2 stretch) | not in v1: T07 moved to M11 (D-026) | §7 |
| Full `make perf` (T05) | measured; final quiet window round 66 (§5.6), exit summary §5.7: 6 bars pass, 5 miss (U2, U5, VID1 T4, VID2 T4, B5) | §5 |
| `make test-offline` | **pass** on the RC (harness fix `30508376d`) | §0.1 |
| `make test-install` | **pass** on the RC (Tart VM; harness fix `7ce0adae3`, product fix `62e069850`) | §0.1 |
| AT-NFR-S3 8 h soak (T06) | 8-h run on `0418f820a` **failed** (40 hangs > 2 s only); root cause the soak's launch policy; **2-h confirmation soak on `dbaad0bc9` passed**; no 8-h re-run (owner decision) | §6 |
| AT-NFR-S1 crash-free sessions | `⟦PENDING:T06-CRASHFREE⟧` | §6 |
| AT-NFR-R2 swap session | `⟦PENDING:T06-SWAP⟧` | §6 |
| AT-VQ-M9 parity release bar | single builder-scorer: pass. **Blind re-score on `366483ef8`: misses the looks bar** (★ 2/11 pass; others ≈ 55 %). Owner decision 2026-11-12: looks-only misses do not gate the release. Its 8 functional bugs (F1–F8) fixed in round 66 | §8 |
| Upstream sync rehearsal #2 / real sync (T09) | done 2026-11-10, gates green, no voice NFR regression | §9 |
| `/code-review` on the M9 diff (rounds 61–66) | 5 findings, all fixed in round 68 (§0.1) | §0.1 |
| `make audit`, R-241 audit, independent triage | no RC result recorded `⟦PENDING:T10-GATES⟧` | — |
| Unit, integration-stub; AT-220, AT-109, AT-100, AT-229 checks | **pass** on the RC | §0.1 |
| Full `make test-ui` on the RC | re-run `⟦PENDING:T10-XCUI⟧` | §10 |
| PRD amendments | 24 M9 rows; **none `proposed`** (lead decisions 2026-11-11 applied); 4 rows (A-M9-T01a, T01b, T02a, T04a) have no recorded status and are **listed for T10 sign-off** | §11 |

### 0.1 Exit summary on the release candidate (2026-11-13)

**RC contents.** main `e8fe19986`, plus round 67 (`45f2bfd09`: T05 docs and tools; the perf-only MLX cache-cap switch
reverted), plus round 68 (code-review fixes: Evil withdrawal on a resumed onboarding, the Step-4 way out, the
untrusted-repair flag, the repetition guard on tool calls only, retitle off main). **Round 68 merged:** main `daff18809` (checked 2026-11-13).

**Acceptance on the RC.**
- `make test-offline`: **pass** (harness fix `30508376d`).
- `make test-install`: **pass** in Tart. Fixes: harness `7ce0adae3`, and product bug `62e069850` (the session ledger
  re-created the logs folder after Remove everything).
- AT-102 strict: **pass**. Unit and integration-stub: **pass**. AT-220, AT-109, AT-100 and AT-229 checks: **pass**.
- The UI suite (`make test-ui`) re-run on the RC: **pending**.
- Real-model and GPU evals were **not re-run on the RC**. Their evidence is the prior runs: §5 (T05), the M3–M8
  reports and the M10 final acceptance.

**AT-273 on RC `e8fe19986`.** 150/150 run; 145 files right on the first pass. Of the 5 misses, 4 pass when re-run
alone (1 harness, 2 flaky). One was a real normaliser bug (malformed `sheets` JSON), fixed in `bfd2e55c2`; its re-run
result is **pending**. The 15 image prompts: 15/15.

**AT-NFR-S3.** See §6: the 8-h run failed on hangs only, the cause was the soak's launch policy, and the 2-h
confirmation soak passed.

**T05.** See §5.7 (from the round-66 quiet window, §5.6).

**Visual parity.** See §8: the blind re-score misses the looks bar. Looks-only misses do not gate the release (owner,
2026-11-12).

**Code review (rounds 61–66).** 5 findings, all fixed in round 68.

**Owner-only items** are in §13. The signed release is an M10 item (M10-report).

## 1. M9.T01: VoiceOver and keyboard (done, `m9/polish`)

- `StreamAnnouncer` (at end / per sentence), the Settings › General row "VoiceOver reads replies" (A-M9-T01a),
  labels on every icon-only control, VoiceOver actions on every tap target, the Evil / Incognito window title for
  VoiceOver, `keyboard-paths.yml` (208 entries at T01), `a11y-lint` and `keyboard-paths` in `make audit`.
- Method deviations recorded in A-M9-T01b (AppKit announcement path, no separate FocusCoordinator).
- In-process probe `tools/at/at-223-probe.sh` passed in en/de/fr/es/nl/pt (`build/at/AT-223/<lang>/probe.json`).
- XCUITest legs: VoiceOverLabel ×2 pass (rounds 6–7); **KeyboardOnly ×2 blocked** on the owner's Full Keyboard Access
  (`defaults write -g AppleKeyboardUIMode -int 2`, OWNER-STEPS) and on the spec gap A-Q015-r6-kb (22 ⌘K paths in
  `keyboard-paths.yml` that no requirement lists; lead/owner to choose option 1 or 2).

## 2. M9.T02: contrast, motion, text size, media (done, `m9/polish`)

- DEBUG overrides `-ForceReduceMotion`, `-ForceReduceTransparency`, `-ForceIncreaseContrast`, `-TextSizeScale`;
  `tools/frametime.py --fade-detect`; `DesignTokenContrastTests` covers every tokens.md §7 pair in light / dark / IC.
- NFR-A5 picture descriptions (A-M9-T02a): `ImageDescriptionService`, editable Description field in the viewer,
  "Generated image: <description>" labels, migration `v31_image_description`.
- Contrast tokens re-tuned during T03; golden-100 091–100 re-recorded for them (fixtures `5293154`, main `76e834720`).

## 3. M9.T03: accessibility audit and VoiceOver walkthrough

**XCUITest accessibility audit (AT-223 part 3, H4): 0 issues** on the audited screens (onboarding S-01…S-04, S-05,
S-08, S-18 palette, every S-21 Settings section at every scroll position), on main since `88720aae7` (fix/a11y-audit,
round 59). Method amendments A-M9-T03a (Settings measured per section and scroll position, chat window closed) and
A-M9-T03b (element-less Parent/Child issues counted, bounded by [switches, attributable]), both resolved by the lead
2026-11-11.

`tools/a11y/audit-ignores.yml` holds **22 entries, every one signed by the lead** (orchestrator) with evidence. None
hides an issue in our own code; each is an AppKit/SwiftUI-owned element or a measured contrast false positive:

| # | Element | Issue (scope) | Why it is ignored | Signed |
|---|---|---|---|---|
| 1 | `_XCUI:FullScreenWindow` | parentChild | AppKit NSThemeFrame full-screen button children; Terminal and TextEdit show the same | lead 2026-11-10 |
| 2 | `sidebar` | sufficientElementDescription (sameFrame) | SwiftUI NavigationSplitView column group; repro `navsplit-sidebar-group.swift` | lead 2026-11-10 |
| 3 | `_XCUI:ZoomWindow` | parentChild | same AppKit title-bar widget in its zoom form; Terminal / Safari / TextEdit show it | lead 2026-11-11 |
| 4 | `labelsHiddenSwitch` | parentChild (countMatched) | one element-less issue per SwiftUI labels-hidden switch; exact-count rule A-M9-T03b; repro `labels-hidden-switch-parentchild.swift` | lead 2026-11-11 |
| 5 | `disabledSettingsRowLabel` | contrast (inactive) | disabled rows look disabled; WCAG 1.4.3 exempts inactive components | lead 2026-11-11 |
| 6–12 | `onb.4.subtitle`, `onb.4.mac.facts`, `onb.4.mac.note`, `onb.4.search.note`, `onb.4.row.chat`, `onb.4.row.voice`, `onb.4.row.photo` | contrast (exact id) | onboarding step 4 on glass: measured 7.2–14.6:1 on the settled capture; the audit samples the translucent panel | lead 2026-11-11 |
| 13–20 | `settings.row.toolAccess.description`, `mcpDirectory.tagline.{huggingface, deepwiki, supabase, neon, netlify, notion, atlassian}` | contrast (exact id) | Settings › Tools two-line footnotes, measured 17.7–18.1:1; one-line text in the same style passes | lead 2026-11-11 |
| 21 | `progressIndicator` | parentChild (countMatched) | one element-less issue per AppKit-backed ProgressView; an upper-bound term of #4; standalone repro inconclusive, revisit in M11 (M11-candidates §G) | lead 2026-11-11 |
| 22 | `quickPanelRecorderClear` | parentChild (countMatched) | KeyboardShortcuts recorder's orphaned AXClearButton; an upper-bound term of #4; upstream issue drafted (M11-candidates §G) | lead 2026-11-11 |

Still owner-only: the Accessibility Inspector audit pass on the primary screens and the 16 VoiceOver walkthroughs
(NFR-A6, `tools/visual/vq-12-a11y.md`, `tools/a11y/vo-walkthrough.md`) `⟦PENDING:T03-VO⟧`. Upstream issues to file:
M11-candidates §G (KeyboardShortcuts recorder orphan).

## 4. M9.T04: localisation (done, `m9/polish`)

- 1195 keys × de, fr, es, nl, pt translated, each language reviewed by an independent agent and signed off (A-M9-T04a:
  Claude translator + reviewer per language instead of the local `chat-122b` pass; method unchanged). 61 more keys in
  round 2. Help pages × 5; legal pages stay English (binding text). App-language picker + restart; plural variations.
- `make audit` runs `l10n-source` (blocking) and `l10n-langs` (lists untranslated keys, non-blocking). Rounds 6–7 report
  untranslated keys added since T04.
- **Round 3 (late keys, branch `l10n/m9-late-keys` from queue/60 `0cea5f4d1`, 2026-11-12):** 86 missing keys
  (Library, video plan/player/viewer, Tools page + tool access, editor, voice pointers, a11y names) and 2 stale keys
  (`set.tools.location.note`, `perm.location.why`: English now says "country-level" hint) translated × 5 languages; the
  unknown `set.tools.later` (removed from the copy deck in M7.T14) dropped from every `translations/<lang>.json`.
  Independent reviewer per language (different agent from the translator) re-read all 88 strings in context:
  de 0 changed; fr 3 (`library.search` shortened for the 240 pt field, `perm.location.why` "localiser" → "obtenir … locaux",
  `set.tools.builtin.note` pronoun); es 3 (`editor.bestQuality.help` subjunctive, `set.tools.location.note` word order,
  `set.tools.access.note` "para que … sigan"); nl 3 (`perm.location.why` pronoun, `video.length.medium` "Middellang",
  `editor.removeBg.none` quotes ‘Wis’); pt 1 (`video.lowPower` "Modo de Pouca Energia") + `a11y.dictation.recording`
  "A gravar" (pt-PT) → "Gravando". All five signed off; strict `--require translated` = 0 missing / 0 needs_review /
  0 unknown / 0 invalid per language. Follow-up: `act.searched.region` read "1 sources"; it is now a plural key
  (`tools/l10n/plurals.json`, like `act.searched`) with one/other (fr/es/pt also many) in all five languages,
  CopyDeck.swift + catalog regenerated, unit tests cover the singular (`WebSearchUITests`, `CopyPipelineTests`);
  the new forms were reviewed independently (de/fr/es/nl/pt: 0 changed, signed off).
- **AT-102 strict gate** (`l10n-check.py --langs de,fr,es,nl,pt --require translated`) after translating the late keys
  (`python3 -I tools/l10n/l10n.py todo <lang>`), plus `at-223-probe.sh` per language: **pass on the RC** (2026-11-13).
  Native review of the P1 update-copy translations and of the "No lectures" copy is an owner item
  `⟦PENDING:OWNER-L10N⟧`.

## 5. M9.T05: performance re-measure

Run plan: [`M9-T05-runplan.md`](M9-T05-runplan.md). Driver `tools/perf/t05.py` (`make perf-all`); per-step JSON in
`build/perf/runs/`, per-batch summaries in `build/perf/t05/<stamp>/summary.md` (worktree of branch `m9/t05-run`). Machine:
M5 Max, 18 cores, 128 GB, macOS 26.6.2, speed class S4, AC power, Low Power Mode off. Every day-1 record below is
labelled `clean` by `tools/perf/load.py` unless noted.

### 5.1 Day 1 (2026-11-11, builds `9e18fbb6`…`f21af4f9`): prep → chat → UI → voice → photo/CSC → video → search

Bars are the PRD NFR budgets for that tier. Values are p50 unless the bar names another statistic.

| NFR / AT | T0 | T1 | T2 | T3 | Verdict |
|---|---|---|---|---|---|
| C1 TTFT (s) | 0.066 / 1.5 | 0.168 / 1.5 | 0.327 / 1.0 | 0.148 / 0.8 | pass |
| C1b TTFT p95 (s) | 0.072 / 3.0 | 0.173 / 3.0 | 0.172 / 2.0 | 0.153 / 1.5 | pass |
| C2 decode (tok/s, ≥) | 305 / 20 | 97.6 / 15 | 97.8 / 20 | 141 / 30 | pass |
| C4 prefill (tok/s, ≥) | 12,047 / 150 | 2,726 / 150 | 2,289 / 300 | 3,423 / 400 | pass |
| M1 model load (s) `[WARM-CACHE]` | 0.17 / 3 | 0.23 / 3 | — | 0.50 / 8 | pass (warm; cold needs `sudo -n purge`) |
| C7 mode swap (s) | — | 0.885 / 9.5 | — | 0.069 / 1.5 | pass |
| U3 typed-ahead send (p95, s) | — | 0.0023 / 2.0 | — | 0.0024 / 2.0 | pass |
| U9 (p95, ms) | — | 9.4 / 150 | — | — | pass |
| B1 idle (mean over a 5-min window, tier n/a) | | 0.443 / 1.0 | | | pass |
| V1 voice round trip (s) | 0.938 / 2.5 | 0.936 / 1.5 | — | 0.935 / 1.0 | pass |
| V1b round trip p95 (s) | 2.02 / 3.5 | 2.02 / 2.5 | — | **2.02 / 1.8** | **T3 miss** → fixed (A-M9-T05-V2 `openEnd`, §5.2) |
| V2 T3 endpointing (ms) | 936 | 934 | — | **933 / 450** | **miss** → owner decision (§12, A-M9-T05-V2c) |
| V2 T3 other parts (stt final, LLM TTFT, first clause, TTS chunk, audio out) | | | | all within their parts | pass |
| V3 onset → TTS silent / cancel (ms) | — | 32.3 / 200 · 260.7 / 300 | — | — | pass (the step errored on AT-282 AC2 → A-M9-T05-AT282b) |
| V4 false splits (% per bed, max) | — | 0 / 2 / 0 / 0 (≤ 2) | — | — | pass |
| V5 (ms) | — | 12.6 / 150 | — | — | pass |
| V6 (s) | — | 0.487 / 0.6 | — | — | pass |
| V7 (s) | 0.054 / 1.0 | 0.052 / 0.4 | — | 0.050 / 0.3 | pass |
| V8 read aloud (s) | 0.120 / 1.0 | 0.119 / 0.5 | — | 0.120 / 0.4 | pass |
| V10 (ms) | — | 78.7 / 300 | — | — | pass |
| V11 STT speed (× real time, ≥) | 477 / 4 | 478 / 10 | — | 480 / 10 | pass |
| V283 turn end → final (ms) | | 47.9 / 300 | | | pass |
| V9 WER worst language (%) | — | **11.42 (ar) / 6** | — | — | **miss**, = A-M3-06 baseline; empty-decode retry A-M9-T05-V9 → ar 10.18 %; re-measure in Phase B |
| U1 launch to usable | | **no value** (0/20 launches reached `launchToUsable` in 30 s) | | | **error** (harness), re-run → Phase A result in §5.3 |
| U5 renderer (AT-008, S1 stand-in `-RendererCPUScale 0.25`) | | **apply median 124.7 ms, 723 passes > 33 ms** | | | **miss** → renderer rework (§5.2) |
| U2 / U6 / U10 / U11 (XCUITest perf legs) | | fail | | | re-run → Phase A result in §5.3 |
| AT-286 hand-off, P1 bench, M3 co-resident T2-24, JOB_CANCEL_FREE, P4 T1, P5 | | ok | | | pass |
| IMAGE_TURN_OVERHEAD (s) | | **2.10 / 2.0** | | | **miss (marginal)**, re-run → Phase A result in §5.3 |
| P4 edit (T3) | | | | img-edit run errored (1,371 s test) | → A-M9-T05-P4: judged on the T3 default edit (img-klein): **1.24 pass** |
| P3 | | missing prereq (perf-app) | | | re-run → Phase A result in §5.3 |
| F7 CSC (p95, s) | | **314 / 300** (`noisy`) | | | **miss under load**, re-run → Phase A result in §5.3 |
| Video T3 480p preview, VID3 cancel T2V + I2V | | | | ok | pass |
| Video T4 default, F7_VIDEO T3/T4 | | | | missing prereq (perf-app) | re-run → Phase A result in §5.3 |
| Video speed table | | | | `engine.video.runtimeMissing` (runtime not staged in the run's build) | environment, re-run → Phase A result in §5.3 |
| B5 GPU yield / resume | | **error** | | | GPUYieldMonitor fix (A-M9-T05b); **blocked by orphan pid 5587** (owner) |
| B3 thermal | | blocked | | | covered in-process (ThermalPolicyTests, `-FakeThermal serious`, `build/at/AT-041`) |
| AT-248 c1 search e2e (s) | | 5.69 / 12 | | | pass (`<web_results>` p50 4,082 tokens) |
| AT-254 first token after search (s) | | 4.23 / 8 | | **11.54 / 5** | **T3 miss** → fixes + owner decision (§5.2, §12) |
| AT-266 | 0.805 | | 0.86 | | pass |

Groups not run on day 1 (day 2/3 of the plan): install / privacy (M5 50 / 10 Mbps, D3 real bytes, PR1 capture with
journeys) and memory / files (R1 soaks T1 / T2-24 / T0 / T3-48, StepAside, warm document, AT-273 / AT-275 model runs),
then `compare`. They are in Phase A / Phase B below.

### 5.2 Fixes since day 1

| Day-1 miss | Fix | Commits / branch | Amendment | Re-measured |
|---|---|---|---|---|
| AT-254 T3 11.54 s | T3 harness-written direct search (saves the model step); fetch deadline 1.0 s (late pages as snippets); rule-written sub-queries for multi-part questions; evidence budget counted in real chat-model tokens; ranked-prefix tokenising; embedding cap 64 chunks | `14f9dbbad`, `a2c275b01`, `2768016be`, `46aab2054`, `8eebd4095`, `1b1692d78`, evidence `a714e1d5c`, `599f81740` (all on main) | A-M9-T05b, A-M9-T05-AT254c | cold, rows 1–20 **4.36 s**, rows 21–40 3.86 s, rows 41–60 7.30 s; pooled 6.11 s; ≥ 2 pills 59/60; AT-250 c2 held-out-5 0.917 PASS (`build/at/AT-254/t3-deadline/NOTE-t3b.txt`) |
| V1b T3 p95 2.02 s | `openEnd`: an unfinished sentence smart-turn calls complete ends at 1.5 s; the `sentenceStable` early end was measured and switched off (split 4–6/50 per bed) | `4222aa624`, `b62da276d` | A-M9-T05-V2 (resolved) | V1b T3 1.534 s, **pass** (§5.3) |
| V2 T3 endpointing 933 ms | model search (A-M9-T05-V2b): no local model meets V2 T3 and V4 together; owner decision: ship at ≈ 0.93 s | `742cc76fc` | A-M9-T05-V2b → A-M9-T05-V2c | resolved by decision (§12) |
| V9 ar 11.42 % | an empty decode of VAD-voiced audio is retried once without the first-token log-prob threshold | `9b20a6e21` | A-M9-T05-V9 (resolved) | ar 10.18 % (bench); Phase B ar 10.18 % (pass, §5.4) |
| V3 step error (AT-282 AC2 flake) | AC2 reference = forced-aligned word onsets (MFA 3.4.3), 36/36 | `27842d088`, `9b27f2eb7` | A-M9-T05-AT282 (withdrawn), A-M9-T05-AT282b (resolved) | 36/36 |
| U5 renderer | parts 1–3: append-only root blocks, per-block observation, live blocks not selectable until settled, 40 Hz reveal clock; the ScrollView answers size queries itself; size/alignment queries no longer re-measure the transcript | `c35f55f1d`, `4fa3a3a31`, `27511dc05` (main); part 3 `a83f15dd0` (on `m9/t05-run`, **not on main**); part 4 on `fix/u5-renderer-4` (7 commits, not merged) | A-M9-T05-U5 (resolved), A-M9-T05-U5b (resolved), A-M9-T05-U5c (resolved, on `fix/u5-renderer-4`) | Phase A: **miss**, 20 hitches at 0.25, 7 at 1.0 (§5.3); part 4 in round 60; round 66 quiet: **miss**, 18 at 0.25, 3 at 1.0 (§5.6) |
| P2 measurement | first visible preview = the card's visible progress state under A-M4-R1b | `bd2c30e4f` | A-M9-T05-P2 (resolved) | — |
| P4 T3 | judged on the T3 default edit (img-klein, 1.24 pass); img-edit reference stays uncapped (blind A/B drift) | `df0fa4181` | A-M9-T05-P4 (resolved) | 1.24 pass |
| B5 resume | GPUYieldMonitor no longer counts the app's own window or WindowServer as "another app" | `14f9dbbad` | A-M9-T05b (open: environment) | blocked until pid 5587 is gone |
| Integration flake `engine.helloTimeout` | EngineClient adds launchd's respawn throttle to the hello deadline | `1f4fdf6ee` (`fix/hello-timeout`, on `m9/t05-run`, **not on main**) | — | r7 gates |
| Test-run hygiene | stray-kill hardening (signal only unreaped children); snapshot flakes; test plists | `b6b03df3a`, `fb8f4ef4c`, `55edb8add`, `99a8c6d95`, `4faa91a90` | — | — |

### 5.3 Phase A: quiet timing re-run (done 2026-11-12 10:49Z, perf build `09d658a07`)

Written by M9.T05 on `m9/t05-run` @071311d68 (merged into round 60).

**Status:** phase A (quiet, timing) complete. Post-merge re-measures (round 60) and phase B (non-timing, beside the
M9.T06 soak) pending. **Branch:** `m9/t05-run`. **Plan:** [`M9-T05-runplan.md`](M9-T05-runplan.md); runner
`make perf-all` (`tools/perf/t05.py`). **Evidence:** run records `build/perf/runs/`, metrics `build/perf/report.json`,
AT artefacts `build/at/…`; per-step logs and summaries `build/perf/t05/<stamp>/` (not committed).

**Machine:** M5 Max (S4), 128 GB, macOS 26, AC power, Low Power Mode off (`powermode 0`), thermal nominal, ≥ 109 GB
free. No reboot before the run (the owner was asleep). **Known noise source:** an orphaned AntiChat test app (pid 5587,
started from a deleted XCUITest snapshot path, ~1 core and 5–6 GB RSS) ran the whole time; only the owner may stop it.
`load.py` never counted it as "other" load, because its process name is `AntiChat`. B5 was skipped because of it.

#### How the numbers were taken

- **Perf-harness build, never Debug.** Debug numbers are never NFR results. Every app-driven step measured
  `build/perf-app/AntiChat.app` (`make build-perf`): Release configuration, `-O`, `NDEBUG`, no `DEBUG`, plus
  `ANTICHAT_PERF_HARNESS`. That flag compiles in only the test hooks the probes use (`#if DEBUG || ANTICHAT_PERF_HARNESS`).
  Destructive and test-only data hooks, content logging, the loopback OAuth AS, the update feed and the new renderer/UI
  diagnostics stay Debug-only. Bundle id `app.antichat.AntiChat.perf`, container `AntiChat-Dev`: the owner's data
  was never touched.
  - `run.py` files an entry as valid only when the app's own `-Bench buildinfo` reports optimized, not DEBUG, and the
    perf flag on.
  - `tools/ci/perfharness-guard.py` (make audit, release preflight) keeps the flag out of release and try-out builds.
- **D-006.** The ChildSafetyCheck gate compiles identically in the perf build: MediaOutputGate, MediaJobRunner and the
  ChildSafetyCheck package carry no DEBUG or perf condition (guard rule 2b). Only the dev detector manifest's pinning
  differs (r241-audit rule 2c). Every timed image asserts exactly one final gate check. Evidence:
  [`build/at/T05-perfbuild/d006-image-smoke.jsonl`](../../build/at/T05-perfbuild/d006-image-smoke.jsonl), with 4
  preview checks and 1 result check per job on the real detectors.
- **Quiet gate.** Every timed step waited for: 1-min load ≤ 1 per CPU, other processes ≤ 2 cores, GPU ≤ 10 % busy, AC
  power, nominal thermal, no Low Power Mode. GPU steps ran under `gpu-run.sh timing`, except the m5 benches, which hold
  that lock themselves. A noisy entry is never a result; F7 was re-run for that.
- **XCTest-bundle timing** (V3, V283 eager) comes from `make test-unit`, which is always Debug, so it is filed
  `valid=false`.
- **Caches.** There is no `sudo -n purge` on this Mac, so M1 is labelled [WARM-CACHE] and U1 "cold" means the first
  launch of a pair. AT-254 was re-run with an empty private page cache per query (see below).
- **Sample sizes** follow the plan: 20 runs per metric. Exceptions: V11 3 files, T4 / F7_VIDEO 3 jobs, P2 visible 10
  launches, U2 40 sends, B1 300 one-second samples, cancel 10.

**Builds measured.**
- **Day 1, 2026-11-11:** main `f767a630c`, perf build `9e18fbb65`. Chat and UI U9/B1, voice V5–V11, photo P1/M3/P5/R4,
  T3-480p, VID3, AT-266 and search-e2e were not re-run, so they keep their day-1 values.
- **Phase A, 2026-11-12:** main `5e66e7d18` plus fix/u5-renderer-3 `a83f15dd0`, fix/hello-timeout `1f4fdf6ee` and
  fix/xcuitest-r7 `da72e89ba`; perf build `09d658a07`.

#### Pass / miss per bar

| Area | Metric (tier) | Measured | Bar | Verdict | Evidence |
|---|---|---|---|---|---|
| Chat | C1 first token p50 (T0/T1/T2/T3) | 0.066 / 0.168 / 0.327 / 0.148 s | ≤ 1.5 / 1.5 / 1.0 / 0.8 s | pass | `build/perf/runs/20261111T1142..1147*-C1-*.json` |
| Chat | C1b first token p95 (T0–T3) | 0.072 / 0.173 / 0.172 / 0.153 s | ≤ 3 / 3 / 2 / 1.5 s | pass | `…-C1b-*.json` |
| Chat | C2 decode p50 (T0–T3) | 305 / 98 / 98 / 141 tok/s | ≥ 20 / 15 / 20 / 30 | pass | `…-C2-*.json` |
| Chat | C4 prefill p50 (T0–T3) | 12 047 / 2 726 / 2 289 / 3 423 tok/s | ≥ 150 / 150 / 300 / 400 | pass | `…-C4-*.json` |
| Chat | M1 load p50 (T0/T1/T3) [WARM-CACHE] | 0.17 / 0.23 / 0.50 s | ≤ 3 / 3 / 8 s | pass | `…-M1-*.json` |
| Chat | C7 Normal→Evil first token p50 (T1 cold / T3 warm) | 0.89 / 0.069 s | ≤ 9.5 / 1.5 s | pass | `…-C7-*.json` |
| Chat | U3 status after send p95 (T1/T3) | 2.3 / 2.4 ms | ≤ 2 s | pass | `…-U3-*.json` |
| UI | U1 launch p50 (first of pair / warm) | 0.604 / 0.595 s | ≤ 1.0 / 0.5 s | pass / **miss** | `build/perf/runs/20261112T044957Z-U1-na.json` |
| UI | U2 send ack p50 / p99 | 78.3 / 98.4 ms | ≤ 16 / < 100 ms | **miss** / pass | `build/perf/runs/20261112T045926Z-U2-na.json` |
| UI | U5 renderer, S1 stand-in (0.25) / S4 (1.0) | cadence 25 ms, fade on, jumps 0 px; hitches > 33 ms: 20 / 7 | cadence 16.7–33.3 ms; 0 hitches | **miss** (hitches) | `build/at/AT-008/renderer.json`, `build/at/AT-008-S4/renderer.json` |
| UI | U6 Stop p50 / p95 | 178 / 205 ms | ≤ 300 ms / ≤ 1 s | pass | `…-U6-na.json` |
| UI | U9 quick panel p95 | 9.4 ms | ≤ 150 ms | pass | `build/perf/runs/20261111T122720Z-U9-T1.json` |
| UI | U10 palette query p95 | not measured | ≤ 200 ms | owed | palette.field (see the fix list) |
| UI | U11 open a 1000-message chat p95 | 167 ms (n 4) | ≤ 500 ms | pass, n short | `…-U11-na.json` |
| UI | B1 idle energy, mean | 0.44 | ≤ 1 | pass | `build/perf/runs/20261111T123329Z-B1-na.json` |
| Voice | V1 round trip p50 (T1/T3/T0) | 0.935 / 0.936 / 0.935 s | ≤ 1.5 / 1.0 / 2.5 s | pass | `build/perf/runs/20261112T0508..0518*-V1-*.json` |
| Voice | V1b p95 (T1/T3/T0) | 1.53 / 1.53 / 1.53 s | ≤ 2.5 / 1.8 / 3.5 s | pass | `…-V1b-*.json` |
| Voice | V2 T3 endpointing p50 | 934 ms | ≤ 450 ms | **miss** | `build/perf/runs/20261112T051355Z-V2-T3.json` |
| Voice | V2 T3 other stages (STT final / LLM first token / first clause / TTS first chunk / audio out) | 0.2 / 0.5 / 0.9 / 0.1 / 0.5 ms | ≤ 100 / 200 / 120 / 100 / 30 ms | pass | same |
| Voice | V3 onset → TTS silent / → cancel p50 (Debug test bundle) | 31.5 / 260 ms | ≤ 200 / 300 ms | pass (valid=false) | `build/at/AT-282/v3.json` |
| Voice | V283 eager end → final p50 (Debug test bundle) / from the session (perf) | 48 ms / 0.19 ms | ≤ 300 ms | pass | `build/at/AT-283/eos.json`, `…-V283_EOS_FINAL-T3.json` |
| Voice | V4 false splits, worst bed | 2.0 % (cafe) | ≤ 2.0 % | pass | `build/at/AT-283/turn-split.json` |
| Voice | V5 mic → bar p50 | 12.6 ms | ≤ 150 ms | pass | `…-V5-T1.json` |
| Voice | V6 / V7 (T1, T3, T0) / V10 | 0.487 s / 0.052, 0.050, 0.054 s / 79 ms | ≤ 0.6 s / 0.4, 0.3, 1.0 s / 300 ms | pass | `…-V6/V7/V10-*.json` |
| Voice | V8 read aloud p50 (T0/T1/T3) | 0.120 / 0.119 / 0.120 s | ≤ 1.0 / 0.5 / 0.4 s | pass | `…-V8-*.json` |
| Voice | V11 file transcription (T0/T1/T3) | 477× / 478× / 480× | ≥ 4× / 10× / 10× | pass | `…-V11-*.json` |
| Voice | V9 WER (day 1, debug test bundle) | ar 11.42 %, zh 10.60 %, en 0.40 %, de 3.92 %, ja 4.92 % | ≤ 6 %; ar ≤ 11.42 / zh ≤ 10.60 accepted (A-M3-06 row) | pass at the accepted values; Phase B ar 10.18 % (§5.4) | `build/at/AT-284/wer.json` |
| Photo | P1 S4 1024² q4 (T3-48) p50 | 17.23 s | ≤ 20 s | pass | `build/at/T05/day1-image-q4-1024.jsonl` (sd-scale) |
| Photo | P2 first visible progress (A-M4-R1b) p50 / p95 | 0.074 / 0.142 s | ≤ 1 s | pass | `build/at/AT-NFR-P2/perf-uitest.json` |
| Photo | P3 progress never stale | pixels 0 s, label 0.58 s | ≤ 3 s | pass | `build/at/AT-NFR-P3/perf-uitest.json` |
| Photo | P4 edit/create T1 768² / T3 1024² (klein, A-M9-T05-P4) | 1.15 / 1.09 | ≤ 1.5 | pass | `build/at/AT-033/real-legs.log` |
| Photo | P4 T3 "best edit" (qwen, recorded only) | ratio 2.10 (create 83 s, edit 174 s) | none | recorded | same |
| Photo | P5 remove background p50 | 0.22 s | ≤ 1 s | pass | `build/at/AT-NFR-P5/p5-unit-timing.txt` |
| Photo | Image handoff T1: unload / chat reload / peak | 0.04 s / 0.55 s / 6.1 GB | ≤ 1 s / ≤ M1 / ≤ 9.5 GB | pass | `build/at/AT-286/handoff-T1.json` |
| Photo | M3 co-resident T2-24: eviction / peak / next first token | none / 14.34 GB / 0.07 s | none / ≤ 16 GB / ≤ M1 | pass | `build/at/T05/day1-coresident-T2-24.jsonl` |
| Photo | JOB_CANCEL_FREE: cancel → stop / memory freed p50 | 0.042 / 0.043 s | ≤ 2 s | pass | `build/at/T05/phaseA-cancel-q4-1024.jsonl` |
| Photo | IMAGE_TURN_OVERHEAD p50 | 1.87 s | ≤ 2 s | pass | `build/perf/runs/20261112T053743Z-IMAGE_TURN_OVERHEAD-T1.json` |
| Photo | R4 resident set / R5 fallback and refusal | as specified | as specified | pass | `build/at/AT-NFR-R4/resident-set.json` |
| CSC | F7 full path p95 (as used p95 83 ms) | 305.5 ms | ≤ 300 ms | **miss** | `build/perf/runs/20261112T071729Z-F7-T1.json` |
| CSC | body-only age re-check (A-M4-T02b) | no better lawful operating point; v1 kept (fused recall 99.0 / 96.9 %, adult ≥ 30 false flag 12.5 %) | adopt only if better | not adopted | `build/at/AT-NFR-F2/2026-11-11.json` |
| Video | VID1 T4 1280×704 × 121 f p50 | 55.7 s (153 / 51 / 56) | ≤ 90 s | pass | `build/at/T4-video/t05-t4-default.jsonl` |
| Video | VID1 T3 480p real path: benign false blocks | 1 / 60 | (AT-M5) | recorded | `build/at/AT-M5-preview-fp/after.json` |
| Video | F7_VIDEO gate share, max (T4 / T3) | 2.10 % / 10.23 % | ≤ 10 % | pass / **miss** | `…-F7_VIDEO-T4.json`, `…-F7_VIDEO-T3.json` |
| Video | VID3 cancel → freed (T2V p95 / I2V max) | 1.44 / 0.74 s | ≤ 2 s | pass | `build/at/AT-NFR-VID3/cancel-T3.json`, `cancel-i2v-T3.json` |
| Video | AT-290 speed table | ran; table not adopted | | owed | `build/at/AT-290/t05/` (see the fix list) |
| Video | B5 paused for another app | skipped (pid 5587) | ≤ 12 s, resumes after | owed | day 1: paused 12.5 s, never resumed |
| Video | B3 thermal | blocked: no way to force `.serious` | | blocked | ThermalPolicyTests (in-process) |
| Search | AT-248 c1 answer complete p50 (T1) | 5.69 s, 20/20 with ≥ 2 pills | ≤ 12 s | pass | `build/perf/runs/20261111T152221Z-search_e2e-T1.json` |
| Search | AT-254 first token p50, cold (T1 / T3) | 4.15 / 3.78 s | ≤ 8 / 5 s | pass | `build/perf/runs/20261112T071205Z-search-T1.json`, `…071653Z-search-T3.json` |
| Search | AT-266 tool selection (T2 / T0) | 0.86 / 0.805 | ≥ 0.85 / 0.70 | pass | `build/at/AT-266/t05-T2.json`, `t05-T0.json` |
| Memory | StepAside unload / reload (T1, real model) | 0.051 / 0.49 s | ≤ 1 s / ≤ M1 | pass | `build/at/AT-206/step-aside-real.json` |
| Memory | Warm document pin release, max (T2-24) | 0.061 s, peak 8.4 GB | ≤ 2 s, ≤ B | pass | `build/at/AT-279/t05-files-warm.json` |
| Install | M5 first chat at 50 Mbps [EMULATED] p50 | 107.0 s | ≤ 120 s | pass | `build/at/AT-NFR-M5/t05-firstchat-50.jsonl` |
| Install | M5 first chat at 10 Mbps [EMULATED] p50 | 526.5 s | ≤ 600 s | pass | `build/at/AT-NFR-M5/t05-firstchat-10.jsonl` |
| Phase B | V9, D3 real bytes, R1 mini-soaks T1/T2-24/T0/T3-48, AT-273, AT-275, PR1 capture | pending (on the round-60 build) | | owed | |

**AT-254 cache state.** The warm phase-A search run used the shared on-disk page cache
(`~/Library/Caches/AntiChat/web`, 24 h TTL). Of 365 fetched pages, only 65 were new cache entries; about 300 were cache
reads, left by day 1's runs of the same 20 queries
([`build/at/AT-254/t05-a5-cache-check.json`](../../build/at/AT-254/t05-a5-cache-check.json)).
- **Result runs:** all 20 queries per tier again, each with:
  - a new empty private page cache (`search-e2e --web-cache-per-run`, now run.py's default for AT-254);
  - a new on-disk store;
  - no URLCache (NetworkGate sessions keep none).
- **Kept as a real user has them:** DNS and remote CDN caches.
- **Repeated URLs:** 11 (T1) and 18 (T3) of the cited URLs repeat across queries. None was readable from another
  query's cache.
- **Cold vs warm:** T1 4.15 vs 3.94 s, T3 3.78 vs 3.86 s. The page cache does not drive AT-254; the T3 evidence budget
  does. `<web_results>` p50 at T3 went from 11 800 tokens on day 1 to 4 376.
- Every run's notes now carry the cache-state line.

#### T05-fix list

Product misses. Status after the round-60 re-measures (§5.3.1), updated with the round-66 quiet window (§5.6):
1. **V2 endpointing, T3:** p50 934 ms against ≤ 450 ms. It is about 934 ms at every tier, and the turn-end wait
   dominates V1. V1b T3 now passes at p95 1.53 s. Covered by A-M9-T05-V2c (§12).
2. **U2 send ack:** still a miss (round 66: p50 34.2 ms, p99 119 ms). Phase A: p50 78 ms against ≤ 16 ms, p99 98 ms. Round 60: p50 56 ms, p99 167 ms,
   so both stats now miss.
3. **U1 warm launch:** fixed in round 60 (warm 0.479 s).
4. **U5 main-thread hitches:** still a miss (round 66: 18 at 0.25, 3 at 1.0). Round 60: 6 at 0.25 and 18 at 1.0, against 0. Cadence, word fade and
   jumps pass.
5. **F7 full-path check:** fixed by fix/t05-f7 (p95 241 ms).
6. **F7_VIDEO T3:** fixed (max 0.93 %).
7. **B5:** round 66: the job now resumes (8.4 s after the load stops), but the pause comes 12.38 s after the load
   starts, against ≤ 12 s. The sampler attributes the GPU load to WindowServer, not gpu-burn (§5.6).
8. **V9:** pass. The A-M3-06 row accepts ar 11.42 % and zh 10.60 %; run.py now reads both values from that row.
   Phase B measured ar 10.18 % and zh 10.60 %.
9. **U10 palette:** fixed (fix/t05-ui-latency). U10 p95 123 ms; U11 p95 386 ms, n 22.
10. **AT-273 file outputs:** 138/150. On round 64 the 12 misses were re-run with `--ids`: 4 made a file and 7 still end in
    `engine.stalled`. In xlsx-18 the repair step went out with `tool_choice` none, so the model could answer in text.
    Both are with a fix agent (§5.4).
11. **R1 T0 headroom:** round 64 peak 3.96 / 4.0 GB, at a 35 % higher job rate than round 60 (3.79 GB). It passes.
12. **T4 video (VID1 / VID2).** On runtime 0.3.4 VID1 passed (p50 73.8 s) at a 46.7 GB peak, and no previews reached the
    app. On 0.3.5 (round 66) the peak is back to about 28 GB and previews reach the app, but VID1 now misses: p50
    105.5 s, with denoise slowing from the second job in the same child. VID2 misses on timing: first preview after
    37.6–76.4 s, against ≤ 5 s (§5.6).
13. **i2v on runtime 0.3.5 (S2, known regression).** Peak 17.71 GB (was 14.19) and steps 64 % slower. i2v-480p is no
    longer offered on T2-S1 or T3. The fix is in runtime 0.3.6 (§5.6).
14. **U11 open a 500-turn chat:** fixed in round 66 (p95 274 ms; round 65: 665 ms).
15. **C2 T1:** no regression. The −6 / −7 % readings were load; quiet it is +3.8 % (§5.6).

Tooling gaps:
- AT-290 speed table: fixed in round 60 (stage metrics present, LTX preset requested properly, strict preset check).
  The table was regenerated on the round-60 build and committed separately; see §5.3.1.
- I2V result rows carry no `h_*` metrics. The table falls back to `final_s`; the measured 355–413 s matches the
  calibrated 367 s.
- `load.py` names its own processes by name, so the orphan `AntiChat` was invisible to the gate.

#### Driver and tooling fixes made during the run

All committed on `m9/t05-run`:
- Perf-harness build: `make build-perf`, BuildFlavor / `-Bench buildinfo`, perfharness-guard with the D-006 rule, and
  run.py validity.
- report_schema accepts `Perf`.
- XCUITest perf legs drive the perf app (`ANTICHAT_PERF_APP`); log ingests take an explicit `--app`'s validity;
  XCTest-bundle timing is filed against the Debug app.
- The perf build skips the Move-to-Applications offer: LetsMove had moved the perf app to `~/Applications`.
- t05 and sd-scale use `--replace`, so T05 entries replace the Low Power Mode era keys. The skipped chat keys were
  backfilled.
- video-speed.py: absolute runtime path; I2V `final_s` fallback.
- The m5 benches hold their own GPU lock: under `gpu-run.sh timing` they had waited on themselves.
- `load.py` counts `csc-bench` as the measured process, so F7 was no longer "noisy" because of itself.
- The video.T4 result glob is fixed.
- New steps: `prep.t4-install`, `ui.U5.S4`.
- Phase-B `--overlap` mode: non-timing steps only, no quiet gate, GPU work on the shared slot (`gpu-run.sh shared`).
- The PR1 capture counts only the captured app's processes.
- AT-254 cache state recorded, with a cold page cache per query.

#### Gates

The three gates ran green on the perf-build commit `e889d59d6` (test-unit, test-integration-stub at 93 tests / 30
skipped / 0 failures, audit at 39 checks). They are re-run on the final T05 head after phase B.

### 5.3.1 Post-merge re-measures (round 60, main `0418f820a`, runtime 0.3.4; 2026-11-12 14:03–14:58Z)

Quiet gate, perf build, n 20 unless noted. Evidence is in `build/perf/runs/20261112T14*`; per-step logs are under
`build/perf/t05/20261112T14*`.

| Metric | Phase A | Round 60 | Bar | Verdict |
|---|---|---|---|---|
| U1 first launch / warm p50 | 0.604 / 0.595 s | 0.491 / 0.479 s | ≤ 1.0 / 0.5 s | pass / pass |
| U2 send ack p50 / p99 (n 40) | 78.3 / 98.4 ms | 55.8 / 167 ms | ≤ 16 / < 100 ms | **miss / miss** |
| U6 Stop p50 / p95 | 178 / 205 ms | 181 / 206 ms | ≤ 300 ms / 1 s | pass |
| U10 palette query p95 (n 30) | not measured | 123 ms | ≤ 200 ms | pass |
| U11 open a 1000-message chat p95 | 167 ms (n 4) | 386 ms (n 22) | ≤ 500 ms | pass |
| U5 hitches > 33 ms, 0.25 / 1.0 | 20 / 7 | 6 / 18 | 0 | **miss** |
| F7 full path p95 | 305.5 ms | 241 ms | ≤ 300 ms | pass |
| F7_VIDEO T3 max / T4 max | 10.23 / 2.10 % | 0.93 / 1.44 % | ≤ 10 % | pass |
| C1 T1 p50 / C2 T1 p50 | 0.168 s / 97.6 tok/s (day 1) | 0.327 s / 91.2 tok/s | ≤ 1.5 s / ≥ 15 | pass |
| VID1 T4 p50 (n 3) | 55.7 s | 73.8 s | ≤ 90 s | pass (+18 s) |

**U1 launch phases** (`launchPhase` rows, p50 ms from process start): main 30, appInit 67, databaseOpen 93,
appInitDone 103, willFinishLaunching 127, windowReady 416, didFinishLaunching 437. Window creation (about 290 ms) is
the largest step. Raw rows: `build/perf/raw/m1/U1-20261112T140937Z.jsonl`.

**F7 per image.** The p95 is 241 ms and the as-used p95 (safe-for-work images, nudity stage only) is 73 ms. One crowd
image with 10 faces takes 359–376 ms, because the MiVOLO age stage runs once per face (295 ms). The age-stage cost
grows with the number of faces.

**T4 on runtime 0.3.4** (rows `build/at/T4-video/t05-t4-default.jsonl`):
- Finals 67.7 / 73.8 / 76.0 s; first step 21–25 s (16–17 s on runtime 0.3.3).
- Denoise 21–24 s per step; `h_child_denoise_peak_gib` 15.43.
- Previews: 1 per job, `h_child_preview_s` 0.62–0.67 s (about 1 % of the job), made at 65–73 s. `preview_events` 0
  and `first_preview_s` −1, so the previews never reached the app.
- The 18 s increase is in denoise, not the preview cost.
- Peak footprint (helper and children) is 46.7 GB, against 27.4 GB on runtime 0.3.3.

**AT-290 video speed table** (re-run on runtime 0.3.4). All four presets matched the strict check; the T2V and LTX rows
are split from the runtime's own stage clock. S4 step time (`t_step`):
- t2v-480p: 2.95 → 3.19 s.
- t2v-720p: 10.31 → 16.12 s. The old row is stale: against the same perf build path on runtime 0.3.3 (Phase A, finals
  43–50 s), the 720p job is only 3–5 s slower.
- i2v-480p: 17.0 → 19.6 s.
- LTX 512p: 13.2 → 4.2 s.

The table is committed on its own (`AT-290 / A-M5-10` commit). Raw rows: `build/at/AT-290/t05-postmerge/`.

**C1 first token and the GPU clock (A/B).** C1 T1 passes in every run (worst p50 348 ms against ≤ 1.5 s). The warm
first token depends on how long the GPU has cooled off; that is an MLX/GPU clock or power state, not app code.
- **Setup.** A perf-only switch leaves the B/10 MLX cache cap off (commit `90eb490bb`; on `m9/t05-run` only).
  C1 T1 ran with the cap on, off, off, on, n 20 each, back to back.
- **Shape.** Every run starts with 1–4 fast requests (2,190–2,315 tok/s prefill), then drops to 1,000–1,400 tok/s and
  stays there. That happens with the cap on and off, and day 1 (before round 60) shows the same shape.
- **Not the cache.** The MLX cache at request start is 0.82–0.89 GB whether the limit is 0.95 GB or 9.5 GB, and active
  memory is a flat 5.42 GB. The slow state follows time under sustained load, not cache or active memory.
- **Not thermal.** Thermal stays nominal, and decode drops less than prefill.
- **Evidence:** `build/at/T05/c1-cache-ab/` (run records, raw rows with the MLX cache and active fields,
  `summary.txt`).

### 5.4 Phase B: overlap steps beside the T06 soak

`make perf-all OVERLAP=1`: only the non-timing steps (D3 real bytes, the R1 mini-soaks, files spreadsheet /
presentation model runs, PR1 30-min capture, V9 WER) run beside the soak, labelled `overlapped`.

Ran 2026-11-12 15:10Z – 2026-11-13 01:52Z beside the M9.T06 8-h soak, on the shared GPU slot (`gpu-run.sh shared`). Each
step ran on the build named in its row.

| Step | Build | Result | Bar | Verdict | Evidence |
|---|---|---|---|---|---|
| V9 WER per language | round 60 | en 0.40, de 3.92, ja CER 4.92, ar 10.18, zh CER 10.60 % | 6 %; ar ≤ 11.42, zh ≤ 10.60 (A-M3-06, read from the amendment row) | pass | `build/perf/runs/20261112T153152Z-V9-T1.json` |
| D3 real bytes, T1, all eligible packs | round 60 | 11.40 GB = the catalog "all" sum (deviation 0) | ≤ 15 GB | pass | `build/at/AT-NFR-D3/t05-d3-T1.json` |
| R1 mini-soak T3-48, 60 min | round 60 | peak 27.63 GB; 2,376 turns, 792 image jobs, 594 Evil chats | ≤ 36 GB, 0 crash / jetsam | pass | `build/at/AT-206/soak-T3-48.*` |
| R1 mini-soak T2-24, 60 min | round 60 | peak 11.87 GB; 3,762 turns, 1,254 image jobs, 940 Evil chats | ≤ 16 GB | pass | `build/at/AT-206/soak-T2-24.*` (commit `1213438e0`) |
| R1 mini-soak T0, 30 min | round 60 | peak 3.79 GB; footprint p50 2.14 GB; 3,033 turns, 1,011 image jobs | ≤ 4.0 GB | pass | commit `5aaef8d93` |
| R1 mini-soak T0, 30 min | round 64 | peak 3.96 GB; footprint p50 2.87 GB, p90 3.45 GB; 4,086 turns (+35 %), 1,362 image jobs | ≤ 4.0 GB | pass (4 % headroom) | `build/at/AT-206/soak-T0.*` (commit `46c6dbf3b`) |
| R1 mini-soak T1, 60 min | round 60 | peak 7.96 GB; 2,544 turns, 848 image jobs, 636 Evil chats | ≤ 9.5 GB | pass | commit `4e0f658a1` |
| R1 mini-soak T1, 60 min | round 64 | peak 8.06 GB; footprint p50 4.94 GB (round 60: 4.80), p90 7.23 GB (7.24); 2,620 turns, 873 image jobs, 655 Evil chats; under build load 20–27 | ≤ 9.5 GB | pass | `build/at/AT-206/soak-T1.*` |
| AT-275 presentations (model run) | round 60 / round 62–63 | 7/20 → 20/20 | 20/20 | pass | `build/at/AT-275/t05/model/fileout-golden.json` |
| AT-273 file outputs (model run) | round 60 / round 62–63 | 121/150 → 138/150 | 150/150 | **miss** | `build/at/AT-273/t05/model/fileout-golden.json` |
| AT-273, the 12 missing prompts (`--ids`) | round 64 | 4/12 made | | **miss** | `build/at/AT-273/t05-ids/fileout-golden.json` |
| PR1 30-min capture | build/perf/t05/20261113T041442Z (overlap, load 18.8 at the end) | 0 bytes for the app-under-test PIDs; journeys J02/J07/J08 45 each, 0 failures (Evil seen 45/45); tcpdump leg not run (owner, root) | 0 bytes for the app's own processes; every journey ran | **pass** | runs 1–3 were harness misses (wrong app attached; J08 left incognito via the disabled Incognito button so the alert blocked the composer; loop outlived the capture). Fixes cb264bdc9, ffa365521; network leg was 0 bytes on every run |

Every mini-soak had a stable helper pid, no new crash reports and no jetsam.

- **R1 T0 on round 64.** The job rate was 35 % higher and the median footprint 0.73 GB higher than on round 60. The peak
  still passes, but the extra headroom expected from E3 (detectors released at the end of each job) did not show. The
  perf build writes no engine log, so the release count is not available.
- **AT-273 on round 64** (`--ids` re-run).
  - Four prompts made their files: docx-26, xlsx-06, xlsx-12, xlsx-30.
  - Seven stalled again with `engine.stalled` (about 121 s with no engine event and no tool call): csv-06, csv-16,
    csv-25, md-14, md-16, pdf-16, pdf-26. These are the same seven that stalled beside the soak, so the stall is
    reproducible. This re-run had load 20–27 from other builds, so contention is not excluded.
  - xlsx-18: create_spreadsheet refused the empty sheet. The repair step went out with `tool_choice` none, not forced to
    the tool, and the model answered in text. That is a forced-repair bug.
  - Both findings went to a fix agent.
- **D3.** This run's install folder `/tmp/antichat-dest.MrTwq9` (18 GB) was deleted by its literal path.

### 5.5 Round-65 quiet attempt (2026-11-13, merge `1c92cc4ef` of main `366483ef8`)

Merged round 65, rebuilt prep (all 10 prep steps ok, perf build validated by `-Bench buildinfo`), then started the
quiet batch. Five fix agents were building round 66 at the same time, so load spiked mid-run. The coordinator moved
every timed item to the round-66 QUIET WINDOW (§5.6). Only measures taken on a clean gate and below
load1 12 for the whole run count.

| Step | Load (before → during max → after) | Result | Bar | Verdict |
|---|---|---|---|---|
| U6 Stop → idle | 14 → 4 (ingest 4.2–4.5), quality clean | p50 284 ms, p95 325 ms (n 20) | p50 ≤ 300, p95 | **pass** |
| U10 ⌘K query, 10,000 chats | same run | p95 176 ms, p50 91 ms (n 30) | p95 ≤ 200 | **pass** (palette.field fix holds) |
| U2 send ack | same run | p50 57.6 ms, p99 235 ms (n 40) | p50 ≤ 16, p99 < 100 | miss; re-measured on round 66 (it changes U2) |
| U11 open a 500-turn chat | same run | p95 665 ms, p50 553 ms (n 22) | p95 ≤ 500 | miss; re-measured on round 66 (it changes U11) |
| U5 renderer | 10.8 → 25 | 410 hitches | 0 hitches > 33 ms | **not recorded** (contaminated mid-run) |
| C2 T1 chat-9b-q4 | 5.9 → 5.8 → 4.7; other processes 2.04 cores max (owner's Finder at 81–83 % CPU all session) | p50 90.25 tok/s, −7.1 % vs 97.18 | ≥ 15 tok/s | bar passes; run.py quality noisy (0.04 core over), so not recorded; S2 flagged with these loads |
| T4 video | 4.6 → 36.2 | 94–109 s per job | p50 ≤ 90 s | **not recorded** (contaminated) |

- **VID2 early data** (from the contaminated T4 run, not a result). Previews now reach the app over XPC: 16 preview
  events per job, and the child makes 2 at step 2. The first preview arrives at 61–63 s, even in the row taken at load 7,
  against the S4 bar of ≤ 5 s. If no amendment covers T4 720p, VID2 is a timing miss rather than "no previews". To be
  confirmed in the quiet window.
- **Tooling.** AT-008 / U5 now samples load1 every 2 s into `renderer.json` and `summary.json` (`a39776271`), so a run
  that turns noisy mid-run is visible.

### 5.6 Round-66 QUIET WINDOW (2026-11-13 09:46–10:50Z, merge `00bf5011f` of main `dbaad0bc9`, runtime 0.3.5)

All other agents were stopped. Each step waited for a clean load.py gate and load1 < 10, and a load1 sampler ran during
it. A run above load1 12 is not recorded. U5 also samples load inside the probe (`renderer.json` `load`).

| Item | Load1 during (max) | Result | Bar | Verdict |
|---|---|---|---|---|
| U2 send ack | 6.1 | p50 34.2 ms, p95 46 ms, p99 119 ms (n 40) | p50 ≤ 16, p99 < 100 | **miss** (round 65: 57.6 / 235) |
| U6 Stop → idle | 6.1 | p50 164 ms, p95 174 ms (n 20) | p50 ≤ 300, p95 ≤ 1000 | pass |
| U10 ⌘K, 10,000 chats | 6.1 | p95 124 ms (n 30) | ≤ 200 | pass |
| U11 open a 500-turn chat | 6.1 | p95 274 ms, p50 221 ms (n 22) | ≤ 500 | **pass** (round 65: 665) |
| U5, S1 stand-in (0.25) | 7.5 (in-probe) | 18 main-thread hitches > 33 ms (longest 272 ms); cadence 25.0 ms, 0 jumps, fade on | 0 hitches | **miss** |
| U5, S4 (1.0) | 4.7 (in-probe) | 3 hitches (longest 65 ms); cadence, jumps and fade pass | 0 hitches | **miss** |
| C2 T1 chat-9b-q4 | 3.4 | p50 100.84 tok/s, +3.8 % vs 97.18 | ≥ 15 | pass; the −6 / −7 % S2 was load, cleared |
| VID1 T4 720p × 121 f | 2.95 | 61.3, 105.5, 113.8 s → p50 105.5 s | ≤ 90 s | **miss** |
| T4 peak footprint | 2.95 | 27.7–28.1 GB (0.3.4: 46.7) | — | fixed by 0.3.5 chunked previews |
| VID2 T4 first preview | 2.95 | 37.6, 62.2, 76.4 s; 16 preview events per job reach the app | ≤ 5 s (S4) | **miss** (timing) |
| F7_VIDEO T4 | 1.7 | max 5.8 % of generation time | ≤ 10 % | pass |
| F7_VIDEO T3 | 2.0 | max 1.24 % | ≤ 10 % | pass |
| B5 paused for another app | 3.6 | paused 12.38 s after the load; resumed 8.4 s after it stopped | ≤ 12 s | **miss** (0.38 s) |
| AT-290 speed table | 3.2 | re-measured on 0.3.5 (S4 n 3) | — | shipped (see below) |

- **VID1 T4.** Denoise slows down from job 2 inside the same video child: 56.7 s, then 101.0 s, then 109.4 s. Thermal
  is nominal and load is about 2, so this looks like the same sustained-GPU slow state as C1 prefill (§5.3.1). Job 1
  alone would pass. Evidence: `build/at/T4-video/t05-t4-default.jsonl`.
- **B5.** The yield sampler named WindowServer as the GPU holder (share 0.54–0.60), with gpu-burn at 0.07–0.14. The
  per-process GPU attribution needs checking; it may also explain the extra 0.38 s. The XCTest passes because it
  allows 14 s for UI. Evidence: `build/at/AT-NFR-B5/t05-r66.json`, taken from the AT-EVIDENCE line because the
  UI-test runner did not write `perf-uitest.json`.
- **Speed table (owner rule: offer a preset only where the shipped runtime can run it).** The runtime-0.3.5 table
  ships (commit `e8fe19986` on main `dbaad0bc9`), with the speed-table tests updated to the measured values:
  VideoEstimator, VideoTools, VideoPlanCard (estimate text and snapshots), VideoPlanPolicy.
  - **Known regression (S2), fix in runtime 0.3.6:** i2v-480p is no longer offered on T2-S1 (M4 24 GB) or T3
    (M4 Pro 48 GB). On 0.3.5 i2v peaks at 17.71 GB (was 14.19) and its step time is up 64 % (S4 27.9 s vs 17.0).
  - **Behaviour change:** LTX Sound-on at T3-S4 is now about 149 s, so under the existing ≤ 5-min rule it counts down
    and auto-starts instead of waiting for Start. The coordinator accepted this; no Sound-on special case.
  - The runtime-0.3.4 table (`d90975630`) was not taken: it also dropped t2v-720p on T3.
- **Tooling fixes in the window:** `load.py` counts `python3.N` (the video runtime child) as ours, after F7_VIDEO T3
  read noisy twice; `compare.py` sorts keys whose model is None; t05 `--only ui.U5` also runs U5.S4.
- **compare vs main** (`build/perf/compare.json`): 174 compared, 6 not comparable, 1 S1, 8 S2.
  - The S1 is C1.T1 p50 TTFT +94.5 %: the GPU-clock slow state already explained in §5.3.1, where the C1 bar passes.
  - The S2 rows: F7_VIDEO ratios (T4 4.3 % against 2.1 %, all well inside the 10 % bar), R1 T0 and T3-48 peaks (both
    pass their bars), U11 against a 167 ms baseline (bar passes), and U2 p99.
- **AT-221** (`build/at/AT-221/t05-2026-11-13.json`): AC2 miss (U2) and AC7 miss (VID1 / VID2 at T4). AC1, AC3–AC6,
  AC8 and AC9 pass.

### 5.7 T05 exit summary (from the round-66 quiet window, §5.6)

The round-66 quiet window (§5.6) is the T05 result of record. Round 67 changed no timed path: the perf-only MLX
cache-cap switch (`90eb490bb`) was reverted in `45f2bfd09`, and the Usage MLX diagnostics stay.

| Verdict | Items |
|---|---|
| **pass** | U6 (p50 164 ms), U10 (p95 124 ms), U11 (p95 274 ms), C2 T1 (100.8 tok/s), F7_VIDEO T4 (5.8 %) and T3 (1.24 %), PR1 (0 bytes, §5.4) |
| **miss** | U2 (p50 34.2 ms, p99 119 ms); U5 (S1 stand-in 18 hitches, S4 3 hitches); VID1 T4 (p50 105.5 s); VID2 T4 (first preview 38–76 s); B5 (paused at 12.38 s against ≤ 12 s; the sampler attributes the GPU to WindowServer) |
| **fixed** | T4 peak memory: 27.7–28.1 GB on runtime 0.3.5 (0.3.4: 46.7 GB) |
| **known regression (S2)** | runtime 0.3.5: i2v is no longer offered on T2-S1 or T3; the fix goes to runtime 0.3.6 |
| **unchanged rule** | the ≤ 5-min auto-start rule (LTX Sound-on at T3-S4 now auto-starts) |

The five misses ship as known S2 performance issues and go to M11.

## 6. M9.T06: 8-hour soak, swap session, crash-free sessions

Tooling on `m9/t06-soak` (`5a0fe0815`, `432511a21`, dry run 2 `64391c73b`): `SoakProbe` (mixed session on the real
models: chat, voice through the real STT/TTS, 3 images/h, Normal↔Evil swaps, quick panel, project retrieval, small
imports), `make soak HOURS= TIER=`, `soak-sampler.py`, `soak-report.py`, `crashscan.py`, `swap-session.sh`,
`crash-free.py`, `SessionLedger` (`~/Library/Logs/AntiChat-Dev/sessions.jsonl`). Dry run 2 (20 min, T1) ran the tooling
end to end.

| AT | Bar | Result |
|---|---|---|
| AT-NFR-S3 8 h soak (T1) | no crash, no hang, memory growth within budget | 8-h run on `0418f820a`: **fail** (hangs only). 2-h confirmation on `dbaad0bc9`: **pass**. See below |
| AT-NFR-S1 crash-free sessions | ≥ 400 sessions, crash-free rate at the NFR bar | no result recorded `⟦PENDING:T06-CRASHFREE⟧` |
| AT-NFR-R2 swap session | swap within the NFR budget | no result recorded `⟦PENDING:T06-SWAP⟧` |

**AT-NFR-S3.** Method note: [`AT-NFR-S3-method.md`](AT-NFR-S3-method.md).
- **8-h T1 run on `0418f820a`: FAIL, on 40 hangs > 2 s only.** Growth −0.4 %, 0 crashes, 0 OOM, 319 loops,
  0 failures.
- **Root cause.** The soak launched the app with the `.prohibited` activation policy. Its main thread ran at priority
  31 and was starved under load: the stalls were CPU work stretched into seconds, not waits.
- **Fix.** The soak now launches the app through LaunchServices with the `.accessory` policy, so the main thread runs
  at priority 46, as in the app a user runs. The database-writer change (main-actor writes off the main thread,
  `da092f429`) is kept as well.
- **A/B under the same load:** hangs > 2 s went from 3 to 0, hangs ≥ 1 s from 33 to 0.
- **Owner decision: no 8-h re-run.** The **2-h confirmation soak on `dbaad0bc9` PASSED**: 0 hangs > 2 s (max 0.50 s),
  growth 2.8 %, 98 loops, 0 failures, 0 crashes, 0 OOM.

## 7. M9.T07: P2 stretch (AT-035, AT-094)

Moved to M11 (D-026). Not part of v1; not exit-blocking.

## 8. M9.T08: visual QA against the parity rubric (AT-VQ-M9)

Full write-up: [`M9-T08-visual-qa.md`](M9-T08-visual-qa.md) (`qa/visual`, `qa/visual-residuals`).

- **Release bar met after the fixes:** every ★ screen ≥ 4.5 with L, V, C ≥ 4 (S-01…S-05, S-08, S-09, S-11, S-14, S-16,
  S-18); every other screen ≥ 4.0 (Capabilities, Privacy & Data, Storage ≥ 4.5); none below 3.5; no dimension below 3.
- **Before the fixes:** 4 ★ screens failed (S-04, S-05, S-08, S-11) and 6 others (S-10 with C 2.5, Chats page, S-21 Evil
  Mode, Tools & Connections with K 2.5, Privacy & Data, Storage). 12 fix commits on `qa/visual` plus 4 in the residuals
  pass; no bar loosened, no copy-deck key added.
- **Residuals:** R1 (S-09, S-22, S-23 not captured), R2, R3, R6 resolved. Open: **R4** S-11 / S-13 scored on AT-VQ-M4
  captures (Photo not ready in the dev store; proposed S3, owner: M9 exit VQ run on a host with the Photo models);
  **R5** citation pill on its own line after a wrapping paragraph (accepted MarkdownView limit A-M7-T03a d; proposed S3);
  **R7** screenshot H3 / H5 / H6 inconclusive (OCR; `DesignTokenContrastTests` is the H3 authority), H7 pass.
- **Method deviation (R8):** one builder-scorer, not the two-agent blind panel of rubric §4.
- **Blind re-score on `366483ef8` (T10): misses the looks bar.** ★ screens: 2 of 11 pass; others ≈ 55 %. **Owner
  decision 2026-11-12: looks-only misses do not gate the release.** The re-score also found 8 functional bugs (F1–F8);
  all are fixed in round 66.

## 9. M9.T09: upstream sync (2026-11-10)

**Branch:** `sync/t09` (one commit per dependency; main merged at round 43). Full evidence: [`docs/research/07-spikes/S-1-vendor-sync.md` "T09 real sync"](../research/07-spikes/S-1-vendor-sync.md). The plan came from rehearsal #2: [`M9-T09-rehearsal.md`](M9-T09-rehearsal.md).

**Taken:**
- osaurus `2922745` → 0.25.33 `66c3dde` (vendored, 1 conflict resolved by keeping ours, all UP markers survive, patch-lint 0 errors).
- FluidAudio 0.18.0 → 0.18.3.
- mlx-swift-lm `f5b0677` → `ec4c966`, the last commit that builds, with the MLXAdapter steering/stop-reason change.
- GRDB 7.12.0, EventSource 1.6.0, swift-log 1.17.0.
- swift-sdk `3059fd5`, which fixes a socket leak and data races.
- swift-huggingface `3bee3b6`, swift-transformers 1.4.0.
- swift-nio 2.105.0, swift-asn1 1.7.4, swift-jinja 3.1.0.

llama.cpp b12254 and libxls `93f1ad5` landed on main before T09.

**Held (lead-approved, listed in [`M11-candidates.md` §F](M11-candidates.md)):**
- **Osaurus 1.0.0.** Its keychain change re-scopes the service names, which orphans stored credentials, and it pulls a type into Keychain.swift from outside our closure. The onboarding design system would also need to be ported, and 24 watch files changed.
- **FastVideo `4deb3a5`.** The only change is an env-var refactor with no fix on our MLX path, and it would force video-runtime 0.3.4 plus catalog v15.
- **sqlite-vec, sd.cpp, swift-crypto 5.x, npm image-size.** Same reasons as in the rehearsal.

**Gates:**
- `make build`: green.
- `make test-unit`: green. The flakes seen under load (a Metal shader compile in LlamaServerSupervisorTests, two Settings window snapshots) passed when re-run.
- `make test-integration-stub`: green (90 tests, 20 skipped, 0 failures).
- `BINARIES_SRC=… make audit`: green (38 checks).
- `make audit-vendor`, `pins-verify`: green.
- Engine conformance at T1 is unchanged from baseline: 9b-q4 40/20/10, 0.8b 29/20/10, with the same 11 tool misses as before.

**Voice metrics after FluidAudio 0.18.3 (T1): no NFR regression.**

| Metric | Before | After |
|---|---|---|
| V9 WER | en 0.40 %, de 3.92 % | same; all 400 hypotheses byte-identical |
| V4 false splits | 0/1/0/0 of 50 | identical |
| V3 onset → TTS silent, p50 | 32.7 ms | 25.7 ms |
| V3 onset → cancel, p50 | 260.9 ms | 254.8 ms |
| V1 round trip, p50 / p95 | 1.037 / 2.021 s | 0.961 / 2.024 s |
| V8 read aloud, p50 | 0.182 s | 0.129 s |

The timing runs are labelled noisy (shared GPU). AT-282 AC2 missed 1–2 of 36 items. That is a pre-existing boundary-timing flake: the same misses show with FluidAudio 0.18.0, and the TTS output is byte-identical between the two versions.

**Follow-ups:**
- `-Bench voice-session` fails with "voice models missing" when `installs/turn` holds the ONNX manifest. `BenchMode.conversationModels()` then looks up `turn-coreml`.
- `TestPlistHygieneTests` now finds `Vendor/osaurus@<short>` at any short.

## 10. XCUITest catch-up (Q-015), rounds 1–7

Full report: [`XCUITEST-REPORT.md`](XCUITEST-REPORT.md). Round 7 is on `fix/xcuitest-r7` / `m9/t05-run` (`da72e89ba`),
not yet on main. The owner enabled automation mode before round 1 (`automationmodetool`), so every round ran on this Mac.

| Round | Date, branch | Scope | Result |
|---|---|---|---|
| 1 | 2026-11-10, `fix/xcuitest-catchup` | first full pass, 332 tests in 99 suites | 129 pass · **191 fail** · 4 blocked · 8 skipped (before: 0 could pass; the bundle did not load) |
| 2 | 2026-11-10, `fix/xcuitest-r2` | every round-1 failure + 14 new tests (346) | 190 pass · **140 fail** · 4 blocked · 12 skipped |
| 3 | 2026-11-10, `fix/xcuitest-r3` | 101 of the 144 round-2 failures re-run | 28 now pass · **116 fail** (43 kept their round-2 result); every M10 failure passes |
| 4 | 2026-11-10, `fix/xcuitest-r4` | 81 of the 116 re-run | 41 now pass · **75 fail** (9 of them launch failures caused by orphan pid 5587) |
| 5 | 2026-11-11, `fix/xcuitest-r5` | the 76 failing by test id | 38 now pass · **38 fail** |
| 6 | 2026-11-11, `fix/xcuitest-r6` | the 38 | 21 now pass · **17 fail** (6 of them the accessibility audits, owned by the a11y track) |
| 7 | 2026-11-11/12, `fix/xcuitest-r7` | the 10 in scope (r6's 17 minus KeyboardOnly ×2, the audits and the overlay-field-focus three) + J09 ×4 | **10 / 10 pass**, 0 fail; regression chunks c6 + c7 all pass |

Product bugs found and fixed across the rounds: P1…P80 (round 7: P75 ⌘K focus, P76 palette recents, P77 Composio
relay refusal copy, P78 Settings window AX title, P79 Network activity rows, P80 voice caption = whole sentence).

**Still failing or not run after round 7, with owners:**

| Test | Why | Owner |
|---|---|---|
| KeyboardOnlyTests ×2 | Full Keyboard Access is off (a system setting), plus spec gap A-Q015-r6-kb (resolved: the 22 ⌘K page/command paths are a recorded spec gap → M11, not counted as failures) | **owner** (Full Keyboard Access, OWNER-STEPS) |
| AccessibilityAuditTests ×5, FileActionsTests/testAccessibilityAudit | failed read-only in r7 c6 because round 59 (fix/a11y-audit) was not on main yet; on main since `88720aae7`: 0 issues (§3) | a11y track: re-run on the RC build `⟦PENDING:T10-XCUI⟧` |
| ImageEdit ×2, ImageViewer versions rail (the overlay-field-focus three) | fixed by round 58 (fix/overlay-field-focus); pass on the r7 branch | re-run on the RC build `⟦PENDING:T10-XCUI⟧` |
| Integration-stub `engine.helloTimeout` flake (LoadGateWiring, LlamaServerSupervision) | launchd respawn throttle; fixed by `fix/hello-timeout` `1f4fdf6ee` (on `m9/t05-run`, not main) | lead: merge with r7 |
| AT248RenderedPillsUITests | live network + real model; not run in the catch-up | m7 track (evidence in M7-report) |

The full M9.T10 `make test-ui` on the RC build: `⟦PENDING:T10-XCUI⟧`.

## 11. PRD amendments added in M9

Status as in [`../PRD-AMENDMENTS.md`](../PRD-AMENDMENTS.md) on 2026-11-12. Rows still needing a decision are in bold.

| ID | Task | What (short) | Class | Status |
|---|---|---|---|---|
| A-M9-T01a | T01 | Settings › General "VoiceOver reads replies" row | minor | **not recorded: listed for T10** |
| A-M9-T01b | T01 | accessibility method deviations (AppKit announcement path, no FocusCoordinator) | minor | **not recorded: listed for T10** |
| A-M9-T02a | T02 | NFR-A5 picture descriptions (`ImageDescriptionService`, `v31_image_description`) | minor | **not recorded: listed for T10** |
| A-M9-T04a | T04 | localisation method (agent translator + independent reviewer per language; legal stays English) | minor | **not recorded: listed for T10** |
| A-M9-T03a | T03 | how the audit measures S-21 (per section and scroll position) | minor | resolved (lead, 2026-11-11) |
| A-M9-T03b | T03 | element-less Parent/Child issues counted in [switches, attributable] | minor | resolved (lead, 2026-11-11) |
| A-M9-T05a | T05 prep | Xcode pin 27.1 → 27.2 | minor | resolved |
| A-M9-T05a (sd) | T05 prep | sd-server / sd-cli rebuilt on 27.2, checksums re-recorded | minor | resolved |
| A-M9-T05a (filetools) | T05 prep | filetools-runtime zip sha re-recorded | minor | resolved |
| A-M9-T05a (video) | T05 prep | video-runtime zip sha re-recorded | minor | resolved |
| A-M9-T05-U5 | T05 | renderer rework for NFR-U5 (parts 1–2; streaming block not selectable until it settles; 40 Hz reveal) | minor | resolved (lead, 2026-11-11) |
| A-M9-T05-U5b | T05 | U5 part 3: size / alignment queries no longer re-measure the transcript (code on `m9/t05-run`; row copied to this branch) | minor | resolved (lead, 2026-11-11) |
| A-M9-T05-U5c | T05 | U5 part 4: end-of-reply and long-chat hitches; code blocks show whole lines (on `fix/u5-renderer-4`) | minor | resolved (lead, 2026-11-11) |
| A-M9-T05b | T05 | AT-254 T3 direct search; B5 GPU-yield fix | minor | open: AT-254 T3 part → A-M9-T05-AT254c; B5 blocked by environment (pid 5587) |
| A-M9-T05-AT254c | T05 | AT-254 T3 judged on the availability set (rows 1–20); evergreen ≈ 7.3 s is a known characteristic; lever 3 → M11 | minor | resolved (owner via lead, 2026-11-11) |
| A-M9-T05-V2 | T05 | end of turn: `openEnd` ships (V1b T3 fixed); `sentenceStable` measured and off | minor | openEnd resolved (lead, 2026-11-11); V2 T3 → V2b / V2c |
| A-M9-T05-V2b | T05 | turn-model search: no local model meets V2 T3 + V4 | major | proposed (escalated) → resolved by A-M9-T05-V2c |
| A-M9-T05-V2c | T05 | V2 endpointing ships at ≈ 0.93 s; re-test with conversational turn data and a turn-1-mini port in M11 | major (owner) | resolved (owner via lead, 2026-11-11) |
| A-M9-T05-AT282 | T05 | timed AC2 reference | minor | withdrawn (2026-11-11) |
| A-M9-T05-AT282b | T05 | AT-282 AC2 reference = forced-aligned word onsets | minor | resolved (lead, 2026-11-11) |
| A-M9-T05-V9 | T05 | WhisperKit empty-decode retry | minor | resolved (lead, 2026-11-11) |
| A-M9-T05-P2 | T05 | NFR-P2 measured on the visible progress state (A-M4-R1b) | minor | resolved (lead, 2026-11-11) |
| A-M9-T05-P4 | T05 | AT-NFR-P4 T3 judged on the default edit (img-klein) | minor | resolved (lead, 2026-11-11) |
| A-Q015-r6-kb | T01 (XCUITest r6) | 22 ⌘K keyboard paths that no requirement lists | minor | resolved as a recorded spec gap → M11 (lead, 2026-11-11; M11-candidates §H) |

Flags for T10: (1) no row is `proposed` any more (lead decisions of 2026-11-11 applied on 2026-11-12); (2) A-M9-T05-U5b is now in `PRD-AMENDMENTS.md` on this branch **and** on `m9/t05-run` (there still `proposed`): when the two merge, keep this branch's copy (status resolved) and drop the other; A-M9-T05-U5c is still only on `fix/u5-renderer-4`; (3) A-M9-T01a/T01b/T02a/T04a now have the full column set, but their text records no decision, so their status reads "not recorded: listed for M9.T10 sign-off": T10 marks them resolved (or not).

## 12. Owner decisions resolved (owner via lead, 2026-11-11)

1. **AT-254 at T3 (A-M9-T05-AT254c).** AT-254 T3 is judged on the availability set, rows 1–20 of
   `search-availability-100.jsonl` (the set the T05 step uses): cold p50 **4.36 s ≤ 5 s, pass**. Evergreen "what is /
   history of" queries (rows 41–60) take ≈ 7.3 s: Wikipedia-class pages arrive in < 1 s and fill the 10k evidence
   budget, so the first token is prefill-bound. That is a known characteristic, not a miss. Lever 3 (incremental
   prefill overlapping fetch / rank, saves ≤ 1.9 s → ≈ 5.4–5.8 s) goes to M11 (M11-candidates §H).
2. **NFR-V2 T3 endpointing (A-M9-T05-V2c).** V2 endpointing ships at ≈ 0.93 s p50 (bar ≤ 450 ms) with smart-turn v3.2
   and the A-M9-T05-V2 rules; V4 false splits stay ≤ 2 % per bed. After release, M11 re-tests with conversational turn
   data (the read-passage fixtures pause after finished sentences) and a port of p99lab turn-1-mini (Apache-2.0,
   5.4 M parameters) (M11-candidates §H).

## 13. Open items at exit (S2 / owner)

| Item | Owner | Blocks |
|---|---|---|
| KeyboardOnly ×2: Full Keyboard Access | owner | AT-223 part 2 XCUITest leg |
| 16 VoiceOver walkthroughs, Inspector audit | owner (live) | NFR-A6 |
| Native review of the P1 update-copy translations and the "No lectures" copy | owner | l10n sign-off |
| sudo legs: tcpdump (NFR-PR1), fs_usage, `purge` (cold M1 / U1 / U3; otherwise the `[WARM-CACHE]` labels stand) | owner (root) | those legs |
| Open Numbers, Pages and Keynote once each, then re-run the office open matrix | owner | office open matrix |
| Push fixtures `5416b9c` to the local bare repo | owner | fixtures on the bare repo |
| Status of A-M9-T01a, T01b, T02a, T04a (content records no decision) | lead | amendment status |
| T05 misses U2, U5, VID1 T4, VID2 T4, B5 (§5.7); i2v on T2-S1 / T3 (runtime 0.3.6) | M11 / runtime 0.3.6 | — (S2) |
| Blind re-score looks misses (§8) | M11 | — (owner: not gating) |
| VQ R4 (S-11 / S-13 live capture with Photo models), R5 (pill line break, S3) | M11 | — |
| UI suite re-run on the RC; AT-273 normaliser re-run (`bfd2e55c2`); AT-NFR-S1, R2; `make audit`, R-241 | lead | exit evidence (pending) |

Release-only owner items (production keys, RB-1, RB-2, legal K-060, the M10 DMG size doc) are in the M10 report.

## 14. README row (draft for T10)

Written to `docs/prd/README.md` on 2026-11-13 (status **done, exit conditional**; see that row). Parity minima from the
builder-scorer (§8): ★ 4.50 (S-02, S-04, S-08, S-09, S-11, S-14, S-16, S-18), others 4.28 (S-10, S-19); the blind
re-score misses the looks bar (not gating, owner 2026-11-12).

## 15. Placeholders still to fill

| Id | What | State (2026-11-13) |
|---|---|---|
| `T05-REMEASURE` | Quiet post-merge re-measures | filled: §5.3.1, §5.6, §5.7 |
| `T05-B` | Phase B overlap steps | filled: §5.4 |
| `T06-SOAK` | AT-NFR-S3 soak verdict | filled: §6 (8 h fail on hangs, cause found; 2 h confirmation pass) |
| `T06-CRASHFREE` | AT-NFR-S1 crash-free sessions (≥ 400) | **pending** |
| `T06-SWAP` | AT-NFR-R2 swap session | **pending** |
| `T03-VO` | Inspector audit + 16 VoiceOver walkthroughs (owner, live) | **pending (owner)** |
| `OWNER-L10N` | native review of the P1 update-copy translations and the "No lectures" copy | **pending (owner)** |
| `T10-AT102` | AT-102 strict gate after the late keys | filled: pass on the RC |
| `T10-OFFLINE`, `T10-INSTALL` | `make test-offline`, `make test-install` on the RC build | filled: both pass |
| `T10-XCUI` | full `make test-ui` on the RC build | **pending** |
| `T10-VQ-BLIND` | blind two-agent re-score | filled: misses the looks bar; not gating (owner) |
| `T10-GATES` | `make audit`, R-241 audit, triage | **pending**; `/code-review` done (5 findings, fixed in round 68) |
| `T10-README` | README M9 row | filled: §14 |
