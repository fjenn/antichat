# M2 card: hardware, catalog, downloads, scheduler, Evil, onboarding, router

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M2.md`. This card doesn't repeat task steps. Where it and `M2.md` disagree on a repo fact, the card is right (it was checked against the tree on 2026-11-02).

## What M2 delivers
The app knows the Mac's hardware and tier, fetches a signed model catalog, and picks models per pack × mode. It downloads them resumably with sha256 checks into a deduplicated store. One scheduler loads and evicts every model. Evil Mode (consent, per-chat lock, red frame) goes end to end. A 4-screen onboarding reaches a first answer from the 0.8B starter model in about 2 minutes. Settings › Capabilities manages packs. `NetworkGate` + Offline only make the privacy claim provable. A semantic pre-router feeds install cards that re-run the request.
**Exit:** `M2.md` header "Exit" row. Journeys 1, 7 and 10 must pass.

## Order (dependencies; T07 runs after T10)
T01 → T06 · T02 → T03, T04, T08 · T04 → T05 → T06 → T09 · T08 → T09 → T10 → **T07** → T11 · T06 + T10 → T12 → T13 → T14 → T15 · T06 + T12 → T16 · T17 (needs T15) → T18 → T19 → T20 → T21 · T16 → T22 → T23 → T24 → T25 → T26.
Chunks (proposed in `M11-candidates.md` §D): [T01–T06] [T08 T09 T10 T07 T11] [T12–T15 T17] [T16 T18–T21] [T22–T26].

## Repo reality (the PRD text is older than M1's code)
- **Launch args** live in `Packages/Foundation/Sources/AntiChatFoundation/Debug/LaunchOptions.swift` (`enum Key`). `TestHooks.swift` doesn't exist. Add new keys there, Debug-only. `FakeHardware`, `OfflineOnly`, `UseScriptedEngine` and `ANTICHAT_DEV_CONTAINER` already exist.
- **Migrations** are one file, `Packages/Storage/Sources/AntiChatStorage/Database/Migrations.swift` (`v1_core … v4_unread`). Not `Migrations/v<N>_*.swift`. Register the next as `v5_…`, append-only. DEBUG has `eraseDatabaseOnSchemaChange = true`. On parallel merges, renumber (that already happened in M1).
- **`NetworkGate`** exists as a minimal M0 version: `Packages/Network/Sources/AntiChatNetwork/NetworkGate.swift`, with an `apply(_:)` hook and `session(for:configuration:delegate:)`. `NetworkCategory` today is `models, catalog, search, mcp, relay, updates, other`. T02 adds `connectors`, `crashReport` (R-297 names). Keep the existing call sites compiling.
- **`FeatureFlags.swift` doesn't exist.** The first task that needs a rollback flag (T11 or T13) creates `AntiChatFoundation/FeatureFlags.swift`. Flags: `autoModelUpdates, mediaStepAside, powerPolicy, warmSecondVariant, semanticSearch, evilMode, starterHandoff, preRouter, fallbackIntentCheck`.
- **Strings:** the catalog is `App/AntiChat/Localizable.xcstrings`, not `Packages/UI/.../Resources`. Run `tools/ci/copy-sync.py` after every new key, and add each key to `docs/research/10-architecture/design-system/copy-deck.md` in the same commit.
- **Makefile:** `test-unit FILTER=` passes the raw string to `swift test --filter`. T02 adds comma-list expansion (`A,B` → `'\.(A|B)(/|$)'`) and a fail-on-0-tests guard. `test-offline` currently calls `tools/offline/run.py --case`, and `tools/offline/` doesn't exist. T03 creates it and adds `STEP=` as an alias. Don't break `--case`.
- **M0 spike code to replace, not duplicate:**
  - `Platform/Downloads/{SpikeDownloader,ChunkMap,Verify}.swift`: T08 supersedes it, reusing `Verify` if it fits.
  - `Engines/Scheduler/SpikeScheduler.swift`: T12 replaces it and moves its callers to `ModelScheduler`.
- `ScriptedEngine` is at `Packages/Engines/Sources/AntiChatEngines/LLM/ScriptedEngine.swift`. T13 creates `Jobs/ScriptedImageEngine.swift`. Keep exactly one copy, because M4.T04 extends it.
- **Vendored:** `Vendor/osaurus@2922745` allow-list already holds ChipProfile, GPUMemoryBudget, ChunkedFileDownloader, ModelResidencyManager, ModelLease, MetalGate, Swap/MemoryPressure*, Onboarding DesignSystem and CapabilityQueryIntent. Check `Vendor/osaurus-allowlist.tsv` before you edit `vendir.yml`. Not vendored yet: TUFF (T09) and sqlite-vec (T16).
- **Not yet present, so the owning task creates it:**
  - `fixtures/hardware/` (T01)
  - `fixtures/catalog/test-keys/catalog-{a,b}.*` and fixture catalogs (T04). `catalog/test-keys/sparkle-test.*` is the M0 Sparkle key; don't reuse it for the catalog.
  - `Config/Endpoints.plist` (T04)
  - `site/` (T04: `make site-dev`, falling back to `python3 -I -m http.server 4321 -d site/public`)
  - `catalog/models.yaml` and `assignments.yaml` (T04). `catalog/dev.yaml` and `dev-catalog.json` are M1's dev catalog.
  - `tools/antichat-cli` (T10)
  - `fixtures/prompts/router-300.jsonl` (T22)
  - `media-100.jsonl` (T24)
- **XCUITest can't start on this Mac (Q-015, automation mode).** Write the UI tests, then run the in-process probe path M1 used (`tools/at/*-probe.sh`, `tools/at/run.sh <AT> -- <probe>`). Record the XCUITest leg as `pending (Q-015)`; don't loop on it.
- **Computer use for AT-VQ-M2 (P-CU, Q-021)** may be missing. Capture what you can with `tools/shot.sh`, `rec.sh` and `tools/visual/capture.sh`, and record the rest as pending.
- **sudo:** probe once with `sudo -n true` and never wait for a password. Without it, use the documented non-sudo path, which is authoritative: `proxy-logger.py --rate`, `nettop`+`lsof`, `disk-diff.py`, `-FakePower lowpower`, the 2× RAM read instead of `purge`. Log "not run: permission".

## Key types and interfaces (names are contracts; other tasks call them)
- **Hardware (T01):**
  - `HardwareProfile {chip, ramGB, W, B, tier, subband, speedClass, bandwidthGBs, freeDiskGB, …}`
  - `TierClassifier.classify(facts:)` is pure.
  - `HardwareProfile.fits(residentGB:mustStayGB:)` is the single eligibility rule. T06, T18 and T24 use it.
- **Network (T02/T03):**
  - `NetworkGate.session(for:)` tags requests with the `"ac.category"` property.
  - `GateURLProtocol` refuses with `AntiChatError(.network, "network.blockedByOfflineOnly")`.
  - `NetworkPolicyStore` (`net.category.<name>`, `net.offlineOnly`), `network_activity` table, `PathStatus`.
  - `TurnNetworkLedger` lives in Harness, fed through the `NetworkEventSource` protocol.
- **Catalog (T04–T06):**
  - `catalog-tool {keygen,build,lint,sign}` at the root `Package.swift`.
  - Schema v2 per blueprint E.2.2: `catalog_version, issued, expires, revoked[], sources[], chunk{}`, roles `chat_fast, embed, rerank, title, csam_check`.
  - `CatalogVerifier` (keys A **or** B), `CatalogStore.refresh() / isLoadable(id) / mayInstallNew`.
  - `ModelSelector.select(profile, enabledPacks, modes, overrides) -> Selection`; `FitRule` → `Fits / Tight / TooLarge`.
- **Store (T08–T10):**
  - `DownloadCoordinator` (actor, `download` table, 4 lanes × 64 MB, bitmap resume), `InstallQueue`, `ProgressAggregator`, `DiskPreflight.check(total:)`, `MenuBarProgressModel`.
  - `BlobStore.commit(partial:sha256:)`, `InstallView.materialize(model)` (atomic rename), `GarbageCollector.sweep()` (mark-and-sweep, no refcounts), `SpaceAccountant.frees(_:)`, `Repair.run(_:)`.
  - `antichat-cli models install|list|remove|gc|verify|rollback`, `catalog sizes`, `index rebuild`.
- **Scheduler (T12–T15, helper side):**
  - `ModelScheduler.ensureLoaded(role:model:ctx:) -> ModelLease`, `isIdle(pack:)`, `releaseIdle()`.
  - EngineProtocol `Lifecycle.swift`: `Warmup{pack,mode}`, `Evict`, `SetPolicy{budgetB, keepAlive, lowPower, allowOverBudget}`, event `loadState`.
  - `LlamaRouterControl` (`POST /models/load|unload` only).
  - `StepAside`, `LighterFallback`, `BudgetOverride`, `PressureMonitor`, `PowerPolicy`, `ThermalPolicy`, `PowerAssertion`, `ModeSwap`, `WarmVariant`, `PredictiveWarmup`.
- **Search (T16):** `EmbeddingService` / `RerankService` (XPC `EmbedRequest` / `RerankRequest`), tables `chunk / chunk_vec (vec0 float[1024]) / chunk_fts`, `HybridRetriever.search(q)` (FTS5 + KNN → RRF k=60 → optional rerank), `BackgroundJobQueue.enqueue(_:for:)` (the only door for title/index/embed/memory jobs).
- **Evil (T17/T19):** `EvilModeManager.continueInNewChat(from:mode:)`, `ConsentStore` (`evil_terms`, version = sha256 prefix of `onb.3.body` + `onb.3.adult`), trigger `chat_mode_lock`, `ToneClause` (via `ToneSentenceProviding`), `EvilVariantPlanner.plan(selection)`, `EvilReadiness`.
- **Onboarding (T18/T20):** `OnboardingModel` (pure view model), `StarterHandoff` (switches at the next turn boundary, via `ModelReadinessProviding`), signposts `onboardingContinue` → `firstToken` (NFR-M5).
- **Router (T22–T24):** `PreRouter`, `RouteScorer`, `RouteDecision {scores, forcedTool?, toolsToExpose}` → TurnController, `ChipOverride` (`tool_choice = required`), `ToolPruner` (≤ 4 tools on T0–T2), `FallbackIntentCheck` (≤ 1 re-ask, then `MediaOfferChip`), `InstallCardPolicy` + `PendingRequestStore` (via `PackInstalling`).

## Cross-task contracts (break one and a later task fails)
1. **Import edges:** Harness never imports Platform or Network, and the helper's Engines never imports Platform. Harness declares a small protocol, `AntiChatUI` conforms, and the composition root injects it. The scheduler gets B, keep-alive and power only via `SetPolicy`. The only new edge allowed is Platform → `TUFFVendored`.
2. **The scheduler is the only loader.** llama-server runs with `--no-models-autoload --sleep-idle-seconds -1` and explicit `-c` / `-ngl 999`. Nothing loads behind its back. Keep the `M2.T12: scheduler wiring` commit separate (it's the rollback point).
3. **Every byte goes through `NetworkGate`.** Hugging Face is anonymous only: `tokenProvider: .none`, never `Authorization`, never a gated repo, `/resolve/<40-char commit>/` URLs. No background `URLSession`.
4. **Sizes and disk:**
   - Shown size = Σ unique sha256 − already present. Never "0.0 GB".
   - "frees X GB" = `SpaceAccountant`, within ±1% of `du`.
   - One disk rule, free ≥ total + 10 GB (NFR-D2), at every entry point: onboarding, pack add, Evil add, catalog update, install card.
5. **Queue order (E.2.4):** `chat_fast` alone → chat + embed → Voice → Photo + `csam_check` → Video → Evil variants. Dedup by sha256 across packs and modes.
6. **Incognito:** no `network_activity` rows, no KV snapshot, no title/index/embedding/memory jobs.
7. **Evil:**
   - It never uses `chat_fast` and never gets a weaker stand-in. An unavailable pack shows `evil.notAvailablePack`.
   - Photo/Video Evil slots point at the Normal ids (Q-009 a).
   - The prompt differs from Normal **only** by the catalog `tone_sentence`.
   - No filter, safety prompt or keyword list anywhere (R-241, D-006). `make audit` checks this.
8. **Fail closed:** on a bad catalog signature, keep the last good catalog or the baseline and install nothing new. On an expired catalog, warn and keep installed models, with `mayInstallNew == false`. On a sha mismatch, re-fetch once, then `download.failed`. A corrupt blob at load shows `model.corrupt` + Re-download and never crashes.
9. **Closing legs:**
   - AT-220 part 2 closes in **T08** (`SourceFallbackTests`).
   - The zero-enqueue half of AT-NFR-SEC7 closes in **T09**.
   - AT-NFR-SEC2 closes in **T10**.
   - AT-NFR-D2 closes in **T19**.
   - AT-209 AC2 and AT-NFR-PR1 §7.2 close in **T25**.
   - Note each "closes in" in the commit body.
10. **Fixture sets are frozen before fitting.** Freeze `router-300` (seed-3 split, 100 calib / 200 test) with its sha256 in `SOURCES.md` before any threshold fitting. M4.T07 reuses the same split, so never make a second set. `media-100` is newly written, not copied from router-300.
11. **Copy:** every new string is a copy-deck key, added to the deck and the xcstrings file in the same commit (H5). Onboarding copy is verbatim VISION §1.2 via `onb.*`.

## Outcomes
- **T23b (R-235 AC2), 2026-11-03:** a cheap in-process embedder was tried and rejected on AC4. static-similarity-mrl-multilingual-v1 int8-256 was CPU-only and sub-ms, but the T1 full stack fell to video R 0.83 (stopped at 168/200). NLContextualEmbedding and potion-multilingual were weaker router-only. Qwen3-Embedding stays; its call moved off the send path: `RoutePrefetch` embeds the draft on composer debounce, and a send scores the cached vector on the CPU (p95 8.4 ms, CPU-only, unscaled). An unprefetched send waits ≤ `PreRouter.sendBudget` (20 ms, lowered to 10 ms on 2026-11-03: cold p95 29.6 ms at 20 ms on a quiet host), then goes out unscored with the default tools. P/R unchanged (same embedder and thresholds).

## Gotchas
- `B = min(W, RAM − H_os − 0.5)`. Take H_os from hardware-tiers §2.1. Numbers come from `nfr.md` by ID; never retype them.
- Never spawn `system_profiler` in the app. The probe budget is < 50 ms, and `MicroProbe` runs only for unknown chips, off-main.
- The swizzle install must be the first line of `AntiChatApp.init()`, unless B1 is approved; it was (D-026), so use `InjectionCoverageTests` (swizzle returns only if a dependency cannot be injected).
- Generate catalog keys **without the Keychain** (`catalog-tool keygen`). `generate_keys` would trigger a Keychain prompt, which is user input. `PinnedKeys.swift` gets `#error` under `RELEASE` if the test fingerprints are present.
- Never publish a lower `catalog_version`. To undo, publish version + 1 with the old content.
- Symlinked install views may fail for some engines. Use `clonefile` per engine (catalog `symlinks: false`).
- Keep the `Models/` folder excluded from Time Machine. The DB is not excluded.
- Router scores never block a request (R-241); they only expose and force tools.
- Evil models: `evil-T1` is a llama.cpp GGUF via router, and the T1 Normal model is MLX. The C7 swap therefore crosses engines; that's intended.
- Keep GPU runs serial with `lockf /tmp/antichat-gpu.lock …`. The model budget is ≤ 150 GB (D-003).

## Pins and IDs to grep
- **Code pins:**
  - `osaurus@2922745`, `swift-huggingface 199277c` (Xet trait off), `swift-sdk 0.12.1`, `FluidAudio 0.18.0`, `Sparkle 2.10.1 (ab7d712)`, `Yams 6.2.2`
  - `llmfit@d52eac4` (bandwidth table), `Wormholy@4f3a7a4` (swizzle), `TUFF@22bb1af` (`DownloadETAEstimator`)
  - `ollama@4d22e65` (store GC) and `@04088e7` (`sched.go`)
  - `Atomic-Chat@29b01d8` (step-aside), `openasr@08c5c9a` (catalog incident vectors)
  - `sqlite-vec v0.1.9 @e9f598a`, `sqlite-vec-data@f980c99`, `mlx-swift-lm f5b0677`, `llama.cpp 620d222`
  - `semantic-router@aef8310`, `ActionRouter@7d94cb6`, `gorilla@6ea5797`
- **Models:**
  - `chat-0.8b` = `mlx-community/Qwen3.5-0.8B-MLX-4bit@5d894f8`
  - `embed` = `Qwen3-Embedding-0.6B-4bit-DWQ@6c3ae70`
  - `rerank` = `Qwen/Qwen3-Reranker-0.6B@e61197e` (T2+)
  - `evil-9b` = llmfan46 Qwen3.5-9B Heretic GGUF `@b93c15b`
  - `evil-35b-q4` = `froggeric/Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit@32939a6`
  - Other catalog keys: `chat-2b` (T0), `chat-4b` (T1 step-down below 120 GB/s), `chat-9b-q4`, `chat-35b-q4`, `chat-g26`
- **Decisions:**
  - D-003 (only this Mac), D-005/D-006 (no filters), D-007/D-010 (no mirror; Video sizes separate), D-011 (lawful lecture set)
  - D-013, D-014 (`LSMinimumSystemVersion 26.0`), D-025 (lean method)
  - Q-009 a, Q-015 (XCUITest), Q-021 (computer use)
- **Patches:** P-platform-01…06, -08; P-shell-11, -13; P-media-15. Read only the section a task cites, in `docs/research/09-patches/`.
- **Specs, by section only:** blueprint E §E.2.1–E.2.7, hardware-tiers §2–§6, model-matrix §1–§4 and §9, test-strategy §4–§7, screens S-00…S-04, S-06, S-21, S-24, S-25.

## Owner decision applied (D-026)
- T07: skip step 4 "Add by HF ID" (AT-224 is in M11).
- **T11: build in full. B2 was rejected; model auto-updates stay in v1.**
- T02: replace the swizzle with `InjectionCoverageTests` (condition in B1).
- T23: skip the model-alone report, the constrained-JSON path (keep it as the fallback only) and the nightly bench.
- T25/T26: slim per their "Verification scope (D-025)" notes.

All other ATs stay. Chunk order: `docs/prd/BUILD-ORDER.md`.
