# M1 wave plan (M1.T01, T03–T27)

**Date:** 2026-10-30 · **Author:** M1.T02 build agent · **Base:** `main` after `M1.T02` (CI audits, AT runner, schemes, module skeleton). **Source:** task Inputs and "Files / modules" of [`M1.md`](M1.md), the open items of [`M0-report.md`](M0-report.md) §8 and the logged review items of [`review-M0-close.md`](../research/07-spikes/review-M0-close.md). Reordering tasks is a minor change (PRD §1.4 rule 2); this plan only orders, it changes no task.

## 0. Rules for running the waves

1. **One task = one worktree = one branch**, merged by the lead in the merge order given per wave. Every branch merges `main` first and must pass `make audit && make audit-selftest && make test-unit` before the merge (M1.T02 gate; R-241 on every commit, convention 7).
2. **GPU lock.** Only one GPU-heavy job runs at a time (`lockf /tmp/antichat-gpu.lock <cmd>`). GPU tasks are marked **[GPU]**; two GPU tasks in one wave share the lock and serialise their measurement legs, not their coding.
3. **Hot files** (more than one task writes them). Each has one rule, so a merge conflict is mechanical:

| Hot file | Writers | Rule |
|---|---|---|
| `Package.swift`, `Package.resolved`, workspace `xcshareddata/swiftpm/Package.resolved`, `tools/ci/pins.json` | T03 (swift-snapshot-testing, test-only), T07 (swiftui-introspect, only if the NFR-U5 fallback fires), T08 (Defaults 9.0.9), T09 (MarkdownView 3.0.0), T11 (vendored `CommandPaletteKit` target) | add one dependency line per task, never reorder; the lead re-resolves at merge (`swift package resolve --disable-keychain`), copies the root resolved file to the workspace (bootstrap step 6) and runs `pins-verify` |
| `docs/research/10-architecture/design-system/copy-deck.md`, `App/AntiChat/Localizable.xcstrings` | every UI task (convention 6) | deck rows are appended inside their section; `Localizable.xcstrings` is generated (T03) and is **never hand-merged**: `make design-gen` after each merge, then `copy-sync` |
| `AntiChat.xcodeproj` (generated from `project.yml`) | T12 (`llama-watchdog` helper), any task adding files under `App/` | merge `project.yml` only, then `make xcodeproj`; never hand-merge `project.pbxproj` |
| `Packages/Storage/.../Database/Migrations.swift` | T04 (`v1_core`), T15 (`v2_think_harder`), T17 (`chat.tools_json` if not in v1) | append-only migrations; the version name is fixed by merge order |
| `Makefile` | T03 (`design-gen`), T09 (`vendor-js`), T26 (`perf`), T20 (`test-offline` cases) | each replaces only its own M1.T02 stub target |
| `docs/PRD-AMENDMENTS.md`, `docs/research/STATUS.md`, `docs/research/07-spikes/S-2-effort.csv`, `docs/prd/README.md` | all | append-only; amendment IDs `A-M1-T<task><letter>` (collision-free across worktrees) |
| `Packages/UI/Sources/AntiChatUI/Conversation/ConversationView.swift` | T06 owns; T10, T12, T15, T16, T18, T19, T25 add views | new views live in their own files; the host edit is a one-line insertion |
| `Packages/UI/Sources/AntiChatUI/Composer/ComposerView.swift` | T08 owns; T15, T17, T21 add hooks | same as above |
| `Packages/UI/Sources/AntiChatUI/Window/MainWindow.swift` | T07 owns (hosts T06 conversation + T08 composer); T20, T24 | the lead wires T06/T07/T08 together at the W2 merge |
| `Packages/UI/Sources/AntiChatUI/Settings/Keys*.swift` | T08 (`Keys+Composer.swift`), T22 (consolidates into `Keys.swift`), T23, T24, T25 | after T22 every key goes into `Keys.swift` and `settings-map-check.py` |
| `tools/bench/` (`antichat-bench`) | T05 creates (`chat`), T13 (`tools`), T26 (`launch`, `idle`) | one subcommand file per task |
| `App/UITests/J02SendStreamStopTests.swift`, `J13CrashRecoveryTests.swift` | T06 creates; T19 extends J02; T12 extends J13 | merge T06 before T12 and T19 |

4. **S-2 timebox (M1.T01).** Opened at the start of M1.T02 (`docs/research/07-spikes/S-2-shell-parity.md`). Every session on T02–T11 appends a row to `S-2-effort.csv` (8 h = 1 day). The gate is a barrier at the start of W5 (or day 10, whichever is first).
5. **If the S-2 gate fails** (ratio > 2.0 → D-012 F1, major amendment, stop and ask): only the base-independent tasks continue (T12, T13, T14, T16; architecture §10). UI work started in W5 (T15, T18 UI halves) is then parked, not merged.

## 1. Dependency graph (task → tasks it needs)

| Task | Needs | Base-independent (survives F1)? |
|---|---|---|
| T03 Design system | T02 | no |
| T04 Storage v1 | T02 | yes (Storage) |
| T05 EngineProtocol, XPC, MLX, ScriptedEngine | T02 | yes |
| T06 TurnController | T04, T05 | partly (Harness yes, UI no) |
| T07 Main window, sidebar | T03 | no |
| T08 Composer | T03 | no |
| T09 Renderer | T06 (deltas), T03 | no |
| T10 Actions, versions, edit, branch | T04, T06, T09 | no |
| T11 ⌘K palette + FTS | T04 (FTS), T07 (window) | no |
| T12 llama-server supervision, restart | T05 (T06 for the UI notice + J13) | yes |
| T13 Conformance + tool eval | T05, T12 | yes |
| T14 Prompt layer | T05, T12, T13 | yes |
| T01 S-2 gate | T02–T11 | n/a |
| T15 Think harder | T13, T14 (T08 for the toggle) | no |
| T16 Tool loop, ApprovalCard | T13, T14 | yes (Harness) |
| T17 + / slash / @ menus, chips | T08, T16 | no |
| T18 Context usage, compaction | T04, T14 | partly |
| T19 Titles, sidebar status, queues | T06, T07, T09, T16 | no |
| T20 Incognito | T04, T06, T19 | no |
| T21 Draft autosave | T04, T08, T20 | no |
| T22 Settings, General, Personalization, Archived | T07, T11, T14 | no |
| T23 Appearance | T03, T22 | no |
| T24 Shortcuts, menus, windows | T07, T20, T22 | no |
| T25 Provenance + Model info | T04, T05, T06, T22 (Advanced row) | no |
| T26 Felt-speed + M1 NFR set | T05, T13 (bench); every instrumented flow for the runs | n/a |
| T27 Visual QA, AT-VQ-M1, exit | all; AT-VQ-M0 first (Q-021) | n/a |

## 2. Waves

Critical path: **T05 → T12 → T13 → T14 → T16 → T19 → T20 → T24 → T26 → T27** (≈ 5+5+4+4+4+3+3+4+4+3 = 39 working days if strictly serial). The UI chain (T03 → T07/T08 → T09 → T10/T11 → gate) runs beside it.

### W1 — foundations (3 tasks + 1 side item, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T03** Design system | `Packages/Design/Sources/AntiChatDesign/{Tokens,Components}/`, `Packages/Design/Tests/`, `tools/design/{gen-tokens,gen-xcstrings}.py`, `App/AntiChat/Localizable.xcstrings`, copy-deck §2–§5/§8–§9, `Package.swift` (snapshot-testing, test-only), Makefile `design-gen` | owns the copy pipeline; also fixes **CR-P-10** (freeze the tiny-MLX tokenizer corpus to a committed snapshot instead of the living `copy-deck.md`, which T02 and every UI task edit) |
| **T04** Storage v1 | `Packages/Storage/Sources/AntiChatStorage/{Database,Tree,Import,Records,Repositories}/`, `Packages/Storage/Tests/`, `tools/fixtures/gen-chats.py` | uses plain `Int64`/UUID ids or waits for T05's `IDs.swift` at merge; promotes the M0.T11 importer |
| **T05** Engine contract + MLX + ScriptedEngine **[GPU]** | `Packages/EngineProtocol/`, `Packages/Foundation/Sources/AntiChatFoundation/{AntiChatError,RecoveryAction,AppLog,Signposts,IDs}.swift`, `Packages/Engines/Sources/AntiChatEngines/LLM/{EngineAdapter,MLXAdapter,ScriptedEngine,DeltaBatcher}.swift`, `Packages/EngineHost/`, `App/EngineHelper/main.swift`, `Packages/Harness/.../Engine/EngineClient.swift`, `fixtures/scripts/*.jsonl`, `tools/bench/` (`antichat-bench chat`), `App/IntegrationTests/XPC*Tests.swift` | fixes **CR-S-22, CR-S-24** (Listener cancel gap, `SessionBox` sync) and **CR-S-25** (undecodable `ServerMessage` → stream error, not a hang); writes the `R241PathTests` chat leg skeleton (A-M1-T02a d) |
| *X1* M0 carry-overs (small, no task file) | `tools/fixtures/make-ocr.py` → `fixtures/images/ocr/` (Q-013; Pillow is now in the tools venv), `tools/bootstrap.sh` (**CR-T-14** `.ok` stamp re-hash), `tools/m0/*.sh` + `tools/eval/pairs.py` (**CR-P-05/06/07/08/09/12/14**) | only M0 tooling and fixtures; no overlap with W1 tasks. Fixtures-repo write needs `-c protocol.file.allow=always` (A-M0-05) |

Merge order: T04 → T05 → T03 → X1 (T03 last so `make design-gen` runs once on the merged deck).

### W2 — first vertical slice (4 tasks, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T06** TurnController | `Packages/Harness/Sources/AntiChatHarness/Turn/{TurnController,TurnState,StreamPersister,StatusLineModel}.swift`, `Packages/UI/Sources/AntiChatUI/Conversation/{ConversationView,UserBubble,AssistantMessageView,PendingDot,StatusVerbView,InterruptedNotice}.swift`, `App/UITests/{J02SendStreamStopTests,J13CrashRecoveryTests}.swift` | owns `ConversationView`; closes AT-004 and AT-NFR-S2 |
| **T07** Main window, sidebar, empty state | `Packages/UI/Sources/AntiChatUI/{Window,Sidebar,Empty}/`, `Conversation/{TranscriptList,JumpToBottom,StartSeparator}.swift`, `App/UITests/{WindowLayoutTests,SidebarChatManagementTests}.swift` | owns `MainWindow`; lead wires T06 + T08 into it at merge |
| **T08** Composer | `Packages/UI/Sources/AntiChatUI/Composer/{ComposerView,ComposerTextView,ComposerModel,SendStopButton,PasteAttachmentCard,ComposerStatusRow}.swift`, `Settings/Keys+Composer.swift`, `Package.swift` (Defaults), `App/UITests/ComposerTests.swift` | send action is a closure; T06's `TurnController.send` binds at merge |
| **T12** llama-server supervision, restart **[GPU]** | `Packages/Engines/Sources/AntiChatEngines/LLM/{LlamaServerSupervisor,LlamaServerAdapter,LlamaFaultClassifier,LlamaWatchdog}.swift`, `App/EngineHelper/llama-watchdog/`, `project.yml` (watchdog copy), `Packages/Harness/.../Engine/{EngineSupervisorClient,LaunchRecovery,MemoryFitGuard}.swift`, `Conversation/EngineRestartedNotice.swift`, `App/IntegrationTests/{LlamaServerSupervision,HelperRestart,LaunchRecovery,MemoryFit}Tests.swift` | fixes **CR-S-23** (`setPolicy` ordering), **CR-S-28** (pipe write end before `FD_CLOEXEC`), **CR-S-26** (image poll timeout/cancellation, with M2); merge **after T06** (J13 + InterruptedNotice) |

Merge order: T06 → T07 → T08 → T12.

### W3 — rendering, palette, conformance (4 tasks, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T09** Streaming renderer | `Packages/UI/Sources/AntiChatUI/Renderer/`, `Resources/mermaid/`, `Vendor/js/`, Makefile `vendor-js`, `Package.swift` (MarkdownView), `fixtures/render/golden-100/`, `tools/visual/{capture.sh,layout-jump.py}`, `App/UITests/RendererStreamingTests.swift` | emits the `rendererApply` signpost the S-2 gate needs |
| **T11** ⌘K palette + FTS | `Vendor/CommandPaletteKit@69acb38/` (+ `.upstream`), `Package.swift` target, `Packages/UI/Sources/AntiChatUI/Palette/`, `Packages/Storage/.../Search/FTSSearch.swift`, `Benchmarks/PaletteBenchmarks/`, `App/UITests/J09PaletteTests.swift` | vendoring goes through `tools/vendor-sync` + patch-lint |
| **T13** Conformance + tool eval **[GPU]** | `App/IntegrationTests/Conformance/`, `Packages/Engines/.../LLM/{ToolFormat,GrammarBuilder,RawToolSyntaxScrubber}.swift`, `fixtures/prompts/{conformance/,antichat-tools-200.jsonl}`, `tools/bench/tool-eval.swift` | closes **K-NEW-ENG-7** (pin + suite plan); AT-229, AT-231 |
| **T25** Provenance + Model info (Harness half) | `Packages/Harness/.../Turn/ProvenanceRecorder.swift`, `ProvenanceRecorderTests.swift` | the `ModelInfoPopover` + `showModelInfo` row wait for T22 (W7); small |

Merge order: T13 → T09 → T11 → T25a.

### W4 — versions and prompt layer (2 tasks, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T10** Actions, regenerate, edit, branch | `Packages/UI/Sources/AntiChatUI/Conversation/{ActionBar,RegeneratePopover,VersionSwitcher,VersionsViewer,DislikeMenu,InlineEditor,ReportProblemSheet}.swift`, `Pasteboard/MessageCopier.swift`, `Packages/Harness/.../Turn/{Regenerate,Edit,Branch}Service.swift`, `App/UITests/J03EditVersionsTests.swift` | last S-2-scope task |
| **T14** Prompt layer **[GPU]** | `Packages/Harness/Sources/AntiChatHarness/Prompt/`, `Packages/Harness/Tests/.../{PromptStability,PromptSnapshot}Tests.swift` + `__Snapshots__/`, `App/IntegrationTests/PrefixReuseTests.swift` | its snapshots switch on **R-241 rule 4** (`system-prompt-{normal,evil}*.txt`, A-M1-T02a d); re-measures TTFT with the prefix cache for **A-M0-11** (K-004/K-006/K-008) — records numbers, the ask happens after T26 |

Merge order: T14 → T10. Starting T14 in W3's tail (after T13's tool schemas land) is allowed.

### W5 — S-2 gate barrier + harness (gate, then 3 tasks)

| Task | Main files / modules | Notes |
|---|---|---|
| **T01** S-2 gate **[GPU]** (sequential, first) | `docs/research/07-spikes/{S-2-shell-parity.md,S-2-effort.csv}`, `registry/spikes.json`, `tools/at/s2-effort.py`, `App/UITests/S2ShellParityTests.swift`, `build/at/AT-M1-S2/` | runs right after T10 + T11 merge (or day 10). Fail → §0 rule 5 |
| **T16** Tool loop, ApprovalCard | `Packages/Harness/Sources/AntiChatHarness/Tools/`, `Conversation/{ActivityLineView,ApprovalCardView}.swift`, `App/UITests/J12ToolApprovalTests.swift` | base-independent; may start during the gate |
| **T15** Think harder | `Harness/Prompt/ThinkHarderPolicy.swift`, `UI/Composer/ThinkHarderToggle.swift`, `UI/Conversation/ReasoningDisclosure.swift`, migration `v2_think_harder` | after the gate passes |
| **T18** Context usage + compaction | `Packages/Harness/Sources/AntiChatHarness/Context/`, `Conversation/{ContextUsageIndicator,SummaryNotice}.swift`, `App/IntegrationTests/CompactionSoakTests.swift` | Harness half may start during the gate |
| *T26a* perf infrastructure (split of T26, minor reorder) | `tools/perf/{run.py,report_schema.json,compare.py,gen-targets.py,nfr_targets.json}`, `Packages/Foundation/Sources/AntiChatFoundation/Perf/{Signposts,HitchCounter}.swift` (moves T05's `Signposts.swift`), Makefile `perf` | lets every later task close its `make perf` leg as it lands instead of waiting for T26; fixes **CR-T-12** (`--replace` semantics) and **CR-T-13** (temp + rename) |

Merge order: T01 verdict → T16 → T26a → T15 → T18 (T15 before T18 for the migration order).

### W6 — composer menus, titles/queues, settings (3 tasks, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T17** + / slash / @ menus, chips | `Packages/UI/Sources/AntiChatUI/Composer/{Menus/,AddMenu,TriggerDetector,ToolChipsModel,ToolChipView}.swift`, `Packages/Harness/.../Tools/{SlashCommandRegistry,AtFileMen…}.swift`, `chat.tools_json` | Harness `Tools/` is T16's dir: new files only |
| **T19** Titles, sidebar status, queues | `Packages/Harness/.../Turn/{TitleService,FollowUpQueue,ReadinessQueue,CompletionCoordinator}.swift`, `Conversation/QueuedBubble.swift`, `Sidebar/ChatRow.swift` (T07's file), `App/UITests/{J02 (extended),QueueTests,SidebarStatusTests}.swift` | AT-003, AT-010, AT-014, AT-299 |
| **T22** Settings window | `Packages/UI/Sources/AntiChatUI/Settings/{SettingsScene,SettingsSidebar,SettingsRegistry,SettingsSearch,Keys}.swift`, `Settings/Sections/*`, `Settings/Privacy/`, `Harness/Chats/AutoArchiveService.swift`, `tools/ci/settings-map-check.py` | absorbs `Keys+Composer.swift`; re-runs AT-005 leg (4) via T11 provider and AT-012 leg (2) |

Merge order: T19 → T17 → T22.

### W7 — incognito, appearance, model info (3 tasks, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T20** Incognito | `Packages/Storage/.../StoreRouter.swift`, `Packages/Harness/.../Incognito/`, `UI/Window/IncognitoFrame.swift`, `UI/Toolbar/IncognitoButton.swift`, `UI/Empty/IncognitoEmptyState.swift`, `tools/ci/{disk-diff.py,fs-usage-audit.sh}`, `fixtures/prompts/copy-check/incognito-phrases.txt`, first `make test-offline` case | `fs_usage` leg is `[PERM: sudo]` → `not run: permission` if `sudo -n` fails (PRD §1.5) |
| **T23** Appearance | `Settings/Sections/AppearanceSection.swift`, `Packages/Design/Sources/AntiChatDesign/Environment/`, OpenDyslexic font resource, `AppearanceEnvironmentTests.swift` | |
| *T25b* Model info UI | `UI/Conversation/ModelInfoPopover.swift`, `showModelInfo` in `Keys.swift`, `App/UITests/ModelInfoTests.swift` | closes AT-234 |

Merge order: T20 → T23 → T25b.

### W8 — drafts, shortcuts and windows (2 tasks, parallel)

| Task | Main files / modules | Notes |
|---|---|---|
| **T21** Draft autosave | `Packages/Storage/.../Drafts/DraftStore.swift`, `UI/Composer/DraftBinding.swift`, `DraftStoreTests.swift`, `App/UITests/DraftTests.swift` | uses T20's `StoreRouter` (no incognito drafts) |
| **T24** Shortcuts, menus, windows | `Packages/UI/Sources/AntiChatUI/{Shortcuts,Menus}/`, `Window/WindowRestoration.swift`, `Settings/Sections/ShortcutsSection.swift`, `App/AntiChat/AppDelegate.swift` | closes AT-008 leg (3) via AT-103 |

Merge order: T21 → T24.

### W9 — NFR set (sequential) **[GPU]**

| Task | Main files / modules | Notes |
|---|---|---|
| **T26** (b) measurement | `App/UITests/Perf/`, `Benchmarks/{PaletteBenchmarks,PromptBenchmarks}/`, `tools/bench/` (`launch`, `idle`), `build/perf/report.json` | closes every forward `make perf` leg (AT-003/004/010/011/012, convention 9); with T14's numbers, decides whether **A-M0-11** (major) is asked |

### W10 — exit (sequential)

| Task | Main files / modules | Notes |
|---|---|---|
| **T27** Visual QA, AT-VQ-M1, exit | `tools/visual/{grid,contrast-sampler,ocr-copy-check,grayscale}.py`, `tools/visual/vq-0{2,3,9}-*.md`, `vq-10-settings.md`, `build/visual/<version>/parity-M1.md`, `docs/prd/M1-report.md` | **AT-VQ-M0 must pass first** (pending Q-021, computer-use approval); step 8 re-runs every AT in full; `/code-review` high + triage (PRD §1.4 rule 5) |

## 3. Parallelism summary

| Wave | Tasks | Max concurrent worktrees | GPU tasks |
|---|---|---|---|
| W1 | T03, T04, T05 (+ X1) | 4 | T05 |
| W2 | T06, T07, T08, T12 | 4 | T12 |
| W3 | T09, T11, T13, T25a | 4 | T13 |
| W4 | T10, T14 | 2 | T14 |
| W5 | T01 gate → T16, T15, T18, T26a | 4 | T01 |
| W6 | T17, T19, T22 | 3 | — |
| W7 | T20, T23, T25b | 3 | — |
| W8 | T21, T24 | 2 | — |
| W9 | T26b | 1 | T26 |
| W10 | T27 | 1 | — |

Ten waves instead of 26 serial tasks. Sequential by necessity: the S-2 gate (barrier for the UI tasks after it), T26b (needs every instrumented flow) and T27 (needs everything plus AT-VQ-M0).

## 4. M0 carry-overs and logged review items → owner

| Item | Owner | Source |
|---|---|---|
| AT-VQ-M0 visual run (parts A/B/C) | before T27 (Q-021, computer-use approval; not blocking W1–W9) | M0-report §8 |
| A-M0-11 scaled TTFT → re-measure with prefix cache, then ask | T14 (measure) + T26b (C1/C1b) | S-3, K-004/K-006/K-008 |
| K-NEW-ENG-7 engine pin + suite plan | T13 | M0-report §3 |
| `fixtures/images/ocr/` committed (Q-013) | X1 (W1) | M0-report §8 |
| CR-S-22, CR-S-24, CR-S-25 (EngineHost Listener, `EngineClient` decode) | T05 | review-M0-close |
| CR-S-23, CR-S-26, CR-S-28 (`setPolicy`, image poll, pipe `FD_CLOEXEC`) | T12 | review-M0-close |
| CR-T-12, CR-T-13 (perf scripts write semantics) | T26a | review-M0-close |
| CR-T-14 (bootstrap `.ok` stamp) | X1 | review-M0-close |
| CR-T-15 (hf-fetch 206 offset) | **done in T02** | A-M1-T02a k |
| CR-P-05/06/07/08/09/12/14 (M0 AT scripts, eval pairs) | X1 (CR-P-09 no longer recurs for M1 ATs: `tools/at/run.sh` truncates) | review-M0-close |
| CR-P-10 (tiny-MLX tokenizer trained on the living copy deck) | T03 | review-M0-close |
| R-241 rule 4 (prompt snapshots) / rule 5 (runtime trace) | T14 / T05 + T06 (chat leg), M4 (image leg) | A-M1-T02a d |
| Self-hosted runner registration (K-NEW-ARCH-3) | human step (PRD §9); meanwhile local `make` runs with logs | ci.yml |
