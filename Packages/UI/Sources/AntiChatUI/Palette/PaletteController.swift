// ⌘K palette state (M1.T11, R-012, S-18; components.md §5 CommandPalette). One per window. The vendored
// CommandPaletteKit view owns the field, keyboard selection and rows; this controller owns the tabs (All | Actions |
// Chats | Settings), the Liked filter, the providers and what activating a row does. It learns the query through
// the UP-CP-001 host hook and feeds the view a candidate binding already filtered and ranked (the view's scorer is
// a pass-through, so bm25 order survives). Chats reload 30 ms after the last keystroke (step 3 debounce).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import CommandPaletteKit
import Foundation
import Observation
import os
import QuartzCore
import SwiftUI

/// The palette's filter tabs (S-18; copy `palette.tab.*`).
public enum PaletteTab: String, CaseIterable, Hashable, Sendable {
    case all, actions, chats, settings

    public var title: CopyKey {
        switch self {
        case .all: CopyKey("palette.tab.all")
        case .actions: CopyKey("palette.tab.actions")
        case .chats: CopyKey("palette.tab.chats")
        case .settings: CopyKey("palette.tab.settings")
        }
    }
}

/// One palette row.
public struct PaletteItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case action(PaletteAction)
        case chat(String, messageID: String?)
        case setting(SettingsSection, rowID: String)
    }

    public var id: String
    public var kind: Kind
    /// The section header it sits under on the All tab (`.actions`, `.chats` or `.settings`).
    public var group: PaletteTab
    public var title: String
    public var subtitle: String?
    /// Chat rows: the snippet runs (`isMatch` = highlighted).
    public var excerpt: [ChatSearchHit.Run] = []
    public var symbol: String
    public var shortcut: String?
    public var keywords: [String] = []
    public var titleMatched = false

    /// VQ-M10 S-18: the header the row sits under on the All tab. An "open a Settings page" action is listed on the
    /// Actions tab but reads under its own "Settings" header on All (it sat under "Actions", looking misfiled).
    public var header: PaletteTab {
        if case .action(.openSettings) = kind { return .settings }
        return group
    }

    public init(id: String, kind: Kind, group: PaletteTab, title: String, subtitle: String? = nil,
                excerpt: [ChatSearchHit.Run] = [], symbol: String, shortcut: String? = nil, keywords: [String] = [],
                titleMatched: Bool = false) {
        self.id = id
        self.kind = kind
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.excerpt = excerpt
        self.symbol = symbol
        self.shortcut = shortcut
        self.keywords = keywords
        self.titleMatched = titleMatched
    }
}

/// What the palette does in its window.
@MainActor
public struct PaletteHandlers {
    public var openChat: (String, String?) -> Void
    public var newChat: () -> Void
    /// Opens a new incognito chat in the window (M1.T20).
    public var newIncognitoChat: () -> Void
    /// Tab: a new chat with `text` in the composer, not sent (R-012 AC3).
    public var askInNewChat: (String) -> Void
    public var toggleSidebar: () -> Void
    public var openSettings: (SettingsSection, String?) -> Void

    public init(openChat: @escaping (String, String?) -> Void = { _, _ in }, newChat: @escaping () -> Void = {},
                newIncognitoChat: @escaping () -> Void = {}, askInNewChat: @escaping (String) -> Void = { _ in },
                toggleSidebar: @escaping () -> Void = {},
                openSettings: @escaping (SettingsSection, String?) -> Void = { _, _ in }) {
        self.openChat = openChat
        self.newChat = newChat
        self.newIncognitoChat = newIncognitoChat
        self.askInNewChat = askInNewChat
        self.toggleSidebar = toggleSidebar
        self.openSettings = openSettings
    }

    /// The handlers for a main window: chats open in it, Tab fills its composer, settings go through
    /// `SettingsNavigator` and `openSettings` (the SwiftUI action, set by the panel).
    public static func window(_ state: WindowState, openSettings: @escaping () -> Void = {}) -> PaletteHandlers {
        PaletteHandlers(
            openChat: { id, _ in state.open(.chat(id)) },
            newChat: { state.newChat() },
            newIncognitoChat: { state.newIncognitoChat() },  // M1.T20
            askInNewChat: { text in
                state.newChat()
                state.composerText = text
            },
            toggleSidebar: { state.toggleSidebar() },
            openSettings: { section, row in
                SettingsNavigator.shared.request(section, row: row)
                openSettings()
            })
    }
}

@MainActor
@Observable
public final class PaletteController {
    /// Rows of each group shown on the All tab for a query (the group's own tab shows them all).
    static let allTabGroupLimit = 5
    /// Quiet time after the last keystroke before chats are searched (M1.T11 step 3).
    public static let debounce: Duration = .milliseconds(30)

    public private(set) var isPresented = false
    public private(set) var tab: PaletteTab = .all
    public private(set) var likedOnly = false
    public private(set) var query = ""
    /// The rows on screen, in order.
    public private(set) var items: [PaletteItem] = []
    /// What the vendored view lists (ids match `items`).
    public var candidates: [PaletteResult] = []
    /// Seconds from the last query change to its chat results being applied (probe; NFR-U10 at the UI level).
    public private(set) var lastResultLatency: Double?
    /// True while a chat search for the current query is pending (the panel holds back `search.empty`).
    public private(set) var isSearching = false
    /// Increments every time a query's results are applied (probe / tests wait on it).
    public private(set) var resultGeneration = 0
    /// The SwiftUI `openSettings` action of the window (set by `PalettePanel`).
    public var openSettingsAction: () -> Void = {}

    private var service: ChatListService?
    private var handlers = PaletteHandlers()
    private var chatHits: [PaletteItem] = []
    /// True while `chatHits` are the empty query's recents (or liked list), not a search's matches.
    private var chatHitsAreRecents = false
    private var reloadTask: Task<Void, Never>?
    private var queryChangedAt: ContinuousClock.Instant?
    /// M9.T05 (NFR-U10): the query change whose results the next `paletteQuery` interval ends on (once per change).
    private var pendingQueryMark: ContinuousClock.Instant?
    /// Set by an action that keeps the palette open (Switch chat); read by the dismiss hook.
    private var keepOpen = false

    public init() {}

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// The palette most recently bound to a window (the in-process AT-012 probe, `-PaletteProbe`).
    public private(set) static weak var lastAttached: PaletteController?
    #endif

    /// Binds the palette to a window (MainWindow's `onAppear`; idempotent).
    public func attach(_ state: WindowState) {
        service = state.service
        handlers = .window(state, openSettings: { [weak self] in self?.openSettingsAction() })
        state.palette = self  // M1.T24
        #if DEBUG || ANTICHAT_PERF_HARNESS
        Self.lastAttached = self
        #endif
    }

    /// Binds custom handlers (tests).
    public func attach(service: ChatListService, handlers: PaletteHandlers) {
        self.service = service
        self.handlers = handlers
    }

    // MARK: Presentation

    public func present(tab: PaletteTab = .all) {
        self.tab = tab
        likedOnly = false
        query = ""
        isPresented = true
        reload()
    }

    public func toggle() { isPresented ? dismiss() : present() }

    public func dismiss() {
        reloadTask?.cancel()
        isPresented = false
    }

    /// The view's dismiss hook (UP-CP-003): after activation and on Escape.
    func hostDismiss() {
        if keepOpen {
            keepOpen = false
            return
        }
        dismiss()
    }

    // MARK: Inputs

    public func select(_ tab: PaletteTab) {
        guard tab != self.tab else { return }
        self.tab = tab
        reload()
    }

    public func setLikedOnly(_ on: Bool) {
        guard on != likedOnly else { return }
        likedOnly = on
        reload()
    }

    /// The view reports every query change (UP-CP-001).
    public func queryDidChange(_ newQuery: String) {
        guard newQuery != query || items.isEmpty else { return }
        query = newQuery
        queryChangedAt = .now
        pendingQueryMark = queryChangedAt
        reload()
    }

    /// Tab (UP-CP-002): ask the query in a new chat. Consumes the key even for an empty query.
    @discardableResult
    public func askInNewChat(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            handlers.askInNewChat(t)
            dismiss()
        }
        return true
    }

    /// A row was activated (Return or click).
    public func activate(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        perform(item)
    }

    func perform(_ item: PaletteItem) {
        switch item.kind {
        case let .chat(id, messageID): handlers.openChat(id, messageID)
        case let .setting(section, rowID): handlers.openSettings(section, rowID)
        case let .action(action):
            switch action {
            case .newChat: handlers.newChat()
            case .newIncognitoChat: handlers.newIncognitoChat()
            case let .openSettings(section): handlers.openSettings(section, nil)
            case .toggleSidebar: handlers.toggleSidebar()
            case .switchChat:
                keepOpen = true
                select(.chats)
            }
        }
    }

    // MARK: Results

    /// The tab's non-chat rows now; chats after the debounce (immediately for an empty query or a tab change).
    func reload() {
        reloadTask?.cancel()
        let q = query
        let wantsChats = (tab == .all || tab == .chats)
        let immediate = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !wantsChats { chatHits = [] }
        // Q-015 r7 (AT-012 leg 1): typing into the recents list kept the 8 recents on screen until the debounced search
        // returned — rows that do not match the query, and Return in that window opened a recent chat. A query's rows
        // start from its own matches; a refined query keeps the previous query's matches until its own arrive.
        if !immediate, chatHitsAreRecents { chatHits = [] }
        apply()
        guard wantsChats, let service else {
            isSearching = false
            finishGeneration()
            return
        }
        isSearching = true
        let liked = likedOnly
        reloadTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            guard let hits = await ChatsProvider.chats(q, likedOnly: liked, service: service) else { return }
            guard let self, !Task.isCancelled, self.query == q, self.likedOnly == liked else { return }
            self.chatHits = ChatsProvider.items(hits)
            self.chatHitsAreRecents = immediate
            self.isSearching = false
            self.apply()
            self.finishGeneration()
            // M2.T16 step 6: semantic rows merge in under the FTS rows when they arrive (never before them).
            guard !immediate, !liked, let semantic = SemanticSearch.shared else { return }
            let shown = Set(hits.map(\.chatID))
            guard let extra = await SemanticResults.items(q, excluding: shown, search: semantic), !extra.isEmpty,
                  !Task.isCancelled, self.query == q else { return }
            self.chatHits += extra
            self.apply()
        }
    }

    private func finishGeneration() {
        if let start = queryChangedAt {
            let d = ContinuousClock.now - start
            lastResultLatency = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        // M9.T05 (NFR-U10, `paletteQuery`): query change → its chat results on screen (the CATransaction commit that
        // draws them), once per non-empty query; perf log + signpost (App/UITests/Perf/PalettePerfTests).
        if let start = pendingQueryMark, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingQueryMark = nil
            let meta = ["chars": "\(query.count)", "rows": "\(items.count)", "chats": "\(chatHits.count)"]
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                let c = (ContinuousClock.now - start).components
                Signposts.mark(.paletteQuery, durationNs: UInt64(max(0, c.seconds)) * 1_000_000_000 + UInt64(max(0, c.attoseconds) / 1_000_000_000),
                               on: Signposts.ui, meta: meta)
            }
            CATransaction.commit()
        }
        resultGeneration += 1
    }

    /// Builds `items` for the tab: empty query → recents (Chats) then actions; a query → actions, chats, settings.
    private func apply() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [PaletteItem] = []
        switch tab {
        case .all:
            if likedOnly {
                rows = chatHits
            } else if q.isEmpty {
                // VQ-M10 S-18: actions, then the Settings pages under their own header.
                let actions = ActionsProvider.actions(matching: "")
                rows = chatHits + actions.filter { $0.header == .actions } + actions.filter { $0.header == .settings }
            } else {
                let actions = Array(ActionsProvider.actions(matching: q).prefix(Self.allTabGroupLimit))
                rows = actions.filter { $0.header == .actions } + chatHits + actions.filter { $0.header == .settings }
                    + Array(SettingsRowsProvider.rows(matching: q).prefix(Self.allTabGroupLimit))
            }
        case .actions:
            rows = ActionsProvider.actions(matching: q)
        case .chats:
            rows = chatHits
        case .settings:
            rows = SettingsRowsProvider.rows(matching: q)
        }
        items = rows
        let groups = Dictionary(uniqueKeysWithValues: PaletteTab.allCases.map { ($0, $0.title.string()) })
        candidates = rows.map { item in
            PaletteResult(id: item.id, title: item.title, subtitle: item.subtitle,
                          category: tab == .all ? groups[item.header] : nil, systemImage: item.symbol,
                          keyboardShortcut: item.shortcut, searchText: item.title, action: {})
        }
    }

    /// The row for a result id (the row builder).
    public func item(_ id: String) -> PaletteItem? { items.first { $0.id == id } }

    /// The vendored view's scorer: the controller already filtered and ranked, so every row passes with one score
    /// and the view keeps the controller's order (CommandPaletteKit breaks ties by source index).
    static let passThroughScorer: PaletteScorer = { _, _ in 0 }
}
