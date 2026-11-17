// Chat search (sidebar Search, ⌘K; R-012, S-18; components.md §5 CommandPalette). One per window. The vendored
// CommandPaletteKit view owns the field, keyboard selection and rows; this controller owns the rows and what
// activating one does: "New chat" and the recent chats for an empty field, the matching chats for a query. It learns
// the query through the UP-CP-001 host hook and feeds the view a candidate binding already ranked (the view's scorer is
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

/// One row: New chat, or a chat.
public struct PaletteItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case newChat
        case chat(String, messageID: String?)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// Chat rows: the snippet runs (`isMatch` = highlighted).
    public var excerpt: [ChatSearchHit.Run] = []
    public var symbol: String
    public var shortcut: String?
    public var titleMatched = false

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, excerpt: [ChatSearchHit.Run] = [],
                symbol: String, shortcut: String? = nil, titleMatched: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.excerpt = excerpt
        self.symbol = symbol
        self.shortcut = shortcut
        self.titleMatched = titleMatched
    }

    /// The row above the recent chats while the field is empty.
    @MainActor static var newChat: PaletteItem {
        PaletteItem(id: "action.newChat", kind: .newChat, title: CopyKey("side.newChat").string(),
                    symbol: "square.and.pencil", shortcut: "⌘N")
    }
}

/// What the search does in its window.
@MainActor
public struct PaletteHandlers {
    public var openChat: (String, String?) -> Void
    public var newChat: () -> Void
    /// Tab: a new chat with `text` in the composer, not sent (R-012 AC3).
    public var askInNewChat: (String) -> Void

    public init(openChat: @escaping (String, String?) -> Void = { _, _ in }, newChat: @escaping () -> Void = {},
                askInNewChat: @escaping (String) -> Void = { _ in }) {
        self.openChat = openChat
        self.newChat = newChat
        self.askInNewChat = askInNewChat
    }

    /// The handlers for a main window: chats open in it, Tab fills its composer.
    public static func window(_ state: WindowState) -> PaletteHandlers {
        PaletteHandlers(
            openChat: { id, _ in state.open(.chat(id)) },
            newChat: { state.newChat() },
            askInNewChat: { text in
                state.newChat()
                state.composerText = text
            })
    }
}

@MainActor
@Observable
public final class PaletteController {
    /// Quiet time after the last keystroke before chats are searched (M1.T11 step 3).
    public static let debounce: Duration = .milliseconds(30)

    public private(set) var isPresented = false
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

    private var service: ChatListService?
    private var handlers = PaletteHandlers()
    private var chatHits: [PaletteItem] = []
    /// True while `chatHits` are the empty query's recents, not a search's matches.
    private var chatHitsAreRecents = false
    private var reloadTask: Task<Void, Never>?
    private var queryChangedAt: ContinuousClock.Instant?
    /// M9.T05 (NFR-U10): the query change whose results the next `paletteQuery` interval ends on (once per change).
    private var pendingQueryMark: ContinuousClock.Instant?

    public init() {}

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// The palette most recently bound to a window (the in-process AT-012 probe, `-PaletteProbe`).
    public private(set) static weak var lastAttached: PaletteController?
    #endif

    /// Binds the palette to a window (MainWindow's `onAppear`; idempotent).
    public func attach(_ state: WindowState) {
        service = state.service
        handlers = .window(state)
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

    public func present() {
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
    func hostDismiss() { dismiss() }

    // MARK: Inputs

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
        case .newChat: handlers.newChat()
        }
    }

    // MARK: Results

    /// The rows for the query: the recent chats at once for an empty field, the matches after the debounce.
    func reload() {
        reloadTask?.cancel()
        let q = query
        let immediate = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Q-015 r7 (AT-012 leg 1): typing into the recents list kept the recents on screen until the debounced search
        // returned — rows that do not match the query, and Return in that window opened a recent chat. A query's rows
        // start from its own matches; a refined query keeps the previous query's matches until its own arrive.
        if !immediate, chatHitsAreRecents { chatHits = [] }
        apply()
        guard let service else {
            isSearching = false
            finishGeneration()
            return
        }
        isSearching = true
        reloadTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            guard let hits = await ChatsProvider.chats(q, service: service) else { return }
            guard let self, !Task.isCancelled, self.query == q else { return }
            self.chatHits = ChatsProvider.items(hits)
            self.chatHitsAreRecents = immediate
            self.isSearching = false
            self.apply()
            self.finishGeneration()
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

    /// Builds `items`: New chat above the recents for an empty field; a query's matching chats otherwise.
    private func apply() {
        let empty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rows = (empty ? [PaletteItem.newChat] : []) + chatHits
        items = rows
        candidates = rows.map { item in
            PaletteResult(id: item.id, title: item.title, subtitle: item.subtitle, category: nil, systemImage: item.symbol,
                          keyboardShortcut: item.shortcut, searchText: item.title, action: {})
        }
    }

    /// The row for a result id (the row builder).
    public func item(_ id: String) -> PaletteItem? { items.first { $0.id == id } }

    /// The vendored view's scorer: the controller already filtered and ranked, so every row passes with one score
    /// and the view keeps the controller's order (CommandPaletteKit breaks ties by source index).
    static let passThroughScorer: PaletteScorer = { _, _ in 0 }
}
