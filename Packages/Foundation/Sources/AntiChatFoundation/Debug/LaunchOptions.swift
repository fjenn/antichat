// Debug launch-option registry (docs/prd/M1.md convention 10; M1.T02). The ONE place that parses
// test-only launch arguments (test-strategy §4.2). Parsing only: each consuming task implements the effect.
// Release builds compile the type (every field at its default) but neither `Key` nor the parser: `parse` returns the
// empty set, so a release ignores every option and its binary carries none of the option names.
// Adding an option = add it to `Key`, to the struct, to `parse`, to LaunchOptionsTests and to M1.md conv. 10.
import Foundation

public struct LaunchOptions: Sendable, Equatable {
    /// Hardware tiers accepted by `-FakeHardware` (hardware-tiers §2).
    public enum Tier: String, Sendable, CaseIterable { case T0, T1, T2, T3, T4 }

    // The names exist only where they are parsed: a release build carries none of them (tools/ci/dev-modes-guard.py).
    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Every recognised argument name (without the leading `-`).
    public enum Key: String, Sendable, CaseIterable {
        case useScriptedEngine = "UseScriptedEngine"
        /// M4.T04 step 7: `<script.json>` (ScriptedImageScript) — image jobs run the helper's ScriptedImageEngine.
        case useScriptedImageEngine = "UseScriptedImageEngine"
        /// M5.T03: `<script.json>` (ScriptedVideoScript) — video jobs run the helper's ScriptedVideoEngine.
        case useScriptedVideoEngine = "UseScriptedVideoEngine"
        case useScriptedTools = "UseScriptedTools"
        case devContainer = "ANTICHAT_DEV_CONTAINER"
        case offlineOnly = "OfflineOnly"
        case fakeHardware = "FakeHardware"
        case fixedClock = "FixedClock"
        case fakeEvilEnabled = "FakeEvilEnabled"
        case fakeVoiceInstalled = "FakeVoiceInstalled"
        case fakeInstalledPacks = "FakeInstalledPacks"
        case fakeDisabledPacks = "FakeDisabledPacks"
        case fakeWebSearchEnabled = "FakeWebSearchEnabled"
        case fakeConnectionsEnabled = "FakeConnectionsEnabled"
        case fakeContextWindow = "FakeContextWindow"
        case rendererCPUScale = "RendererCPUScale"
        case prefillThrottleTokPerSec = "PrefillThrottleTokPerSec"
        /// M1.T07: in-process window/layout probe writing `<dir>/probe.json` (AT-001 while XCUITest is blocked, Q-015).
        case uiProbe = "UIProbe"
        /// M1.T11: in-process ⌘K palette probe writing `<dir>/probe.json` (AT-012 while XCUITest is blocked, Q-015).
        case paletteProbe = "PaletteProbe"
        /// M1.T09: in-process renderer probe (AT-008 leg 4 cadence/hitches/fade) writing `<dir>/renderer.json`.
        case rendererProbe = "RendererProbe"
        /// M1.T18: in-process context probe (AT-009 while XCUITest is blocked, Q-015) writing `<dir>/probe.json`.
        case contextProbe = "ContextProbe"
        /// M1.T22: in-process Settings probe (AT-100/AT-062/AT-011 leg 4/AT-012 leg 2 while XCUITest is blocked, Q-015)
        /// writing `<dir>/probe.json`; a second launch on the same `<dir>` verifies the values after relaunch.
        case settingsProbe = "SettingsProbe"
        /// M1.T23: in-process Appearance probe (AT-101 while XCUITest is blocked, Q-015) writing `<dir>/probe.json`.
        case appearanceProbe = "AppearanceProbe"
        /// M9.T01/T03/T04: in-process accessibility inventory (AT-223 part 1 / AT-102 legs while XCUITest is blocked).
        case a11yProbe = "A11yProbe"
        /// M1.T24: in-process shortcuts / menus / windows probe (AT-103/AT-104 while XCUITest is blocked, Q-015);
        /// `-ShortcutsMode shortcuts|windows|restore|lastwin` picks the leg (read by the probe).
        case shortcutsProbe = "ShortcutsProbe"
        /// M1.T22: Settings keys use the named UserDefaults suite instead of the app domain (probes and tests never
        /// touch the developer's own settings).
        case defaultsSuite = "DefaultsSuite"
        /// M1.T19: in-process turn probe (AT-003/010/014/299 while XCUITest is blocked, Q-015) writing `<dir>/probe.json`.
        case turnProbe = "TurnProbe"
        case searchProbe = "SearchProbe"
        case scriptedWebSearch = "ScriptedWebSearch"
        /// M7.T06: `-DumpPrompts <dir>` writes each rendered prompt to `<dir>/<turn-id>.txt` (PromptDump, AT-081 c2).
        case dumpPrompts = "DumpPrompts"
        /// M7.T06: `-ScriptedMCP <file.jsonl>`: every MCP connection answers from that recorded session (no network).
        case scriptedMCP = "ScriptedMCP"
        /// M7.T07: `-OAuthHeadless YES`: MCP OAuth sign-in runs the authorize GET itself (HeadlessAuthPresenter) instead
        /// of the browser sheet, against the reference AS (`tools/mcp-ref`, auto-approves). DEBUG only.
        case oauthHeadless = "OAuthHeadless"
        /// M1.T20: in-process incognito probe (AT-090 journey 8 while XCUITest is blocked, Q-015) writing `<dir>/probe.json`.
        case incognitoProbe = "IncognitoProbe"
        // Defaults overrides (convention 9) until M1.T22 toggles them through the UI.
        case sendWithCommandEnter = "sendWithCommandEnter"
        case plainTextComposer = "plainTextComposer"
        case showContextUsage = "showContextUsage"
        /// M1.T25b: Settings → Capabilities → Advanced "Show model info" (R-234 AC2) until the Advanced row binds it.
        case showModelInfo = "showModelInfo"
        // M1.T08: debug composer host for ComposerTests until the lead wires the composer into MainWindow.
        case composerHarness = "ComposerHarness"
        /// M4.T10/T11: debug host showing a FileCard per file in `<dir>` and the side panel (FileCardTests,
        /// SidePanelTests) until M6.T13 puts cards into turns.
        case artifactsHarness = "ArtifactsHarness"
        /// M1.T17: in-process + / slash / @ menu and tool-chip probe (AT-013 while XCUITest is blocked, Q-015) writing
        /// `<dir>/probe.json`; a second launch on the same container checks the chips after relaunch.
        case menusProbe = "MenusProbe"
        /// M1.T21: in-process draft autosave probe (AT-302 while XCUITest is blocked, Q-015) writing `<dir>/probe.json`;
        /// phases across launches on the same container (type → quit / crash → relaunch → restored?).
        case draftProbe = "DraftProbe"
        /// M1.T25b: in-process Model info probe (AT-234 while XCUITest is blocked, Q-015) writing `<dir>/probe.json`.
        case modelInfoProbe = "ModelInfoProbe"
        /// M2.T01: free disk on the Models volume, in whole GB (onboarding/preflight fixtures).
        case fakeFreeDiskGB = "FakeFreeDiskGB"
        /// M2.T01: print the hardware profile JSON to stdout and exit (tools/at/at-200-live.sh).
        case printHardwareProfile = "PrintHardwareProfile"
        /// M2.T03: `-FakeNetwork none|expensive|constrained|ok` overrides NWPathMonitor (PathStatus).
        case fakeNetwork = "FakeNetwork"
        /// M2.T09: `-FakePower ac|battery:<pct>|lowpower` overrides the power source (DownloadPolicy, R-207).
        case fakePower = "FakePower"
        /// M2.T14: `-FakeThermal nominal|fair|serious|critical` overrides ProcessInfo.thermalState (NFR-B3).
        case fakeThermal = "FakeThermal"
        /// M2.T14: `-FakePressure warn|critical` makes the helper handle that memory-pressure level once (R-206 AC3).
        case fakePressure = "FakePressure"
        /// M2.T17: `-FakeLAContext succeed|fail` answers the Touch ID prompt for Evil chats (R-211 AC4).
        case fakeLAContext = "FakeLAContext"
        /// M3.T02: `-FakePermission microphone=notDetermined|denied|granted[,…]` overrides PermissionCenter's
        /// TCC status (and answers `request` with it) for the named permissions.
        case fakePermission = "FakePermission"
        /// M3.T03: `-UseScriptedVoice <script.jsonl>`: dictation captures from ScriptedVoice (fixture WAVs at real-time
        /// pace, `{t_ms, wav, gain_db}` lines) in the helper instead of the microphone (environment §5).
        case useScriptedVoice = "UseScriptedVoice"
        /// M3.T08: `-FakeAudioDevices none|<name>[,<name>…]` replaces the CoreAudio input-device list in Settings ›
        /// Voice (`AudioDeviceCatalog`): `none` = no input devices (R-053 AC1 "No devices found").
        case fakeAudioDevices = "FakeAudioDevices"
        /// M3.T12: `-FakeAEC unavailable`: the voice conversation behaves as if VPIO could not be enabled (half duplex).
        case fakeAEC = "FakeAEC"
        /// M3.T12: `-FakeAudioRoute headphones|speakers|noaec`: the conversation's output route (R-280 AC2/AC3).
        case fakeAudioRoute = "FakeAudioRoute"
        /// M3.T04: `-FakePackState voice=absent|downloading|ready[,…]` overrides a pack's install state (Basic voice
        /// vs the Voice pack); a running DEBUG app flips it with the `TestHooks.setPackState` notification.
        case fakePackState = "FakePackState"
        /// M2.T09: `-DownloadHost <url>` rewrites `https://huggingface.co` in download sources to a fixture server.
        case downloadHost = "DownloadHost"
        /// M2.T03: `-TestProxy host:port`: every gated session goes through this HTTP(S) proxy (proxy-logger.py).
        case testProxy = "TestProxy"
        /// M2.T05: `-CatalogURL <url>` replaces Endpoints.plist `CatalogURL` (fixture catalog hosts).
        case catalogURL = "CatalogURL"
        /// M7.T11: `-RelayURL <url>` replaces Endpoints.plist `RelayURL` (the Composio relay; `make relay-dev`).
        case relayURL = "RelayURL"
        /// M7.T01: `-SearchBlockEngine duckduckgo[,brave]`: those engines answer 403 in-process (AT-248 c3).
        case searchBlockEngine = "SearchBlockEngine"
        /// M2.T18: `-SkipOnboarding YES` never shows onboarding (M1 behaviour); `-ResetOnboarding YES` always does.
        case skipOnboarding = "SkipOnboarding"
        case resetOnboarding = "ResetOnboarding"
        /// M2.T20: `-OnboardingProbe <dir>` drives onboarding → first chat → hand-off in-process (NFR-M5 run).
        case onboardingProbe = "OnboardingProbe"
        /// M2.T26: `-VisualQAProbe <dir>` captures the M2 screens (AT-VQ-M2) with `screencapture -l` and quits.
        case visualQAProbe = "VisualQAProbe"
        /// M8.T12: `-NotificationSpy <file.json>`: notifications are recorded to that file instead of delivered
        /// (UserNotificationCenterSpy); with `-FakePermission notifications=…`, opened System Settings URLs go to
        /// `opened-urls.txt` beside it instead of opening.
        case notificationSpy = "NotificationSpy"
        /// M8.T12–T14: `-MacIntegrationProbe <dir>` drives notifications, background media jobs, the menu bar item,
        /// the quick panel and the JIT permission matrix in-process (AT-108/042/105/106/109 while XCUITest is
        /// blocked, Q-015); `<dir>/mode` picks the legs; writes `<dir>/probe.json`, quits.
        case macIntegrationProbe = "MacIntegrationProbe"
        /// M10.T09: `-FinalAcceptanceProbe <dir>` drives the AT-FA legs in-process (real models; `<dir>/leg` picks the
        /// leg; tools/install-test/steps/fa-*.sh in a clean VM while XCUITest is blocked, Q-015); writes
        /// `<dir>/probe.json`, quits.
        case finalAcceptanceProbe = "FinalAcceptanceProbe"
        /// M9.T06: `-SoakProbe <dir>` drives the AT-NFR-S3 mixed session in-process (real models; `<dir>/config.json`
        /// sets the length and the legs; tools/perf/soak.sh) and writes samples, events and `result.json` into `<dir>`.
        case soakProbe = "SoakProbe"
        /// M8.T13: `-QuickPanelHotkeyHook YES`: a DEBUG distributed notification `app.antichat.test.quickPanelHotkey`
        /// calls the same handler as the global hotkey (QuickPanelUITests).
        case quickPanelHotkeyHook = "QuickPanelHotkeyHook"
        /// M10.T06/T07: `-OpenURLSpy <file>`: web links the app hands to the browser (Help › AntiChat Help, the help
        /// guide's "Open the full help centre", Legal's "View latest online") are appended to `<file>`, one per line,
        /// instead of opening (HelpUITests / LegalUITests; never takes focus).
        case openURLSpy = "OpenURLSpy"
        /// M10.T07: `-SimulateUpdatedFrom <version>`: a launch with no recorded What's new version behaves as an update
        /// from `<version>` (the sheet shows once; the next launch has the current version recorded). HelpUITests.
        case simulateUpdatedFrom = "SimulateUpdatedFrom"
        /// fix/test-plist-hygiene: `-FreshDefaultsSuite YES` empties the `-DefaultsSuite` suite once at launch. A UI
        /// test's suite must be on disk (the app is another process, and a relaunch keeps it), so its name is stable
        /// and the app — not the sandboxed test runner, whose prefs live in its container — starts it empty.
        case freshDefaultsSuite = "FreshDefaultsSuite"
    }
    #endif

    /// `-UseScriptedEngine <path|NO>`: path of a ScriptedEngine JSONL script; `NO` = real engines.
    public var scriptedEngineScript: String?
    /// `-UseScriptedImageEngine <script.json>` (M4.T04): steps, delayMs, crashAtStep, slowCancelMs, footprintBytes.
    public var scriptedImageScript: String?
    /// M5.T03: `-UseScriptedVideoEngine <script.json>` (DEBUG).
    public var scriptedVideoScript: String?
    public var useScriptedTools = false
    /// `-ANTICHAT_DEV_CONTAINER <path>`: replaces the Application Support container (tests never touch the dev one).
    public var devContainer: String?
    public var offlineOnly = false
    /// `-FakeHardware T0…T4|<fixture>`: the tier (a tier shorthand maps to its default fixture, HardwareProbe).
    public var fakeHardware: Tier?
    /// M2.T01: `-FakeHardware <fixture>` names `fixtures/hardware/<fixture>.json` (e.g. `t2-m4-24`); nil for a tier.
    public var fakeHardwareFixture: String?
    /// `-FakeFreeDiskGB <n>` (M2.T01).
    public var fakeFreeDiskGB: Int?
    /// `-PrintHardwareProfile YES` (M2.T01).
    public var printHardwareProfile = false
    /// M2.T18: onboarding gate overrides.
    public var skipOnboarding = false
    public var resetOnboarding = false
    public var onboardingProbe: String?
    /// M2.T26 visual QA capture probe.
    public var visualQAProbe: String?
    /// `-FakeNetwork none|expensive|constrained|ok` (M2.T03).
    public var fakeNetwork: String?
    /// `-CatalogURL <url>` (M2.T05).
    public var catalogURL: String?
    /// `-RelayURL <url>` (M7.T11).
    public var relayURL: String?
    /// `-SearchBlockEngine <id>[,<id>]` (M7.T01).
    public var searchBlockEngines: Set<String> = []
    /// `-FakePower ac|battery:<pct>|lowpower` (M2.T09).
    public var fakePower: String?
    /// `-FakeThermal nominal|fair|serious|critical` (M2.T14).
    public var fakeThermal: String?
    /// `-FakePressure warn|critical` (M2.T14).
    public var fakePressure: String?
    /// `-FakeLAContext succeed|fail` (M2.T17).
    public var fakeLAContext: Bool?
    /// `-FakePermission microphone=denied` (M3.T02): permission name → `notDetermined|denied|granted|restricted`.
    public var fakePermissions: [String: String] = [:]
    /// `-UseScriptedVoice <script.jsonl>` (M3.T03).
    public var scriptedVoiceScript: String?
    /// `-FakeAudioDevices none|a,b` (M3.T08): nil = the real CoreAudio list; [] = no devices.
    public var fakeAudioDevices: [String]?
    /// `-FakeAEC` / `-FakeAudioRoute` (M3.T12) as the helper reads them: `aec=unavailable,route=headphones`.
    public var fakeAudio: String?
    /// `-FakePackState voice=ready` (M3.T04): pack → `absent|downloading|ready`.
    public var fakePackStates: [String: String] = [:]
    /// `-DownloadHost <url>` (M2.T09).
    public var downloadHost: String?
    /// `-TestProxy host:port` (M2.T03).
    public var testProxy: (host: String, port: Int)? {
        get { testProxyHost.flatMap { h in testProxyPort.map { (h, $0) } } }
        set { testProxyHost = newValue?.host; testProxyPort = newValue?.port }
    }
    public var testProxyHost: String?
    public var testProxyPort: Int?
    public var fixedClock: Date?
    public var fakeEvilEnabled = false
    public var fakeVoiceInstalled = false
    public var fakeInstalledPacks: [String]?
    public var fakeDisabledPacks: [String]?
    public var fakeWebSearchEnabled = false
    public var fakeConnectionsEnabled = false
    public var fakeContextWindow: Int?
    /// 0…1; `nil` = no busy-time injection (S1 stand-in, `[ASSUMPTION]`, convention 5).
    public var rendererCPUScale: Double?
    /// Helper-side prefill throttle (AT-NFR-C5 only).
    public var prefillThrottleTokPerSec: Int?
    /// `-UIProbe <dir>`: run the AT-001 in-process probe and write its results into `<dir>`.
    public var uiProbe: String?
    /// `-PaletteProbe <dir>`: run the AT-012 in-process ⌘K probe and write its results into `<dir>`.
    public var paletteProbe: String?
    /// `-RendererProbe <dir>` (M1.T09): send one prompt, record the renderer's reveal cadence, main-thread hitches and
    /// word fade while the reply streams, write `<dir>/renderer.json`, quit.
    public var rendererProbe: String?
    /// `-ContextProbe <dir>` (M1.T18): drive the window through AT-009 (usage indicator, summary notice, oversize
    /// refusal), write `<dir>/probe.json`, quit.
    public var contextProbe: String?
    /// `-SettingsProbe <dir>` (M1.T22): drive the Settings window through AT-100/AT-062/AT-011 (4)/AT-012 (2), write
    /// `<dir>/probe.json`, quit; a second launch with the same `<dir>` checks the saved values after relaunch.
    public var settingsProbe: String?
    /// `-AppearanceProbe <dir>` (M1.T23): change every Appearance option with a chat open, measure, quit.
    public var appearanceProbe: String?
    /// `-A11yProbe <dir>` (M9.T01): walk every reachable screen's accessibility tree, write `<dir>/probe.json`, quit.
    public var a11yProbe: String?
    /// `-ShortcutsProbe <dir>` (M1.T24): drive the menus' key equivalents / windows, write `<dir>/<mode>.json`, quit.
    public var shortcutsProbe: String?
    /// `-DefaultsSuite <name>` (M1.T22): the UserDefaults suite every Settings key lives in.
    public var defaultsSuite: String?
    /// `-TurnProbe <dir>` (M1.T19): drive the window through the AT-003/010/014/299 legs for the running script
    /// (titles, sidebar spinner/unread, follow-up queue, type-before-ready), write `<dir>/probe.json`, quit.
    public var turnProbe: String?
    /// `-SearchProbe <dir>` (M7.T03): drive the web search legs of AT-080 / AT-250 c1 (`ui`) or the live latency
    /// runs of AT-248 c1 / AT-254 (`live`), per `<dir>/mode`; writes `<dir>/probe.json` and quits.
    public var searchProbe: String?
    /// `-ScriptedWebSearch YES` (M7.T03 UI legs): `web_search` / `read_url` return fixed sources (1–4 fetched of 9)
    /// without the network, so the window legs are deterministic; the pipeline itself is covered by unit tests + AT-248.
    public var scriptedWebSearch = false
    /// `-DumpPrompts <dir>` (M7.T06, PromptDump): every rendered prompt (system + tool block + volatile tail).
    public var dumpPrompts: String?
    /// `-ScriptedMCP <file.jsonl>` (M7.T06): MCP connections use ScriptedMCPTransport with that session.
    public var scriptedMCP: String?
    /// `-OAuthHeadless YES` (M7.T07): MCP OAuth without a browser (HeadlessAuthPresenter, DEBUG only).
    public var oauthHeadless = false
    /// `-IncognitoProbe <dir>` (M1.T20): drive journey 8 (incognito entry points, Personalized/Unpersonalized, 3 turns
    /// with a 12k paste card and a regenerate, close confirmation, quit), write `<dir>/probe.json`, quit.
    public var incognitoProbe: String?
    public var sendWithCommandEnter: Bool?
    public var plainTextComposer: Bool?
    public var showContextUsage: Bool?
    /// `-showModelInfo YES|NO` (M1.T25b): overrides the Advanced "Show model info" setting.
    public var showModelInfo: Bool?
    /// `-DraftProbe <dir>` (M1.T21): drive the composer through the AT-302 legs (switch, quit, crash), write
    /// `<dir>/probe.json`.
    public var draftProbe: String?
    /// `-ModelInfoProbe <dir>` (M1.T25b): run 10 turns (one stopped, one regenerate), compare every reply's Model info
    /// with its row, capture the popover, write `<dir>/probe.json`, quit.
    public var modelInfoProbe: String?
    /// `-ComposerHarness <fixture>` (M1.T08): show only the composer in a debug host. Fixtures: `empty`,
    /// `project+mode` (status-row chips), `noModel`, `queued`, `incognito`.
    public var composerHarness: String?
    public var artifactsHarness: String?
    /// `-MenusProbe <dir>` (M1.T17): drive the composer menus and chips through AT-013, write `<dir>/probe.json`, quit.
    public var menusProbe: String?
    /// `-NotificationSpy <file.json>` (M8.T12).
    public var notificationSpy: String?
    /// `-MacIntegrationProbe <dir>` (M8.T12–T14).
    public var macIntegrationProbe: String?
    /// `-FinalAcceptanceProbe <dir>` (M10.T09).
    public var finalAcceptanceProbe: String?
    /// `-SoakProbe <dir>` (M9.T06).
    public var soakProbe: String?
    /// `-QuickPanelHotkeyHook YES` (M8.T13).
    public var quickPanelHotkeyHook = false
    /// `-OpenURLSpy <file>` (M10.T06/T07).
    public var openURLSpy: String?
    /// `-SimulateUpdatedFrom <version>` (M10.T07).
    public var simulateUpdatedFrom: String?
    /// `-FreshDefaultsSuite YES` (fix/test-plist-hygiene).
    public var freshDefaultsSuite = false

    /// Options that were present but malformed (`"-Key value: reason"`); they are ignored, never guessed.
    public var errors: [String] = []

    public init() {}

    /// True when any option is set (used to log "debug launch options active").
    public var isEmpty: Bool { self == LaunchOptions() }

    /// An automated launch (an in-process probe, a debug harness, or a throwaway dev container — every tools/at,
    /// tools/perf, tools/offline and UI-test launch uses one): the app runs in the background (AntiChatUI
    /// `BackgroundRun`; UI tests opt out with `ANTICHAT_BACKGROUND=0`). Always false in Release (nothing parses).
    public var isAutomationRun: Bool {
        let dirs: [String?] = [uiProbe, paletteProbe, rendererProbe, contextProbe, settingsProbe, appearanceProbe,
                               a11yProbe, shortcutsProbe, turnProbe, incognitoProbe, draftProbe, modelInfoProbe, menusProbe,
                               onboardingProbe, visualQAProbe, composerHarness, artifactsHarness, macIntegrationProbe,
                               finalAcceptanceProbe, soakProbe, devContainer]
        return dirs.contains { $0 != nil }
    }

    public static let current: LaunchOptions = parse(ProcessInfo.processInfo.arguments)

    /// Parses `-Key value` pairs (NSArgumentDomain style). Unknown arguments are ignored.
    public static func parse(_ arguments: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        #if DEBUG || ANTICHAT_PERF_HARNESS
        var values: [Key: String] = [:]
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a.hasPrefix("-"), let key = Key(rawValue: String(a.dropFirst())) {
                if i + 1 < arguments.count {
                    values[key] = arguments[i + 1]
                    i += 2
                    continue
                }
                o.errors.append("\(a): missing value")
            }
            i += 1
        }
        func bool(_ k: Key) -> Bool? {
            guard let v = values[k] else { return nil }
            switch v.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: o.errors.append("-\(k.rawValue) \(v): not a boolean"); return nil
            }
        }
        func int(_ k: Key, min: Int) -> Int? {
            guard let v = values[k] else { return nil }
            guard let n = Int(v), n >= min else { o.errors.append("-\(k.rawValue) \(v): not an integer ≥ \(min)"); return nil }
            return n
        }
        func csv(_ k: Key) -> [String]? {
            guard let v = values[k] else { return nil }
            return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func path(_ k: Key) -> String? {
            guard let v = values[k] else { return nil }
            if v.isEmpty { o.errors.append("-\(k.rawValue): empty path"); return nil }
            return v
        }

        if let v = values[.useScriptedEngine] {
            if v.uppercased() == "NO" { o.scriptedEngineScript = nil } else { o.scriptedEngineScript = path(.useScriptedEngine) }
        }
        o.useScriptedTools = bool(.useScriptedTools) ?? false
        o.scriptedImageScript = path(.useScriptedImageEngine)
        o.scriptedVideoScript = path(.useScriptedVideoEngine)
        o.devContainer = path(.devContainer)
        o.offlineOnly = bool(.offlineOnly) ?? false
        if let v = values[.fakeHardware] {
            if let t = Tier(rawValue: v.uppercased()) {
                o.fakeHardware = t
            } else if v.wholeMatch(of: /(t[0-4]|unknown)-[a-z0-9-]+/) != nil {
                // M2.T01: a fixture name; its tier is the prefix (unknown chips are classified later, by RAM).
                o.fakeHardwareFixture = v
                o.fakeHardware = Tier(rawValue: String(v.prefix(2)).uppercased())
            } else {
                o.errors.append("-FakeHardware \(v): not T0…T4 or a fixtures/hardware name")
            }
        }
        if let v = values[.fixedClock] {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            let ff = ISO8601DateFormatter()
            ff.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: v) ?? ff.date(from: v) { o.fixedClock = d } else { o.errors.append("-FixedClock \(v): not ISO 8601") }
        }
        o.fakeEvilEnabled = bool(.fakeEvilEnabled) ?? false
        o.fakeVoiceInstalled = bool(.fakeVoiceInstalled) ?? false
        o.fakeInstalledPacks = csv(.fakeInstalledPacks)
        o.fakeDisabledPacks = csv(.fakeDisabledPacks)
        o.fakeWebSearchEnabled = bool(.fakeWebSearchEnabled) ?? false
        o.fakeConnectionsEnabled = bool(.fakeConnectionsEnabled) ?? false
        o.fakeContextWindow = int(.fakeContextWindow, min: 1)
        if let v = values[.rendererCPUScale] {
            if let d = Double(v), d >= 0, d <= 1 { o.rendererCPUScale = d } else { o.errors.append("-RendererCPUScale \(v): not in 0…1") }
        }
        o.prefillThrottleTokPerSec = int(.prefillThrottleTokPerSec, min: 1)
        o.uiProbe = path(.uiProbe)
        o.paletteProbe = path(.paletteProbe)
        o.rendererProbe = path(.rendererProbe)
        o.contextProbe = path(.contextProbe)
        o.settingsProbe = path(.settingsProbe)
        o.appearanceProbe = path(.appearanceProbe)
        o.a11yProbe = path(.a11yProbe)
        o.shortcutsProbe = path(.shortcutsProbe)
        o.defaultsSuite = path(.defaultsSuite)
        o.turnProbe = path(.turnProbe)
        o.searchProbe = path(.searchProbe)
        o.scriptedWebSearch = bool(.scriptedWebSearch) ?? false
        o.dumpPrompts = path(.dumpPrompts)
        o.scriptedMCP = path(.scriptedMCP)
        o.oauthHeadless = bool(.oauthHeadless) ?? false
        o.incognitoProbe = path(.incognitoProbe)
        o.sendWithCommandEnter = bool(.sendWithCommandEnter)
        o.plainTextComposer = bool(.plainTextComposer)
        o.showContextUsage = bool(.showContextUsage)
        o.showModelInfo = bool(.showModelInfo)
        o.draftProbe = path(.draftProbe)
        o.modelInfoProbe = path(.modelInfoProbe)
        o.composerHarness = path(.composerHarness)
        o.artifactsHarness = path(.artifactsHarness)
        o.menusProbe = path(.menusProbe)
        o.notificationSpy = path(.notificationSpy)
        o.macIntegrationProbe = path(.macIntegrationProbe)
        o.finalAcceptanceProbe = path(.finalAcceptanceProbe)
        o.soakProbe = path(.soakProbe)
        o.quickPanelHotkeyHook = bool(.quickPanelHotkeyHook) ?? false
        o.openURLSpy = path(.openURLSpy)
        o.simulateUpdatedFrom = path(.simulateUpdatedFrom)
        o.freshDefaultsSuite = bool(.freshDefaultsSuite) ?? false
        o.fakeFreeDiskGB = int(.fakeFreeDiskGB, min: 0)
        o.printHardwareProfile = bool(.printHardwareProfile) ?? false
        o.skipOnboarding = bool(.skipOnboarding) ?? false
        o.resetOnboarding = bool(.resetOnboarding) ?? false
        o.onboardingProbe = path(.onboardingProbe)
        o.visualQAProbe = path(.visualQAProbe)
        if let v = values[.searchBlockEngine] {
            o.searchBlockEngines = Set(v.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if let v = values[.catalogURL] {
            if URL(string: v)?.scheme != nil { o.catalogURL = v } else { o.errors.append("-CatalogURL \(v): not a URL") }
        }
        if let v = values[.relayURL] {
            if URL(string: v)?.scheme != nil { o.relayURL = v } else { o.errors.append("-RelayURL \(v): not a URL") }
        }
        if let v = values[.fakeNetwork] {
            if ["none", "expensive", "constrained", "ok"].contains(v.lowercased()) { o.fakeNetwork = v.lowercased() } else {
                o.errors.append("-FakeNetwork \(v): not none|expensive|constrained|ok")
            }
        }
        if let v = values[.fakePower] {
            let l = v.lowercased()
            let ok = l == "ac" || l == "lowpower" || (l.hasPrefix("battery:") && Int(l.dropFirst(8)).map { (0...100).contains($0) } == true)
            if ok { o.fakePower = l } else { o.errors.append("-FakePower \(v): not ac|battery:<pct>|lowpower") }
        }
        if let v = values[.fakeThermal] {
            let l = v.lowercased()
            if ["nominal", "fair", "serious", "critical"].contains(l) { o.fakeThermal = l } else {
                o.errors.append("-FakeThermal \(v): not nominal|fair|serious|critical")
            }
        }
        if let v = values[.fakePressure] {
            let l = v.lowercased()
            if ["warn", "critical"].contains(l) { o.fakePressure = l } else { o.errors.append("-FakePressure \(v): not warn|critical") }
        }
        if let v = values[.fakeLAContext] {
            switch v.lowercased() {
            case "succeed": o.fakeLAContext = true
            case "fail": o.fakeLAContext = false
            default: o.errors.append("-FakeLAContext \(v): not succeed|fail")
            }
        }
        if let v = values[.fakePermission] {
            let states = ["notdetermined": "notDetermined", "denied": "denied", "granted": "granted", "restricted": "restricted",
                          "servicesoff": "servicesOff"]  // M8.T08: location only
            for pair in v.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, let s = states[kv[1].lowercased()], !kv[0].isEmpty { o.fakePermissions[kv[0]] = s } else {
                    o.errors.append("-FakePermission \(pair): not <permission>=notDetermined|denied|granted|restricted|servicesOff")
                }
            }
        }
        o.scriptedVoiceScript = path(.useScriptedVoice)
        let fakeAudio = [values[.fakeAEC].map { "aec=\($0.lowercased())" }, values[.fakeAudioRoute].map { "route=\($0.lowercased())" }]
            .compactMap { $0 }
        o.fakeAudio = fakeAudio.isEmpty ? nil : fakeAudio.joined(separator: ",")
        if let v = values[.fakeAudioDevices] {
            o.fakeAudioDevices = v.lowercased() == "none" ? [] : v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let v = values[.fakePackState] {
            for pair in v.split(separator: ",") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if kv.count == 2, ["absent", "downloading", "ready"].contains(kv[1]), !kv[0].isEmpty { o.fakePackStates[kv[0]] = kv[1] } else {
                    o.errors.append("-FakePackState \(pair): not <pack>=absent|downloading|ready")
                }
            }
        }
        if let v = values[.downloadHost] {
            if URL(string: v)?.scheme != nil { o.downloadHost = v } else { o.errors.append("-DownloadHost \(v): not a URL") }
        }
        if let v = values[.testProxy] {
            let parts = v.split(separator: ":")
            if parts.count == 2, let port = Int(parts[1]), port > 0 { o.testProxy = (String(parts[0]), port) } else {
                o.errors.append("-TestProxy \(v): not host:port")
            }
        }
        #endif
        return o
    }
}
