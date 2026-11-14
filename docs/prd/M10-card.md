# M10 card: release build, signing + notarization, DMG, Sparkle, keys, site, release close

Read `BUILD-BRIEF.md` first, then this card, then only your task sections in `M10.md`. This card doesn't repeat task steps. Where it and `M10.md` disagree on a repo fact, the card is right (it was checked against the tree on 2026-11-08, main @4cb051a0).

## What M10 delivers
A reproducible Release pipeline: `make build-release` builds, signs inside out and verifies the app in `adhoc`, `dev` or `devid` mode. In `devid` mode it notarizes (notarytool, keychain profile), staples and passes Gatekeeper. `make dmg` packs a branded, signed (and in devid notarized + stapled) DMG under 300 MB, with Move to Applications. Sparkle updates arrive in the background behind a "Restart to update" pill, from an EdDSA-signed appcast with phased rollout. Keys are split dev/release with a build-time guard. A static site hosts the download, appcast, catalog and legal pages. The milestone closes with the release checklist, the AT-FA suite and RC visual QA.
**Exit:** `M10.md` header "Exit" row.

## Order and chunks
T01 → T02 → T03 → T04 → T05 → T06 → T07 → T08 → T09 → T11 → T10 (BUILD-ORDER chunks 23 = [T01–T06], 24 = [T07 T08 T09 T11 (+T10)]).
Release infrastructure doesn't depend on feature completeness: T01–T03 may run while M3–M9 tracks are still landing, against current main. AT legs that need finished features (AT-FA, the upgrade suite's image/memory/project data) are re-run at chunk 24.

## Changed since M10.md was written (2026-10-30)
- **Credentials exist (Q-003 answered).** `Developer ID Application: Finn Jennen (446XT9839S)` is in the login keychain, and the notary keychain profile is `AntiChat-notary`. So the devid signing, notarization (`xcrun notarytool submit --keychain-profile AntiChat-notary --wait`), stapling and `spctl` legs that M10.md parks in T10 run **now**, in T01 (app) and T02 (DMG). T10 keeps only the production-key ceremony, the production deploys and the devid re-runs of AT-FA-01/12.
- **`notarize.sh` moves forward** from T08 to T01 (`tools/release/notarize.sh`, `make notarize TARGET=app|dmg`). It's a no-op that prints `SKIPPED (UNNOTARIZED)` unless `SIGNING_MODE=devid`. Secrets never enter the repo or logs; the keychain profile is the only credential path.
- **Endpoints placeholders.** `Config/Endpoints.plist` `IssuesURL` and `SupportEmail` stay placeholders until the owner provides the repo URL and the support inbox. `tools/ci/endpoints-check.py --strict` is the release gate and must keep refusing them. The pipeline's publish preflight (`tools/release/preflight.py`) lists every blocker to publishing; today the expected list is the placeholders plus the human items (key ceremony, hosting), and nothing from engineering.
- **Never publish during the build.** No `vercel deploy`, no `gh release`, no `git push` to a remote host, no appcast upload. Every artefact stays under `build/release/`, `build/updates/` and `site/public/`; the M10 report lists what publishing needs.

## Repo reality (the PRD text is older than M0–M8's code)
- **Signing (M0.T12) already exists:**
  - `tools/release/sign.sh --mode adhoc|dev|devid --app <app> [--report f]` (Nativ port; inside out, deepest first, never `--deep`) and `--bundle <dir>` for runtime trees.
  - `tools/release/verify-signing.sh [--mode] [--out] [--tree] <target>` (verify, per-Mach-O identity/runtime/timestamp, `spctl` + `syspolicy_check`, quarantine).
  - Entitlements are `tools/release/entitlements/{AntiChat,AntiChatEngine,llama-server,sd-server,video-runtime}.plist` and `adhoc-extra.plist` (not `*.entitlements` / `adhoc-overrides.plist`). `App/AntiChat/AntiChat.entitlements` must equal `AntiChat.plist` (sign.sh fails otherwise).
  - `make build-release` builds (no archive yet) into `build/AntiChat.app`; T01 moves output to `build/release/AntiChat.app` and adds the archive, dSYMs, arch check and version stamping.
- **Identities on this Mac:** `Apple Development: … (P9327X24WP)` (dev mode) and `Developer ID Application: Finn Jennen (446XT9839S)` (devid). The two Team IDs differ; that's fine, because one build uses one identity throughout.
- **One bundle id per signing identity (M6.T19, `tools/ci/signing-identity-ids.py` on the m6 track).** macOS ties sandbox containers and TCC to the code identity. Debug builds are `app.antichat.AntiChat.dev`; Release builds carry the shipped ids (`app.antichat.AntiChat`, `.Engine`, `.EngineStandby`, `.llama-watchdog`, and the File tools `.FileTools[.Net]` once M6 lands). **Never launch a shipped-id bundle signed with a test identity.** The release pipeline never executes anything inside `build/release/AntiChat.app`. A launch smoke uses a copy re-identified to `app.antichat.AntiChat.relprobe-<mode>` (app + every XPC), signed by `sign.sh`, and launched in the background (`open -g -j`, never taking focus).
- **Sparkle** 2.10.1 is a SwiftPM dependency (Package.swift). The tools (`sign_update`, `generate_appcast`, `generate_keys`) are at `build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/` after one Xcode build. `Packages/Platform/Sources/AntiChatPlatform/UpdateGate.swift` (`UpdateGateDelegate`, M2.T02) already gates checks and downloads on NetworkGate `updates`; T03 builds `UpdaterBridge` on it rather than beside it. Settings › Updates (`UpdatesSection.swift`) holds the models toggle and the `set.updates.later` placeholder row that T03 replaces. `StatusPill` lives in `AntiChatUI/Sidebar/StatusPill.swift`.
- **Sparkle test key:** `catalog/test-keys/sparkle-test.{key,pub}` (M0.T12), already in `SUPublicEDKey` (project.yml). There is no `fixtures/catalog/test-keys/sparkle-dev-ed25519.*`: use the existing pair. `tools/release/appcast-test.sh` is the M0 round trip.
- **Catalog keys / PinnedKeys:** `AntiChatPlatform/Catalog/PinnedKeys.swift` is hand-written (M2). `Config/Keys.*.plist` and `gen-keys-swift.py` are T04.
- **Not present, so the owning task creates it:** `create-dmg` (not installed), `Vendor/LetsMove`, `tools/release/{notarize.sh, package-dmg.sh, verify-dmg.sh, appcast.sh, appcast-post.py, appcast-lint.py, feed-server.py, pr5-check.py, preflight.py, lib/identity.sh}`, `notes/`, `Config/Keys.*.plist`, `site/` Starlight project (only `site/public/` exists).
- **Tart isn't installed.** VM legs (AT-225 move as a standard user, AT-219 upgrade, AT-NFR-PR5 two clones, AT-FA) record `pending (Tart)` until T09 installs it from its pinned release. Local stand-ins, run on re-identified copies only, are allowed and labelled as such.
- **`tools/.venv`** isn't created in a fresh worktree; `uv sync --project tools` creates it. New Python deps go in `tools/pyproject.toml` + `uv.lock` with exact pins.
- **XCUITest can't start (Q-015).** Write UI tests, run in-process probes, record the XCUITest leg as `pending (Q-015)`.

## Key decisions taken up front
- **DMG layout without Finder scripting.** create-dmg lays out the window by AppleScript-driving Finder, which opens Finder windows and needs Automation permission (it takes focus from the owner, against the background-test rule). T02 uses **dmgbuild** (MIT, pinned in `tools/pyproject.toml`), which writes the `.DS_Store` and the background alias directly. Same window, icons, `Applications` link and HiDPI TIFF; recorded as an amendment.
- **Version numbers:** `CFBundleShortVersionString` from `VERSION` (default `0.0.1` until the owner sets 1.0), `CFBundleVersion` = `git rev-list --count HEAD`. Both are stamped into the built app's Info.plist, never into the repo plist.
- **Labels:** adhoc/dev → `UNNOTARIZED` in the DMG name and `build/release/LABEL`; devid builds that used dev keys are labelled `DEVKEYS` and are never put in `appcast.xml` (production feed). Only devid + production keys + no placeholders = publishable.

## Key types and interfaces (names are contracts; later tasks call them)
- **Pipeline (T01/T02):**
  - `make build-release SIGNING_MODE=… [VERSION=…]` → `build/release/AntiChat.app`, `build/release/dSYMs/`, `build/release/LABEL`, `build/release/sign-report.tsv`, `build/release/verify/`.
  - `make notarize TARGET=app|dmg` → `build/release/notary/<target>-<id>.json` + log; staples.
  - `make dmg SIGNING_MODE=…` → `build/release/AntiChat-<ver>[-UNNOTARIZED].dmg`; `tools/release/verify-dmg.sh <dmg>`.
  - `tools/release/preflight.py [--json]` → blockers to publishing, exit 0 only when none.
- **Updates (T03):**
  - `UpdaterService` (vendored osaurus, patched) owns `SPUStandardUpdaterController`.
  - `UpdaterBridge` (SPUUpdaterDelegate + SPUStandardUserDriverDelegate) wraps `UpdateGateDelegate`'s checks; `UpdateState { idle, checking, ready(version, notes), failed }`, `restartToUpdate()`.
  - `tools/release/appcast.sh FEED=dev|stable` → `site/public/appcast-dev.xml` / `appcast.xml`; `appcast-post.py`, `appcast-lint.py`.
- **Keys (T04):** `Config/Keys.dev.plist` / `Keys.release.plist`, `gen-keys-swift.py` (`#error` on test keys in a release-keys build).

## Cross-task contracts
1. **Signing order:** never `--deep` when signing; app last; third-party nested code keeps its entitlements. `make audit` greps `tools/release` for `codesign … --deep` on signing lines.
2. **devid builds are notarized before anything else reads them;** a devid artefact that failed notarization is deleted, never left next to good ones.
3. **Secrets:** notary credentials only via `--keychain-profile AntiChat-notary`; the Developer ID private key never leaves the keychain; no secret in the repo, logs, or `build/` evidence (`make audit` token scan).
4. **No shipped-id launches under a test signature** (above).
5. **The production feed (`appcast.xml`) refuses** UNNOTARIZED or DEVKEYS DMGs and placeholder endpoints.
6. **Never touch models or user data on update** (Sparkle swaps only the bundle; data lives in Application Support).
7. **Copy:** every new string is a copy-deck key, added to the deck and the xcstrings file in the same commit (`make design-gen`, `copy-sync.py`).

## Verification scope (D-025)
- Each task runs its own ATs and the legs it can run on this Mac; VM legs are `pending (Tart)` until T09; XCUITest legs `pending (Q-015)`.
- The end-to-end devid dry run (Release build → Developer ID sign → notarize → staple → `spctl -a -vvv` → DMG notarize/staple → mount check) is run once in T01/T02 on current main and recorded under `build/at/AT-305/` and `build/at/AT-225/`.
- Full NFR re-measurement and parity scoring stay in M9. Visual QA captures (About label, DMG window, Updates settings, pill) are collected in T11.
- Milestone close (T11): all ATs, full suite, independent code review, running-app check on the release build, 1440×900 light/dark captures, headline numbers (DMG size, cold launch of the release build).

## Gotchas
- `codesign --verify --deep-verify-only` doesn't exist at Xcode 27.1; verify falls back to `--deep` (A-M0-T12a b).
- macOS 26 `spctl` prints no `source=` for ad-hoc code; the reason comes from `syspolicy_check distribution` (A-M0-T12a c).
- `spctl -a -t exec` on a devid app accepts only after the ticket is stapled or reachable online; assess after stapling.
- `notarytool` rejects a bare `.app`: submit a `ditto -c -k --keepParent` zip, staple the app, then build the DMG from the stapled app and notarize + staple the DMG too.
- Sparkle's `Downloader.xpc` keeps its own entitlements (`--preserve-metadata=entitlements`); re-signing it bare breaks downloads.
- `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO` still writes dSYMs into the archive; keep them out of the DMG (NFR-D1).
- Release Swift builds of SwiftPM C targets need `NDEBUG` (`RELEASE_CDEFS`, DuckDB).

## Pins and IDs to grep
- Sparkle `2.10.1 (ab7d712)`, Nativ `@72f4b91` (sign/notarize/appcast scripts), LetsMove `@70c5772`, osaurus `@2922745` (UpdaterService), dmgbuild (pinned in `tools/pyproject.toml`), WhatsNewKit `2.2.1 (6157c77)`, Starlight `0.42.7`.
- Decisions: D-006, D-007/D-010 (hosting, no mirror), D-013, D-014 (`LSMinimumSystemVersion 26.0`), D-017 (identities), D-025, Q-003 (answered), Q3 (domain), Q-015.
- Patches: P-platform-02, -07, -12, -13, -14; P-shell-18. Sections only, in `docs/research/09-patches/`.

## M11
Nothing in M10 moved to M11. Sparkle auto-updates are explicitly never touched by M11.
