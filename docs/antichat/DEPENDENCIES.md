# Dependency baseline (M0 step 1)

Set on 2026-11-24 by the integration lane. All versions are exact pins. Nobody else edits `package.json`, `yarn.lock`, `ios/Podfile*`, the Xcode project, Android Gradle files, `AndroidManifest.xml`, `metro.config.js`, `babel.config.js` or `patches/`; ask the integration lane.

## Upgraded

| Package | From → to | Note |
|---|---|---|
| `react-native-keyboard-controller` | 1.22.7 → 1.24.0 | `KeyboardChatScrollView` with `blankSpace` |
| `react-native-reanimated` | 4.7.1 → 4.8.0 | `reanimated.staticFeatureFlags.DISABLE_COMMIT_PAUSING_MECHANISM: true` in `package.json` (keyboard-controller's requirement on iOS); the Android commit-hook flag is already the 4.8 default |
| `react-native-worklets` | 0.13.0 → 0.14.0 | Required by Reanimated 4.8 |
| `react-native-gesture-handler` | 2.33.1 → 3.5.0 | `gestureHandlerRootHOC` is gone; `src/antichat/compat/gestureHandlerRootHOC.tsx` replaces it for upstream `App.tsx` |
| `react-native-enriched-markdown` | 1.1.1 → 1.3.0-nightly-20261123-3a2c1ade8 | Needed for `createMarkdownStream()` and `streamingConfig.smooth` (not in 1.2.0). `enableMath: true`. Upstream's patch ported. Move to 1.3.0 when it is released |
| `react-native-nitro-modules` | 0.37.1 → 0.37.2 | For Unistyles |

## Added

| Package | Version | For | Native |
|---|---|---|---|
| `@legendapp/list` | 3.9.0 | Message list (`KeyboardAwareLegendList`) | no |
| `react-native-pulsar` | 1.7.0 | Haptics, streaming tick | yes |
| `react-native-unistyles` | 3.8.2 | Theme tokens (M1). Babel plugin not enabled yet: M1 asks the integration lane when it adopts it | yes |
| `@lodev09/react-native-true-sheet` | 4.1.2 | Native sheets | yes |
| `@react-native-menu/menu` | 2.3.3 | Native dropdown menus | yes |
| `react-native-teleport` | 1.2.5 | Portal for the long-press overlay | yes |
| `@callstack/liquid-glass` | 0.8.2 | iOS 26 glass | yes (iOS) |
| `@sbaiahmed1/react-native-blur` | 6.0.3 | Blur / material fallback | yes |
| `react-native-zoom-toolkit` | 5.1.1 | Image viewer (substitute for Galeria, see below) | no |
| `@op-engineering/op-sqlite` | 19.0.6 | `antichat.db`, `rag.db`. `op-sqlite: {sqliteVec: true, fts5: true}` in `package.json` | yes |
| `@react-native-community/netinfo` | 12.0.1 | Connectivity flag | yes |
| `react-native-notify-kit` | 10.10.1 | Notifications | yes |
| `react-native-audio-api` | 1.0.1 | Audio decode, echo-cancelled I/O | yes |
| `react-native-localize` | 3.8.0 | Device locale | yes |
| `lucide-react-native` | 1.79.0 | One icon set on both platforms | no |
| `minisearch` | 7.2.0 | BM25 for tool and chunk retrieval | no |
| `jsonrepair` | 3.15.0 | Tool-call repair | no |
| `fflate` | 0.8.3 | Zip for export/import | no |
| `@react-native-community/geolocation` | 3.4.0 | `get_location` tool (M12) | yes |
| `tweetnacl` | 1.0.3 | Ed25519 check of the catalogue signature (M5). Audited (Cure53), pure JavaScript, no dependencies | no |

## Skipped or deferred, and why

| Package | Decision |
|---|---|
| `@nandorojo/galeria` 3.1.0 | **Skipped.** It is an Expo module (`expo-module.config.json`, Gradle applies `expo-modules-core`). Substitute: `react-native-zoom-toolkit` (plain Reanimated + Gesture Handler) |
| `react-native-edge-to-edge` | **Not added.** Deprecated; Unistyles lists it as optional. `edgeToEdgeEnabled=true` in `android/gradle.properties` is the replacement and is M1's call (it changes how upstream screens lay out) |
| `expo-paste-input`, `expo-glass-effect` | **Skipped** (Expo modules). Glass comes from `@callstack/liquid-glass`; image paste becomes a small native patch when M10 gets there |
| `react-native-ama` | **Skipped.** npm has 0.7.5, not the 2.0.0 the research names; dev-time only. Re-check in M14 |
| `llama.rn` | **Kept at 0.13.0-rc.11.** rc.12 exists, but the device spike is measuring rc.11 and upstream carries a 1,100-line patch against it |
| `@modelcontextprotocol/client`, `react-native-inappbrowser-reborn` (M12); `react-native-document-scanner-plugin`, `react-native-image-analysis`, `@cantoo/pdf-lib`, `officeparser` (M10); `@react-native-ai/apple`, `@react-native-ai/android` (M11); `@kesha-antonov/react-native-background-downloader` (M5, only if the head-to-head picks it); `voltra` (M13) | **Deferred** to their milestones through the integration lane (gap analysis §5 rule 2). Each is marked unverified on RN 0.87 / New Architecture in 05a/05b and needs its own build test, Metro remaps or native targets; none blocks M1–M9 |

## Expo: decided against, for now

We do **not** install `expo` / `expo-modules-core`.

- No Expo SDK lines up with our React Native: SDK 57 targets RN 0.86, SDK 58 targets RN 0.88; we are on 0.87.1 with upstream.
- It needs edits in `AppDelegate.swift`, `MainApplication.kt`, `settings.gradle`, the `Podfile` and Metro — all upstream files that would conflict on every merge.
- Nothing in M0–M9 needs it. The three things that wanted it have non-Expo answers (table above).
- Cost: Private Mind components that import Expo modules have those imports rewritten when lifted.

Revisit only if a later milestone needs an Expo-only module with no substitute; then install `expo-modules-core` alone, not `expo prebuild`.

## Build notes

- Android 17: `android/build.gradle` forces CameraX 1.5.3. vision-camera 4.7.2's own pin (1.5.0-alpha03) crashes the app a few seconds after launch on Android 17; CameraX 1.7.0 does not compile with vision-camera 4.7. Upgrading vision-camera to 5.x (M10) removes the force.
- Android 17 shows a "nearby devices" (local network) prompt on first launch of a debug build: React Native's dev support probes for Metro. Release builds do not.

- iOS: `tools/antichat/build-ios-debug.sh sim|device` (incremental). `patches/react-native-unistyles+3.8.2.patch` makes Unistyles include its own `Parser.h` by relative path: llama-rn's `parser.h` otherwise wins through the case-insensitive header map.
- `patches/@react-native-menu+menu+2.3.3.patch` (iOS, `NewArch/MenuView.mm`): a long press on a view taller than the visible part of its scroll view lifts only a band around the finger, so a long answer no longer covers the top bar or gets shrunk. Create patches with `npx patch-package <name> --exclude 'android/build|package\.json$'`.
- Android: `tools/antichat/build-android-debug.sh [install]` → "AntiChat Dev" (`com.pocketpalai.antichatdev`), JS bundle embedded, arm64 only by default. Needs NDK 27.3.13750724, CMake 3.22.1, build-tools 37.0.0, platform android-37 and a local placeholder `android/app/google-services.json` (gitignored) listing the dev application id.
- After any `yarn install`, before `pod install`: `(cd node_modules/react-native-audio-api && bash scripts/download-prebuilt-binaries.sh ios)`. Yarn removes its fetched xcframeworks; without them `pod install` leaves them out of the Pods project and the app fails to link (`_ogg_*` undefined), and a second `pod install` is needed.
- Adding a package: plain `yarn add <name>@<version> --exact`, never with `--ignore-scripts`. Yarn 1 re-extracts every patched package and removes files that were fetched into `node_modules` after the install (the RaTeX engine, `PhononCore.xcframework`). If scripts were skipped anyway, repair with `./scripts/postinstall.sh && node node_modules/react-native-enriched-markdown/postinstall.mjs && (cd ios && pod install)`; check with `for p in patches/*.patch; do patch -p1 -R --dry-run -s -f < $p >/dev/null || echo "not applied: $p"; done`.
- `react-native-enriched-markdown` fetches its LaTeX engine (RaTeX) in its `postinstall`; after an install with `--ignore-scripts` run `node node_modules/react-native-enriched-markdown/postinstall.mjs` before `pod install`.
