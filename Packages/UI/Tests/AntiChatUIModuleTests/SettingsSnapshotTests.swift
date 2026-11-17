// M1.T22 definition of done: snapshots of every Settings page (light/dark), plus the search results
// state, the Archived chats page and the Delete all sheet. Same rig as WindowSnapshotTests.
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=SettingsSnapshotTests.
import AntiChatDesign
import AntiChatHarness
import AntiChatKnowledge
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools
import Defaults
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SettingsSnapshotTests {
    static let size = CGSize(width: 860, height: 620)

    /// Settings › Voice without CoreAudio, the machine's voices or the microphone (M3.T08): two fixed input devices.
    /// Also pins General's power notices (no live machine state on any page).
    static func fixedVoiceHost(devices: [AudioInputDevice] = [AudioInputDevice(uid: "uid-built-in", name: "MacBook Pro Microphone"),
                                                               AudioInputDevice(uid: "uid-usb", name: "USB Audio")]) {
        VoiceSection.host = .init(devices: { AudioDeviceCatalog(provider: StaticAudioDeviceProvider(devices)) },
                                  systemVoices: { [("v1", "Samantha", "en-US"), ("v2", "Daniel", "en-GB"), ("v3", "Karen", "en-AU"),
                                                   ("v4", "Moira", "en-IE"), ("v5", "Rishi", "en-IN"), ("v6", "Tessa", "en-ZA")] },
                                  meterPermitted: { false }, micInUse: { false })
        // Settings › General: no "Notifications are off" banner from this Mac's answer (another suite may have asked).
        PermissionCoordinator.shared.debugForgetStatus(.notifications)
        // Settings › General › Performance: no notice, whatever this Mac's power source or thermal state is right now
        // (a full run's load can take it to serious: `power.cooler`).
        PerformancePicker.currentNotices = { [] }
    }

    @Test(arguments: SettingsSection.allCases)
    func section(_ section: SettingsSection) {
        SettingsKeys.resetAll()
        Self.fixedVoiceHost()
        // Storage: the same list on every Mac (no Release container hiding the shared folders).
        var paths = DataPaths.current()
        paths.keepsReleaseShared = false
        StorageModel.shared.pathsOverride = paths
        // VQ (S-21 Storage): fixed sizes (the test runner never measures this Mac), so the page shows its measured look.
        StorageModel.shared.report = section == .privacy ? Self.storageFixture : nil
        // Capabilities' "Free on disk" footer: a fixed figure, never this Mac's live free space (78 vs 108 GB seen).
        PackManagementModel.shared.debugFreeBytes(78_000_000_000)
        defer { StorageModel.shared.pathsOverride = nil; StorageModel.shared.report = nil
                PackManagementModel.shared.debugFreeBytes(nil) }
        let model = SettingsModel()
        model.open(section)
        // M7.T12: the Skills page gets its own library (the five starters in a temp store), never the shared one
        let skills = section == .skills ? Self.pinnedSkills() : nil
        assertLooks("settings-\(section.rawValue)", size: Self.size, window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model).environment(\.skillsLibrary, skills)
                        .environment(\.settingsEvilModel, section == .capabilities ? Self.pinnedEvil() : nil)
                        .environment(\.settingsMemoryModel, section == .personalization ? Self.pinnedMemory() : nil))
    }

    /// The Capabilities list ends with the Evil row (off: nothing consented in a fresh in-memory store).
    static func pinnedEvil() -> EvilModeModel? { try? EvilSnapshotTests.panelModel { _ in } }

    /// Settings → Personalization with a few saved memories (fixed dates, an in-memory database).
    static func pinnedMemory(count: Int = 3) -> MemorySettingsViewModel? {
        guard let db = try? AppDatabase.inMemory() else { return nil }
        let store = MemoryStore(database: db, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let facts: [(String, String, MemoryOrigin)] = [
            ("Food", "Vegetarian, and allergic to peanuts", .tool), ("Work", "Works as a night nurse in Rotterdam", .user),
            ("Family", "Has two children, Mila and Daan", .import), ("Travel", "Prefers trains over flying", .tool),
            ("Home", "Lives in a flat with a small balcony", .tool), ("Hobbies", "Learning to play the cello", .user),
            ("Pets", "Has a cat called Pip", .tool), ("Sport", "Runs 5 km on Saturdays", .tool),
            ("Style", "Likes short answers with examples", .user), ("Work", "Free on Wednesdays", .import),
        ]
        for (i, f) in facts.prefix(count).enumerated() { _ = try? store.insert(topic: f.0, key: "k\(i)", text: f.1, origin: f.2) }
        return MemorySettingsViewModel(database: db)
    }

    /// The whole Personalization page: a long memory list (so its search field shows) and Advanced open.
    @Test func personalizationWithAdvancedOpen() {
        SettingsKeys.resetAll()
        Self.fixedVoiceHost()
        let model = SettingsModel()
        model.open(.personalization)
        model.setAdvanced(.personalization, true)
        assertLooks("settings-personalization-advanced", size: CGSize(width: 860, height: 1500), window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model)
                        .environment(\.settingsMemoryModel, Self.pinnedMemory(count: 10)))
    }

    static let storageFixture = StorageReport(
        bytes: [.chatModels: 5_400_000_000, .voice: 620_000_000, .photo: 3_100_000_000, .chats: 48_000_000, .media: 210_000_000,
                .caches: 95_000_000],
        total: 9_473_000_000, models: [], freeBytes: 182_000_000_000, measuredAt: Date(timeIntervalSince1970: 0),
        locations: [.library: 258_000_000, .models: 9_120_000_000, .caches: 88_000_000, .logs: 7_000_000, .preferences: 40_000])

    /// M7.T12: Settings → Skills shows a fixed store (the starter skills in a temp folder over an in-memory database).
    /// Per test, not observing other suites' change posts (an empty Skills page was seen once with the shared one).
    static func pinnedSkills() -> SkillsLibrary? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-skills-\(UUID().uuidString)", isDirectory: true)
        guard let db = try? AppDatabase.inMemory() else { return nil }
        let store = SkillStore(root: dir, database: db)
        _ = try? StarterSkills.installIfNeeded(into: store)
        return SkillsLibrary(observe: false, store: { store })
    }

    // MARK: The directory pages (Connections, Skills) at the width the window opens at

    /// The detail column of a 1100 pt Settings window.
    static let column = CGSize(width: 900, height: 720)

    /// A small catalogue with the real apps' slugs (their bundled logos) and one long line to cut.
    static let catalog: ComposioCatalog = {
        func app(_ slug: String, _ name: String, _ summary: String, _ categories: [String], _ popular: Int? = nil) -> ComposioCatalog.App {
            .init(slug: slug, name: name, summary: summary, categories: categories, popular: popular)
        }
        return ComposioCatalog(
            categories: [.init(id: "popular", title: "Popular"), .init(id: "productivity", title: "Productivity"),
                         .init(id: "communication", title: "Communication"), .init(id: "developer", title: "Developer tools")],
            apps: [
                app("gmail", "Gmail", "Read, search and send email", ["popular", "communication"], 1),
                app("googlecalendar", "Google Calendar", "See your schedule and plan events", ["popular", "productivity"], 2),
                app("googledrive", "Google Drive", "Find and read your files", ["popular", "productivity"], 3),
                app("slack", "Slack", "Read channels and send messages", ["popular", "communication"], 4),
                app("notion", "Notion", "Search, read and update pages and databases across every workspace you belong to", ["popular", "productivity"], 5),
                app("github", "GitHub", "Work with repositories, issues and pull requests", ["popular", "developer"], 6),
                app("linear", "Linear", "Track issues and projects", ["popular", "developer"], 7),
                app("outlook", "Outlook", "Mail and calendar from Microsoft", ["popular", "communication"], 8),
                app("airtable", "Airtable", "Bases and tables for a team", ["productivity"]),
                app("asana", "Asana", "Tasks and projects", ["productivity"]),
                app("dropbox", "Dropbox", "Files in the cloud", ["productivity"]),
                app("todoist", "Todoist", "A to-do list", ["productivity"]),
                app("trello", "Trello", "Boards, lists and cards", ["productivity"]),
                app("discord", "Discord", "Servers and messages", ["communication"]),
                app("zoom", "Zoom", "Video meetings", ["communication"]),
                app("sentry", "Sentry", "Errors in your apps", ["developer"]),
            ])
    }()

    private func page(_ flow: ConnectFlow = ConnectFlow(), query: String = "", category: String? = nil, browseAll: Bool = false,
                      servers: [ConnectionsModel.ServerView] = [], available: Bool = true,
                      size: CGSize = SettingsSnapshotTests.column) -> some View {
        ConnectionsPage(flow: flow, catalog: Self.catalog, query: query, category: category, browseAll: browseAll,
                        servers: servers, available: available)
            .frame(width: size.width, height: size.height)
            .background(Color.surfaceCanvas)
    }

    /// Two connections the user added by address: one connected (two tools), one whose sign-in ran out.
    static let customServers: [ConnectionsModel.ServerView] = {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func tool(_ server: String, _ name: String, _ description: String, readOnly: Bool) -> MCPToolRecord {
            MCPToolRecord(serverID: server, name: name, description: description, inputSchemaJSON: "{}",
                          annotationsJSON: readOnly ? #"{"readOnlyHint":true}"# : "{}", descHash: name, updatedAt: at)
        }
        return [
            .init(row: MCPServerRecord(id: "wiki", name: "Team wiki", urlOrCmd: "https://wiki.example.com/mcp", state: .connected,
                                       createdAt: at, updatedAt: at),
                  tools: [tool("wiki", "search_pages", "Finds pages by their text", readOnly: true),
                          tool("wiki", "read_page", "Reads one page", readOnly: true),
                          tool("wiki", "create_page", "Writes a new page in a space you choose, with a title and text", readOnly: false)]),
            .init(row: MCPServerRecord(id: "crm", name: "Orders", urlOrCmd: "https://orders.example.com/mcp", authKind: .oauth,
                                       state: .needsReauth, createdAt: at, updatedAt: at), tools: []),
        ]
    }()

    @Test func connectionsOverview() {
        assertLooks("connections-overview", size: Self.column, converge: true, page())
    }

    /// Two linked apps (a "Connected" section first, ⋯ wherever they show), one signing in, one refused by the relay.
    @Test func connectionsConnected() {
        let flow = ConnectFlow(linked: ["gmail": "c1", "notion": "c2"],
                               phases: ["slack": .waiting, "googledrive": .failed("conn.unavailable")])
        assertLooks("connections-connected", size: Self.column, converge: true, page(flow))
    }

    @Test func connectionsCategory() {
        assertLooks("connections-category", size: Self.column, converge: true, page(category: "productivity"))
    }

    /// The whole list, A to Z, with the category chips ("Browse all 16 apps").
    @Test func connectionsBrowseAll() {
        assertLooks("connections-all", size: Self.column, converge: true, page(browseAll: true))
    }

    /// The overview down to its last row, "Browse all 16 apps" (a tall column: nothing is cut).
    @Test func connectionsOverviewWhole() {
        let tall = CGSize(width: Self.column.width, height: 1500)
        assertLooks("connections-overview-whole", size: tall, converge: true, page(size: tall))
    }

    /// The user's own connections sit under "Connected" with the linked apps, as the same kind of row.
    @Test func connectionsCustom() {
        assertLooks("connections-custom", size: Self.column, converge: true,
                    page(ConnectFlow(linked: ["gmail": "c1"]), servers: Self.customServers))
    }

    /// No relay: the directory still shows, one line says apps cannot be connected, custom connections work.
    @Test func connectionsWithoutRelay() {
        assertLooks("connections-no-relay", size: Self.column, converge: true, page(servers: Self.customServers, available: false))
    }

    // MARK: Add a custom connection, and its details

    private func sheet<V: View>(_ name: String, _ view: V) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view.background(Color.surfaceCanvas), width: 480, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)", testName: "sheet")
        }
    }

    private func addSheet(_ form: AddConnectionSheet.Form = .init()) -> some View {
        AddConnectionSheet(model: ConnectionsModel(host: nil, flow: ConnectFlow(), servers: []), form: form, onAllow: { _ in }, onCancel: {})
    }

    @Test func addConnectionSheet() {
        sheet("add-connection-empty", addSheet())
        sheet("add-connection-filled", addSheet(.init(name: "Team wiki", url: "https://wiki.example.com/mcp")))
        sheet("add-connection-invalid", addSheet(.init(name: "Team wiki", url: "wiki example")))
        sheet("add-connection-key", addSheet(.init(name: "Team wiki", url: "wiki.example.com/mcp", signIn: true, mode: .key,
                                                   token: "sk-1234567890")))
    }

    @Test func connectionDetailSheet() {
        let model = ConnectionsModel(host: nil, flow: ConnectFlow(), servers: Self.customServers)
        for (name, id) in [("connection-detail", "wiki"), ("connection-detail-signin", "crm")] {
            for look in ResponseActionsSnapshotTests.Look.allCases {
                let view = ConnectionDetailSheet(model: model, id: id) {}.background(Color.surfaceCanvas)
                assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: 520, look: look),
                               as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)", testName: "sheet")
            }
        }
    }

    @Test func addressAsTyped() {
        #expect(ConnectionsModel.address(" wiki.example.com/mcp ")?.absoluteString == "https://wiki.example.com/mcp")
        #expect(ConnectionsModel.address("http://localhost:8080/mcp")?.host() == "localhost")
        #expect(ConnectionsModel.address("HTTPS://Wiki.example.com")?.scheme?.lowercased() == "https")
        for bad in ["", "   ", "wiki", "wiki example.com", "ftp://example.com/x", "https://", "example."] {
            #expect(ConnectionsModel.address(bad) == nil, "\(bad)")
        }
        var form = AddConnectionSheet.Form(url: "wiki")
        #expect(form.addressIsWrong && !form.isComplete && form.auth == .none)
        form.url = "wiki.example.com"
        #expect(!form.addressIsWrong && form.isComplete)
        form.signIn = true; form.mode = .key
        #expect(!form.isComplete, "a key is the way and none is pasted")
        form.token = " abc "
        #expect(form.isComplete && form.auth == .token("abc"))
        form.mode = .browser
        #expect(form.auth == .oauth)
    }

    @Test func connectionsSearch() {
        assertLooks("connections-search", size: Self.column, converge: true, page(query: "mail"))
        assertLooks("connections-search-none", size: Self.column, converge: true, page(query: "qwertz"))
    }

    @Test func directoryRowHover() {
        let rows = VStack(spacing: 2) {
            AppRow(app: Self.catalog.apps[4], phase: .idle, pinnedHover: true, onConnect: {}, onDisconnect: {})
            AppRow(app: Self.catalog.apps[0], phase: .connected, pinnedHover: false, onConnect: {}, onDisconnect: {})
        }
        .padding(Spacing.space4)
        .frame(width: 440)
        .background(Color.surfaceCanvas)
        assertLooks("directory-row-hover", converge: true, rows)
    }

    /// A small skills catalogue: one skill that is already installed (a check mark), one long line to cut.
    static let skillsCatalog: SkillsCatalog = {
        func skill(_ name: String, _ title: String, _ summary: String, _ category: String, _ featured: Int? = nil) -> SkillsCatalog.Skill {
            .init(id: "example/\(name)", name: name, title: title, summary: summary, category: category, author: "Example",
                  license: "Apache-2.0", featured: featured)
        }
        return SkillsCatalog(
            categories: [.init(id: "writing", title: "Writing"), .init(id: "documents", title: "Documents"),
                         .init(id: "design", title: "Design")],
            skills: [
                skill("brand-voice", "Brand voice", "Writes in your brand's voice", "writing", 1),
                skill("meeting-notes", "Meeting notes", "Minutes with decisions and action items", "writing", 2),
                skill("internal-comms", "Internal comms", "Status reports, updates and newsletters for the whole company and beyond", "writing"),
                skill("blog-post", "Blog post", "Drafts and edits a blog post", "writing"),
                skill("press-release", "Press release", "A press release in the usual form", "writing"),
                skill("cover-letter", "Cover letter", "A letter that fits the job", "writing"),
                skill("speech", "Speech", "A short speech for an occasion", "writing"),
                skill("pdf", "PDF", "Reads, fills in and makes PDF files", "documents", 3),
                skill("docx", "Word documents", "Makes and edits Word documents", "documents"),
                skill("xlsx", "Spreadsheets", "Makes and edits Excel sheets", "documents"),
                skill("canvas-design", "Canvas design", "Posters and visual pieces", "design"),
                skill("theme-factory", "Theme factory", "Colours and type for a document", "design"),
            ])
    }()

    private func skills(query: String = "", category: String? = nil, browseAll: Bool = false,
                        library: SkillsLibrary? = SettingsSnapshotTests.pinnedSkills(),
                        size: CGSize = SettingsSnapshotTests.column) -> some View {
        SkillsPage(catalog: Self.skillsCatalog, query: query, category: category, browseAll: browseAll)
            .environment(\.skillsLibrary, library)
            .frame(width: size.width, height: size.height).background(Color.surfaceCanvas)
    }

    /// The whole catalogue, A to Z, with the category chips ("Browse all 12 skills").
    @Test func skillsBrowseAll() {
        assertLooks("skills-all", size: Self.column, converge: true, skills(browseAll: true))
    }

    /// The page down to its last rows: "Browse all 12 skills" and the sources line.
    @Test func skillsPageWhole() {
        let tall = CGSize(width: Self.column.width, height: 1300)
        assertLooks("skills-page-whole", size: tall, converge: true, skills(size: tall))
    }

    @Test func skillsPage() {
        assertLooks("skills-page", size: Self.column, converge: true, skills())
    }

    @Test func skillsCategory() {
        assertLooks("skills-category", size: Self.column, converge: true, skills(category: "writing"))
    }

    @Test func skillsSearch() {
        assertLooks("skills-search", size: Self.column, converge: true, skills(query: "notes"))
        assertLooks("skills-search-none", size: Self.column, converge: true, skills(query: "qwertz"))
    }

    /// One catalogue skill downloading, one whose download failed.
    @Test func skillsInstalling() async {
        let library = Self.pinnedSkills()
        library?.download = { skill in
            if skill.name == "pdf" { throw SkillsCatalogInstaller.Failure.fetch(path: "SKILL.md", status: 0) }
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        await library?.installFromCatalog(Self.skillsCatalog.skills[2])  // PDF: fails
        let pending = Task { await library?.installFromCatalog(Self.skillsCatalog.skills[0]) }  // Brand voice: stays downloading
        await Task.yield()
        assertLooks("skills-installing", size: Self.column, converge: true, skills(library: library))
        pending.cancel()
    }

    /// Two installed catalogue skills the index has a newer version of: a quiet "Update" in each row, and the one
    /// line in the Installed title row ("2 updates available · Update all").
    @Test func skillsUpdateAvailable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-skills-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillStore(root: dir.appendingPathComponent("Skills", isDirectory: true), database: try AppDatabase.inMemory())
        try StarterSkills.installIfNeeded(into: store)
        for (name, about) in [("brand-voice", "Writes in your brand's voice"), ("cover-letter", "A letter that fits the job")] {
            let src = dir.appendingPathComponent("src/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \(about)\n---\nAn earlier version.\n"
                .write(to: src.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            // Installed from the catalogue's entry of that name; the index lists other files for it now.
            try store.install(from: src, name: name, trust: .user, source: #require(Self.skillsCatalog.skills.first { $0.name == name }))
        }
        let library = SkillsLibrary(observe: false, store: { store })
        library.catalog = { Self.skillsCatalog }
        library.offlineOnly = { false }
        library.reload()
        #expect(library.updates.keys.sorted() == ["brand-voice", "cover-letter"])
        assertLooks("skills-update", size: Self.column, converge: true, skills(library: library))
    }

    /// M3.T08 (R-053 AC1): no input devices → "No devices found", the meter and the picker disabled.
    @Test func voiceNoDevices() {
        SettingsKeys.resetAll()
        Self.fixedVoiceHost(devices: [])
        PackManagementModel.shared.debugFreeBytes(78_000_000_000)  // never this Mac's live free space
        defer { Self.fixedVoiceHost(); PackManagementModel.shared.debugFreeBytes(nil) }
        let model = SettingsModel()
        model.open(.capabilities)
        assertLooks("settings-capabilities-noDevices", size: Self.size, window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model))
    }

    /// Owner 2026-11-16: Settings is shown inside the main window, over the chat (never a window of its own): the
    /// whole window is Settings (sidebar + page), the chat's sidebar and toolbar are not drawn.
    @Test func insideTheMainWindow() throws {
        SettingsKeys.resetAll()
        Self.fixedVoiceHost()
        let service = try ChatListService.inMemory()
        _ = try service.create(title: "Plan a weekend in Lisbon")
        let state = WindowState(service: service, enabledPacks: [.chat], seed: 4)
        state.activate()
        SettingsModel.shared.open(.general)
        SettingsPresenter.shared.present(in: state)
        defer { SettingsPresenter.shared.dismiss() }
        assertLooks("settings-in-main-window", size: CGSize(width: 1180, height: 820), window: true, converge: true,
                    MainWindow(state: state))
    }

    /// Settings opens in one main window at a time, on the page that was asked for, and closing it leaves the window.
    @Test func presenterShowsSettingsInOneWindow() throws {
        let service = try ChatListService.inMemory()
        let a = WindowState(service: service, enabledPacks: [.chat], seed: 1)
        let b = WindowState(service: service, enabledPacks: [.chat], seed: 2)
        let presenter = SettingsPresenter()
        #expect(!presenter.isShown)
        _ = SettingsNavigator.shared.take()
        SettingsNavigator.shared.request(.connections)
        presenter.present(in: a)
        #expect(presenter.isShown(in: a) && !presenter.isShown(in: b))
        #expect(SettingsModel.shared.selection == .connections && SettingsNavigator.shared.pending == nil)
        presenter.present(in: b)
        #expect(presenter.isShown(in: b) && !presenter.isShown(in: a), "one Settings: it moves to the other window")
        presenter.windowDisappeared(a)
        #expect(presenter.isShown(in: b))
        presenter.dismiss()
        #expect(!presenter.isShown && !presenter.isShown(in: b))
        presenter.windowDisappeared(b)
        #expect(!presenter.isShown)
        SettingsModel.shared.open(.general)
    }

    /// ⌘, with no main window on screen: a window is asked for, and it shows Settings (on the asked page) when it appears.
    @Test func presenterWaitsForAWindow() throws {
        let service = try ChatListService.inMemory()
        let presenter = SettingsPresenter()
        var opened = 0
        presenter.openWindow = { opened += 1 }
        _ = SettingsNavigator.shared.take()
        presenter.show(.privacy, row: "exportAll")
        // Another suite's window may be on screen in this process: then Settings is shown there at once.
        guard !presenter.isShown else { presenter.dismiss(); SettingsModel.shared.open(.general); return }
        #expect(opened == 1)
        let state = WindowState(service: service, enabledPacks: [.chat], seed: 3)
        presenter.windowAppeared(state)
        #expect(presenter.isShown(in: state))
        #expect(SettingsModel.shared.selection == .privacy && SettingsModel.shared.highlightedRow == "exportAll")
        presenter.dismiss()
        presenter.windowAppeared(state)
        #expect(!presenter.isShown, "only the window ⌘, was waiting for")
        SettingsModel.shared.open(.general)
    }

    @Test func searchResults() {
        Self.fixedVoiceHost()
        let model = SettingsModel()
        model.query = "archive"
        assertLooks("settings-search-archive", size: Self.size, window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model))
    }

    @Test func archivedChatsPage() throws {
        let chats = try ChatListService.inMemory()
        for title in ["Trip to Lisbon", "Tax return 2025", "Sourdough starter"] { _ = try chats.create(title: title) }
        try chats.archiveAll(now: Date(timeIntervalSince1970: 1_790_000_000))  // fixed date in the rows
        assertLooks("settings-archived-page", size: CGSize(width: 560, height: 460), converge: true,
                    ArchivedChatsPage(chats: chats, onDone: {}))
    }

    @Test func deleteAllSheet() {
        // Fixed at the reference size: the fitted height came out 186 or 187 pt under parallel load (flake, twice).
        assertLooks("settings-delete-all", size: CGSize(width: 420, height: 186), converge: true, DeleteAllSheet(onDelete: {}, onCancel: {}))
    }
}
}  // extension WindowSuites
