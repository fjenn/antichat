# M9.T09 rehearsal: upstream sync #2, dry run on 2026-11-10

**Branch:** `rehearsal/sync-2` (throwaway, from main `0fe4cfd20`; never merge as a whole). **Who/when:** build agent, 2026-11-10 17:00–19:00 UTC. **Why now:** T09 is the last M9 task (it waits for every other milestone to land). This run checks the procedure, the tools and the upstream deltas ahead of time, so the real T09 can follow a known path. No pins move on `main`.

**Scope:** every upstream in the ledgers: the 10 vendir donors (`Vendor/donors.json`, `Vendor/UPSTREAM_PATCHES.md`, `Vendor/VENDORED.json`), the 2 helper-binary submodules (`Binaries/llama.cpp`, `Binaries/sdcpp` + `Vendor/patches/sdcpp`), the 29 SwiftPM pins in `tools/ci/pins.json` plus the transitive packages in `Package.resolved`, the Python runtime locks (`Runtimes/*/requirements.lock`) and `Vendor/js`. Some names in the T09 brief have no ledger entry: rife-mlx is not in the repo, FullDuplexAudioIO is a file of the speech-swift donor, and trafilatura-swift and duckdb-swift are SwiftPM pins. All of them are covered below.

**Method:** `make vendor-report` (`tools/vendor-sync report --ports`, mirrors in `~/Library/Caches/AntiChat-dev/vendor/`) → `make vendor-bump NAME=… REF=… ARGS=--no-branch` → resolve conflicts → `tools/vendor-sync finish` → `make audit-vendor`. SwiftPM: edit `Package.swift`, `swift package resolve`, `pins-verify`. Submodules: changelog plus a re-apply of the patch (`patch --dry-run` against the upstream head file). Security: GitHub repo advisories (`gh api repos/<r>/security-advisories`) for 48 upstream repos, OSV.dev batch query for the 266 PyPI/npm pins, and a keyword scan of every pin..head log. Licences: `git diff pin..head -- LICENSE*` for every git upstream. Then `make build` and `make test-unit` on the synced branch.

## Summary

| # | Dependency | Our pin | Latest upstream | Change since pin | Patches re-applied | Conflicts | Build / test | Recommendation |
|---|---|---|---|---|---|---|---|---|
| 1 | osaurus (vendored, 122 compiled files) | `2922745` (2026-10-30) | tag **0.25.33** `66c3dde` (2026-11-09); main `15d4089` "Osaurus 1.0" (2026-11-10, untagged) | 75 commits to main; to 0.25.33 only 1 compiled file changed (a test) + 5 watch files | 53 UP rows / 221 blocks, all markers kept, patch-lint 0 errors | 1 (kept ours) at 0.25.33; dry run to 1.0: 13 hunks in 3 files | build green, test-unit green | **take at T09** (0.25.33; 1.0 only if tagged by then, with the onboarding fallback below) |
| 2 | speech-swift (vendored) | `d53bcb3` | main `468db5f`, tag v0.0.29 | 26 commits, none in the allow-list | n/a (UP-SS-001…009 untouched) | 0 | n/a | hold (nothing to take) |
| 3 | FastVideo (Python, video runtime) | `d9e6c3e` | main `4deb3a5` | 39 commits; 1 allow-listed file (`fastvideo/envs.py` +85 −6, CUDA/PAN2 env vars) | UP-FV-001/002 kept | 0 | runtime not rebuilt | hold (no MLX-path change) |
| 4 | CommandPaletteKit | `cf93b66` (v0.3.0) | main `2aec3e3` (no new tag) | 22 commits, none in the allow-list | n/a | 0 | n/a | hold |
| 5 | TUFF (DownloadETAEstimator only) | `22bb1af` | v10.2.2 / main `5016aaa` | 9 commits, none in the allow-list | n/a | 0 | n/a | hold |
| 6 | sqlite-vec (release amalgamation) | v0.1.9 `e9f598a` | v0.1.10-alpha.4 / main `04d28bd` (no stable release) | 45 commits: ANN indexes (IVF, DiskANN, rescore), memory-safety fixes | n/a (no patches) | n/a | not bumped | hold until a stable 0.1.10 (the fixes are unreachable for us, below) |
| 7 | libxls | v1.6.4 `34c7cc6` | main `93f1ad5` (untagged) | 4 commits, 3 fuzz-found memory fixes | n/a (pristine copy) | 0 | build green, test-unit green | **take at T09** (prefer a v1.6.5 tag) |
| 8 | agent-squad (PlaybackClock) | `729d5f5` | same | none | n/a | 0 | n/a | hold |
| 9 | ltx-2-mlx (Python, video runtime) | `895201d` | main `747b30e` | 1 commit, not in the allow-list | n/a | 0 | n/a | hold |
| 10 | LetsMove | `70c5772` (v1.25) | same (dormant since 2020) | none | n/a | 0 | n/a | hold |
| 11 | llama.cpp → llama-server | `b11669` `620d222` (2026-10-15) | `b12251` `18c5a95` (2026-11-10) | 582 commits; Metal OOB-write and overflow fixes, grammar recursion limit | none recorded | n/a | not rebuilt (binary cache) | **take at T09, before release** |
| 12 | stable-diffusion.cpp → sd-server | `e239e4b` (master-1030) | `32d516c` (2026-11-11) | 59 commits (new models, server queue limits, Metal fixes); ggml `7b2b435`→`d803c23` | UP-SD-001 applies cleanly | 0 | not rebuilt | hold (take at T09 only for the Metal fixes) |
| 13 | mlx-swift-lm | `f5b0677` (main) | main `d7b94ee`, **does not build**; `ec4c966` used | 29 commits (RotatingKVCache mask fix, load progress, EmbeddingGemma 2) | — | build break upstream + 2 exhaustive-switch errors in `MLXAdapter` (fixed) | build green, test-unit green | take at T09 at a building commit, with the conformance suite |
| 14 | FluidAudio | 0.18.0 | **0.18.3** | 55 commits (ASR seam, PocketTTS splitting, Kokoro routing on OS 27) | — | 0 | build green, test-unit green | take at T09 (re-run voice V-metrics) |
| 15 | swift-huggingface | `199277c` | main `3bee3b6` (1.0.0 tag is older than our pin) | 1 commit | — | 0 | build green, test-unit green | take at T09 (trivial) |
| 16 | GRDB.swift | 7.11.1 | **7.12.0** | 37 commits (SharedValueObservation, WITHOUT ROWID fixes) | — | 0 | build green, test-unit green | take at T09 |
| 17 | EventSource | 1.5.1 | 1.6.0 | 2 commits | — | 0 | build green, test-unit green | take at T09 |
| 18 | swift-log | 1.16.2 | 1.17.0 | 4 commits (MultiplexLogHandler metadata) | — | 0 | build green, test-unit green | take at T09 |
| 19 | swift-sdk (MCP) | `68300d7` | main `3059fd5` | 10 commits: socket leak (CLOSE_WAIT), data races in NetworkTransport, heartbeat stop | — | 0 | build green, test-unit green | take at T09 |
| 20 | swift-transformers | `deaec6c` | 1.4.0 `402a8a1` | 3 commits | — | 0 | build green, test-unit green | take at T09 |
| 21 | transitive: swift-nio / swift-asn1 / swift-jinja | 2.104.0 / 1.7.3 / 3.0.0 | 2.105.0 / 1.7.4 / 3.1.0 | minor | — | 0 | build green, test-unit green | take at T09 |
| 22 | swift-crypto (transitive) | 4.5.2 | 5.1.1 (latest 4.x = 4.5.2) | GHSA-jwv7 (VOPRF) open on 4.x | — | blocked: dependents cap `<5.0.0` | n/a | hold (we link only `Crypto`, not `_CryptoExtras`) |
| 23 | Sparkle, swift-subprocess, swift-async-algorithms, CocoaLumberjack, ZIPFoundation, KeyboardShortcuts, onnxruntime-spm, argmax-oss-swift, MarkdownView, swift-markdown, Defaults, package-benchmark, duckdb-swift, libxlsxwriter, TPPDF, trafilatura-swift, Yams, swift-snapshot-testing, mlx-swift, swift-syntax, others | latest tag already | — | no newer release (mlx-swift main +4, duckdb-swift main = pin, libxlsxwriter main past v1.2.4) | — | — | — | hold |
| 24 | Python runtimes (20 + 44 pins) and `Vendor/js` (npm) | per lock | — | OSV: 0 vulnerable PyPI pins; npm `image-size` 1.2.1 has 2 HIGH DoS advisories | — | — | — | hold (not in the shipped bundle, below); add an override at the next `make vendor-js` |

**Licence changes:** none. The LICENSE file is byte-identical from pin to head for every git upstream above (osaurus also checked at 1.0). Licence families are unchanged (MIT / Apache-2.0 / BSD-2-Clause / public domain).

**Security fixes that should land before release:** see [Security](#security-review). Short version: take the **llama.cpp** bump (Metal out-of-bounds writes, grammar stack overflow) at T09. The **libxls** fixes are cheap defence in depth. Nothing else that we ship is affected: every published advisory against our pins is already fixed in them, or sits in code we don't link.

**Tooling fixes found by this rehearsal** (commits on this branch; cherry-pick to `main` now, they do not move any pin): `14dc58601` and `28612944d`, see [Tooling](#tooling-and-procedure-findings).

---

## Per dependency

### 1. osaurus

- **Pin → latest:** `292274532cd7` → release tag `0.25.33` (`66c3dde0b322`, 2026-11-09). Main is now `15d4089fe` "Osaurus 1.0 (#3366)", a squash of the 1.0 tree (232 files, +45k lines repo-wide), not tagged yet (newest tag 0.25.33).
- **Change since pin (to 0.25.33):** 1 vendored/test file: `Tests/Model/GPUMemoryBudgetTests.swift` +1 −1, inside a test that UP-OS-035 drops. 5 of the 38 watch (ported) files changed: `AgentToolLoop`, `ContextBudgetManager`, `ContextCompactionService`, `SystemPromptComposer`, `ToolSearchService`. Upstream commits worth reviewing for our ports: `f11d5b26` (validate compaction output, thinking-off summaries → our `ContextCompactionService`), `c0da268a` (count tool-result mirrors once in context estimates → `ContextBudget`), `baec65cf` (compact growing tool chains between batches), `92f20fe2` (tool indexing recovery → `ToolIndex`). None is a security fix.
- **Bump:** `make vendor-bump NAME=osaurus REF=0.25.33 ARGS=--no-branch`: 122 compiled files, 0 entered, 0 absent, **1 conflict**. Wall clock 1 min 19 s for the bump, plus 1.6 min to resolve and finish (17:34:36 → 17:36:11 UTC). That does not count the two tool bugs that had to be fixed first (≈ 20 min, below).
- **Conflict + resolution:** `GPUMemoryBudgetTests.swift`: upstream edited `measuredSizeReplacesFallback`, a test that builds `MLXModel` (not vendored), and ours is the UP-OS-035 empty block. **Keep ours** (rule (ii) of S-1: upstream hunk against a stripped region).
- **Patch re-apply:** `finish` → patch-lint `319 files, 78 patched, 221 blocks, 53 rows, 0 error(s)`. After the fix to `_relocate` (below), access-rewrite.txt keeps the same 100 entries. The compiled copy is **byte-identical** to `Vendor/osaurus@2922745/` apart from `ORIGIN`. `make audit-vendor` is green (`vendir sync --locked` matches 402 files, VENDORED.json current with 383 rows, vendored-allowlist 0 errors).
- **Follow-up edits:** port citations `osaurus-ai/osaurus@2922745:` (24 files under App/ and Packages/) were re-pointed to `@66c3dde:`. Without that, 14 watch rows silently drop out of VENDORED.json (procedure finding P1). `tools/ci/pins.json` `vendir.osaurus.commit` was updated too. `ACKNOWLEDGMENTS.md` was not regenerated, because it needs the binary submodules checked out (P5).
- **Dry run to Osaurus 1.0** (`15d4089`, read-only 3-way merge of the compiled copy, `git merge-file` as `bump` does): 12 compiled files change upstream. **13 conflict hunks in 3 files:** `Views/Onboarding/DesignSystem/OnboardingComponents.swift` (10), `OnboardingDesign.swift` (1), `Services/MemoryPressureResponder.swift` (2). The other 9 merge cleanly: SystemPermission, SeatbeltSandbox, NativeSearchBackends, SwapPressureMonitor, OnboardingMotion, Keychain, KeychainQueryHelpers, and 2 tests. The sentinel scan of the merged text finds no silent re-entry. Proposed resolutions:
  - `MemoryPressureResponder` (UP-OS-008): keep ours (`host.trimCaches()` / lease-free eviction). Upstream adds Osaurus-only caches (ThreadCache, ChatImageCache, `ModelRuntime`, `ImageGenerationService`, `SpeechService`/`TTSService.unloadIfIdle`). Optionally map "unload idle speech/TTS" onto our `ResidencyHost`.
  - Onboarding kit (UP-OS-015): 1.0 moves the components onto the new Osaurus theme catalog (`theme.assignedColor`, `.catalogTypography`, `theme.space`, `theme.hairline`; 50 uses in OnboardingComponents). That means **closure growth** into the non-vendored theme system, and 12 patch blocks re-written against new code. Take the M9.md fallback ("upstream restructured files on the allow-list → port instead of vendor for the worst files"): move the 4 `Views/Onboarding/DesignSystem/*` + `OnboardingTokens.swift` files into `AntiChatUI/Onboarding` as a port (watch rows), since AntiChat re-skins them completely anyway. The 5 AntiChatUI onboarding steps are the only users.
  - Watch files: 24 of the 38 changed between 0.25.33 and 1.0 (the largest are `SandboxManager.swift` +1764 −907, `MemoryView`, `NativeArtifactCardView`, `OnboardingView`, `SystemPromptComposer`). Review their deltas for our ports before re-pointing the citations.
- **Security in osaurus:** no advisories in the repo and no security-keyword commits pin..head. 1.0 hardens `SeatbeltSandbox` (per-agent scratch, `deny network-outbound` to localhost when network is allowed, per-agent writable roots). **AntiChat links SeatbeltSandbox but never calls it** (no use outside Vendor), so it is not applicable. Consider de-listing it at T09 (closure trim). The Keychain change (space-scoped service names) does not apply either: AntiChat uses `app.antichat.search` through UP-OS-033.
- **Licence:** MIT, LICENSE byte-identical (0.25.33 and 1.0).
- **Recommendation: take 0.25.33 at T09.** It changes no compiled code, keeps the citations current, and costs about 3 minutes. Take 1.0 at T09 **only if** it is tagged by then and the onboarding port above is done in the same change. Otherwise hold 1.0 for M11. Cost: the median agent bump stays in the minutes (S-1: 2.65 min). Even the 1.0 bump estimate of about 13 hunks ≈ 2–3 h by hand [INFERENCE, S-1's 10 min/hunk] is far under the 1-day / 4.5 pw-per-year bar.

### 2. speech-swift (FullDuplexAudioIO, SmartTurn, StreamingVADProcessor, Protocols)
- `d53bcb3` → main `468db5f` (26 commits, forced-aligner work). **No allow-listed file changed** (`report`: none). UP-SS-001…009 unaffected. No advisories, licence unchanged (Apache-2.0). **Hold.** At T09 re-run `make vendor-report NAME=speech-swift`. A change to `FullDuplexAudioIO.swift` would touch UP-SS-003/007/008/009 (4 hook rows), the most patched file of this donor.

### 3. FastVideo
- `d9e6c3e` → main `4deb3a5` (39 commits, mostly CUDA/NVFP4 and PAN2). One allow-listed file: `fastvideo/envs.py` (+85 −6, new env-var registry entries). The MLX runtime files with UP-FV-001/002 (`wan22_sample.py`, `wan_vae.py`) are unchanged. `make vendor-bump NAME=FastVideo REF=4deb3a50f`: 0 conflicts, patch-lint green.
- Hard-coded paths the bump does not rewrite: `tools/runtime/build_video_runtime.py` (`FASTVIDEO` path + ref), `Packages/Engines/Python/tests/test_parity.py`, and the citation comments in `antichat_video/{numerics,umt5}.py`. The first two were updated on the branch. The video runtime was **not rebuilt** (heavy, and the pass bar needs no model run).
- New upstream `SECURITY.md` only. Licence unchanged. **Hold:** no benefit to the MLX path, and a runtime rebuild plus R-040 re-check would cost more than it gains.

### 4. CommandPaletteKit
- `cf93b66` (v0.3.0) → main `2aec3e3`, 22 commits, none in the 30 allow-listed sources; no new tag. UP-CP-001…004 unaffected. **Hold.**

### 5. TUFF
- `22bb1af` → `5016aaa` (9 commits), `DownloadETAEstimator.swift` unchanged. The repo advisory GHSA-x5gm-gcx2-jr4p (TUFFServer Host header, DNS rebinding, < 9.5.6) concerns TUFFServer, which we don't vendor, and our pin is v10.x anyway. **Hold.**

### 6. sqlite-vec
- Pin = v0.1.9 release amalgamation (`e9f598a`, 2026-03-31). Upstream has only `v0.1.10-alpha.1…4`; main `04d28bd` (2026-05-17) adds ANN indexes (IVF, DiskANN, rescore), `INSERT OR REPLACE`, xRename.
- Security-relevant commits after the pin: `7de925b` int16 overflow in `l2_sqr_int8_neon`, `2f4c2e4` alignment UB in `distance_hamming_u64`, `c4c23bd` reject NaN/Inf in float32 input, `01b4b2a` DiskANN delete leak. **Our use:** `chunk_vec` is `vec0 float[1024]` (Migrations.swift), so the int8 and bit-vector paths are never taken, and DiskANN does not exist in 0.1.9. NaN/Inf: embeddings are unit-normalised by EmbeddingService, so they cannot reach the index. No GitHub advisories. Licence unchanged.
- Not bumped: a release donor needs a release asset (`github_release.tag`), and an alpha amalgamation is not something to ship. **Hold until v0.1.10 stable.** If it ships before T09, bump through `donors.json` `github_release` and run `SQLiteVecTests` + the Knowledge retrieval tests.

### 7. libxls
- v1.6.4 (`34c7cc6`) → main `93f1ad5` (2026-11-08, 4 commits, untagged): `93f1ad5` bounds-check the fallback index in `xls_getColor`, `5bfc669` grow the `xls_getCSS` buffer as rules are appended, `ddd6b8c` zero the XF entries added for BIFF5 records (uninitialised heap read by `xls_getCSS`), `0f07eaa` fuzz `xls_getCSS`. All four sit on the `xls_getCSS` path, **which AntiChat never calls**: `XLSAdapter` reads cells only, and `xls_getColor` has only `xls_getCSS` as caller. So the user-file attack surface is not changed by these fixes. They are memory-safety fixes in code we compile, though.
- `make vendor-bump NAME=libxls REF=93f1ad5e2`: 14 files, 0 conflicts (pristine copy). The bump did **not** rewrite `path: "Vendor/libxls@34c7cc6"` in Package.swift, `CLibXLSBridge/include/CLibXLSBridge.h` (`#include "../../../../../Vendor/libxls@…/include/xls.h"`), `config.h`, or the XLSAdapter header comment. They were fixed by hand, and the tool fix is below. `tools/ci/pins.json` `vendir.libxls` (commit; the `tag` key was removed because there is no tag) was updated too.
- Licence BSD-2-Clause, unchanged. **Take at T09** (cheap, no patches). Prefer a `v1.6.5` tag if upstream cuts one; otherwise take the commit and record "v1.6.4+4" in pins.json `note`.

### 8–10. agent-squad, ltx-2-mlx, LetsMove
- agent-squad `729d5f5` = head; ltx-2-mlx `895201d` → `747b30e` (1 commit, outside the allow-list); LetsMove `70c5772` = head (v1.25, dormant). **Hold.**

### 11. llama.cpp (llama-server helper)
- Submodule `620d222` (`b11669`, 2026-10-15) → `b12251` (`18c5a95`, 2026-11-10), 582 commits. No UP patch for llama.cpp (we build upstream as is; `Binaries/checksums.json` config `a05e0fa83440`).
- **Advisories:** 13 published GHSAs. All are fixed at or before b8146 (newest: CVE-2026-34159 RPC RCE ≤ b7991, CVE-2026-27940 ≤ b8145), so **our pin is not affected** by any published advisory.
- **Unpublished memory-safety fixes since our pin that hit our configuration (Metal, llama-server, grammar-constrained tool calls):** `e01c9f18` metal: prevent out-of-bounds writes to the Metal FA output buffer (#31662). `9b8446b9` metal: stop overflow in large matrix output offsets (#30072). `f1168ac4` grammar: limit recursion depth to prevent stack overflow (#29755); a model or user-supplied JSON schema could crash the helper. `372dc5ca` sanitize invalid UTF-8 in PEG tool-call arguments (#31861). `0978a6e9` signed overflow in the `ggml_roll` bounds check. `6f1e6543` cli crash on invalid UTF-8 (CLI only). Licence: MIT, LICENSE unchanged.
- Not rebuilt here. `make build` stages helper binaries by checksum from the build cache, and a new submodule means `make binaries` (a CMake/Metal build of about 10 min) plus a new `checksums.json` entry. Skipped on battery.
- **Recommendation: take at T09, before release.** Bump to the newest `b####` tag then, run `make binaries`, update `Binaries/checksums.json`, and re-run the llama-server engine conformance and the Evil-model AT legs. Renovate already proposes this digest PR (S-1).

### 12. stable-diffusion.cpp (sd-server / sd-cli helpers)
- Submodule `e239e4b` (master-1030, 2026-10-30) → `32d516c` (2026-11-11), 59 commits; nested `ggml` `7b2b435` → `d803c23`. Changes: new model families (MiniMax-H3 image, P-H3, HyperFlow H3, ControlNet Union SDXL), server features (`a3f46b6` configurable async job queue limits, `fc350be` generation stages, web UI), Metal fixes (`f61053c` group-norm batch elements, `abc6718` transfer-resource reclaim, `f977add` disable batch_cfg on Metal with upstream ggml).
- **Patch re-apply:** `Vendor/patches/sdcpp/UP-SD-001-unix-socket.patch` applies cleanly (`patch -p1 --dry-run` on head `examples/server/main.cpp`). 14 server files changed upstream, none in the patched hunks.
- **Advisories:** 6 GHSAs, all fixed before our pin (CVE-2026-70659/70660 fixed at master-763/764; our pin is master-1030 and contains both). Licence MIT, unchanged.
- **Recommendation: hold**, unless the Metal group-norm fix shows up in image QA. Take it at T09 if a photo regression points at it; it needs `make binaries` (sd-server/sd-cli are already non-reproduced builds per checksums.json).

### 13–21. SwiftPM pins
Applied on the branch with `swift package resolve` (and `swift package update swift-nio swift-asn1 swift-jinja` for the transitive minors), then `tools/ci/pins.json` updated: `pins-verify: 32 ok, 0 mismatch(es)`.
- **mlx-swift-lm** `f5b0677` → main `d7b94ee` (29 commits; still no tag contains our pin, latest tag 3.32.3 is older). **Main does not build in our Xcode build:** `c9a9a3d` (#711, 2026-11-10) uses `Logger` in `Libraries/MLXLMCommon/ModelComponent.swift` without `import os` (`error: cannot find 'Logger' in scope`, explicit-module build). **Resolution:** pin `ec4c966`, the parent of `c9a9a3d`; or at T09 pick the first main commit that adds the import, and report it upstream. Useful fixes in range: `2775ddd` RotatingKVCache keeps the pinned prefix visible in multi-token masks (#747, long-chat correctness for sliding-window models), `0877a36` weight-loading progress, `52e6001` model tensor buffer memory reporting. **Take at T09** at a building commit, with the engine conformance suite (test-strategy §3.3).
- **FluidAudio** 0.18.0 → **0.18.3**: ASR streaming-seam fixes (`70f4405`, `3037913`), vocabulary boosting fixes, PocketTTS sentence splitting (`9599521`, `da7a72c`), Kokoro ANE routing on OS 27 (`ee78635`). **Take at T09** and re-run the voice V-metrics affected (V1–V4 WER, TTS).
- **swift-huggingface** `199277c` → `3bee3b6` (1 commit: fall back to a regular session for background configurations). The 1.0.0 tag (2026-10-09) predates our pin. **Take at T09.**
- **GRDB.swift** 7.11.1 → **7.12.0**: `1d59d16` fix SharedValueObservation, WITHOUT ROWID / INTEGER PRIMARY KEY fixes. **Take at T09** (the Storage tests cover it).
- **EventSource** 1.5.1 → 1.6.0; **swift-log** 1.16.2 → 1.17.0 (`e3da040` MultiplexLogHandler metadata priority); **swift-transformers** `deaec6c` → 1.4.0. **Take at T09.**
- **swift-sdk (MCP)** `68300d7` → main `3059fd5` (10 commits): `f4ff45e` fix socket leak (CLOSE_WAIT) in NetworkTransport when reconnection is disabled, `960e77e` fix data races in NetworkTransport, `b9778b0` stop heartbeats after failed connection closes. These are reliability fixes, not advisories. **Take at T09** (MCP connector tests).
- **Transitive:** swift-nio 2.104.0 → 2.105.0 (all 6 swift-nio GHSAs were fixed by 2.101.0, so our pin was already clean), swift-asn1 1.7.3 → 1.7.4, swift-jinja 3.0.0 → 3.1.0. **Take at T09.**
- **swift-crypto** stays at 4.5.2 (latest 4.x). GHSA-jwv7-rv4f-rff2 (VOPRF input length, ≤ 5.0.2) is unfixed on 4.x, but it lives in `_CryptoExtras`. swift-huggingface and swift-transformers depend only on product `Crypto`, so the code is not linked. 5.x is blocked by their `"3.0.0"..<"5.0.0"` / `"1.0.0"..<"5.0.0"` ranges. **Hold** (re-check when either raises its range). GHSA-8q93 (RSA double-free, ≤ 4.5.0) is fixed in our 4.5.2.
- **swift-syntax** 603.0.2 (604.0.0 exists, but mlx-swift-lm caps `<604.0.0`): hold. **mlx-swift** 0.33.0 (main +4, no tag): hold.
- **Already latest:** Sparkle 2.10.1 (newest 2.x; its 5 GHSAs, the latest of which were fixed in 2.9.6, are all fixed in our pin), swift-subprocess 1.0.2, swift-async-algorithms 1.1.7, CocoaLumberjack 3.10.0, ZIPFoundation 0.9.20, KeyboardShortcuts 3.1.0, onnxruntime-spm 1.24.2, argmax-oss-swift 1.1.1, MarkdownView 3.0.0, swift-markdown 0.9.0, Defaults 9.0.9, package-benchmark 1.38.1, duckdb-swift `095e449` (= main), libxlsxwriter v1.2.4 (main ahead, no release), TPPDF 2.6.1, trafilatura-swift `e051b5e` (= v0.6.0 = main), Yams 6.2.2, swift-snapshot-testing 1.19.7, yyjson 0.13.0 (fixes GHSA-f4vc), Highlightr, RichText, swift-collections, swift-numerics, swift-system, swift-atomics, swift-argument-parser, SwiftMath, swift-cmark, swift-custom-dump, swift-issue-reporting. Not present yet (`when: present`): kanna, menubarextraaccess, whatsnewkit, swiftui-introspect.

### 22. Python runtimes and Vendor/js
- OSV.dev batch query over all exact pins: filetools runtime (20) + video runtime (44) PyPI pins, 0 known vulnerabilities (numpy 2.5.4, pandas 3.1.1, pillow 13.0.0, pypdf 6.21.4, openpyxl 3.1.5, transformers 5.22.2, fastapi 0.162.2, starlette 1.10.0, h11 0.16.0, …).
- `Vendor/js/package-lock.json`: `image-size` 1.2.1 (dependency of pptxgenjs 4.0.1) has GHSA-5p2g-fcmc-qvqq and GHSA-w3rx-r6r6-pgpr (HIGH, infinite loop in JXL/HEIF/ICNS parsers, fixed in 2.0.3). **Not shipped:** we ship `pptxgen.bundle.js` (the browser bundle), which doesn't contain image-size (Node-only `fs` path; no `image-size`/parser code in the bundle). **Hold.** At the next `make vendor-js`, add an npm `overrides` entry `image-size@^2.0.3` (or accept as dev-only) so the lock stops flagging.

---

## Build and tests on the synced branch

State built: osaurus 0.25.33, libxls `93f1ad5`, FastVideo `4deb3a5`, all SwiftPM bumps above with mlx-swift-lm at `ec4c966`. Helper binaries are at the main pins.

| Step | Result |
|---|---|
| `make build` #1 | **failed**: `AntiChat.xcworkspace/xcshareddata/swiftpm/Package.resolved` out of date (P2). Fix: copy the root `Package.resolved`. |
| `make build` #2 | **failed** in mlx-swift-lm `d7b94ee`: `ModelComponent.swift:28: cannot find 'Logger' in scope` (upstream `c9a9a3d`). Fix: pin `ec4c966` (`9e92d5cd5`). |
| `make build` #3 | **failed** in our code: `MLXAdapter.swift:96` and `:153` "switch must be exhaustive". mlx-swift-lm `173c163` (#608, mid-turn steering) added `Generation.steering(_)` and `GenerateStopReason.steered`. Fix (`391acde30`): drop `.steering` events, and end `.steered` like `.stop` (AntiChat never steers). That is the only source change the whole sync needed. |
| `make build` #4 | **green** (`** BUILD SUCCEEDED **`, app copied to `build/AntiChat.app`). |
| `make test-unit` #1 | not meaningful: the `fixtures` submodule was not checked out in the fresh worktree (`file://` transport is blocked for submodules here), so every fixture-reading test failed. Fixtures were then cloned (APFS `cp -c`) from the main checkout at the same gitlink `c3133f2`. |
| `make test-unit` #2 | **green**: `test-unit: main passed`, `test-unit: childsafety passed`, exit 0. 16 Swift Testing runs, 2,709 tests, 0 failures. Guard checks (summaries, xunit, leftovers) clean. 18 min 26 s wall. Covers the vendored targets (`OsaurusVendoredTests`, e.g. SeatbeltSandboxTests, ChunkedFileDownloaderTests, DeclarativeSearchBackendTests), XLSAdapterTests on the new libxls, GRDB-backed Storage tests, the MCP/swift-sdk tests and the Engines tests on the new mlx-swift-lm. |

Not run (out of scope for a battery-powered rehearsal; required at T09): `make test-integration-stub`, the engine conformance suite with real models, `make audit` (needs `BINARIES_SRC`), helper-binary rebuilds, the video/filetools runtime rebuilds. `make audit-vendor` and `pins-verify` were run (green). Test-produced `build/at/*` evidence files were reverted, not committed.

---

## Security review

| Upstream | Advisory / fix | Affects our pin? | Reachable in AntiChat? | Action |
|---|---|---|---|---|
| llama.cpp | `e01c9f18` Metal FA output OOB write; `9b8446b9` Metal matmul offset overflow; `f1168ac4` grammar recursion stack overflow; `372dc5ca` invalid UTF-8 in tool-call args (no GHSA) | yes (b11669) | yes: llama-server on Metal with grammar/tool calls | **take at T09, before release** (+ `make binaries`) |
| llama.cpp | 13 GHSAs (latest CVE-2026-34159, CVE-2026-27940) | no (fixed ≤ b8146) | — | none |
| libxls | `93f1ad5`, `5bfc669`, `ddd6b8c` (fuzz-found OOB / uninitialised reads) | yes | no (`xls_getCSS` path only) | take at T09 |
| sqlite-vec | `7de925b` int8 NEON overflow, `2f4c2e4` hamming UB, `01b4b2a` DiskANN leak | int8/hamming yes; DiskANN n/a | no (float[1024] only) | hold until v0.1.10 stable |
| swift-crypto | GHSA-jwv7-rv4f-rff2 VOPRF (≤ 5.0.2) | yes (4.5.2) | no (`_CryptoExtras` not linked) | hold; 5.x blocked upstream |
| npm image-size | GHSA-5p2g / GHSA-w3rx DoS | yes (1.2.1 in lock) | no (not in the browser bundle) | override at next vendor-js |
| osaurus 1.0 | SeatbeltSandbox hardening | yes | no (vendored, unused) | none; consider de-listing |
| TUFF | GHSA-x5gm (TUFFServer) | no | no | none |
| stable-diffusion.cpp | 6 GHSAs (pickle/safetensors/imatrix loaders) | no (fixed before master-1030) | — | none |
| Sparkle, swift-nio, yyjson, swift-asn1, mlx, duckdb | all published GHSAs | no (fixed in our pins) | — | none |

---

## Tooling and procedure findings

Fixed on this branch (cherry-pick to `main`; no pin change):
- **T1** `tools/vendor-sync bump` crashed with `KeyError: 'test_target'` in `gen_package()` on the first bump that had a conflict. LetsMove (M10.T02) has a target but no test target. Any conflicted bump of any donor hit it. Fix: skip a missing test target. (`14dc58601`)
- **T2** `_relocate` mapped access-rewrite entries with identical source lines to the *first* occurrence. The three `search` / `parseHTML` declarations of DDG/Brave/Bing in `NativeSearchBackends.swift` all landed on lines 31/65, so patch-lint failed 4× on a file upstream had not touched. This was S-1's "known limit", now hit for real. Fix: keep the occurrence rank among identical lines. (`14dc58601`)
- **T3** A root-level donor (`path: "Vendor/libxls@<short>"`, no trailing slash) kept its old Package.swift path. Hard-coded donor paths elsewhere were silently left stale. Fix: the bump rewrites both Package.swift forms and prints `STALE-REF <file>` for every other file naming `<name>@<old-short>`. (`28612944d`)

Procedure gaps (add to upstream.md §7 / the T09 steps; not fixed here):
- **P1 Port citations gate VENDORED.json.** Watch rows are listed only when a port header cites `<slug>@<current short>:<path>`. After a bump, the 14 cited osaurus watch rows dropped out until the 24 citing files were re-pointed. T09 step: `make vendor-report ARGS=--ports`, review each changed watch file's delta against its port, then re-point the citations (the branch did it mechanically for the rehearsal).
- **P2 Three resolved files move together.** `make build` failed (`an out-of-date resolved file was detected at AntiChat.xcworkspace/xcshareddata/swiftpm/Package.resolved`) until the workspace copy matched the root `Package.resolved`. `Benchmarks/Package.resolved` also carries copies of the bumped pins (not updated here). On `main` the workspace file already differs from the root file in `originHash` (bootstrap step 6 `cmp` would flag it). Copy the root file over at T09.
- **P3 pins.json is hand-edited** for every SwiftPM, vendir and submodule pin (`pins-verify` catches misses).
- **P4 Upstream HEAD can be broken** (mlx-swift-lm `d7b94ee`). For revision-pinned packages, choose a commit that passes our Xcode build, not just upstream CI.
- **P5 ACKNOWLEDGMENTS.md regeneration needs the binary submodules** (`tools/acknowledgments.py` fails "no llama.cpp/vendor or sdcpp/thirdparty"). Run it from a checkout with `git submodule update --init Binaries/*` or pass `--binaries-src`.
- **P6 Fresh worktree:** `.tools/bin/vendir` is not there until `tools/bootstrap.sh` step 3. Installing just vendir from `tools/toolchain-sources.json` (sha256-checked) is enough for the sync.
- **P7 Renovate dry run (M9.md step 4)** was not re-run. S-1 showed Swift lookups need a GitHub token in local mode. The manual ls-remote + `swift package resolve` path above covers the same ground.
- **P8** `main`'s VENDORED.json lacked the watch row for `Services/Skill/SkillSearchService.swift` (cited by `AntiChatTools/Skills/SkillSelector.swift`). `vendored-json` adds it, so regenerate on main.

## T09 run plan (from this rehearsal)
1. Cherry-pick `14dc58601` + `28612944d` to main first.
2. `git switch -c rehearsal/sync-2` (fresh); vendir from toolchain-sources if not bootstrapped.
3. `make vendor-report ARGS=--ports`; osaurus → latest tag (`make vendor-bump NAME=osaurus REF=<tag> ARGS=--no-branch`); resolve per the rules above; `tools/vendor-sync finish osaurus`; review the watch deltas; re-point citations; `make audit-vendor`. If the tag is 1.x, port the onboarding design system first.
4. libxls (and any donor with allow-listed changes) the same way; fix every `STALE-REF`.
5. SwiftPM: the "take at T09" rows above at building commits (carry the `MLXAdapter` steering fix, `391acde30`, if mlx-swift-lm is past `173c163`); copy `Package.resolved` → workspace (and Benchmarks); `pins-verify`.
6. llama.cpp submodule → newest `b####`; `make binaries`; update `Binaries/checksums.json`.
7. `make build`, `make test-unit`, `make test-integration-stub`, the engine conformance suite, `make audit`; regenerate ACKNOWLEDGMENTS.md with submodules present; record the evidence in `S-1-vendor-sync.md` "Rehearsal #2".

## Branch commits
| Commit | What | For main? |
|---|---|---|
| `14dc58601` | vendor-sync: gen_package without a test target; access-rewrite occurrence rank (T1, T2) | **yes, now** |
| `8ab78e6a1` | osaurus → 0.25.33 (66c3dde) + citations + pins.json | no (T09 redoes it) |
| `28612944d` | vendor-sync bump: root-level Package.swift path + STALE-REF listing (T3) | **yes, now** |
| `8c00bf938` | libxls → 93f1ad5, FastVideo → 4deb3a5 + hard-coded paths | no |
| `a4fb06fc7` | SwiftPM pins to latest | no |
| `9e92d5cd5` | mlx-swift-lm → ec4c966; workspace Package.resolved | no |
| `391acde30` | MLXAdapter: `.steering` / `.steered` | at T09, with the mlx-swift-lm bump |
| (this file) | rehearsal record | yes (docs) |

Evidence logs (scratch, not committed): vendor report, build logs #1–#4, test-unit logs #1–#2, GHSA and OSV query output; all numbers above are copied from them.
