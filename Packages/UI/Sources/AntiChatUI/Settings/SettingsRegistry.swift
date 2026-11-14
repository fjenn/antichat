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

    public init(_ id: String, _ section: SettingsSection, _ label: String, key: String? = nil, default defaultText: String = "—",
                _ requirement: String, enabled: Bool = true, keywords: [String] = []) {
        self.id = id
        self.section = section
        self.label = CopyKey(label)
        self.key = key
        self.defaultText = defaultText
        self.requirement = requirement
        self.enabled = enabled
        self.keywords = keywords
    }
}

public enum SettingsRegistry {
    /// Every row, in Settings order (settings-map §1–§13; M1 rows, plus one disabled placeholder per later group).
    public static let rows: [SettingsRowSpec] = [
        // §1 General
        .init("appLanguage", .general, "set.general.language", default: "Follow macOS", "R-102",
              keywords: ["language", "translation", "locale"]),
        .init("announceReplies", .general, "set.a11y.announce", key: "announceReplies", default: "When finished", "R-223",
              keywords: ["voiceover", "accessibility", "announce", "screen reader"]),
        .init("sendWithCommandEnter", .general, "set.general.sendWith", key: "sendWithCommandEnter",
              default: "Enter (Shift+Enter = newline)", "R-002",
              keywords: ["enter", "return", "command enter", "newline", "keyboard"]),
        .init("plainTextComposer", .general, "set.general.plainText", key: "plainTextComposer", default: "Off", "R-002",
              keywords: ["markdown", "formatting", "composer"]),
        .init("showContextUsage", .general, "set.general.contextUsage", key: "showContextUsage", default: "Off", "R-009",
              keywords: ["context", "tokens", "memory"]),
        .init("launchAtLogin", .general, "set.general.launchAtLogin", key: "launchAtLogin", default: "Off", "R-100",
              keywords: ["login", "startup", "open at login"]),
        .init("menuBarItem", .general, "set.general.menuBar", key: "menuBarItem", default: "On", "R-105",
              keywords: ["menu bar", "status item"]),
        .init("keepRunning", .general, "set.general.keepRunning", default: "On while the menu bar item is on", "R-104",
              keywords: ["quit", "close window", "background"]),
        .init("quickPanelHotkey", .general, "set.general.quickPanel", default: "⌥Space", "R-106",
              keywords: ["hotkey", "quick panel", "option space", "global shortcut", "floating composer"]),
        // M8.T12 (R-108): Notifications — when, the four category toggles, sound.
        .init("notifyWhen", .general, "set.notif.when", key: "notifyWhen", default: "Only when unfocused", "R-108",
              keywords: ["notifications", "notify", "alerts", "banner", "unfocused"]),
        .init("notifyResponses", .general, "set.notif.responses", key: "notifyResponses", default: "On", "R-108",
              keywords: ["notifications", "answer", "reply ready"]),
        .init("notifyMedia", .general, "set.notif.media", key: "notifyMedia", default: "On", "R-108",
              keywords: ["notifications", "image", "picture", "video", "media jobs"]),
        .init("notifyDownloads", .general, "set.notif.downloads", key: "notifyDownloads", default: "On", "R-108",
              keywords: ["notifications", "download", "pack ready"]),
        .init("notifyUpdates", .general, "set.notif.updates", key: "notifyUpdates", default: "On", "R-108",
              keywords: ["notifications", "update ready"]),
        .init("notificationSound", .general, "set.notif.sound", key: "notificationSound", default: "System default", "R-108",
              keywords: ["notifications", "sound", "alert sound", "chime"]),
        .init("performance", .general, "set.general.performance", key: "performance", default: "Auto", "R-207",
              keywords: ["battery", "power", "maximum"]),
        // §2 Appearance (M1.T23)
        .init("colorMode", .appearance, "set.appearance.colorMode", key: "colorMode", default: "System", "R-101",
              keywords: ["dark mode", "light mode", "theme", "appearance"]),
        .init("accentColor", .appearance, "set.appearance.accent", key: "accentColor", default: "Default", "R-101",
              keywords: ["accent", "colour", "highlight", "tint"]),
        .init("chatFont", .appearance, "set.appearance.chatFont", key: "chatFont", default: "Default", "R-101",
              keywords: ["font", "typeface", "dyslexia", "opendyslexic"]),
        .init("textSize", .appearance, "set.appearance.textSize", key: "textSize", default: "14 pt", "R-101",
              keywords: ["text size", "font size", "bigger", "smaller", "zoom"]),
        .init("readingWidth", .appearance, "set.appearance.readingWidth", key: "readingWidth", default: "Wide", "R-101",
              keywords: ["column", "width", "narrow", "wide"]),
        .init("reduceMotion", .appearance, "set.appearance.reduceMotion", key: "reduceMotion", default: "System",
              "R-101", keywords: ["animation", "motion", "accessibility"]),
        .init("reduceTransparency", .appearance, "set.appearance.reduceTransparency", key: "reduceTransparency",
              default: "Follows macOS", "R-101", keywords: ["transparency", "glass", "blur", "accessibility"]),
        .init("increaseContrast", .appearance, "set.appearance.increaseContrast", key: "increaseContrast",
              default: "Follows macOS", "R-101", keywords: ["contrast", "accessibility", "high contrast"]),
        // §3 Capabilities
        .init("pack.chat", .capabilities, "set.cap.chat", default: "On (locked)", "R-202", keywords: ["pack", "chat model"]),
        .init("pack.voice", .capabilities, "set.cap.pack.voice", default: "Off", "R-202",
              keywords: ["voice", "pack", "download", "speech", "remove models"]),
        .init("pack.photo", .capabilities, "set.cap.pack.photo", default: "Off", "R-202",
              keywords: ["photo", "image", "pack", "download", "remove models"]),
        .init("pack.video", .capabilities, "set.cap.pack.video", default: "Off", "R-202",
              keywords: ["video", "pack", "download", "remove models"]),
        .init("starter", .capabilities, "set.cap.starter", "R-298", keywords: ["starter", "quick model", "remove", "chat_fast"]),
        .init("capabilities.advanced", .capabilities, "set.cap.advanced", "R-100",
              keywords: ["model", "quantisation", "context length", "keep loaded", "hugging face"]),
        .init("showModelInfo", .capabilities, "set.cap.showModelInfo", key: "showModelInfo", default: "Off", "R-234",
              keywords: ["model info", "provenance", "tokens per second", "sampling"]),
        .init("modelOverrides", .capabilities, "set.cap.reset", default: "Recommended", "R-222",
              keywords: ["model", "override", "quantisation", "context length", "recommended", "reset", "fits", "too large"]),
        .init("keepLoadedMinutes", .capabilities, "set.cap.keepLoaded.label", key: "keepLoadedMinutes", default: "15 min", "R-206",
              keywords: ["keep alive", "unload", "memory", "idle"]),
        .init("allowOverBudget", .capabilities, "set.cap.allowOver", key: "allowOverBudget", default: "Off", "R-222",
              keywords: ["memory budget", "too large", "over budget"]),
        // M5.T09 (R-044 AC2): Advanced → Video — the only place for steps, resolution and exact length.
        .init("videoAdvancedSteps", .capabilities, "set.cap.video.steps", key: "videoAdvancedSteps", default: "Per tier preset",
              "R-044", keywords: ["video", "steps", "quality", "advanced"]),
        .init("videoAdvancedResolution", .capabilities, "set.cap.video.resolution", key: "videoAdvancedResolution",
              default: "Per tier preset", "R-044", keywords: ["video", "resolution", "480p", "720p", "1080p"]),
        .init("videoAdvancedSeconds", .capabilities, "set.cap.video.length", key: "videoAdvancedSeconds", default: "Per tier preset",
              "R-044", keywords: ["video", "length", "duration", "seconds", "clip"]),
        // M5.T11 (NFR-B5): Advanced → pause video jobs for another app's GPU load (default on).
        .init("yieldGPU", .capabilities, "set.capabilities.yieldGPU", key: "yieldGPU", default: "On", "R-041",
              keywords: ["video", "gpu", "game", "pause", "other app", "yield", "background"]),
        // §4 Evil Mode
        .init("evil.later", .evil, "set.evil.later", "R-211", enabled: false, keywords: ["evil", "uncensored", "18+"]),
        // §5 Voice
        .init("voiceInputDevice", .voice, "set.voice.microphone", key: "voiceInputDevice", default: "System default", "R-053",
              keywords: ["microphone", "mic", "input", "device", "level", "headset"]),
        .init("voiceSpokenLanguage", .voice, "set.voice.language", key: "voiceSpokenLanguage", default: "Auto-detect", "R-053",
              keywords: ["language", "dictation", "speech recognition", "transcription", "auto-detect"]),
        .init("voiceID", .voice, "set.voice.voice", key: "voiceID", default: "first of ≥ 6 voices", "R-053",
              keywords: ["voice", "read aloud", "speech", "tts", "preview"]),
        .init("voiceRate", .voice, "set.voice.speed", key: "voiceRate", default: "1.0×", "R-053",
              keywords: ["speed", "rate", "read aloud", "faster", "slower"]),
        .init("voiceMode", .voice, "set.voice.mode", key: "voiceMode", default: "Hands-free (VAD)", "R-052",
              keywords: ["conversation", "hands-free", "push-to-talk", "space", "voice mode"]),
        .init("voiceDuckOthers", .voice, "set.voice.ducking", key: "voiceDuckOthers", default: "On", "R-280",
              keywords: ["ducking", "lower", "other apps", "music", "volume", "conversation"]),
        .init("voice.recordings", .voice, "set.voice.recordings", "R-050",
              keywords: ["recordings", "dictation", "history", "audio", "transcript"]),
        // §6 Personalization
        .init("aboutYou", .personalization, "set.pers.aboutYou", key: "aboutYou", default: "empty", "R-062",
              keywords: ["custom instructions", "about me", "profile"]),
        .init("howToRespond", .personalization, "set.pers.howToRespond", key: "howToRespond", default: "empty", "R-062",
              keywords: ["custom instructions", "respond", "tone"]),
        .init("stylePreset", .personalization, "set.pers.style", key: "stylePreset", default: "Default", "R-062",
              keywords: ["style", "professional", "friendly", "candid", "efficient", "quirky", "personality"]),
        .init("warmth", .personalization, "set.pers.warmth", key: "warmth", default: "Default", "R-062",
              keywords: ["characteristics", "warm"]),
        .init("enthusiasm", .personalization, "set.pers.enthusiasm", key: "enthusiasm", default: "Default", "R-062",
              keywords: ["characteristics", "enthusiastic"]),
        .init("headersAndLists", .personalization, "set.pers.headers", key: "headersAndLists", default: "Default",
              "R-062", keywords: ["characteristics", "headings", "bullets", "lists"]),
        .init("emoji", .personalization, "set.pers.emoji", key: "emoji", default: "Default", "R-062",
              keywords: ["characteristics", "emojis"]),
        // M8.T03 (R-060, R-246): Memory
        .init("memoryMode", .personalization, "set.memory.mode", key: "memoryMode", default: "On", "R-060",
              keywords: ["memory", "remember", "pause"]),
        .init("memoryIncludeSensitive", .personalization, "set.memory.sensitive", key: "memoryIncludeSensitive", default: "Off",
              "R-060", keywords: ["memory", "sensitive", "health", "religion", "politics"]),
        .init("memoryReviewEnabled", .personalization, "set.memory.suggest", key: "memoryReviewEnabled",
              default: "On (T2–T4), Off (T0–T1)", "R-246", keywords: ["memory", "suggest", "review"]),
        .init("manageMemories", .personalization, "set.memory.manage", "R-060", keywords: ["memory", "memories", "edit", "delete"]),
        .init("resetMemory", .personalization, "set.memory.reset", "R-060", keywords: ["memory", "reset", "forget"]),
        .init("useMemoryInEvil", .evil, "set.evil.memory", key: "useMemoryInEvil", default: "Off", "R-060",
              keywords: ["memory", "evil"]),
        // M5.T13 (R-022 AC4): default follows the Evil enable state until the user sets it.
        .init("showEvilInLibrary", .evil, "set.evil.showLibrary", key: "showEvilInLibrary", default: "On when Evil is enabled, else Off",
              "R-022", keywords: ["library", "evil", "badge", "hide", "show"]),
        // §7 Tools & Connections
        .init("createFiles", .tools, "set.tools.createFiles", key: "createFilesEnabled", default: "On", "R-018",
              keywords: ["create files", "documents", "spreadsheets", "presentations", "charts"]),
        .init("runCode", .tools, "set.tools.code", key: "runCodeEnabled", default: "Off until installed", "R-018",
              keywords: ["run code", "python", "file tools", "analysis", "sandbox"]),
        .init("codeNet", .tools, "set.tools.codeNet", key: "allowNetworkForCode", default: "Off", "R-018",
              keywords: ["network", "code", "python", "file tools"]),
        // M7.T03: Web search (the gate's `.search` switch) and Safe search results (R-080, R-241 AC3).
        .init("webSearch", .tools, "set.tools.web", "R-080", keywords: ["web search", "internet", "search engines", "online"]),
        .init("safeSearch", .tools, "set.tools.safeSearch", key: "safeSearch", default: "Off", "R-241", keywords: ["safe search", "web search", "results"]),
        // M8.T08 (R-091 AC3): approximate location for search, Off; asks for Location only when turned on.
        .init("searchUsesLocation", .tools, "set.tools.location", key: "searchUsesLocation", default: "Off", "R-091",
              keywords: ["location", "local results", "web search", "city"]),
        // M7.T05 (R-228 AC3): the fresh-information hint, under Web search (settings-map §7; A-M7-07).
        .init("suggestWebSearch", .tools, "set.tools.suggestWeb", key: "suggestWebSearch", default: "On", "R-228",
              keywords: ["suggest", "hint", "web search", "fresh", "current information"]),
        // M7.T14 (R-268): the built-in tool switches and Tool access (ToolsPage), above Connections.
        .init("toolImage", .tools, "set.tools.image", key: "toolImage", default: "On", "R-268",
              keywords: ["tools", "create image", "picture", "photo"]),
        .init("toolVideo", .tools, "set.tools.video", key: "toolVideo", default: "On", "R-268",
              keywords: ["tools", "create video", "clip", "animation"]),
        .init("toolMemory", .tools, "set.tools.memory", key: "toolMemory", default: "On", "R-268",
              keywords: ["tools", "memory", "remember"]),
        .init("toolAccess", .tools, "set.tools.access", key: "toolAccess", default: "Load tools when needed", "R-268",
              keywords: ["tools", "tool access", "load tools when needed", "always offer all"]),
        // M7.T06 (R-081): Connections (remote MCP servers; Composio M7.T11).
        .init("connections", .tools, "conn.title", "R-081", keywords: ["connections", "mcp", "server", "connectors", "apps"]),
        // §8 Skills
        // M7.T12 (R-082, R-261): the skills list (switches, Apply to every chat, delete, export) and Add skill.
        .init("skills", .skills, "set.skills", default: "4–6 starter skills, on", "R-082",
              keywords: ["skills", "skill", "instructions", "starter", "apply to every chat", "export"]),
        .init("addSkill", .skills, "skills.add", "R-082", keywords: ["add skill", "import", "zip", "folder", "skill.md"]),
        // §9 Privacy & Data — M8.T08 (R-091): settings-map §9 order, after the statement paragraph (PrivacyDataView).
        // M2.T03 (R-209, R-297): Offline only + Network activity.
        .init("offlineOnly", .privacy, "set.privacy.offlineOnly", "R-209", keywords: ["offline", "network", "internet", "privacy"]),
        .init("networkActivity", .privacy, "set.privacy.activity", "R-297", keywords: ["network", "activity", "hosts", "internet"]),
        .init("privacyLocation", .privacy, "privacy.location.label", "R-091", keywords: ["location", "gps", "where", "privacy"]),
        .init("newChatsIncognito", .privacy, "set.privacy.incognitoDefault", key: "newChatsIncognito",
              default: "Off `[ASSUMPTION, owner 3]`", "R-091", keywords: ["incognito", "private", "new chat", "temporary"]),
        .init("incognitoPersonalizationDefault", .privacy, "set.privacy.incognitoPersonalization",
              key: "incognitoPersonalizationDefault", default: "Personalized", "R-090",
              keywords: ["incognito", "personalized", "unpersonalized", "memory"]),
        .init("importChats", .privacy, "set.privacy.import", "R-092", keywords: ["import", "chatgpt", "claude", "export", "zip"]),  // M8.T06
        .init("exportAll", .privacy, "set.privacy.exportAll.label", "R-093", keywords: ["export", "backup", "zip", "download", "data"]),  // M8.T07
        .init("restoreBackup", .privacy, "set.privacy.restore", "R-301", keywords: ["backup", "restore", "undo", "recover"]),  // M8.T01
        .init("archivedChats", .privacy, "archived.title", "R-011", keywords: ["archive", "unarchive", "archived"]),
        .init("archiveAll", .privacy, "set.privacy.archiveAll", "R-011", keywords: ["archive", "all chats"]),
        .init("deleteAll", .privacy, "set.privacy.deleteAll", "R-011", keywords: ["delete", "erase", "all chats"]),
        .init("autoArchiveDays", .privacy, "set.privacy.autoArchive", key: "autoArchiveDays", default: "Never", "R-011",
              keywords: ["archive", "inactive", "old chats"]),
        .init("crashReports", .privacy, "set.privacy.crash", key: "crashReportMode", default: "Ask after a crash", "R-218",
              keywords: ["crash", "reports", "diagnostics", "telemetry"]),  // M8.T09
        .init("exportLogs", .privacy, "set.privacy.exportLogs", "R-218", keywords: ["logs", "diagnostics", "export", "debug"]),
        // §10 Storage
        .init("storage.later", .storage, "set.storage.later", "R-205", enabled: false,
              keywords: ["disk", "models folder", "remove everything", "uninstall"]),
        // M8.T10 (R-205): the dashboard rows (the bar and the paths list are read-only blocks above / between them).
        .init("storage.modelsFolder", .storage, "storage.modelsFolder", "R-205",
              keywords: ["models folder", "move", "external drive", "time machine", "disk"]),
        .init("storage.cleanUp", .storage, "storage.cleanUp", "R-205", keywords: ["clean up", "cache", "free space", "disk"]),
        .init("storage.removeEverything", .storage, "set.storage.removeEverything", "R-205",
              keywords: ["remove everything", "erase", "reset", "delete all data"]),
        .init("storage.uninstall", .storage, "set.storage.uninstall", "R-226", keywords: ["uninstall", "remove app", "delete app"]),  // M8.T11
        // §11 Updates
        .init("autoUpdateModels", .updates, "set.updates.models", key: "autoUpdateModels", default: "On", "R-294",
              keywords: ["model updates", "automatic", "upgrade", "download"]),
        // M10.T03 (R-219): Sparkle app updates (values live in Sparkle's own defaults, so no Keys.swift entries).
        .init("updates.autoCheck", .updates, "set.updates.autoCheck", "R-219",
              keywords: ["update", "automatic", "check", "sparkle"]),
        .init("updates.autoDownload", .updates, "set.updates.auto", "R-219",
              keywords: ["update", "automatic", "download", "install"]),
        .init("updates.beta", .updates, "set.updates.beta", "R-219", keywords: ["beta", "pre-release", "channel"]),
        .init("updates.whatsNew", .updates, "set.updates.whatsNew", "R-303", keywords: ["what's new", "release notes"]),  // M10.T07
        .init("updates.check", .updates, "set.updates.check", "R-219",
              keywords: ["update", "check now", "release notes", "version"]),
        // §12 Keyboard shortcuts (M1.T24 replaces the placeholder with the shortcut list)
        .init("shortcutsRestore", .shortcuts, "set.shortcuts.restore", "R-103",
              keywords: ["shortcut", "hotkey", "keyboard", "rebind", "key binding"]),
        // §13 About & Help
        .init("version", .about, "set.about.version", "R-218", keywords: ["version", "build", "about"]),
        .init("help", .about, "set.about.help", "R-303", keywords: ["help", "guide"]),
        .init("reportProblem", .about, "set.about.report", "R-218", keywords: ["bug", "report", "feedback"]),
        .init("systemReport", .about, "set.about.systemReport", "R-218", keywords: ["system", "report", "hardware", "tier", "diagnostics"]),  // M8.T09
        .init("exportDiagnostics", .about, "set.about.diagnostics", "R-218", keywords: ["logs", "diagnostics", "export"]),
        .init("legal", .about, "legal.title", "R-217", keywords: ["legal", "terms", "privacy", "evil mode terms", "abuse"]),  // M10.T06
        .init("licences", .about, "set.about.licences", "R-218", keywords: ["licence", "license", "open source", "font"]),
    ]

    public static func rows(in section: SettingsSection) -> [SettingsRowSpec] { rows.filter { $0.section == section } }

    public static func row(_ id: String) -> SettingsRowSpec? { rows.first { $0.id == id } }

    /// The ⌘K index (M1.T11's `SettingsRowsIndex`): every row, label + section + keywords.
    public static var paletteRows: [SettingsRowEntry] {
        rows.map { SettingsRowEntry(id: $0.id, section: $0.section, label: $0.label, keywords: $0.keywords) }
    }
}
