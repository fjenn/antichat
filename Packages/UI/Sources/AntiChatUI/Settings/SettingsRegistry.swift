// SettingsRegistry (M1.T22 step 2; R-100, R-012 AC2): every row of the Settings window as data —
// `{id, key, section, label, default, R-ID}` — in settings-map.md order. It feeds the Settings search
// (`SettingsSearch`), the ⌘K settings provider (`SettingsRowsIndex`, M1.T11) and SettingsRegistryTests.
// A row with a `key` binds to that Defaults key (Keys.swift) and saves instantly; a row without one is a page,
// a button or read-only. `enabled == false` rows show their reason (SettingsRow "disabled with a reason").
import AntiChatDesign

public struct SettingsRowSpec: Identifiable, Hashable, Sendable {
    /// Unique across sections; equals the Defaults key name for keyed rows.
    public var id: String
    public var section: SettingsSection
    public var label: CopyKey
    /// The `Defaults.Keys` name the row writes (nil: page, button, read-only or disabled placeholder).
    public var key: String?
    /// The settings-map Default column (documentation; Keys.swift holds the typed default).
    public var defaultText: String
    public var requirement: String
    /// False = shown disabled with a reason (arrives in a later milestone).
    public var enabled: Bool
    /// Extra words the row is found by (English synonyms).
    public var keywords: [String]
    /// The one-line description under the row's title, when it has one (Settings search reads it too).
    public var note: CopyKey?
    /// The row sits inside its page's collapsed "Advanced" group (revealing it opens the group).
    public var advanced: Bool

    public init(_ id: String, _ section: SettingsSection, _ label: String, key: String? = nil, default defaultText: String = "—",
                _ requirement: String, enabled: Bool = true, advanced: Bool = false, keywords: [String] = [],
                note: String? = nil) {
        self.id = id
        self.section = section
        self.label = CopyKey(label)
        self.key = key
        self.defaultText = defaultText
        self.requirement = requirement
        self.enabled = enabled
        self.keywords = keywords
        self.advanced = advanced
        self.note = note.map { CopyKey($0) }
    }
}

public enum SettingsRegistry {
    /// Every row, grouped as settings-map §1–§13 lists them; `section` is the page a row is on now (six pages).
    public static let rows: [SettingsRowSpec] = [
        // §1 General
        .init("appLanguage", .general, "set.general.language", default: "Follow macOS", "R-102",
              keywords: ["language", "translation", "locale"]),
        .init("announceReplies", .general, "set.a11y.announce", key: "announceReplies", default: "When finished", "R-223",
              advanced: true, keywords: ["voiceover", "accessibility", "announce", "screen reader"]),
        .init("sendWithCommandEnter", .general, "set.general.sendWith", key: "sendWithCommandEnter",
              default: "Enter (Shift+Enter = newline)", "R-002",
              keywords: ["enter", "return", "command enter", "newline", "keyboard"]),
        .init("plainTextComposer", .general, "set.general.plainText", key: "plainTextComposer", default: "Off", "R-002",
              advanced: true, keywords: ["markdown", "formatting", "composer"]),
        .init("showContextUsage", .general, "set.general.contextUsage", key: "showContextUsage", default: "Off", "R-009",
              advanced: true, keywords: ["context", "tokens", "memory"]),
        .init("launchAtLogin", .general, "set.general.launchAtLogin", key: "launchAtLogin", default: "Off", "R-100",
              keywords: ["login", "startup", "open at login"]),
        .init("menuBarItem", .general, "set.general.menuBar", key: "menuBarItem", default: "On", "R-105",
              keywords: ["menu bar", "status item"], note: "set.general.menuBar.note"),
        .init("keepRunning", .general, "set.general.keepRunning", default: "On while the menu bar item is on", "R-104",
              advanced: true, keywords: ["quit", "close window", "background"]),
        .init("quickPanelHotkey", .general, "set.general.quickPanel", default: "⌥Space", "R-106",
              advanced: true, keywords: ["hotkey", "quick panel", "option space", "global shortcut", "floating composer"]),
        // One visible switch (off = "Never"); when, the four category toggles and the sound are under Advanced (R-108).
        .init("notifications", .general, "set.general.notifications", "R-108", keywords: ["notifications", "notify", "alerts", "banner"]),
        .init("notifyWhen", .general, "set.notif.when", key: "notifyWhen", default: "Only when unfocused", "R-108",
              advanced: true, keywords: ["notifications", "notify", "alerts", "banner", "unfocused"]),
        .init("notifyResponses", .general, "set.notif.responses", key: "notifyResponses", default: "On", "R-108",
              advanced: true, keywords: ["notifications", "answer", "reply ready"]),
        .init("notifyMedia", .general, "set.notif.media", key: "notifyMedia", default: "On", "R-108",
              advanced: true, keywords: ["notifications", "image", "picture", "video", "media jobs"]),
        .init("notifyDownloads", .general, "set.notif.downloads", key: "notifyDownloads", default: "On", "R-108",
              advanced: true, keywords: ["notifications", "download", "pack ready"]),
        .init("notifyUpdates", .general, "set.notif.updates", key: "notifyUpdates", default: "On", "R-108",
              advanced: true, keywords: ["notifications", "update ready"]),
        .init("notificationSound", .general, "set.notif.sound", key: "notificationSound", default: "System default", "R-108",
              advanced: true, keywords: ["notifications", "sound", "alert sound", "chime"]),
        .init("performance", .general, "set.general.performance", key: "performance", default: "Auto", "R-207",
              advanced: true, keywords: ["battery", "power", "maximum"]),
        // §2 Appearance (M1.T23)
        .init("colorMode", .general, "set.appearance.colorMode", key: "colorMode", default: "System", "R-101",
              keywords: ["dark mode", "light mode", "night", "theme", "appearance"]),
        .init("accentColor", .general, "set.appearance.accent", key: "accentColor", default: "Default", "R-101",
              keywords: ["accent", "colour", "highlight", "tint"]),
        .init("chatFont", .general, "set.appearance.chatFont", key: "chatFont", default: "Default", "R-101",
              keywords: ["font", "typeface", "dyslexia", "opendyslexic"]),
        .init("textSize", .general, "set.appearance.textSize", key: "textSize", default: "14 pt", "R-101",
              keywords: ["text size", "font size", "bigger", "smaller", "zoom"]),
        .init("readingWidth", .general, "set.appearance.readingWidth", key: "readingWidth", default: "Wide", "R-101",
              advanced: true, keywords: ["column", "width", "narrow", "wide"]),
        .init("reduceMotion", .general, "set.appearance.reduceMotion", key: "reduceMotion", default: "System",
              "R-101", advanced: true, keywords: ["animation", "motion", "accessibility"]),
        .init("reduceTransparency", .general, "set.appearance.reduceTransparency", key: "reduceTransparency",
              default: "Follows macOS", "R-101", advanced: true, keywords: ["transparency", "glass", "blur", "accessibility"]),
        .init("increaseContrast", .general, "set.appearance.increaseContrast", key: "increaseContrast",
              default: "Follows macOS", "R-101", advanced: true, keywords: ["contrast", "accessibility", "high contrast"]),
        // §3 Capabilities
        .init("pack.chat", .capabilities, "set.cap.chat", default: "On (locked)", "R-202", keywords: ["pack", "chat model", "answers"]),
        .init("pack.voice", .capabilities, "set.cap.pack.voice", default: "Off", "R-202",
              keywords: ["voice", "pack", "download", "speech", "talk", "dictation", "read aloud", "remove models"]),
        .init("pack.photo", .capabilities, "set.cap.pack.photo", default: "Off", "R-202",
              keywords: ["photo", "image", "picture", "create image", "draw", "pack", "download", "remove models"]),
        .init("pack.video", .capabilities, "set.cap.pack.video", default: "Off", "R-202",
              keywords: ["video", "clip", "create video", "animation", "pack", "download", "remove models"]),
        // Owner 2026-11-16: Evil is the fifth row of the same list (its options: the Evil Mode group further down).
        .init("pack.evil", .capabilities, "set.evil", default: "Off", "R-210",
              keywords: ["evil", "evil mode", "uncensored", "unfiltered", "adult", "18+"]),
        .init("starter", .capabilities, "set.cap.starter", "R-298", advanced: true, keywords: ["starter", "quick model", "remove", "chat_fast"]),
        .init("showModelInfo", .capabilities, "set.cap.showModelInfo", key: "showModelInfo", default: "Off", "R-234",
              advanced: true, keywords: ["model info", "provenance", "tokens per second", "sampling"]),
        .init("modelOverrides", .capabilities, "set.cap.reset", default: "Recommended", "R-222",
              advanced: true, keywords: ["model", "override", "quantisation", "context length", "recommended", "reset", "fits", "too large"]),
        .init("keepLoadedMinutes", .capabilities, "set.cap.keepLoaded.label", key: "keepLoadedMinutes", default: "15 min", "R-206",
              advanced: true, keywords: ["keep alive", "unload", "memory", "idle"]),
        .init("allowOverBudget", .capabilities, "set.cap.allowOver", key: "allowOverBudget", default: "Off", "R-222",
              advanced: true, keywords: ["memory budget", "too large", "over budget"], note: "set.cap.allowOver.note"),
        // M5.T09 (R-044 AC2): Advanced → Video — the only place for steps, resolution and exact length.
        .init("videoAdvancedSteps", .capabilities, "set.cap.video.steps", key: "videoAdvancedSteps", default: "Per tier preset",
              "R-044", advanced: true, keywords: ["video", "steps", "quality", "faster", "speed", "advanced"],
              note: "set.cap.video.steps.note"),
        .init("videoAdvancedResolution", .capabilities, "set.cap.video.resolution", key: "videoAdvancedResolution",
              default: "Per tier preset", "R-044", advanced: true, keywords: ["video", "resolution", "480p", "720p", "1080p"]),
        .init("videoAdvancedSeconds", .capabilities, "set.cap.video.length", key: "videoAdvancedSeconds", default: "Per tier preset",
              "R-044", advanced: true, keywords: ["video", "length", "duration", "seconds", "clip"]),
        // M5.T11 (NFR-B5): Advanced → pause video jobs for another app's GPU load (default on).
        .init("yieldGPU", .capabilities, "set.capabilities.yieldGPU", key: "yieldGPU", default: "On", "R-041",
              advanced: true, keywords: ["video", "gpu", "game", "pause", "other app", "yield", "background"]),
        // §4 Evil Mode
        // §5 Voice
        .init("voiceInputDevice", .capabilities, "set.voice.microphone", key: "voiceInputDevice", default: "System default", "R-053",
              keywords: ["microphone", "mic", "input", "device", "level", "headset"]),
        .init("voiceSpokenLanguage", .capabilities, "set.voice.language", key: "voiceSpokenLanguage", default: "Auto-detect", "R-053",
              advanced: true, keywords: ["language", "dictation", "speech recognition", "transcription", "auto-detect"]),
        .init("voiceID", .capabilities, "set.voice.voice", key: "voiceID", default: "first of ≥ 6 voices", "R-053",
              keywords: ["voice", "read aloud", "speech", "tts", "preview"]),
        .init("voiceRate", .capabilities, "set.voice.speed", key: "voiceRate", default: "1.0×", "R-053",
              advanced: true, keywords: ["speed", "rate", "read aloud", "faster", "slower"]),
        .init("voiceMode", .capabilities, "set.voice.mode", key: "voiceMode", default: "Hands-free (VAD)", "R-052",
              advanced: true, keywords: ["conversation", "hands-free", "push-to-talk", "space", "voice mode"]),
        .init("voiceDuckOthers", .capabilities, "set.voice.ducking", key: "voiceDuckOthers", default: "On", "R-280",
              advanced: true, keywords: ["ducking", "lower", "other apps", "music", "volume", "conversation"]),
        .init("voice.recordings", .capabilities, "set.voice.recordings", "R-050",
              advanced: true, keywords: ["recordings", "dictation", "history", "audio", "transcript"]),
        // §6 Personalization
        .init("aboutYou", .personalization, "set.pers.aboutYou", key: "aboutYou", default: "empty", "R-062",
              keywords: ["custom instructions", "about me", "profile"]),
        .init("howToRespond", .personalization, "set.pers.howToRespond", key: "howToRespond", default: "empty", "R-062",
              keywords: ["custom instructions", "respond", "tone"]),
        .init("stylePreset", .personalization, "set.pers.style", key: "stylePreset", default: "Default", "R-062",
              keywords: ["style", "professional", "friendly", "candid", "efficient", "quirky", "personality", "tone"],
              note: "set.pers.style.note"),
        .init("warmth", .personalization, "set.pers.warmth", key: "warmth", default: "Default", "R-062",
              advanced: true, keywords: ["characteristics", "warm"]),
        .init("enthusiasm", .personalization, "set.pers.enthusiasm", key: "enthusiasm", default: "Default", "R-062",
              advanced: true, keywords: ["characteristics", "enthusiastic"]),
        .init("headersAndLists", .personalization, "set.pers.headers", key: "headersAndLists", default: "Default",
              "R-062", advanced: true, keywords: ["characteristics", "headings", "bullets", "lists"]),
        .init("emoji", .personalization, "set.pers.emoji", key: "emoji", default: "Default", "R-062",
              advanced: true, keywords: ["characteristics", "emojis"]),
        // M8.T03 (R-060, R-246): Memory
        .init("memoryMode", .personalization, "set.memory.mode", key: "memoryMode", default: "On", "R-060",
              keywords: ["memory", "remember", "pause"], note: "set.memory.note"),
        .init("memoryIncludeSensitive", .personalization, "set.memory.sensitive", key: "memoryIncludeSensitive", default: "On",
              "R-060", advanced: true, keywords: ["memory", "sensitive", "health", "religion", "politics"]),
        .init("memoryReviewEnabled", .personalization, "set.memory.suggest", key: "memoryReviewEnabled",
              default: "On (T2–T4), Off (T0–T1)", "R-246", advanced: true, keywords: ["memory", "suggest", "review", "remember"],
              note: "set.memory.suggest.note"),
        .init("manageMemories", .personalization, "set.memory.manage", "R-060", keywords: ["memory", "memories", "edit", "delete", "forget", "remembered"]),
        .init("resetMemory", .personalization, "set.memory.reset", "R-060", advanced: true, keywords: ["memory", "reset", "forget"]),
        .init("useMemoryInEvil", .capabilities, "set.evil.memory", key: "useMemoryInEvil", default: "On", "R-060",
              keywords: ["memory", "evil"]),
        // M5.T13 (R-022 AC4): default follows the Evil enable state until the user sets it.
        .init("showEvilInLibrary", .capabilities, "set.evil.showLibrary", key: "showEvilInLibrary", default: "On when Evil is enabled, else Off",
              "R-022", keywords: ["library", "evil", "badge", "hide", "show"]),
        // §7 Tools & Connections
        .init("createFiles", .capabilities, "set.tools.createFiles", key: "createFilesEnabled", default: "On", "R-018",
              keywords: ["create files", "documents", "spreadsheets", "presentations", "slides", "pdf", "word", "excel", "charts"],
              note: "set.tools.createFiles.note"),
        .init("runCode", .capabilities, "set.tools.code", key: "runCodeEnabled", default: "Off until installed", "R-018",
              keywords: ["run code", "python", "file tools", "analysis", "analyze", "spreadsheet", "csv", "sandbox"],
              note: "set.tools.code.note"),
        .init("codeNet", .capabilities, "set.tools.codeNet", key: "allowNetworkForCode", default: "On", "R-018",
              advanced: true, keywords: ["network", "internet", "code", "python", "file tools", "analyse data", "download"],
              note: "set.tools.codeNet.note"),
        // M7.T03: Web search (the gate's `.search` switch) and Safe search results (R-080, R-241 AC3).
        .init("webSearch", .capabilities, "set.tools.web", "R-080", keywords: ["web search", "internet", "search engines", "online", "browse", "google"],
              note: "set.tools.web.note"),
        .init("safeSearch", .capabilities, "set.tools.safeSearch", key: "safeSearch", default: "Off", "R-241", advanced: true, keywords: ["safe search", "web search", "results"]),
        // M8.T08 (R-091 AC3): approximate location for search, On; macOS is asked at the first search that would use it.
        .init("searchUsesLocation", .capabilities, "set.tools.location", key: "searchUsesLocation", default: "On", "R-091",
              advanced: true, keywords: ["location", "local results", "web search", "city"]),
        // M7.T05 (R-228 AC3): the fresh-information hint, under Web search (settings-map §7; A-M7-07).
        .init("suggestWebSearch", .capabilities, "set.tools.suggestWeb", key: "suggestWebSearch", default: "On", "R-228",
              advanced: true, keywords: ["suggest", "hint", "web search", "fresh", "current information"]),
        // M7.T14 (R-268): the built-in tool switches and Tool access (ToolsPage).
        // Create image / Create video have no row: the Images and Video packs' switches are their switches
        // (`toolImage` / `toolVideo` follow the pack, PackManagementModel.syncTools).
        .init("toolMemory", .capabilities, "set.tools.memory", key: "toolMemory", default: "On", "R-268",
              keywords: ["tools", "memory", "remember"], note: "set.tools.memory.note"),
        .init("toolAccess", .capabilities, "set.tools.access", key: "toolAccess", default: "Load tools when needed", "R-268",
              advanced: true, keywords: ["tools", "tool access", "load tools when needed", "always offer all"]),
        // M7.T06 (R-081): Connections (remote MCP servers; Composio M7.T11).
        .init("connections", .connections, "conn.title", "R-081", keywords: ["connections", "connect", "connectors", "apps", "gmail", "google calendar", "google drive", "slack", "notion",
                         "github", "linear", "outlook", "email", "mcp", "server"]),
        // §8 Skills
        // M7.T12 (R-082, R-261): the skills list (switches, Apply to every chat, delete, export) and Add skill.
        .init("skills", .skills, "set.skills", default: "4–6 starter skills, on", "R-082",
              keywords: ["skills", "skill", "instructions", "starter", "apply to every chat", "export"]),
        .init("addSkill", .skills, "skills.add", "R-082", keywords: ["add skill", "import", "zip", "folder", "skill.md"]),
        // §9 Privacy & Data — M8.T08 (R-091): settings-map §9 order, after the statement paragraph (PrivacyDataView).
        // M2.T03 (R-209, R-297): Offline only + Network activity.
        .init("offlineOnly", .privacy, "set.privacy.offlineOnly", "R-209", keywords: ["offline", "network", "internet", "privacy", "airplane"],
              note: "set.privacy.offlineOnly.note"),
        .init("networkActivity", .privacy, "set.privacy.activity", "R-297", advanced: true, keywords: ["network", "activity", "hosts", "internet"]),
        .init("privacyLocation", .privacy, "privacy.location.label", "R-091", advanced: true, keywords: ["location", "gps", "where", "privacy"]),
        .init("newChatsIncognito", .privacy, "set.privacy.incognitoDefault", key: "newChatsIncognito",
              default: "Off `[ASSUMPTION, owner 3]`", "R-091", keywords: ["incognito", "private", "new chat", "temporary", "history"]),
        .init("incognitoPersonalizationDefault", .privacy, "set.privacy.incognitoPersonalization",
              key: "incognitoPersonalizationDefault", default: "Personalized", "R-090",
              advanced: true, keywords: ["incognito", "personalized", "unpersonalized", "memory"]),
        .init("importChats", .privacy, "set.privacy.import", "R-092", keywords: ["import", "chatgpt", "claude", "export", "zip", "move chats", "transfer"]),  // M8.T06
        .init("exportAll", .privacy, "set.privacy.exportAll.label", "R-093", keywords: ["export", "backup", "zip", "download", "data"]),  // M8.T07
        .init("restoreBackup", .privacy, "set.privacy.restore", "R-301", advanced: true, keywords: ["backup", "restore", "undo", "recover"]),  // M8.T01
        .init("archivedChats", .privacy, "archived.title", "R-011", keywords: ["archive", "unarchive", "archived", "hidden chats"]),
        .init("archiveAll", .privacy, "set.privacy.archiveAll", "R-011", advanced: true, keywords: ["archive", "all chats"]),
        .init("deleteAll", .privacy, "set.privacy.deleteAll", "R-011", keywords: ["delete", "erase", "remove", "clear", "wipe", "history", "conversations", "all chats"]),
        .init("autoArchiveDays", .privacy, "set.privacy.autoArchive", key: "autoArchiveDays", default: "Never", "R-011",
              advanced: true, keywords: ["archive", "inactive", "old chats"]),
        .init("crashReports", .privacy, "set.privacy.crash", key: "crashReportMode", default: "Ask after a crash", "R-218",
              advanced: true, keywords: ["crash", "reports", "diagnostics", "telemetry"]),  // M8.T09
        .init("exportLogs", .privacy, "set.privacy.exportLogs", "R-218", advanced: true, keywords: ["logs", "diagnostics", "export", "debug"]),
        // §10 Storage
        // M8.T10 (R-205): the dashboard rows (the bar and the paths list are read-only blocks above / between them).
        .init("storage.modelsFolder", .privacy, "storage.modelsFolder", "R-205",
              advanced: true, keywords: ["models folder", "move", "external drive", "time machine", "disk"]),
        .init("storage.cleanUp", .privacy, "storage.cleanUp", "R-205", keywords: ["clean up", "cache", "free space", "disk", "storage"], note: "storage.cleanUp.note"),
        .init("storage.removeEverything", .privacy, "set.storage.removeEverything", "R-205",
              advanced: true, keywords: ["remove everything", "erase", "reset", "delete all data"]),
        .init("storage.uninstall", .privacy, "set.storage.uninstall", "R-226", advanced: true, keywords: ["uninstall", "remove app", "delete app"]),  // M8.T11
        // §11 Updates
        .init("autoUpdateModels", .general, "set.updates.models", key: "autoUpdateModels", default: "On", "R-294",
              advanced: true, keywords: ["model updates", "automatic", "upgrade", "download"]),
        // M10.T03 (R-219): Sparkle app updates (values live in Sparkle's own defaults, so no Keys.swift entries).
        .init("updates.autoCheck", .general, "set.updates.autoCheck", "R-219",
              advanced: true, keywords: ["update", "automatic", "check", "sparkle"]),
        .init("updates.autoDownload", .general, "set.updates.auto", "R-219",
              advanced: true, keywords: ["update", "automatic", "download", "install"]),
        .init("updates.beta", .general, "set.updates.beta", "R-219", advanced: true, keywords: ["beta", "pre-release", "channel"]),
        .init("updates.whatsNew", .general, "set.updates.whatsNew", "R-303", advanced: true, keywords: ["what's new", "release notes"]),  // M10.T07
        .init("updates.check", .general, "set.updates.check", "R-219",
              keywords: ["update", "check now", "release notes", "version"]),
        // §12 Keyboard shortcuts (M1.T24 replaces the placeholder with the shortcut list)
        .init("shortcuts", .general, "set.shortcuts", "R-103",
              keywords: ["shortcut", "hotkey", "keyboard", "rebind", "key binding"]),
        // §13 About & Help
        .init("version", .general, "set.about.version", "R-218", advanced: true, keywords: ["version", "build", "about"]),
        .init("help", .general, "set.about.help", "R-303", keywords: ["help", "guide"]),
        .init("reportProblem", .general, "set.about.report", "R-218", keywords: ["bug", "report", "feedback"]),
        .init("systemReport", .general, "set.about.systemReport", "R-218", advanced: true, keywords: ["system", "report", "hardware", "tier", "diagnostics"]),  // M8.T09
        .init("exportDiagnostics", .general, "set.about.diagnostics", "R-218", advanced: true, keywords: ["logs", "diagnostics", "export"]),
        .init("legal", .general, "legal.title", "R-217", advanced: true, keywords: ["legal", "terms", "privacy", "evil mode terms", "abuse"]),  // M10.T06
        .init("licences", .general, "set.about.licences", "R-218", advanced: true, keywords: ["licence", "license", "open source", "font"]),
    ]

    public static func rows(in section: SettingsSection) -> [SettingsRowSpec] { rows.filter { $0.section == section } }

    public static func row(_ id: String) -> SettingsRowSpec? { rows.first { $0.id == id } }

    /// The ⌘K index (M1.T11's `SettingsRowsIndex`): every row, label + section + keywords.
    public static var paletteRows: [SettingsRowEntry] {
        rows.map { SettingsRowEntry(id: $0.id, section: $0.section, label: $0.label, keywords: $0.keywords) }
    }
}
