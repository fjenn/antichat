# Isolation audit: framework callbacks that inherit main-actor isolation

- Branch: `fix/isolation-traps` (from `main` @ `f767a630c`).
- Trigger: P74, the MCP sign-in crash. `ASWebAuthenticationSession` called its completion on an XPC reply queue. The
  closure was written inside a `@MainActor` method, so it was main-actor isolated, and Swift 6's runtime isolation
  check trapped on entry (EXC_BREAKPOINT in `_dispatch_assert_queue_fail`). Fixed in `86c5faa70` on
  `fix/xcuitest-r6`. That commit is cherry-picked here unchanged, so the two branches merge cleanly.
- Scope: every Swift file the app and its helpers compile. That is 1,147 files: `App/{AntiChat,EngineHelper,
  EngineStandby,FileToolsHelper}`, `Packages/*/Sources`, `Packages/*/Tools`, `tools/*/Sources`, plus the vendored
  sources compiled through `Package.swift` (the `osaurusSources`, `speechSwiftSources`, `agentSquadSources`,
  `tuffSources` and `commandPaletteSources` lists). SPM dependencies (Sparkle, KeyboardShortcuts, Defaults, GRDB,
  WhisperKit, FluidAudio, mlx and others) are covered only where our code passes them a closure.

## When the trap fires (measured, not assumed)

I compiled small probes with `swiftc -swift-version 6` on this machine's SDK. Each probe registers a callback from an
isolated context and fires it from a background queue:

| Case | Result |
|---|---|
| `@MainActor` method, `DispatchSource.setEventHandler`, source on `.global()` | **trap** (SIGTRAP, exit 133) |
| `actor` method (instance isolation), same DispatchSource | no trap |
| `@MainActor` method, Combine `publisher(for:).sink`, notification posted off main | **trap** |
| `@MainActor` method, `NotificationCenter.addObserver(forName:queue:nil)` (block is `NS_SWIFT_SENDABLE`), posted off main | no trap (the closure is nonisolated) |
| `@MainActor` method, our own Swift 6 API taking a non-Sendable closure, called off main | no trap (no check emitted) |
| SwiftUI `.onReceive(NotificationCenter.publisher)`, posted off main | no trap (SwiftUI delivers the action on the main thread) |

So the crash class needs all three of these:

1. The closure is written in a **global-actor** context (`@MainActor` type, method or SwiftUI view).
2. It is passed to an **Objective-C / C or pre-Swift-6 module** API whose parameter is **not `@Sendable`**.
3. The framework calls it **off that actor's thread**.

An explicitly `@Sendable` closure is nonisolated, which is the fix pattern.

I checked the SDK headers and swiftinterfaces for which callback types are not Sendable:

- **Not Sendable (risky):** `DispatchSourceHandler`, `AVAudioNodeTapBlock` (`NS_SWIFT_NONSENDABLE`), `AVAudioNodeCompletionHandler` (`NS_SWIFT_SENDING` only), `AudioObjectPropertyListenerBlock`, `xpc_handler_t`, `AVSpeechSynthesizer.BufferCallback`, `ASWebAuthenticationSession.CompletionHandler`, the `NSWorkspace` `openApplication`/`open(_:configuration:)`/`recycle` completions, `NSEvent` monitor handlers, `NSSavePanel.beginSheetModal` and `CFRunLoopObserver` handler blocks.
- **Sendable (safe by type):** `NotificationCenter` block observers, `Timer` blocks, `FileHandle.readabilityHandler`, `NSItemProvider` completions, `Thread.detachNewThread`, the Network.framework handlers (`NWPathMonitor`, `NWConnection`, `NWListener`) and the XPC Swift overlay (`XPCSession`, `XPCListener`).

## Fixed

| Site | Verdict | Fix | Test |
|---|---|---|---|
| `Packages/Tools/.../MCP/OAuth/WebAuthPresenter.swift` `present` (`ASWebAuthenticationSession` completion, XPC reply queue) | **Real** (P74, crashed in MCPOAuthUITests) | cherry-pick of `86c5faa70`: explicit `@Sendable` completion, released on the main queue | none (the closure is local to `present`; extracting it would conflict with `fix/xcuitest-r6`). Covered by MCPOAuthUITests on that branch |
| `Packages/UI/.../Failure/NewerDataWindow.swift` `AppRelaunch.relaunch` (`NSWorkspace.openApplication` completion, private concurrent queue) | **Real, latent**: the relaunch after Remove everything / newer-data recovery would trap before `terminate` | `WorkspaceCompletion.onMain` builds a nonisolated `@Sendable` completion that hops to the main actor | `IsolationTrapTests.workspaceCompletionCalledOffMainHopsToTheMainActor` |
| `Packages/UI/.../Uninstall/UninstallSheet.swift` `UninstallRunner.run` (`NSWorkspace.recycle` completion) | **Latent**: main-actor closure, called on "the queue recycle was called from". The main actor runs on the main queue today, so it holds, but only by that coupling | same helper | same test (recycle shape, with an error) |
| `Packages/UI/.../Uninstall/InstallTestHooks.swift` `-RunUninstall` hook (`recycle` completion → `exit`) | **Latent** (same as above; DEBUG/AT hook) | explicit `@Sendable` closure | n/a (calls `exit`) |
| `Packages/UI/.../Settings/Voice/LevelMeter.swift` `InputLevelMeter.tapBlock` (audio render thread) | Already fixed (Q-015 r4 / M9 probe). No regression test existed | none needed | `IsolationTrapTests.levelTapCalledOffMainDeliversOnTheMainActor` (calls the tap from a background queue) |

## Checked: safe

Each row gives the site, the callback queue, the isolation of the code that writes the closure, and the verdict.

### Non-Sendable callbacks (the risky types), all outside any global actor

| Site | Callback / queue | Context | Verdict |
|---|---|---|---|
| `Engines/.../Scheduler/PressureMonitor.swift:41` | DispatchSource memory pressure, `.global` | `actor PressureMonitor` (instance actor: no dynamic check, measured) | safe |
| `Platform/.../Power/AppPressureMonitor.swift:23` | DispatchSource, `.global` | `@unchecked Sendable` class, nonisolated | safe |
| `Vendor/osaurus/.../MemoryPressureResponder.swift:52` | DispatchSource, private queue | nonisolated class | safe |
| `Engines/.../Voice/ScriptedVoice.swift:84` | DispatchSource timer | nonisolated class | safe |
| `FileToolsHost/.../FileToolsService.swift:39,50` | DispatchSource timer; `xpc_connection_set_event_handler` | nonisolated class (XPC service) | safe |
| `Tools/.../FileTools/FileToolsClient.swift:101,127` | `xpc_connection_set_event_handler`, `xpc_connection_send_message_with_reply` | nonisolated class / nonisolated async func | safe |
| `Engines/.../Voice/DictationCapture.swift:37` (`MicCapture`) | `installTap`, render thread | nonisolated class | safe |
| `Vendor/speech-swift/.../FullDuplexAudioIO.swift:198,572` | `installTap`; `scheduleBuffer` completion | nonisolated class | safe |
| `Engines/.../Voice/CaptureVPIO.swift:76` | `scheduleBuffer(completionHandler: nil)` | no closure | safe |
| `Engines/.../Voice/AudioFormat.swift:43`, `FullDuplexAudioIO.swift:509,680` | `AVAudioConverter` input block | synchronous, caller's thread | safe |
| `Engines/.../TTS/SystemTTS.swift:30`, `SystemVoiceBackend.swift:105` | `AVSpeechSynthesizer.write` buffer callback | nonisolated classes | safe |
| `Platform/.../Audio/AudioDeviceCatalog.swift:128` | `AudioObjectAddPropertyListenerBlock`, private queue | nonisolated class; block typed `@Sendable` | safe |
| `Knowledge/.../Projects/LinkedFolderWatcher.swift:20` | FSEvents C callback, private queue | `@convention(c)`, no captures, nonisolated class | safe |
| `Platform/.../Power/PowerMonitor.swift:68` | `IOPSNotificationCreateRunLoopSource` C callback | nonisolated class | safe |
| `UI/.../Renderer/RendererInstrumentation.swift:48`, `UI/.../Window/BackgroundRun.swift:46` | `CFRunLoopObserverCreateWithHandler` | `@MainActor`, but added to `CFRunLoopGetMain()` only | safe (main thread) |
| `UI/.../Voice/VoiceOverlay.swift:286`, `Vendor/CommandPaletteKit/.../KeyMonitor.swift:23` | `NSEvent.addLocalMonitorForEvents` | `@MainActor` | safe (AppKit calls local monitors on the main thread) |
| `UI/.../Composer/Menus/ComposerMenus.swift:253` | `NSOpenPanel.beginSheetModal` | `@MainActor` | safe (main thread) |
| `UI/.../Window/WindowState.swift:515`, `UI/.../MacIntegration/QuickPanelController.swift:153` | `NSAnimationContext` / `CATransaction` completion | main | safe |
| `UI/.../MacIntegration/GlobalShortcuts.swift:39` | `KeyboardShortcuts.onKeyDown` (Carbon hot key) | main run loop | safe |

### Sendable callbacks (the compiler keeps these nonisolated)

| Site(s) | API | Verdict |
|---|---|---|
| `Network/.../PathStatus.swift:28`, `UI/.../Help/HelpGuideSheet.swift:20`, `Engines/.../LLM/UnixHTTPClient.swift` | `NWPathMonitor.pathUpdateHandler`, `NWConnection.stateUpdateHandler` (`@Sendable`) | safe |
| `Harness/.../Engine/EngineClient.swift:141`, `EngineHost/.../EngineListener.swift:92`, `SessionRouter` | `XPCSession` / `XPCListener` handlers (`@Sendable`) | safe |
| `Tools/.../MCP/StdioPipeTransport.swift:28` | `FileHandle.readabilityHandler` (Sendable) | safe |
| `UI/.../Composer/PasteHandler.swift:36,42` | `NSItemProvider.loadObject` / `loadDataRepresentation` (Sendable), in `@MainActor` funcs | safe |
| All `NotificationCenter.addObserver(forName:object:queue:using:)` sites (Engines `VoiceAudioEngine`; Harness `FileToolsTools`, `MCPTools`; Platform `WakeObserver`, `DownloadPolicy`, `PowerMonitor`, `LocationPermission`, `PermissionCenter`, `PermissionCoordinator`; Tools `MCPHTTPTransport`, `WebSearchAvailability`; UI `AppBootstrap` ×4, `DraftBinding`, `ZoomableImageView`, `GlobalShortcuts`, `MenuItemIdentifiers`, `OnboardingWindow`, `SkillsPage`, `ConnectionsModel`, `ShortcutNames`, `SpikeChatView`, `VoiceAvailability`, `VoiceOverlay`, `ChatSessions` ×2, `WindowCentered`, `WindowState`; osaurus `Localization`) | Sendable block. Every one that uses `MainActor.assumeIsolated` registers with `queue: .main` | safe |
| `Harness/.../AutoArchiveService.swift:64`, `UI/.../AXAttributeProbe.swift:19`, `MemoryReviewScheduler.swift:54`, `DailyBackupScheduler.swift:29`, osaurus `SystemPermissionService.swift:318` | `Timer.scheduledTimer(block:)` (Sendable), main run loop | safe |
| `Engines` / `Platform` / `Storage` / `Tools` / `UI/ExportAllView` `Thread.detachNewThread` | Sendable block | safe |
| `App/AntiChat/AntiChatApp.swift:76` | `PerfRecorder.setQuitHandler` (`@Sendable`, fired via `DispatchQueue.main.async`) | safe |

### Delegates and `@objc` entry points

| Site | Verdict |
|---|---|
| `Platform/.../Notifications/NotificationService.swift` (`@MainActor`, `UNUserNotificationCenterDelegate`) | both delegate methods are `nonisolated` and hop with `Task { @MainActor }`. safe |
| `Platform/.../Permissions/LocationPermission.swift` `LiveLocationBridge`; osaurus `SystemPermissionService` (`@MainActor`) | `CLLocationManagerDelegate` methods nonisolated (bridge class / `nonisolated func`). safe |
| `Platform/.../Updates/UpdaterBridge.swift` (`@preconcurrency SPUStandardUserDriverDelegate`), `UpdateGate.swift` | nonisolated `@unchecked Sendable` classes, so the `@preconcurrency` conformance has no isolated witnesses to check. Sparkle calls on main anyway. safe |
| URLSession delegates: `NetworkGate.Recorder`, `TransferEngine.TransferLane`, `PageFetcher.TaskProbe`, `HeadlessAuthPresenter.NoRedirect`; osaurus `ChunkedFileDownloader` ×2, `SearchReadability` | nonisolated classes (nested types do not inherit the outer actor). safe |
| `Tools/.../FileOut/RenderHost.swift`, `UI/.../SandboxedWebPreview.swift` (+ `ErrorProxy`), `UI/.../MermaidBlockView.swift` | WebKit delegates / script handler / scheme handler: WebKit calls on main. safe |
| `UI/.../Artifacts/SidePanel.swift:240` `SelectionCoordinator` (`@MainActor`, `#selector` observers) | `PDFViewSelectionChanged` / `PDFViewPageChanged` are posted on main by PDFKit. safe |
| `Engines/.../TTS/SystemVoiceBackend.swift` (`AVSpeechSynthesizerDelegate`) | nonisolated class. safe |
| XMLParser delegates (Knowledge EPUB / Extraction, Tools XLSX, osaurus PPTX / XLSX) | synchronous on the caller's thread, nonisolated classes. safe |

### Continuations wrapping callback APIs (closure body inherits the caller's isolation)

| Site | Context | Verdict |
|---|---|---|
| `Tools/.../RenderHost.swift:107`, `UI/.../MermaidBlockView.swift:89` | `@MainActor`, stores the continuation; resumed from WebKit delegate (main) | safe |
| `UI/.../Media/MediaJobQuitGuard.swift:66` | `@MainActor`, closure stored in our own main-actor dictionary | safe |
| osaurus `SystemPermissionService.swift:570` | `@MainActor`, resumed from a `Task { @MainActor }` | safe |
| `Harness/.../EngineClient.swift:155,218,493,533`, `FileToolsClient.swift:126`, `TransferEngine.swift:407`, `SystemTTS.swift:28`, `SystemVoiceBackend.swift:93`, `UnixHTTPClient.swift:91`, `ChildSafetyCheck.swift:312,346`, `VideoRuntimeSupervisor.swift:45`, `SDVideoEngine.swift:34`, `QueryDataTool.swift:127`, osaurus `FileReadImageSupport.swift:120` / `Keychain.swift:458` / `ChunkedFileDownloader.swift:729`, `tools/bench Citations.swift:271` | nonisolated | safe |
| actor-isolated waiters (`VideoPlanBroker`, `RouteScorer`, `FileToolsSlots`, osaurus `MetalGate` / `ModelLease`, Harness / Engines / Platform waiter lists) | instance actors (no dynamic check) | safe |

### Async-imported framework calls from `@MainActor` code

`AVCaptureDevice.requestAccess`, `UNUserNotificationCenter.requestAuthorization` / `notificationSettings`,
`LAContext.evaluatePolicy` (`EvilModeModel`), `QLThumbnailGenerator.generateBestRepresentation` (`Thumbnail`),
`WKWebView.evaluateJavaScript` / `takeSnapshot` / `callAsyncJavaScript`, `NSSavePanel.beginSheetModal` (async),
`CNContactStore.requestAccess` (osaurus). All are safe: the compiler-generated continuation resumes the caller's
executor, so no user closure runs on the framework's queue.

### Other categories checked with nothing found

- KVO `observe(\.…)` / `observeValue`: no uses.
- Combine `.sink` / `.assign`: no uses (the trap case in the table above).
- `Process.terminationHandler`: no uses. `Process` is used with `waitUntilExit` only.
- `NSXPCConnection` / `remoteObjectProxy` / interruption / invalidation handlers: no uses (the XPC Swift overlay and libxpc are used instead; covered above).
- `SFSpeechRecognizer`: no uses (`SpeechAnalyzerBackend` is async).
- `AVAsset.loadValuesAsynchronously`, `AVAssetImageGenerator`, `AVAssetExportSession`, `addPeriodicTimeObserver`: no uses.
- `CLLocationManager` completion APIs, `NSBackgroundActivityScheduler`, `SecTrustEvaluateAsync`, `NSFilePresenter`: no uses.
- SwiftUI `.onReceive` (16 sites, several on notifications posted off main, e.g. `PathStatus.didChange` from the
  `NWPathMonitor` queue): measured safe, because SwiftUI delivers the action on the main thread.
- `Defaults.observe` (`EnginePolicyPush`, `PersonalizationSync`): written in nonisolated contexts. safe.
- Default isolation: no target sets `SWIFT_DEFAULT_ACTOR_ISOLATION` / `defaultIsolation(MainActor.self)` or
  `NonisolatedNonsendingByDefault`, so nothing is main-actor by inference beyond the explicit annotations and
  AppKit / SwiftUI types.

### `@preconcurrency import`

`AVFoundation` (24 files), `CoreML` (5), `CoreLocation` (2), `Highlightr` (`CodeHighlighter`), `AppKit` (osaurus
`SystemPermissionService`). These imports only downgrade Sendable diagnostics. Every closure handed to those modules
from those files is listed above: the installTap / scheduleBuffer / speech-write sites, all in nonisolated classes,
and `LevelMeter`, which is already nonisolated. Highlightr and CoreML calls are synchronous. Nothing else in those files
hands those modules an escaping closure.

## Rule for new code

When a framework or C API takes a callback that is not `@Sendable` and you are in a `@MainActor` type, method or
view, do not write the closure literal inline. Build it as an explicitly `@Sendable` closure (or in a `nonisolated`
static factory) and hop to the main actor inside it. `WorkspaceCompletion.onMain` and `InputLevelMeter.tapBlock` are
the patterns to copy. The same applies to `MainActor.assumeIsolated` inside a callback: use it only when the API
guarantees the main thread (`queue: .main`, the main run loop, AppKit UI callbacks).

## Gates (2026-11-11, this branch)

`make test-unit` passed: main and childsafety, including `IsolationTrapTests`. `make test-integration-stub` passed:
93 tests, 30 skipped, 0 failures. `make audit` with `BINARIES_SRC` set passed (EXIT=0).
