# M8 card: migrations, memory, projects, import/export, privacy, diagnostics, storage, Mac integration

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M8.md`. This card doesn't repeat task steps. Where it and `M8.md` disagree on a repo fact, the card is right (checked against the tree on 2026-11-04, `integration/m0 @420d5ff7`).

## What M8 delivers
Safe schema evolution (backup before every migration, auto-restore, 7 daily backups, newer-data refusal). Topic memory with a frozen per-chat snapshot and a propose-only background review. Projects (instructions, files, linked folder, project-only memory) with a whole-vs-retrieval switch. ChatGPT/Claude import, export-all + round trip, single-chat share. Privacy & Data page, diagnostics (opt-in crash prompt, logs, Report a problem), Storage dashboard, Remove everything, Uninstall. Then (after voice): notifications, menu bar + quick panel, the JIT permission matrix.
**Exit:** `M8.md` header "Exit" row minus the D-026 moves below.

## Split (D-026, BUILD-ORDER chunks 12, 13, 20; dependency note 7)
- **M8 core, before M3:** chunk 12 = T01, T02, T03, T04, T05 · chunk 13 = T06, T07, T09, T10, T11.
- **M8 rest, after M5:** chunk 20 = T08 (Privacy page: uses the permission service vendored in M3), T12 (notifications, voice/job events), T13 (menu bar, quick panel), T14 (permission matrix only), T16 (exit).
- **Moved to M11 (`M11.md`):** all of T15 (AT-055, AT-061, AT-063, AT-107, AT-110 leave the exit) and T14's system-wide dictation (AT-051 leaves; `PermissionCoordinator` keeps the Accessibility/Input Monitoring kinds). `MemoryImporter.swift` (R-063) is therefore M11; keep it as an allowed (absent) entry in `memory-write-paths.py`.
- T01 first: every later task adds a migration, and it protects the owner's try-out chats.

## Per task (essentials; steps in `M8.md`)
- **T01 migrations + backups (R-301, AT-301).** `MigrationRunner` runs before the writable pool: guard (newer data → refuse, write nothing) → `pre-<head id>-<ts>.sqlite` backup (fsync + `integrity_check`) → migrate → on throw restore the backup, `failed-<ts>.sqlite` kept. `BackupService`: daily after ≥ 60 s idle, keep 7 daily + 3 pre-update; restore = `pre-restore` copy + swap + relaunch. Windows `NewerDataWindow`, `MigrationFailedWindow`; Settings › Privacy & Data › Restore from backup. Fixtures `fixtures/chats/db/<id>.sqlite` per identifier + `migrations.lock` + `future-v999` (DELETE and WAL). Absorbs M6.T01's `backupBeforeMigrating` (one code path).
- **T02 memory core (R-242, R-243, R-060 AC1/3/5; AT-242, AT-243).** Tables `memory_topic`, `memory_item`, `memory_event`, `chat.memory_snapshot_*`; tool `memory` (view/save/delete); `MemoryUpdateDecider` (cosine ≥ 0.92 update, ≥ 0.60 → ported mem0 prompt, else add); sensitive categories stored only when the setting is on (privacy choice, not a filter; D-006); frozen snapshot ≤ 2,000 chars in `stable.memory`, in-chat writes in `volatile.memory`. Real-model bar: paraphrase ≥ 0.80, distinct ADD ≥ 0.90 (T1, `chat-9b-q4`, GPU lock).
- **T03 memory UI (R-060, R-246; AT-060, AT-246).** Inline "Memory updated ▸" + Undo; Settings › Personalization › Memory (On/Paused/Off, sensitive toggle, browser, typed RESET); per-chat Memory off before the first message; incognito/Evil never read or write (unless `useMemoryInEvil`); `MemoryReviewService` writes only `memory_suggestion` pending rows (AC power, idle ≥ 300 s, default off on T0–T1).
- **T04 projects (R-064, AT-064).** `project`, `project_instruction`, `project_file`; page (chats, files ≤ 100 / 2 GB or linked folder + FSEvents, instructions frozen per chat), move chat, delete keep-or-delete, project-only memory (default global).
- **T05 project context (R-245, AT-245).** ≤ 30 % of context → whole files, else hybrid RRF (+ rerank on T2+) with page citations; `qa-50` ≥ 40/50 on T1 with a correct citation.
- **T06 import (R-092, AT-092).** ChatGPT + Claude export zips onto the message tree (`TreeMapper` replaces the M0 mappers); 1 GB ≤ 2 min, cancellable, re-import dedups, unsupported parts kept as text.
- **T07 export (R-093, R-019; AT-093, AT-019).** Export-all zip (JSON + Markdown, projects, memory, settings, optional media), lossless re-import (`db-canon.py` diff from T01); single-chat share (Markdown/PDF/HTML/image, no network, Evil watermark).
- **T08 Privacy & Data (R-091, AT-091, AT-NFR-PR4)** — after voice.
- **T09 diagnostics (R-218, AT-218, AT-NFR-PR2).** Zero telemetry by default; opt-in crash prompt with preview; redacted log export; Report a problem; System report.
- **T10 storage (R-205; AT-205, AT-NFR-D7, AT-NFR-D8).** 8-category bar ±1 % of `du`, per-model rows, Clean up, Models folder show/move/repair, Remove everything.
- **T11 uninstall (R-226, AT-226)** + `make test-install`.
- **T12 notifications (R-108, R-042; AT-108, AT-042)**, **T13 menu bar + quick panel (R-105, R-106; AT-105, AT-106, AT-NFR-U9 ≤ 150 ms p95)**, **T14 JIT matrix (R-109, AT-109)** — after voice.

## Repo reality
- **Migrations are one file:** `Packages/Storage/Sources/AntiChatStorage/Database/Migrations.swift` (`v1_core … v14_files_m6`, plus `Migrations.identifiers`). Not `Migrations/v<N>_*.swift`. The frozen DDL is `Packages/Storage/Schema/v1_core.sql` (`MigrationV1Tests`); every schema change regenerates it.
- **Renumbering (parallel branches):** name M8 migrations distinctively (`v<N>_memory`, `v<N>_projects` …) and expect the lead to renumber at merge. A renamed identifier is registered through `Migrations.renamed` (`new: [old]`, GRDB `merging:`), and the lock test fails if an identifier in `migrations.lock` disappears without that entry. Example already needed: `v2_tool_permission` → `v3_tool_permission` (M1 renumber; the owner's Release container still has it).
- **DB opens:** `AppDatabase.onDisk(at:)` / `openDefault()`; the app opens through `LaunchRecovery.openDatabase` → `ChatEnvironment.open` in `App/AntiChat/AntiChatApp.swift`, which used to fall back silently to an in-memory DB on any error. T01 replaces that with `AppLaunchState`.
- **Debug vs Release containers:** Release `~/Library/Application Support/AntiChat`, Debug `…/AntiChat-Dev`, tests `-ANTICHAT_DEV_CONTAINER`. Never touch the Release container except read-only (`?immutable=1`) or on a clone.
- **Knowledge** has `Index/`, `Intake/`, `OCR/`, `Vision/`; `Memory/` and `Projects/` are new. Settings sections live in `Packages/UI/Sources/AntiChatUI/Settings/Sections/*Section.swift` (Privacy already has archived chats, delete all, network activity, Offline only).
- **Feature flags:** `AntiChatFoundation/FeatureFlags.swift` (`FeatureFlag` enum, `ff.<name>`); add the M8 cases as each task lands.
- **Copy:** `Packages/Design/Sources/AntiChatDesign/Copy/CopyDeck.swift` + `docs/research/10-architecture/design-system/copy-deck.md` + `App/AntiChat/Localizable.xcstrings` (`tools/ci/copy-sync.py`). Same commit.
- **Fixtures:** `fixtures/` is a submodule (bare `~/AntiChat-fixtures.git`, `*.sqlite` via LFS). Commit on a branch inside the worktree's own submodule clone; don't move the shared `~/AntiChat/fixtures` checkout.
- **CLI:** `tools/antichat-cli` (hand-rolled args). T01 adds `db make-fixture` (DEBUG).
- **XCUITest can't start here (Q-015):** write the UI tests, run host/probe tests, record the XCUITest leg as `pending (Q-015)`.

## Cross-task contracts
1. Every M8 migration adds its fixture DB and its `migrations.lock` line (T01 DoD); migrations are append-only and never edited.
2. Backups and the guard never run for incognito in-memory DBs; the newer-data path writes nothing.
3. Memory writes only through `MemoryTool`, `MemorySettingsViewModel`, `MemoryReviewService` (after a tap); `tools/ci/memory-write-paths.py` enforces it.
4. Frozen prefix: memory snapshot and project instructions are captured at a chat's first send and never change for that chat.
5. Incognito: no memory, no suggestions, no backups, no index jobs. Evil: memory only with `useMemoryInEvil`.
6. No filter anywhere (D-006): sensitive-topic handling is a storage setting; `make audit` must stay green.
7. Indexing and import make zero network requests (NetworkGate counter = 0).

## Verification scope (D-025)
T16 keeps every M8 AT still in v1, the PR3 and S2 re-runs, `make test-install` (remove everything, uninstall, reinstall), journeys 6/13/15/16, and the headline numbers for U9, D7, D8, PR2, PR4 at T1; `make test-unit` + `make audit`, an independent `/code-review` (high), a running-app check, and 1440×900 light/dark captures with hard checks H3–H7. Blind scoring of S-20…S-23 and the S-21 sections moves to M9.T08; NFR re-measurement to M9.T05.

## Pins and IDs to grep
GRDB 7.11.1 `b83108d` (P-platform-11); LibreChat `@8d3da9b`, mem0 `@26cdefb` (P-media-01); osaurus `@2922745` (projects port); sqlite-vec v0.1.9 `@e9f598a`, mlx-swift-lm `f5b0677` (P-media-15). Models: `chat-9b-q4` (T1 default), `embed` Qwen3-Embedding-0.6B-4bit-DWQ `@6c3ae70`, `rerank` Qwen3-Reranker-0.6B `@e61197e`. Decisions D-006, D-025, D-026; Q-007, Q-015.
