# M9 card: polish, accessibility, localisation, performance, soak, parity, upstream sync

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M9.md`. This card doesn't repeat task steps. Where it and `M9.md` disagree on a repo fact, the card is right (checked against the tree on 2026-11-08, main `12e88336`).

## What M9 delivers
The whole app (as it is on main, plus whatever M3/M4/M5/M7/M8/M10 land) is usable with VoiceOver and the keyboard alone, meets WCAG 2.2 AA in every theme including Evil and Incognito, follows Reduce Motion / Reduce Transparency / Increase Contrast and text sizes 12–24 pt (and 200% in DEBUG), and ships in English plus de, fr, es, nl and pt (Brazilian, shipped as `pt`) with a "Follow macOS" override. Then the full NFR re-measurement, an 8-hour soak, the release-bar visual QA and the second upstream-sync rehearsal.
**Exit:** `M9.md` header "Exit" row (AT-102, AT-221, AT-223 ×3, AT-NFR-A1…A6, S1, S3, R2, every AT-NFR re-run, AT-VQ-M9, rehearsal #2). T07 is in M11 (D-026); AT-035/AT-094 are not part of v1.

## Order and timing
T01 → T02 → T04 → T03 (now, on branch `m9/polish`) · **after every other milestone has landed:** T05 → T06 → T08 → T09 (last) → T10.
T05, T06, T08, T09 and T10 measure or score the finished product; running them while M3/M4/M5/M7/M8/M10 still land UI and models would only have to be repeated. Start them when README §1 shows M3–M8 and M10 `done` (M10 can close after M9 only for its T10 credentials step).

## Repo reality (the PRD text is older than the code)
- **Strings:** the catalog `App/AntiChat/Localizable.xcstrings` is **generated** (`tools/design/gen-xcstrings.py`) from `copy-deck.md` (English) plus `docs/research/10-architecture/design-system/translations/<lang>.json` (M9.T04). Never edit the catalog. A new key = a copy-deck row, then `python3 -I tools/design/gen-xcstrings.py`; translate it with `tools/l10n/l10n.py set <lang> batch.json` (rules: `tools/l10n/translate-pass.md`, `glossary.csv`). `CopyKey.string` resolves through the compiled catalog (`Bundle.main`), so translations need no code change.
- **Count strings** use plural variations: list the key in `tools/l10n/plurals.json` (arg + English singular); the generator writes `%lld` variations, `CopyKey.string` picks the CLDR form and keeps the caller's number formatting.
- **App language** is the app-domain `AppleLanguages` default (`AppLanguage` in Foundation/Locale), applied at relaunch; Settings → General shows "AntiChat will use this language after it restarts" + [Restart now] (`AppRelaunch`).
- **Help pages** are translated under `App/AntiChat/Resources/HelpL10n/<lang>/` (`BundledDocument.localizedURL`). **Legal pages stay English** (they equal the site's binding text; A-M9-T04a).
- **Launch args** live in `LaunchOptions.swift`; M9 adds `-A11yProbe <dir>`. The DEBUG design overrides `-ForceReduceMotion`, `-ForceReduceTransparency`, `-ForceIncreaseContrast`, `-TextSizeScale` are read by `AppearanceSettings.applyingLaunchOverrides()` (UserDefaults argument domain), not LaunchOptions.
- **Reduce Motion / Transparency / Increase Contrast** were built in M1 (Settings → Appearance rows + `EffectiveReduceMotion`, `EffectiveReduceTransparency`, `ContrastOverride`); `DesignTokenContrastTests` already checks every tokens.md §7 pair (incl. Evil, Incognito, focus ring) in light/dark/IC-light/IC-dark. `tools/a11y/contrast-pairs.py` is not a second copy: the pairs are `TokenCatalog.contrastPairs`, generated from tokens.md by `gen-tokens.py`.
- **XCUITest can't start on this Mac (Q-015).** The M9 UI tests are committed in `App/UITests/Accessibility/` (VoiceOverLabelTests, KeyboardOnlyTests, AccessibilityAuditTests, TextSizeClipTests, SystemSettingsTests, LocalisationTests, MediaAltTests) and compile under `make audit` (uitests-build); the in-process leg is `tools/at/at-223-probe.sh` (`-A11yProbe`, per language): it gates the Evil window AX title, the running UI language, resolved catalog strings and plurals, and lists the interactive AppKit views of S-05, S-08 and all 13 Settings sections. That list is informational: SwiftUI creates its own AX nodes (where most labels sit) only for a real AX client, so the authoritative "0 unlabeled" inventory is VoiceOverLabelTests + the vq-12 walkthroughs (owner steps). What needs the owner is in `M9-owner-steps.md`.
- **Guards for late-landing tracks (in `make audit`):** `a11y-lint` (icon-only controls need `.accessibilityLabel`; `.onTapGesture` needs `.isButton`/`.accessibilityAction`; no hidden Button/Toggle; no symbol-name labels; Button/Toggle identifier ratchet `tools/a11y/a11y-lint-baseline.json`, may only shrink), `keyboard-paths` (`tools/a11y/keyboard-paths.yml` regenerated from SettingsRegistry + fixed paths), `l10n-source` (catalog fresh, no hard-coded UI literal) and `l10n-langs` (report-only counts; the strict `--require translated` is the AT-102 gate at T10). A track adding keys after M9 shows up as untranslated there; translate before T10.

## Key types and interfaces
- `StreamAnnouncer` (UI/Accessibility): `begin / replyDelta / reasoningDelta (ignored) / activity(id:summary:) / finished / interrupted`, `.atEnd` (one announcement ≤ 400 chars, `.standard`) or `.perSentence` (NLTokenizer sentences, `.low`, ≥ 1.5 s apart, queued). Fed by `ConversationModel.announce(_:)` for its own turn; voice sessions skip it. Posts `NSAccessibility.announcementRequested` (the M9.md fallback path, used always).
- `AnnounceReplies` (Foundation/Settings/A11yDefaults.swift) + Defaults key `announceReplies` (General row "VoiceOver reads replies", A-M9-T01a).
- `WindowAccessibilityTitle.text(chatTitle:evil:incognito:)` + `.windowAccessibilityTitle(_:)`: the NSWindow AX title says "…, Evil mode chat" / "…, Incognito chat" (visual title unchanged).
- `AppLanguage` (`system, en, de, fr, es, nl, pt`; `current/set/atLaunch/running`).
- `tools/l10n/l10n-check.py` (`--source en`, `--langs … --require translated`, `--report-only`), `tools/l10n/l10n.py` (todo/set/dump).
- `tools/frametime.py --fade-detect` (frames caught mid-fade; 0 = instant).

## Tasks
| Task | State (2026-11-08) | Notes |
|---|---|---|
| T01 VoiceOver + keyboard | done on `m9/polish` (code + lint + probe); XCUITest legs pending Q-015 | StreamAnnouncer, announce setting, labels (send/stop, mode switch, versions, recordings, project icon, rename field), VO actions on every tap target, Evil/Incognito window title, keyboard-paths.yml (208 entries), a11y-lint in audit |
| T02 contrast / motion / text size / media | done on `m9/polish` (round 2: editable picture descriptions, A-M9-T02a) | DEBUG overrides, `-TextSizeScale`, fade detector, `ImageDescriptionService` + viewer Description field + "Generated image: <description>" labels (`v31_image_description`) |
| T03 audit + VoiceOver walkthrough | partial: automated AX inventory in-process; `performAccessibilityAudit`, Inspector audit and the 16 walkthroughs need the owner (`M9-owner-steps.md`) | `tools/visual/vq-12-a11y.md`, `tools/a11y/vo-walkthrough.md`, `tools/a11y/audit-ignores.yml` (empty) |
| T04 localisation | done on `m9/polish`: 1195 keys × 5 languages translated + independent review sign-off per language; help pages ×5; picker + restart; plurals | AT-102 strict gate re-run at T10 after late keys |
| T05 perf re-measure | **after all milestones land** | full deferred list below |
| T06 8 h soak | **after all milestones land** | `make soak HOURS=8 TIER=T1`, swap session, crash-free ≥ 400 sessions |
| T08 visual QA (AT-VQ-M9) | **after all milestones land** | blind scoring list in M9.md T08 + the M7.T16 citation-pill line-break check; computer use (Q-021) |
| T09 upstream sync #2 | **after all milestones land; last task** | throwaway branch `rehearsal/sync-2` |
| T10 exit | **after T09** | AT-102 strict, AT-223 ×3, all AT-NFR, report |

## Deferred to M9.T05 (collected 2026-11-08 from HANDOFF.md and the DEFERRED / "→ M9.T05" records under build/at and in commits on main)
Re-check at T05 start: `git grep -n "M9.T05\|DEFERRED" -- build/at docs/PRD-AMENDMENTS.md` and `git log --grep "M9.T05"` on main (tracks still landing add theirs).
- **Search latency (M7.T03):** AT-248 c1 T1 search answer p50 (21.5 s vs ≤ 12 s) and AT-254 first token after search (13.9 s vs ≤ 8 s), `build/at/AT-254/2026-11-04.json`. First measure the `<web_results>` prefill token count per tier (`antichat-bench search-e2e`); a large block is fixed in `search.evidence_tokens` / EvidenceBudget, never by relaxing bars. Plus the 20-query T1/T3 timing legs.
- **NFR-M5 (M2.T25):** 20-run p50 at 50 Mbps (one run 110.2 s vs 120 s, `build/at/AT-NFR-M5/2026-11-03.log`) and the 10 Mbps leg (`[EMULATED]` scaling if no link conditioner).
- **NFR-U3 (M2.T25):** the perf driver `make perf METRIC=U3 TIER=T1` (not written yet).
- **NFR-PR1 (M2.T25):** tcpdump leg (permission, `build/at/AT-NFR-PR1/pcap-status.txt`) and the journeys 2/7/8 loop during the 30-min Offline-only capture (needs XCUITest, Q-015).
- **NFR-D3 (M2.T25):** real bytes for all packs (`build/at/AT-NFR-D3/2026-11-03.log`; D4 chat-only passed).
- **NFR-F7 (M5.T14):** full path; plus P1/R1/M4 re-runs.
- **ChildSafetyCheck body-age model re-check (A-M4-T02b):** adopt a better body-only age model / operating point only if recall stays ≥ NFR-F2 and the false flag drops (lawful proxies only, D-019/Q-012).
- **Voice (M3):** AT-050 AC2 V7 at T3 (`build/at/AT-050/pending.txt`); V8 at T0/T3 (`AT-054`); V11 at T0 (`AT-056`); V9 at T0 (M3.T05 commit `9e8b70e8f`: T1 FAIL 24.2 % worst language at load 60–70, re-measure quiet); TTS T0/T3 (`636291b1f`); T3/T0/S-scaled V1–V11 repeats; U2/U5/C1/R1/R4 re-runs.
- **Photo (M4):** AT-NFR-M3 (T1, T2-24), AT-236 AC3 `IMAGE_TURN_OVERHEAD`, AT-291 AC3 `JOB_CANCEL_FREE`, AT-286 AC2 / AT-236 AC2–AC3 timing (forward keys in `tools/perf/run.py`, commit `1969fb36c`); P1/P2 real-model perf (`5a08362b1`); T3 repeats; R1/R4/R5/M4 re-runs.
- **Files / sandbox (M6):** C4 per-tier repeats; C1/R1 re-runs; the full 150-prompt create_spreadsheet model run (`c253b8ab5`); the full 20 create_presentation run (`97bb44d50`); warm-document `memory_pressure -l warn` ≤ 2 s release (`1c3be3f97`).
- **Search (M7.T16):** C1/R1 re-runs.
- **M8.T13:** NFR-U9 timing (`d027444aa`, `build/perf/runs/20261108T101211Z-U9-T1.json`: refused at load 86; indicative p50 27.5 ms / p95 65 ms in A-M8-T13a).
- **Scheduler:** the StepAside ≤ 1 s unload bound under the real-model leg (`2e5aef106`).
- **T05 load rule:** run T05 with **no other tracks active**. `make perf` goes through `tools/perf/load.py`, whose own bar (1-min load ≤ 1.0 per CPU, plus other-core and GPU-busy checks) is much stricter than `gpu-run.sh timing`'s load < 40, so a timing slot granted by gpu-run can still be refused by load.py. Under `gpu-run.sh timing` the wrapper exports `ANTICHAT_GPU_LOCK_HELD=timing` and load.py skips only its GPU-lock probe (it holds that lock itself); every other check stays.
- **Every `gpu-run.sh timing` exit 75 (`DEFERRED`)** recorded by any track, plus second-tier repeats (T0/T2/T3) of numbers measured only at T1, and the 1180×820 and Reduce Motion/Transparency capture repeats.

## Gotchas
- `make test-unit` runs package tests where `Bundle.main` is the test runner: `CopyKey` returns English there. Language behaviour is checked in-process (`at-223-probe.sh <lang>`), not in package tests.
- Typed confirmation words (RESET, DELETE, UNINSTALL, REMOVE) are compared in English by the code: translations keep them English.
- `set.general.language.*` are native names in every language (never translated).
- Never relax a bar because of load; note the load average next to every timing number (HANDOFF).
- Tests never take focus (BackgroundRun, `no-focus-steal`); visual-QA capture is the only exception.

## Handoff
- Branch `m9/polish` (worktree `m10-release`): T01, T02, T04 and the automatable part of T03.
- Gate run (2026-11-08, load 10–15): `make test-unit` green, `make test-integration-stub` green (`TEST SUCCEEDED`), `BINARIES_SRC=$HOME/AntiChat/Binaries make audit` EXIT=0 (new checks a11y-lint, keyboard-paths, l10n-source, l10n-langs ok). `tools/at/at-223-probe.sh` passed in en/de/fr/es/nl/pt (`build/at/AT-223/<lang>/probe.json`: running language, translated placeholder, section titles, plurals "1 Seite / 5 Seiten").
- Found and fixed on the way: `InputLevelMeter` (Settings › Voice) trapped on the audio thread (main-actor tap block); a timing flake in `DictationServiceTests`.
- Open for the owner: `M9-owner-steps.md` (XCUITest legs, Inspector audit, 16 VoiceOver walkthroughs).
- Round 2 (after main e534800f): picture descriptions built (A-M9-T02a); 61 new keys translated + reviewed; a11y on the menu bar / quick panel (AX title + field label) / voice overlay (localised phase, mute and mode values) / variant strip; a11y-lint now judges a Menu by its `label:` closure (5 icon-only menus fixed) and the identifier ratchet went 115 → 48. Fixture commit `ccdd476` is on the fixtures bare repo branch `m9/polish`: push it to fixtures main only after this branch is on main. The in-process Evil-title leg doesn't switch the window to Evil in a scripted run without Evil models; it's covered by the unit test and `VoiceOverLabelTests/testEvilTitleAnnounced`.
- Next owner of M9: wait for the other milestones, then T05 → T06 → T08 → T09 → T10. Before T10, translate any keys added since (`python3 -I tools/l10n/l10n.py todo <lang>`), regenerate `keyboard-paths.yml`, re-run `at-223-probe.sh`, and run the owner steps.
