// Every Settings key (M1.T22 step 2, P-shell-16 `sindresorhus/Defaults` 9.0.9): one `Defaults.Keys` entry per
// setting, each with its documented default. Each key carries a `// settings-map:` line —
// `§<section> "<Setting>" = "<Default column>" ↔ <Swift default>` — which `tools/ci/settings-map-check.py`
// (`make audit`) checks against docs/research/02-target/settings-map.md, so a key cannot drift from the map.
// Later tasks add their keys here (M1-plan hot-file rule), with the same annotation.
//
// Launch overrides (M1.md conventions 9/10): `-<key> YES|NO` lands in NSArgumentDomain as an NSString, which a
// Defaults `Bool` key does not read (A-M1-T18a (l)). `DefaultsLaunchOverrides.normalize()` (AppBootstrap.start)
// rewrites those values as booleans once, for every Bool key below, so `-sendWithCommandEnter YES` etc. work
// exactly like a stored setting.
import AntiChatFoundation
import Defaults
import Foundation

public extension UserDefaults {
    /// The store every Settings key lives in: the app domain, or (DEBUG) the `-DefaultsSuite <name>` suite, so an
    /// in-process probe never touches the developer's own settings.
    /// UserDefaults is thread-safe (Apple docs); the reference itself never changes after first use.
    /// DEBUG: a `ScopedSettingsDefaults`, which is the plain suite (or the app domain) unless a test has bound its own
    /// settings scope (`SettingsIsolation`).
    nonisolated(unsafe) static let antichat: UserDefaults = {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let name = AppDefaults.launchSuite != nil ? LaunchOptions.current.defaultsSuite : nil  // emptied first if asked
        let process = name == nil ? AppDefaults.testProcessMemory : nil  // a test process: never the shared tool domain
        if let scoped = ScopedSettingsDefaults(suiteName: name, isolatedSuite: name != nil, processMemory: process) { return scoped }
        #endif
        return .standard
    }()

    /// True when settings live in a probe/test suite or a test's settings scope (side effects such as Launch at login
    /// are skipped).
    static var antichatIsIsolated: Bool {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if ScopedSettingsDefaults.scope != nil { return true }
        if let scoped = antichat as? ScopedSettingsDefaults { return scoped.isolatedSuite || scoped.processMemory != nil }
        #endif
        return antichat !== UserDefaults.standard
    }
}

#if DEBUG || ANTICHAT_PERF_HARNESS
/// Test isolation for the Settings store (DEBUG only). The `Defaults.Keys` are static and all name the one
/// `UserDefaults.antichat` suite, so suites that run in parallel in one test process used to share every setting:
/// one test's `SettingsKeys.resetAll()` or `Defaults[.plainTextComposer] = true` changed what another test read.
/// `withIsolatedSettings` binds a fresh in-memory store to the current task (and the work it runs synchronously,
/// including run-loop callouts while the test spins the main run loop); reads fall back to the registered defaults,
/// writes and resets stay in that store and end with the scope. Without a scope: the suite, or in a unit-test process the
/// process's own store (`AppDefaults`).
/// AntiChatUIModuleTests applies it to every test (`.isolatedSettings`).
public enum SettingsIsolation {
    public static func withIsolatedSettings<T>(_ body: () async throws -> T) async rethrows -> T {
        try await ScopedSettingsDefaults.$scope.withValue(SettingsScope()) { try await body() }
    }

    /// True inside `withIsolatedSettings`.
    public static var isActive: Bool { ScopedSettingsDefaults.scope != nil }
}

/// One test's settings values (AntiChatFoundation's `DefaultsMemory`: misses read the registered defaults only).
public typealias SettingsScope = DefaultsMemory

/// `UserDefaults.antichat` in DEBUG builds: the bound `SettingsScope` when there is one; else, in a unit-test process
/// without `-DefaultsSuite`, the process's private store behind `AppDefaults.standard` (never the test tool's domain,
/// which every test process on the Mac shares); else the suite itself.
final class ScopedSettingsDefaults: MemoryDefaults, @unchecked Sendable {
    @TaskLocal static var scope: SettingsScope?
    /// True when this is a `-DefaultsSuite` probe suite (not the app domain).
    let isolatedSuite: Bool
    /// The test process's own store (nil in the app and in probe suites).
    let processMemory: DefaultsMemory?

    init?(suiteName: String?, isolatedSuite: Bool, processMemory: DefaultsMemory? = nil) {
        self.isolatedSuite = isolatedSuite
        self.processMemory = processMemory
        // A test process's misses read a suite nothing writes (launch arguments, NSGlobalDomain, registered defaults).
        super.init(suiteName: processMemory != nil ? MemoryDefaults.missSuite : suiteName, memory: nil)
    }

    override var memory: DefaultsMemory? { Self.scope ?? processMemory }
}
#endif

public extension Defaults.Keys {
    // MARK: §1 General

    /// "Send with": `false` = Return sends, ⇧Return inserts a newline (default); `true` = ⌘Return sends and
    /// Return inserts a newline (R-002 criterion 4).
    // settings-map: §1 "Send with" = "Enter (Shift+Enter = newline)" ↔ false
    static let sendWithCommandEnter = Key<Bool>("sendWithCommandEnter", default: false, suite: .antichat)
    /// "Plain-text composer": `false` = inline Markdown styling (default, F-101); `true` = unstyled text.
    /// The sent payload is Markdown text either way (R-002 criterion 5).
    // settings-map: §1 "Plain-text composer" = "Off" ↔ false
    static let plainTextComposer = Key<Bool>("plainTextComposer", default: false, suite: .antichat)
    /// "Show context usage" (R-009 AC1): the ContextUsageIndicator is hidden unless on.
    // settings-map: §1 "Show context usage" = "Off" ↔ false
    static let showContextUsage = Key<Bool>("showContextUsage", default: false, suite: .antichat)
    /// "Launch at login" (`SMAppService.mainApp`, LoginItem.swift).
    // settings-map: §1 "Launch at login" = "Off `[ASSUMPTION, owner 3]`" ↔ false
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false, suite: .antichat)
    /// "VoiceOver reads replies" (M9.T01, NFR-A2, A-M9-T01a): AnnounceReplies raw value.
    // settings-map: §1 "VoiceOver reads replies" = "When finished" ↔ "atEnd"
    static let announceReplies = Key<String>("announceReplies", default: "atEnd", suite: .antichat)
    /// "Menu bar item" (R-105; the item itself arrives in M8). "Keep running when last window closes" follows it.
    // settings-map: §1 "Menu bar item" = "On" ↔ true
    static let menuBarItem = Key<Bool>("menuBarItem", default: true, suite: .antichat)
    /// "Performance" (M2.T14, R-207): auto / maximum / batterySaver (PerformanceMode). Auto switches to Battery saver
    /// on battery < 20 % or in Low Power Mode (PowerPolicy).
    // settings-map: §1 "Performance" = "Auto" ↔ "auto"
    static let performance = Key<String>("performance", default: "auto", suite: .antichat)
    /// "Notify me" (M8.T12, R-108 AC1): `NotifyWhen` raw value — unfocused / always / never.
    // settings-map: §1 "Notifications: when" = "Only when unfocused" ↔ "unfocused"
    static let notifyWhen = Key<String>("notifyWhen", default: "unfocused", suite: .antichat)
    /// Notification categories (M8.T12): Responses (answers).
    // settings-map: §1 "Notifications: categories" = "Responses, Media jobs, Downloads, Updates all on" ↔ true
    static let notifyResponses = Key<Bool>("notifyResponses", default: true, suite: .antichat)
    /// Media jobs (pictures and videos).
    // settings-map: §1 "Notifications: categories" = "Responses, Media jobs, Downloads, Updates all on" ↔ true
    static let notifyMedia = Key<Bool>("notifyMedia", default: true, suite: .antichat)
    /// Downloads (a pack finished).
    // settings-map: §1 "Notifications: categories" = "Responses, Media jobs, Downloads, Updates all on" ↔ true
    static let notifyDownloads = Key<Bool>("notifyDownloads", default: true, suite: .antichat)
    /// Updates (fired from M10.T03).
    // settings-map: §1 "Notifications: categories" = "Responses, Media jobs, Downloads, Updates all on" ↔ true
    static let notifyUpdates = Key<Bool>("notifyUpdates", default: true, suite: .antichat)
    /// "Sound" (M8.T12, R-108 AC2): `default`, `none` or a `/System/Library/Sounds` name (`NotificationSound`).
    // settings-map: §1 "Notification sound" = "System default `[ASSUMPTION, owner 3]`" ↔ "default"
    static let notificationSound = Key<String>("notificationSound", default: "default", suite: .antichat)

    // MARK: §7 Tools & Connections (M7.T05, R-228 AC3)

    /// "Suggest web search when helpful": the fresh-information hint under local answers (FreshnessHintPolicy).
    // settings-map: §7 "→ Suggest web search when helpful (if off)" = "On" ↔ true
    static let suggestWebSearch = Key<Bool>("suggestWebSearch", default: true, suite: .antichat)
    /// "Safe search results" (M7.T01/T15, R-241 AC3): a URL parameter for the engines (SafeSearch), the same in both modes.
    // settings-map: §7 "→ Safe search results" = "Off (no restriction, either mode)" ↔ false
    static let safeSearch = Key<Bool>("safeSearch", default: false, suite: .antichat)
    /// "Use my approximate location for search" (M8.T08, R-091 AC3): On until the user chooses otherwise (owner
    /// 2026-11-16). macOS is asked just in time: the first web search that would use it shows `perm.location.why`
    /// and only then the system dialog (SearchLocationPrompt); "Not now" turns this off. Never asked at launch or
    /// onboarding. Until macOS says yes, searches carry no location.
    // settings-map: §7 "→ Use my approximate location" = "On" ↔ true
    static let searchUsesLocation = Key<Bool>("searchUsesLocation", default: true, suite: .antichat)
    // settings-map: §7 "Create image / Create video / Create files / Memory" = "On when the pack or feature is installed" ↔ true
    static let createFilesEnabled = Key<Bool>(ToolDefaults.createFilesEnabled, default: true, suite: .antichat)
    // settings-map: §7 "Run code for analysis (File tools sandbox)" = "Off until installed (85 MB)" ↔ false
    static let runCodeEnabled = Key<Bool>(ToolDefaults.runCodeEnabled, default: false, suite: .antichat)
    // settings-map: §7 "→ Network for code" = "Off" ↔ false
    static let allowNetworkForCode = Key<Bool>(ToolDefaults.allowNetworkForCode, default: true, suite: .antichat)
    /// M7.T14 (R-268 AC1): Tools page switches for Create image, Create video and Memory (Create files / Run code are
    /// M6.T19's keys above). The harness reads the same keys (ToolSwitches); a chat's own on/off is a
    /// `tool.on/off:<group>` marker in `chat.tools_json` and never touches these (R-268 AC2).
    // settings-map: §7 "Create image / Create video / Create files / Memory" = "On when the pack or feature is installed" ↔ true
    static let toolImage = Key<Bool>("toolImage", default: true, suite: .antichat)
    // settings-map: §7 "Create image / Create video / Create files / Memory" = "On when the pack or feature is installed" ↔ true
    static let toolVideo = Key<Bool>("toolVideo", default: true, suite: .antichat)
    // settings-map: §7 "Create image / Create video / Create files / Memory" = "On when the pack or feature is installed" ↔ true
    static let toolMemory = Key<Bool>("toolMemory", default: true, suite: .antichat)
    /// M7.T14 (R-268 AC3): "Tool access" — `whenNeeded` (ToolSelector picks per message) or `all` (every enabled
    /// tool; warns on T0–T2). Read by the harness as `ToolSwitches.access`.
    // settings-map: §7 "Tool access" = "Load tools when needed" ↔ "whenNeeded"
    static let toolAccess = Key<String>("toolAccess", default: "whenNeeded", suite: .antichat)

    // MARK: §2 Appearance (R-101; AppearanceRoot applies them to every window, M1.T23)

    // settings-map: §2 "Color mode" = "System" ↔ "system"
    static let colorMode = Key<String>("colorMode", default: "system", suite: .antichat)
    // settings-map: §2 "Accent color" = "Default (first preset) `[ASSUMPTION, owner 3]`" ↔ "default"
    static let accentColor = Key<String>("accentColor", default: "default", suite: .antichat)
    // settings-map: §2 "Chat font" = "Default" ↔ "default"
    static let chatFont = Key<String>("chatFont", default: "default", suite: .antichat)
    // settings-map: §2 "Text size" = "14 pt `[ASSUMPTION, owner 3]`" ↔ 14
    static let textSize = Key<Int>("textSize", default: 14, suite: .antichat)
    // settings-map: §2 "Reading width" = "Wide `[ASSUMPTION, owner 3]`" ↔ "wide"
    static let readingWidth = Key<String>("readingWidth", default: "wide", suite: .antichat)
    // settings-map: §2 "Reduce motion" = "System" ↔ "system"
    static let reduceMotion = Key<String>("reduceMotion", default: "system", suite: .antichat)
    // settings-map: §2 "Reduce transparency" = "Follows macOS" ↔ "system"
    static let reduceTransparency = Key<String>("reduceTransparency", default: "system", suite: .antichat)
    // settings-map: §2 "Increase contrast" = "Follows macOS" ↔ "system"
    static let increaseContrast = Key<String>("increaseContrast", default: "system", suite: .antichat)

    // MARK: §3 Capabilities → Advanced

    /// "Show model info" (M1.T25b, R-234 AC2): on, a reply's ⋯ menu shows `msg.modelInfo` → ModelInfoPopover.
    /// Default off: the default UI shows no model names (R-007).
    // settings-map: §3 "→ Show model info (key `showModelInfo`; A-M1-T25c)" = "Off" ↔ false
    static let showModelInfo = Key<Bool>("showModelInfo", default: false, suite: .antichat)

    /// Keep-alive after last use in minutes: 5 / 15 / 30, 0 = Never unload (M2.T07, NFR-M2; the scheduler gets it
    /// through `SetPolicy`, T12). 15 on AC; battery / Low Power shortens it to 5 (PowerPolicy, T14).
    // settings-map: §3 "→ Keep models loaded after last use (keep-alive)" = "15 min (AC), 5 min on battery" ↔ 15
    static let keepLoadedMinutes = Key<Int>("keepLoadedMinutes", default: 15, suite: .antichat)

    /// "Allow loads above the memory budget" (M2.T07, NFR-R5): Too-large picks become selectable and the scheduler
    /// may load past B (`SetPolicy.allowOverBudget`).
    // settings-map: §3 "→ Allow loads above the memory budget" = "Off" ↔ false
    static let allowOverBudget = Key<Bool>("allowOverBudget", default: false, suite: .antichat)

    /// Advanced → Video (M5.T09, R-044 AC2): the plan card offers only length and shape; these three replace the tier
    /// preset (`VideoAdvanced`, clamped to the tier's limits by `VideoPresets.resolve`). 0 / "" = the tier's preset.
    /// Denoise steps of the tier's text-to-video model.
    // settings-map: §3 "→ Video advanced parameters" = "Per tier preset" ↔ 0
    static let videoAdvancedSteps = Key<Int>("videoAdvancedSteps", default: 0, suite: .antichat)
    /// "480p" / "720p" / "1080p" (only the tier's resolutions apply).
    // settings-map: §3 "→ Video advanced parameters" = "Per tier preset" ↔ ""
    static let videoAdvancedResolution = Key<String>("videoAdvancedResolution", default: "", suite: .antichat)
    /// Exact length in whole seconds (snapped to the model's frame grid, bounded by the tier).
    // settings-map: §3 "→ Video advanced parameters" = "Per tier preset" ↔ 0
    static let videoAdvancedSeconds = Key<Int>("videoAdvancedSeconds", default: 0, suite: .antichat)
    /// M5.T11 (NFR-B5): when another app holds > 50 % of the GPU for > 10 s, the running video job pauses ("Paused for
    /// another app"); off: it only drops to background priority. Read at submit (`VideoRequest.yieldToOtherApps`).
    // settings-map: §3 "→ Pause video jobs when another app needs the GPU" = "On" ↔ true
    static let yieldGPU = Key<Bool>("yieldGPU", default: true, suite: .antichat)

    // MARK: §5 Voice (M3.T08, R-053; read at the start of each utterance / each read aloud, VoicePreferences)

    /// "Microphone": the CoreAudio device UID dictation captures from; "" = the system default input (follows it).
    // settings-map: §5 "Microphone" = "System default" ↔ ""
    static let voiceInputDevice = Key<String>("voiceInputDevice", default: "", suite: .antichat)
    /// "Spoken language": "auto" = Auto-detect (LanguageRouter), else a base language code ("de", "ja", …).
    // settings-map: §5 "Spoken language" = "Auto-detect" ↔ "auto"
    static let voiceSpokenLanguage = Key<String>("voiceSpokenLanguage", default: "auto", suite: .antichat)
    /// "Voice": the read-aloud voice id (Kokoro `af_heart` …, or a system voice identifier); "" = the first voice.
    // settings-map: §5 "Voice" = "first of ≥ 6 voices `[ASSUMPTION, owner 3]`" ↔ ""
    static let voiceID = Key<String>("voiceID", default: "", suite: .antichat)
    /// "Speed": read-aloud rate 0.75–1.5 in 0.05 steps.
    // settings-map: §5 "Speed" = "1.0×" ↔ 1.0
    static let voiceRate = Key<Double>("voiceRate", default: 1.0, suite: .antichat)
    /// "Conversation mode": "handsFree" (VAD end of turn) or "pushToTalk" (hold Space; M3.T11 reads it).
    // settings-map: §5 "Conversation mode" = "Hands-free (VAD)" ↔ "handsFree"
    static let voiceMode = Key<String>("voiceMode", default: "handsFree", suite: .antichat)
    /// M3.T12 (R-280 AC3): duck other apps' audio (no more than the minimum system level) during a conversation.
    // settings-map: §5 "Lower other apps while talking" = "On" ↔ true
    static let voiceDuckOthers = Key<Bool>("voiceDuckOthers", default: true, suite: .antichat)

    // MARK: §11 Updates

    /// "Update models automatically" (M2.T11, R-294 / R-220 AC2): on = silent background updates up to +2 GB; above
    /// that, or off, Capabilities shows an offer row. Read by ModelUpdateService (PRD name `models.autoUpdate`).
    // settings-map: §11 "Update models automatically" = "On (asks first above +2 GB disk)" ↔ true
    static let autoUpdateModels = Key<Bool>("autoUpdateModels", default: true, suite: .antichat)

    // MARK: §6 Personalization (R-062; feeds the prompt's layer 3, PersonalizationSync)

    // settings-map: §6 "About you" = "empty" ↔ ""
    static let aboutYou = Key<String>("aboutYou", default: "", suite: .antichat)
    // settings-map: §6 "How should AntiChat respond" = "empty" ↔ ""
    static let howToRespond = Key<String>("howToRespond", default: "", suite: .antichat)
    // settings-map: §6 "Style preset" = "Default" ↔ "default"
    static let stylePreset = Key<String>("stylePreset", default: "default", suite: .antichat)
    // settings-map: §6 "Characteristics (warmth, enthusiasm, headers/lists, emoji)" = "Default" ↔ "default"
    static let warmth = Key<String>("warmth", default: "default", suite: .antichat)
    // settings-map: §6 "Characteristics (warmth, enthusiasm, headers/lists, emoji)" = "Default" ↔ "default"
    static let enthusiasm = Key<String>("enthusiasm", default: "default", suite: .antichat)
    // settings-map: §6 "Characteristics (warmth, enthusiasm, headers/lists, emoji)" = "Default" ↔ "default"
    static let headersAndLists = Key<String>("headersAndLists", default: "default", suite: .antichat)
    // settings-map: §6 "Characteristics (warmth, enthusiasm, headers/lists, emoji)" = "Default" ↔ "default"
    static let emoji = Key<String>("emoji", default: "default", suite: .antichat)

    // M8.T03 (R-060, R-246): memory. The raw names are shared with MemoryPolicy.from (Knowledge reads them too).
    /// "Memory": on | paused (keeps what's saved, saves nothing new) | off (don't use or save).
    // settings-map: §6 "Memory" = "On" ↔ "on"
    static let memoryMode = Key<String>("memoryMode", default: "on", suite: .antichat)
    /// "Include sensitive topics in memory" (R-060 AC3): a storage choice, not a filter.
    // settings-map: §6 "Include sensitive topics in memory" = "On" ↔ true
    static let memoryIncludeSensitive = Key<Bool>("memoryIncludeSensitive", default: true, suite: .antichat)
    /// "Keep memory up to date automatically" (R-246; was "Suggest things to remember"): the launch registers false on T0–T1 (MemoryReviewScheduler).
    // settings-map: §6 "Suggest things to remember" = "On (T2–T4), Off (T0–T1)" ↔ true
    static let memoryReviewEnabled = Key<Bool>("memoryReviewEnabled", default: true, suite: .antichat)
    /// Settings → Evil Mode "Use memory in Evil chats".
    // settings-map: §4 "Use memory in Evil chats" = "On" ↔ true
    static let useMemoryInEvil = Key<Bool>("useMemoryInEvil", default: true, suite: .antichat)
    /// M5.T13 (R-022 AC4): Settings → Evil Mode "Show Evil items in Library". nil = not set by the user: the Library
    /// then shows Evil items exactly when Evil Mode is enabled (LibraryIndex.showsEvil); a choice sticks either way.
    // settings-map: §4 "Show Evil items in Library" = "On when Evil is enabled, else Off" ↔ nil
    static let showEvilInLibrary = Key<Bool?>("showEvilInLibrary", default: nil, suite: .antichat)

    // MARK: §9 Privacy & Data

    /// "Auto-archive inactive chats": days of inactivity, 0 = Never (AutoArchiveService, daily).
    // settings-map: §9 "Auto-archive inactive chats" = "Never" ↔ 0
    static let autoArchiveDays = Key<Int>("autoArchiveDays", default: 0, suite: .antichat)
    /// "Crash reports" (M8.T09, R-218 AC2, NFR-PR2): ask / always / never (`CrashReportMode`). "Ask after a crash" is
    /// the map's "Off (opt-in)": nothing is sent without a tap (A-M8-T09a).
    // settings-map: §9 "Crash reports" = "Off (opt-in)" ↔ "ask"
    static let crashReportMode = Key<String>("crashReportMode", default: "ask", suite: .antichat)
    /// "New chats are incognito" (M8.T08, R-091 AC4): ⌘N and the toolbar's new chat open an incognito chat.
    // settings-map: §9 "New chats are incognito" = "Off `[ASSUMPTION, owner 3]`" ↔ false
    static let newChatsIncognito = Key<Bool>("newChatsIncognito", default: false, suite: .antichat)
    /// "Incognito personalization" (M8.T08, R-090): the choice a new incognito chat starts with (`IncognitoPersonalization`
    /// raw value); the incognito empty state still switches it per chat.
    // settings-map: §9 "Incognito personalization" = "Personalized" ↔ "personalized"
    static let incognitoPersonalizationDefault = Key<String>("incognitoPersonalizationDefault", default: "personalized", suite: .antichat)
}

/// The Bool keys whose `-key YES|NO` launch argument must be read as a boolean (every Bool key above).
public enum SettingsKeys {
    public static let bools: [Defaults.Key<Bool>] = [
        .sendWithCommandEnter, .plainTextComposer, .showContextUsage, .launchAtLogin, .menuBarItem,
        .showModelInfo, .allowOverBudget, .autoUpdateModels, .suggestWebSearch, .safeSearch,
        .createFilesEnabled, .runCodeEnabled, .allowNetworkForCode,
        .memoryIncludeSensitive, .memoryReviewEnabled, .useMemoryInEvil,  // M8.T03
        .searchUsesLocation, .newChatsIncognito,  // M8.T08
        .voiceDuckOthers,  // M3.T12
        .notifyResponses, .notifyMedia, .notifyDownloads, .notifyUpdates,  // M8.T12
        .toolImage, .toolVideo, .toolMemory,  // M7.T14
    ]

    /// Every key name with its default rendered as text (SettingsRegistryTests, settings-map-check cross-check).
    public static var defaults: [String: String] {
        var d: [String: String] = [:]
        for k in bools { d[k.name] = k.defaultValue ? "true" : "false" }
        for k in [Defaults.Keys.performance, .aboutYou, .howToRespond, .stylePreset, .warmth, .enthusiasm, .headersAndLists, .emoji,
                  .colorMode, .accentColor, .chatFont, .readingWidth, .reduceMotion, .reduceTransparency,
                  .increaseContrast, .memoryMode, .crashReportMode, .incognitoPersonalizationDefault,
                  .voiceInputDevice, .voiceSpokenLanguage, .voiceID, .voiceMode, .announceReplies,  // M3.T08 (settings-map §5; announceReplies M9.T01)
                  .notifyWhen, .notificationSound,  // M8.T12
                  .toolAccess] {  // M7.T14
            d[k.name] = k.defaultValue
        }
        d[Defaults.Keys.autoArchiveDays.name] = "\(Defaults.Keys.autoArchiveDays.defaultValue)"
        d[Defaults.Keys.keepLoadedMinutes.name] = "\(Defaults.Keys.keepLoadedMinutes.defaultValue)"
        d[Defaults.Keys.textSize.name] = "\(Defaults.Keys.textSize.defaultValue)"
        d[Defaults.Keys.voiceRate.name] = "\(Defaults.Keys.voiceRate.defaultValue)"
        d[Defaults.Keys.videoAdvancedSteps.name] = "\(Defaults.Keys.videoAdvancedSteps.defaultValue)"  // M5.T09
        d[Defaults.Keys.videoAdvancedResolution.name] = Defaults.Keys.videoAdvancedResolution.defaultValue
        d[Defaults.Keys.videoAdvancedSeconds.name] = "\(Defaults.Keys.videoAdvancedSeconds.defaultValue)"
        d[Defaults.Keys.yieldGPU.name] = "\(Defaults.Keys.yieldGPU.defaultValue)"  // M5.T11
        d[Defaults.Keys.showEvilInLibrary.name] = "nil"  // M5.T13: follows the Evil enable state until set
        return d
    }

    /// Resets every key (tests, probes).
    public static func resetAll() {
        Defaults.reset(.announceReplies)
        Defaults.reset(.sendWithCommandEnter, .plainTextComposer, .showContextUsage, .launchAtLogin, .menuBarItem,
                       .showModelInfo, .allowOverBudget, .keepLoadedMinutes, .autoUpdateModels, .aboutYou, .howToRespond, .stylePreset, .warmth, .enthusiasm, .headersAndLists, .emoji,
                       .autoArchiveDays, .performance, .colorMode, .accentColor, .chatFont, .textSize, .readingWidth, .reduceMotion,
                       .reduceTransparency, .increaseContrast, .memoryMode, .memoryIncludeSensitive, .memoryReviewEnabled,
                       .useMemoryInEvil, .suggestWebSearch, .safeSearch, .crashReportMode,
                       .searchUsesLocation, .newChatsIncognito, .incognitoPersonalizationDefault,
                       .createFilesEnabled, .runCodeEnabled, .allowNetworkForCode,
                       .voiceInputDevice, .voiceSpokenLanguage, .voiceID, .voiceRate, .voiceMode, .voiceDuckOthers,
                       .videoAdvancedSteps, .videoAdvancedResolution, .videoAdvancedSeconds, .yieldGPU, .showEvilInLibrary,
                       .notifyWhen, .notifyResponses, .notifyMedia, .notifyDownloads, .notifyUpdates, .notificationSound,
                       .toolImage, .toolVideo, .toolMemory, .toolAccess)
    }
}

/// Fix for A-M1-T18a (l), once for every Bool key: NSArgumentDomain holds `-key YES` as the string "YES"; the
/// Defaults Bool bridge reads `object(forKey:) as? Bool`, which is nil for a string, so the override was ignored.
/// `normalize()` replaces each such string with the NSNumber `UserDefaults.bool(forKey:)` derives from it
/// ("YES"/"true"/"1" → true), in the argument domain itself, so it still wins over the stored value for this launch
/// and is never written to disk.
public enum DefaultsLaunchOverrides {
    @discardableResult
    public static func normalize(_ names: [String] = SettingsKeys.bools.map(\.name),
                                 defaults: UserDefaults = AppDefaults.standard) -> [String: Bool] {
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var changed: [String: Bool] = [:]
        for name in names {
            guard let s = domain[name] as? String else { continue }
            let v = (s as NSString).boolValue
            domain[name] = NSNumber(value: v)
            changed[name] = v
        }
        guard !changed.isEmpty else { return [:] }
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        return changed
    }
}

public enum ModelInfoSetting {
    /// The `-showModelInfo YES|NO` launch override, else the setting (M1.T25b; `DefaultsLaunchOverrides` also makes
    /// the Defaults key read it, this keeps the explicit LaunchOptions path for tests).
    public static func isEnabled(setting: Bool = Defaults[.showModelInfo], options: LaunchOptions = .current) -> Bool {
        options.showModelInfo ?? setting
    }
}
