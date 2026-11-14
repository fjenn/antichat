# RC review (M10.T11): independent whole-product correctness review of the release candidate

Reviewer: independent (D-025 style). Base: main @ d29a4b503. Fixes are on `rc/review`; P2-4 to P2-10 on `rc/p2-fixes`.
Scope: the shipping product (Packages/*/Sources, App/AntiChat, App/EngineHelper, App/FileToolsHelper, relay/,
Config/, catalog/, project.yml), focused on P0/P1: crashes, data loss, privacy and network leaks (Offline only = zero
calls, no telemetry by default), the D-006 ChildSafetyCheck invariant, secrets in the repo or the bundle, and
Sparkle and catalog signature checks. Findings already fixed in M3/M4/M5/M6/M8/R2 reviews were not repeated.
Not run: XCUITests and GPU jobs (other agents own those slots).

Counts: **P0 0 · P1 3 (all fixed) · P2 11 (10 fixed, 1 open: P2-11, folded into RB-2) · release blockers 2 (owner, M10.T10)**.

---

## Status update (M10.T11 close prep, 2026-11-12, main `5e66e7d18`)

Read-only re-check on main; nothing was built or run (an M9.T05 timing run held the machine).

### Review findings: where each fix landed (all on main)

| Finding | Fix commit(s) | Test |
|---|---|---|
| P1-1 Offline only vs File tools network variant | `09ab78f5e` | `FileToolsClientTests.offlineOnlyNeverPicksTheNetworkVariantAndIsReadPerCall` |
| P1-2 dev relay URL in Release (gate) | `09ab78f5e` (`endpoints-check.py --strict`) | `test_endpoints.py` (2 cases) |
| P1-3 re-import deleted local messages | `42ae5dcb1` (its subject says "P1-1": the review renumbered it) | `ImportDedupTests.newerExportNeverReplacesAChatWithLocalMessages` |
| P2-1 empty image pointer, P2-3 Models folder into itself | `42ae5dcb1` | `StorageTests`, `ImportDedupTests` |
| P2-2 AntiChat export rows into other chats | `7053f11f3` (subject says "P2-3") | `RoundTripTests` |
| P2-4 blob reference checks | `428fbc293`, `7264a732c` | `RecordingStoreTests…`, `ProjectStoreTests…` |
| P2-5 import dedup key | `cc335d70a` | `ImportDedupTests.conversationsWithoutIdsAndSameTitleDoNotCollide` |
| P2-6 MCP / relay GET stream vs Offline only | `1058e5491` | `MCPHTTPTransportPolicyTests` |
| P2-7 update notes HTML | `b6202d21e` | `UpdateNotesRenderTests` |
| P2-8 Sparkle test key + feed override | `543956e42` | `UpdaterBridgeTests…`, `test_devfeed_guard.py` (9) |
| P2-9 runtime installs vs catalog latch | `96740b055` | `RuntimeInstallCatalogGateTests` |
| P2-10 Mermaid without its rule list | `5970b2a23` | `MermaidSandboxTests.noRuleListMeansNoRender` |
| Review doc / gate results | `47d975934`, `7d81127b0`, `c8979e534` | — |
| **P2-11** hard-coded dev relay fallback (`RelayClient.swift:52`) | **open**, still `http://127.0.0.1:3000` on 2026-11-12; goes with RB-2 | — |

### Fixed since the review (found by later tracks)

| Fix | What | Commits | Where |
|---|---|---|---|
| **Isolation traps** (`fix/isolation-traps`) | P74: the MCP sign-in crash (`ASWebAuthenticationSession` completion called on an XPC queue trapped Swift 6's main-actor check). Then a whole-tree audit of framework callbacks that inherit main-actor isolation (1,147 files); NSWorkspace completions (relaunch, uninstall recycle) made nonisolated, off-main callback tests | `86c5faa70` (P74), `cd6d81e89`, `5d98f51e3`; write-up [`isolation-audit.md`](isolation-audit.md) | main |
| **Stray kill** (`fix/stray-kill`) | The UI-runner kills were RunningBoard / cache_delete under a full disk, not our code. Hardening for pid reuse: FileToolsHost signals only its unreaped child / recorded group, LlamaWatchdog re-checks the group leader's start time and refuses pgid ≤ 1, VideoChild reaps under its kill lock, ProcessPause signals only an unreaped child | `b6b03df3a`, `fb8f4ef4c`, `55edb8add` | main |
| **Hello timeout** (`fix/hello-timeout`) | `engine.helloTimeout` in the integration suites (and for any client of a throttled launchd job): EngineClient now adds the job's remaining launchd respawn throttle to its hello deadline; deaths deduplicated by helper pid | `1f4fdf6ee` | **`m9/t05-run` only, not on main yet** |
| Test flakes | snapshot window isolated from the pointer and key state; tick-cost guard on exact work counters | `99a8c6d95` | main |
| Test plists | tests leave no plists in `~/Library/Preferences`; owner cleanup script `tools/dev/clean-test-plists.sh` | `4faa91a90` | main |
| XCUITest rounds 1–7 | product bugs P1…P80 (e.g. P74 above, P75 ⌘K focus, P77 relay refusal copy, P79 Network activity rows) | see [`../XCUITEST-REPORT.md`](../XCUITEST-REPORT.md) | r1–r6 on main; **r7 (`da72e89ba`) on `m9/t05-run` only** |

### Release blockers re-verified (2026-11-12): all still open, owner

- **RB-1 runtime URLs: still localhost.** `catalog/runtimes.yaml:19` `http://localhost:4321/runtimes/filetools-runtime-0.1.0.zip`,
  `:33` `http://localhost:4321/runtimes/video-runtime-0.3.3.zip`; the same two URLs in the signed baseline
  `catalog-baseline.json` (lines 8457, 8471). Owner: host the zips, set the URLs, re-sign the catalog.
- **RB-2 RelayURL: still the dev relay.** `Config/Endpoints.plist:34-35` `RelayURL = http://127.0.0.1:3000`; the
  `RelayClient.swift:52` fallback (P2-11) is the same. `endpoints-check.py --strict` fails on it, as intended.
- **Sparkle and catalog keys: still the test keys.** `Config/Keys.release.plist` holds the test Sparkle key
  (`Lfhwtsep…`) and test catalog keys A (`pAicWX6U…`) and B (`S31zXwjb…`), all three listed in
  `catalog/test-keys/FINGERPRINTS`, so a release-keys build stops at the generated `#error` (intended);
  `SparklePublicEDKeyBackup` is empty. `project.yml:104` and `App/AntiChat/Info.plist:45` `SUPublicEDKey` are the test
  key; `build-release.sh` stamps the real one after the key ceremony. The catalog is signed with test key A.
- **Hosting:** `CatalogURL`, `AppcastURL` and `AppcastDevURL` point at the interim host `antichat-site.vercel.app`
  until the domain is set (`Config/Hosting.json` → `set-hosting.py`).

The owner steps for all four are in [`../OWNER-STEPS.md`](../OWNER-STEPS.md) §E.

---

## Release blockers (owner, M10.T10). Recorded only, not changed here.

- **RB-1: Runtime URLs point at localhost.**
  - `catalog/runtimes.yaml:19` is `http://localhost:4321/runtimes/filetools-runtime-0.1.0.zip`.
  - `catalog/runtimes.yaml:33` is `http://localhost:4321/runtimes/video-runtime-0.3.3.zip`.
  - The same two URLs are in the signed baseline `Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json`.
  - `tools/release/preflight.py:93-97` already catches the yaml.
  - The owner hosts the zips and re-signs the catalog.
- **RB-2: The Composio relay URL is the dev relay.**
  - `Config/Endpoints.plist:34-35` has `RelayURL = http://127.0.0.1:3000`. `RelayClient.endpoint`
    (`Packages/Tools/Sources/AntiChatTools/Composio/RelayClient.swift:46-53`) uses it in Release.
  - See P1-2. The release gate now fails until the owner sets the deployed https relay.

## P1 (all fixed)

### P1-1: Offline only did not stop model-written Python from using the network when "Allow network for code" was on. Fixed.

- Where: `Packages/Tools/Sources/AntiChatTools/FileTools/FileToolsClient.swift:48-53` (before the fix), used by
  `Packages/Harness/Sources/AntiChatHarness/Tools/FileToolsTools.swift:29,63`.
- The bug:
  - The client picked the `…FileTools.Net.slot<k>` service (`network.client` entitlement, `project.yml:28-32`) once, when the tool registered, from `allowNetworkForCode` alone.
  - The Net service opens its own sockets, which never pass through `NetworkGate`. Turning on Offline only later did not change the variant, so nothing was blocked and nothing reached the ledger.
  - A prompt-injected document could make `run_python` send data out while the UI showed "Offline only".
  - Side effect: turning "Allow network for code" off also had no effect until relaunch.
- Fix:
  - The routed client now decides its variant at each call: `allowNetworkForCode && !NetworkPolicyStore.shared.offlineOnly`.
  - The lease and the slot client use that same decision.
  - Slot clients are cached per service name.
- Test: `FileToolsClientTests.offlineOnlyNeverPicksTheNetworkVariantAndIsReadPerCall`.

### P1-2: A Release build would send relay traffic, over plain http, to whatever listens on 127.0.0.1:3000. Fixed: the release gate now catches it.

- Where: `Config/Endpoints.plist:34-35`, `RelayClient.swift:46-53`.
- The bug:
  - Release reads the plist's dev value, and the hard-coded fallback is the same URL.
  - Port 3000 is a common dev-server port. Once the user adds a Composio connection (off by default), the app sends that local process:
    - the install-ID header;
    - session and link calls;
    - MCP tool calls carrying user data.
  - It also accepts tool results from whatever answers.
- No gate caught it:
  - `tools/ci/endpoints-check.py --strict` (run by `preflight.py:69`) checked only IssuesURL and SupportEmail.
  - Its markers did not include `127.0.0.1`.
- Fix: `endpoints-check.py --strict` now requires RelayURL to be https on a public dotted host. Loopback, `localhost` and placeholders fail.
- Tests: `tools/ci/tests/test_endpoints.py::test_strict_fails_on_loopback_relay` and `test_relay_url_rule`.
- Still to do (owner, M10.T10): deploy the relay and set the URL. This review does not set it.

### P1-3: Re-importing a newer ChatGPT/Claude export deleted the messages the user had added to that chat in AntiChat. Fixed.

- Where: `Packages/Storage/Sources/AntiChatStorage/ImportExport/ChatImporter.swift:194-205` →
  `TreeImporter.write(replacing:)` → `DELETE FROM message WHERE chat_id = ?` (`Import/TreeImporter.swift:262-264`).
- The bug:
  - Ordinary path: import an export, keep chatting in one of those chats here, then import a fresher export where the conversation's `update_time` moved.
  - Every local turn, edit and regeneration was deleted (`source_id IS NULL`), together with its parts, attachments and feedback.
- Fix:
  - A chat that has any message without a source id is never replaced.
  - The newer export lands as a new chat, and the import record moves to it, so later re-imports replace only imported content.
  - Chats without local messages are still replaced in place, as before (AT-092 AC2).
- Test: `ImportDedupTests.newerExportNeverReplacesAChatWithLocalMessages`.

## P2

### Fixed

- **P2-1: An empty image pointer attached a random image from the zip** (`ChatImporter.swift`, `ImageIndex.entry`). The empty string is a prefix of every name. An empty reference now resolves to nothing.
- **P2-2: An AntiChat export could put rows into chats that already exist here** (`ImportExport/AntiChatImporter.swift:189-205`).
  - Before: message `chat_id`, part, attachment and feedback `message_id`, and draft `chat_id` came from the file unchecked.
  - Now: messages and the draft are forced to the document's chat. Parts, attachments and feedback are kept only for the document's own messages.
  - `RoundTripTests` still checks the lossless round trip.
- **P2-3: Moving the Models folder into a subfolder of itself deleted the new copy and lost every install**
  (`Packages/Platform/Sources/AntiChatPlatform/Storage/ModelsFolderMover.swift:43,80-83`). Such a destination is now refused (`destinationNotEmpty`). Test: `ModelsFolderMoverTests.destinationInsideSourceIsRefused`.
- **P2-4: Two "is this blob still used?" checks missed a table each.** Fixed on `rc/p2-fixes`.
  - `RecordingStore.dropBlobIfUnused` (`Packages/Storage/Sources/AntiChatStorage/Voice/RecordingStore.swift`) ignored `project_file`, so deleting or pruning a recording deleted a same-sha project file's file.
  - `ProjectStore.deleteBlobIfUnreferenced` (`Packages/Knowledge/Sources/AntiChatKnowledge/Projects/ProjectStore.swift`) ignored `recording`, so removing the file or deleting the project threw on `RESTRICT`.
  - Fix: both now call `LibraryIndex.isReferenced` (made public), the one list of tables that reference `file_blob`.
  - Tests: `RecordingStoreTests.deletingARecordingKeepsABlobAProjectFileStillUses`, `ProjectStoreTests.deleteKeepsABlobARecordingStillUses`.
- **P2-5: The import dedup key could collide.** Fixed.
  - Before: a conversation with no source id was keyed `title|createdAt` (`ChatImporter.swift`). Two of them with the same title and no `created_at` shared a key, so the second was skipped as a re-import of the first.
  - Now: the key is `content:` plus a SHA-256 over the title, the creation time and every message (id, parent, role, parts, image refs). The same conversation re-imported still matches. A different one never does.
  - Test: `ImportDedupTests.conversationsWithoutIdsAndSameTitleDoNotCollide`.
- **P2-6: An MCP or relay GET event stream opened before Offline only stayed open for up to 24 h.** Fixed.
  - `MCPHTTPTransport` (`Packages/Tools/Sources/AntiChatTools/MCP/MCPHTTPTransport.swift`) now watches `NetworkPolicyStore.didChange` while it is connected. When its category stops being allowed (Offline only on, or the category off), it cancels the GET task and its URLSession data task at once.
  - A new GET stream is not started while the category is blocked. The stream reopens when the category is allowed again.
  - The transport now takes the host's policy, and tags its requests with it (`MCPHost` passes its own).
  - Test: `MCPHTTPTransportPolicyTests.openGETStreamClosesWhenOfflineOnlyTurnsOn` (`.mcp` and `.relay`, against a stub server whose SSE stream never ends on its own).
- **P2-7: The update-notes sheet ran appcast HTML through AppKit's WebKit-backed HTML importer.** Fixed.
  - `UpdateNotesSheet.render` (`Packages/UI/Sources/AntiChatUI/Sidebar/UpdatePill.swift`) now uses `HTMLText` (libxml2, `HTML_PARSE_NONET`, no base URL, attributes never read, script and style dropped; made public).
  - The result is shown as inline-styled text with every link and image URL removed. No remote load, no script.
  - Tests: `UpdateNotesRenderTests` (text kept; script, style, image, link and `example.com` gone; the source never uses the AppKit importer).
- **P2-8: The committed Sparkle test key and an ungated feed-URL override.** Fixed. The test key stays committed, because dev tooling and the VM upgrade test (AT-FA-12) sign with it.
  - `UpdateFeed.devFeedAllowed` is true only under `DEBUG` or `ANTICHAT_DEV_FEED`. `build-release.sh` sets `ANTICHAT_DEV_FEED` only for adhoc/dev signing with dev keys, never for devid.
  - Where the dev feed is not allowed, the test key (or a missing key) resolves to no feed and the override is ignored. The `AntiChatFeedURLOverride` key is compiled in only behind the same gate.
  - `UpdaterService.start` never creates Sparkle without a feed, so a Developer ID build never trusts the test key.
  - New guard `tools/ci/devfeed-guard.py`, run by `make audit` (`devfeed-guard`). It checks the gate, the refusal in `resolve`, the start guard and the one `build-release.sh` line. On a devid build in `build/release` it also checks that no binary carries the override key.
  - `preflight.py` runs the guard with `--app build/release/AntiChat.app --release`. It fails when the app's `SUPublicEDKey` is the test key or the override is compiled in. This also covers a DEVKEYS build made after the key ceremony, which the old checks let through.
  - Tests: `UpdaterBridgeTests.releaseBuildRefusesTheTestKeyAndTheOverride`, `tools/ci/tests/test_devfeed_guard.py` (9 cases, one seeded violation each).
- **P2-9: Runtime installs skipped `CatalogStore.mayInstallNew`, the expiry and bad-signature latch.** Fixed.
  - `FileToolsSettingsModel.install` (`Packages/UI/Sources/AntiChatUI/Settings/ToolsSettings+FileTools.swift`) now fails closed exactly like `InstallQueue`.
  - An expired catalog, a bad-signature latch or no catalog store starts nothing and shows `catalog.badSignature`.
  - Tests: `RuntimeInstallCatalogGateTests.expiredCatalogStartsNoRuntimeInstall`, `refusalFollowsTheStoreAndNoStoreRefuses`.
- **P2-10: The Mermaid web view rendered without its block-all rule list if that list failed to compile.** Fixed.
  - `MermaidRenderer` (`Packages/UI/Sources/AntiChatUI/Renderer/MermaidBlockView.swift`) records whether the rule list was installed. Without it, `render` returns `.unavailable` before any load, so the block keeps showing its source. This matches `SandboxedWebPreview`.
  - Test: `MermaidSandboxTests.noRuleListMeansNoRender`.

### Open (owners: lead / M11 triage)

- **P2-11: The dev relay fallback is hard-coded** (`RelayClient.swift:52`). A missing plist entry falls back to `http://127.0.0.1:3000` in Release. Folded into RB-2: when the URL is set, also make Release refuse a non-https relay.

---

## D-006 ChildSafetyCheck invariant: verified, no finding

- **One import.** `import ChildSafetyCheck` appears only in
  `Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift:11` (and in the package's own csc-bench). The `tools/ci/r241-audit.py` rule 1 passes in `make audit`.
- **One caller.** The gate's `checkPreview`, `checkResult` and `checkVideo` are called only from
  `Packages/Engines/Sources/AntiChatEngines/Jobs/MediaJobRunner.swift`:
  - `emitPreview` :234;
  - `emitResult` :284;
  - `emitVideoResult` :357;
  - `beginVideoCheck` :381, whose verdict is applied only in `finishVideo` :402 → `writeVideo` :422.
  - Audit rule 2 checks this, including bare `g.check…(` calls.
- **Every output goes through the runner.** Every engine that produces a picture or a clip hands its bytes to `MediaJobOutputs`, and none writes them itself:
  - sd image: `EngineRuntime.swift:456-457, 514`;
  - local edits, i.e. Remove background and Erase: `LocalImageJob.swift:44`;
  - video, both the streamed and the one-shot path: `VideoEngine.swift:160,173,320`;
  - sd video: `SDVideoEngine.swift:123,144`;
  - the scripted engines;
  - the bench lanes: `BenchImageTurn`, `BenchMode+Video`.
  - The runtimes return frames and previews in memory over unix sockets: sd-server previews and AVI, video-runtime frames and JPEG previews. Nothing raw lands on disk.
  - The app shows only the paths in `jobProgress.previewPath` and `jobResult.path`. Those files exist only after `allow`.
  - The mask composite is applied before the check, so the picture checked is the picture written (`EngineRuntime.swift:500-506`).
- **Fail closed.**
  - No manifest, a damaged file or a load error gives `safetyMissing` (`MediaOutputGate.loadChecker`).
  - A timeout, a detector error or a non-finite score while nudity is true or unknown gives `block`.
  - A preview below its valid size, or one whose check errored, is withheld, never shown.
  - Video:
    - an incomplete, errored, cancelled or empty frame stream blocks (`VideoFrameSampler.swift:41-55`);
    - every sampled index (≥ 2 fps, plus the first and last frame) must arrive;
    - `VideoCheckStream` aborts or deinits with an error, so an abandoned check can only block, and nobody applies that outcome.
  - A multi-image PNG is refused, because only frame 0 would be checked (`MediaJobRunner.decode`).
  - A cancel during the check writes nothing.
  - Withheld or blocked: the bitmap is dropped and nothing is written.
- **No bypass.**
  - The only override is `ForcedVerdictCheck` under `ANTICHAT_UI_TESTING`. No shipped configuration defines it: rule 2 checks the build configurations, and `--binary` runs an `nm` scan.
  - The self-hashing unpinned manifest is DEBUG-only (rule 2c).
  - Audio is out of D-006 scope and is not checked.

## Checked, no finding

- **Network gate.**
  - Every URLSession comes from `NetworkGate` (`Packages/Network/Sources/AntiChatNetwork/NetworkGate.swift:98-106`), with the category's `GateURLProtocol` first.
  - `isEnabled = !offlineOnly && stored`.
  - Connectors, MCP, relay and crash reports are off by default.
  - `-OfflineOnly`, `-CatalogURL` and `-RelayURL` are DEBUG-only.
- **Every egress path is gated:** catalog, downloads, search, page fetch, MCP (with swift-sdk and EventSource), OAuth discovery, relay and Sparkle (`UpdateGateDelegate`).
- **No ungated sockets.** There is no `URLSession.shared` and no raw socket in product code. Engines use unix sockets. `HF_HUB_OFFLINE` and `TRANSFORMERS_OFFLINE` are set for helpers. FluidAudio is set to `offlineMode`, and WhisperKit to `download: false`.
- **Markdown images** do not fetch (`NoFetchImageRenderer`). The WebViews use block-all rule lists, and `SandboxedWebPreview` fails closed.
- **No telemetry.** The crash-report mode defaults to "ask", and Send only hands the report to Mail or the browser. There are no analytics SDKs.
- **Sparkle settings:** `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, https feeds, system profiling off.
- **Catalog:**
  - Ed25519 under pinned keys A or B; the signature must be 64 bytes.
  - A bad signature keeps the last good catalog and latches; a rollback is rejected; an expired catalog blocks new model installs.
  - Release-keys builds refuse test keys at compile time.
  - Downloads are fully sha256-checked before commit.
- **Secrets:**
  - No Composio key, token or private key in any tracked file except the Sparkle test key (P2-8).
  - The relay reads the key only from env, and production refuses the base-URL and http overrides (`relay/src/policy.ts:54-66`).
  - The bundle carries only Help, Legal, notes, `Endpoints.plist` and SwiftPM resources. `catalog/test-keys` is not bundled.
- **Crash and data-loss paths:**
  - the tree importers (cycles, dangling parents, iterative walks);
  - the JSON streamer;
  - zip bounds;
  - migrations: backup, integrity check, restore on failure;
  - streaming writes in transactions;
  - incognito: in-memory stores only;
  - bulk deletes;
  - the File tools jail (`O_NOFOLLOW`, realpath, strict chat-id regex);
  - XPC descriptor caps;
  - the force unwraps in shipping code, none reachable from user, disk or XPC data.

## Gate results (rc/review)

- **`make test-unit`: green.**
  - Full run: every lane passed except `SDServerProcessTests.listensOnUnixSocketOnlyWithoutModels`. That failure was environmental: the worktree had a stale `build/binaries/sd-server` copied from the main checkout, whose sha did not match `Binaries/checksums.json`.
  - After the pinned binaries were staged (checksums match), that suite passes.
  - The fixed and new suites pass in a filtered run: ImportDedup, ModelsFolderMover, FileToolsClient, RoundTrip, ExportAll, ChatGPT/Claude import.
- **`make test-integration-stub`: green.**
  - Full run: 90 tests, 20 skipped, 2 failures under load average ≈ 22: `LlamaServerSupervisionTests.testSetPolicyAppliesBeforeTheNextRequest` (`engine.helloTimeout`) and `SystemReportEngineTests.testProbeCarriesResidentSetAndLoadTimes`.
  - Both suites re-run green: 7 tests, 0 failures. They touch no code changed here.
- **`BINARIES_SRC=… make audit`: exit 0.** `r241-audit` ok.

Test setup: this worktree had no `fixtures` submodule checkout, and the sandbox refuses `file://` submodule clones. The tests therefore ran against an APFS clone of the main checkout's fixtures, which are at the pinned commit c3133f2. The pinned binaries and the reproducible filetools runtime zip came from sibling worktrees, with sha256 values matching the lock and the catalog.

## Gate results (rc/p2-fixes: P2-4 to P2-10)

- **`make test-unit`: green.** Full run: `main` passed, `childsafety` passed.
  - Each new test was checked against its fix: with the fix mutated out (the old key, the old blob queries, no policy close, no catalog guard, no test-key refusal, no rule-list guard), every new Swift test failed. With the fix in place, every one passes.
  - The first full run flagged `SettingsIsolationTests.everySuiteIsIsolated`, because two new UI suites lacked `.isolatedSettings`. They now have it, and that change was folded into the P2-7 and P2-9 commits.
- **`make test-integration-stub`: green.** 90 tests, 20 skipped, 0 failures.
- **`BINARIES_SRC=… make audit`: exit 0.** 38 of 38 checks ok, including the new `devfeed-guard`. `tools/ci/tests/test_devfeed_guard.py`: 9 passed.

Test setup: the same as above.
- Fixtures: an APFS clone of the main checkout's fixtures (c3133f2).
- Pinned binaries (`build/binaries`) and the filetools runtime zip: copied from a sibling worktree, with sha256 matching `Binaries/checksums.json` and the catalog.
- `BINARIES_SRC`: llama.cpp at 620d222 from a sibling worktree, plus sdcpp at e239e4b, with the matching `checksums.json`.
- `tools/.venv`: linked to the main checkout's venv. The worktree has no `Binaries/llama.cpp/gguf-py` to build its own.
- No XCUITests and no GPU jobs were run.
