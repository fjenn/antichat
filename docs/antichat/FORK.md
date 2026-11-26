# AntiChat Mobile — fork rules

This repo is a fork of [PocketPal AI](https://github.com/a-ghorbani/pocketpal-ai) (MIT).

- `upstream` remote = `a-ghorbani/pocketpal-ai`. Branch `vendor/upstream` tracks `upstream/main` untouched; `main` is ours.
- Base: `upstream/main` at `5a27b5f` (v1.24.0 plus 6 commits). The tag itself was not used because the `onnxruntime-c` pod fix that `pod install` needs landed after it.
- Take upstream changes with `git fetch upstream && git merge upstream/main` (merge, not rebase), then run `ruby tools/antichat/add-ios-files.rb` if `project.pbxproj` conflicted (also after adding a file to `ios/AntiChat/`). The script needs the `xcodeproj` gem, which Homebrew's CocoaPods carries: `GEM_HOME=/opt/homebrew/Cellar/cocoapods/<version>/libexec ruby tools/antichat/add-ios-files.rb`.

## The rule

**Our code lives in our own directories. Upstream files get the smallest possible edit, marked `ANTICHAT:`, and are listed below.**

| Ours | What |
|---|---|
| `src/antichat/` | All AntiChat TypeScript. `index.ts` is the only entry upstream code calls. |
| `src/antichat/spike/` | Hidden developer spike harness (see below). |
| `src/antichat/spike-ui/` | M0 scroll/keyboard/streaming spike (`docs/antichat/M0-DECISION.md`). |
| `src/antichat/compat/` | Shims for APIs upstream code still calls after a dependency upgrade. |
| `ios/AntiChat/` | Our native iOS code and the debug entitlements. |
| `android/app/src/main/java/com/pocketpalai/antichat/` | Our native Android code (Kotlin package `com.pocketpal.antichat`). |
| `docs/antichat/`, `docs/PLAN.md`, `docs/research/` | Our docs (upstream owns the other files in `docs/`). |
| `tools/` | Our scripts (`tools/antichat/`). |
| `refs/`, `models/` | Local only, gitignored: reference checkouts and GGUF files. |

Do not delete or restyle upstream screens, stores or services; leave them in place and stop importing them. Prefer a wrapper in `src/antichat/` to an edit.

## Edits to upstream files

Listed in [`docs/UPSTREAM-PATCHES.md`](../UPSTREAM-PATCHES.md) (file, edit, reason, owner). Dependencies, what was skipped and the Expo decision: [`DEPENDENCIES.md`](DEPENDENCIES.md).

Release and Profiling configurations are still upstream's (`ai.pocketpal`, manual signing); they are rebranded when the first release build is set up.

## Local files a build needs (gitignored)

`.env` (copy of `.env.example`), `ios/Config/Env.xcconfig` (copy of the example), a placeholder `ios/GoogleService-Info.plist`, `ios/.xcode.env.local` (`NODE_BINARY`), a placeholder `android/app/google-services.json` with a client entry for `com.pocketpalai.antichatdev`.

## Android

`source tools/android-env.sh` (JDK 17, SDK, AVD `antichat-pixel`), then `tools/antichat/build-android-debug.sh install`. The debug build installs as "AntiChat Dev" (`com.pocketpalai.antichatdev`) with the JS bundle embedded (release-mode JS, no Metro). SDK packages the Gradle files need: platform `android-37.0`, build-tools `37.0.0`, NDK `27.3.13750724`, CMake `3.22.1`.

After moving or re-cloning the repo, delete `ios/build/ModuleCache.noindex` (it stores absolute paths); everything else in `ios/build` is reused.

## Spike harness

`src/antichat/spike/` runs `docs/research/03-spike-protocol.md` steps 1–3 without supervision. It replaces the app's root only in a debug build launched with `-antichatSpike 1` (or env `ANTICHAT_SPIKE=1`).

- Models: every `*.gguf` in the app's `Documents/spike-models/` (files with `mmproj` in the name are skipped), smallest first.
- Results: `Documents/spike-results/<model>.json`, rewritten after every stage, plus `_run.json`, `status.json` (progress, `finished`) and `spike.log`.
- Per model: memory before/after load and after release (`os_proc_available_memory`, `phys_footprint`, resident size, sampled every 2 s natively for the peak), cold and warm load time, `bench()`, time to first token (short prompt; tool prompt cold and with cache reuse), tokens per second at start, a sustained run with tokens per second and thermal state per iteration, the 30 tool cases in native and router mode, and the 10 chat prompts (answers stored for manual scoring).
- A model that throws on load is recorded as `load_failed`. A model that kills the process is recorded as `crashed` on the next launch and skipped, so relaunching resumes.
- Options, as launch arguments (`-antichatSpikeSustainSec 20`) or env (`ANTICHAT_SPIKE_SUSTAIN_SEC=20`): `SustainSec` (600), `NCtx` (8192), `NGpuLayers` (99), `IdleSec` (10), `CooldownSec` (300), `ToolLimit` (0 = all 30), `ChatLimit` (0 = all), `Skip` (comma list of `warm,bench,ttft,tps_start,sustained,tools_native,tools_router,chat`), `Models` (comma list of name parts), `Force 1` (rerun finished models), `Reset 1` (forget status).
- Not covered yet (protocol items that need a hand or a second build): step 0 entitlement A/B and dirty-memory probe, context growth, mmap/KV-type one-offs, vision, background survival, the thinking-on rerun, MLX head-to-head. C10 uses a stand-in article (`chatSet.ts`).

Phone run in one go: `tools/antichat/run-spike-on-device.sh` (build must exist; see the script header).

### Running it

- Build: `tools/antichat/build-ios-debug.sh sim|device` (incremental, JS bundle embedded, no Metro).
- Simulator: copy a GGUF into the app container's `Documents/spike-models/`, then
  `SIMCTL_CHILD_ANTICHAT_SPIKE=1 xcrun simctl launch <sim> ai.antichat.mobile.dev -RCT_jsLocation 127.0.0.1:1`
  (the last argument stops a Metro server of another project on port 8081 from being used). CPU only: it checks the harness, not speed.
- iPhone: `tools/antichat/run-spike-on-device.sh` (install → copy models → launch → poll → results in `docs/research/spike/results/`). The app must stay in front with the phone unlocked; in the background iOS stalls Metal work and the run hangs.

### Signing state (2026-11-24)

Xcode on this Mac has no Apple ID signed in, so automatic signing cannot create a profile for `ai.antichat.mobile.dev` with the two memory entitlements ("No Accounts"). Until someone signs in under Xcode → Settings → Accounts, only the baseline build works: `ANTICHAT_NO_ENTITLEMENTS=1 tools/antichat/build-ios-debug.sh device` signs with the existing wildcard team profile and `ios/AntiChat/AntiChatDevBaseline.entitlements` (about 3.0 GiB available at launch on the iPhone 17 Pro).

## Scroll/keyboard/streaming spike (M0)

`src/antichat/spike-ui/` is the M0 chat-list spike; the result and what M2 lifts from it are in [`M0-DECISION.md`](M0-DECISION.md). It replaces the app's root only in a debug build: iOS launch argument `-antichatSpikeUI A|B`, or on any platform a file `Documents/antichat-spike-ui.json` (`{"list":"A"}`).

- Unattended checks with frame recording: `tools/antichat/spike-ui-run.sh ios|android A|B script15|script30|script60|model` → `docs/antichat/m0/`. Summary of any result file: `tools/antichat/spike-ui-summary.py docs/antichat/m0/*.json`.
- Touch-driven flow (Maestro): `tools/antichat/spike-ui-maestro.sh ios|android A|B`.
- With several simulators or emulators running, set `ANTICHAT_SIM=<udid>` and `ANDROID_SERIAL=<serial>`.
- JS console of the simulator app: `tools/antichat/ios-js-log.sh <seconds> [launch args]`.
