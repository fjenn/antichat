// Per-window state (M1.T07 steps 1–2, 5–6): what the chat column shows, visited-chat history (⌘[ / ⌘]), the
// sidebar list (observed from the database), the new-chat headline/suggestions, and the composer docking.
// One instance per window; every chat mutation goes through `ChatListService` → `ChatRepository`, and the
// sidebar updates from the ValueObservation (signpost `sidebarUpdate`, ≤ 100 ms).
// M1.T20: route `.incognito` shows the window's IncognitoSession (in-memory store, no sidebar row, no history entry);
// leaving it with messages asks `incognito.close.confirm` first (`pendingIncognitoLeave`), then discards the session.
import AntiChatDesign
import AppKit
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import Foundation
import Defaults
import Observation
import os
import QuartzCore
import SwiftUI

public enum WindowRoute: Hashable, Sendable {
    case newChat
    case chat(String)
    case library
    case projects
    /// M8.T04: one project's page.
    case project(String)
    case chats
    /// M1.T20: the window's incognito chat (`WindowState.incognito`); never in the sidebar or the history stacks.
    case incognito
}

/// M1.T20 step 5: what the window does once the user confirms closing an incognito chat that has messages.
public enum IncognitoLeaveIntent: Equatable, Sendable {
    case navigate(WindowRoute)
    case newChat
    case newIncognito
    case back
    case forward
    case closeWindow
    case quit
}

@MainActor
@Observable
public final class WindowState {
    // MARK: Inputs

    public let service: ChatListService
    public let enabledPacks: Set<SuggestionPack>

    // MARK: Navigation

    public private(set) var route: WindowRoute = .newChat {
        didSet { if case .chat = route { Self.lastChatRoute = route } }
    }
    /// R-042 AC3 (Q-015 r5): the last chat any window showed (never an incognito one). The menu bar's Open AntiChat
    /// brings a closed window back on it, so a picture or video still being made is on screen again.
    public static var lastChatRoute: WindowRoute?
    public private(set) var backStack: [WindowRoute] = []
    public private(set) var forwardStack: [WindowRoute] = []
    public var columnVisibility: NavigationSplitViewVisibility = .all
    /// True when the window collapsed the sidebar because it got narrower than 900 pt (restored when wider).
    private var autoCollapsed = false
    /// VQ-M10 round 65 (S-15): true when opening the side panel collapsed the sidebar (restored when it closes).
    private var panelCollapsed = false
    /// The window's last width (the side panel's room check).
    private var windowWidth: CGFloat = 0

    // MARK: Sidebar

    public private(set) var sidebar: [ChatSummary] = []
    public private(set) var sidebarLimit = ChatListService.sidebarPageSize
    public private(set) var sidebarTotal = 0
    public var renamingChatID: String?
    /// M1.T24: the Help menu's sheets (⌘/ shortcut list, Legal, Report a Problem).
    public var presentedSheet: PresentedSheet?
    public enum PresentedSheet: String, Identifiable, Sendable {
        case shortcuts, legal, report
        /// M8.T09: Help › Export Logs…; the next-launch crash prompt.
        case exportLogs, crashPrompt
        /// M6.T13 (R-017 AC2): chat ⋯ → Files in this chat.
        case filesInChat
        /// M8.T11 (R-226): AntiChat › Uninstall AntiChat…; Help › How to Uninstall.
        case uninstall, uninstallHelp
        /// M10.T07 (R-303): Help › AntiChat Help offline (bundled guide); What's New.
        case help, whatsNew
        public var id: String { rawValue }
    }
    /// M1.T24: the NSWindow showing this state (set by the window guards; restoration and probes read it).
    @ObservationIgnored public internal(set) weak var window: NSWindow?
    /// M1.T24: this window's ⌘K palette (the menus' fallback target).
    @ObservationIgnored public internal(set) weak var palette: PaletteController?
    /// The chat whose delete confirmation is showing, and where it is anchored.
    public var pendingDelete: PendingDelete?
    /// Last measured mutation → sidebar-applied latency (signpost `sidebarUpdate`), seconds.
    public private(set) var lastSidebarUpdateLatency: Double?
    private var sidebarToken: ObservationToken?
    private var pendingMutation: (start: ContinuousClock.Instant, state: OSSignpostIntervalState)?
    /// M1.T19 step 4: the row's live status (spinner while the chat's turn runs), from the window's ChatSessions.
    /// Read in the sidebar's body, so the observable state behind it is tracked.
    @ObservationIgnored public var rowActivity: (@MainActor (String) -> ChatRowActivity)?

    // MARK: Chat column

    public private(set) var headlineSeed: UInt64
    public private(set) var headline: CopyKey
    public private(set) var suggestions: [Suggestion]
    /// Composer text (the T08 composer binds to it; a suggestion click fills it, never sends).
    public var composerText = ""
    /// False on an empty new chat (composer centred); true once the chat has a message (composer docked).
    public private(set) var isDocked = false
    /// The open chat's messages for the plain transcript (MainWindow's fallback when no conversation slot is wired).
    public private(set) var transcript: [TranscriptItem] = []
    /// M9.T05 (NFR-U11): false when the window draws its chats through the conversation slot (ConversationModel loads
    /// and follows the chat itself), so a chat open neither fetches the whole visible path on the main thread nor
    /// keeps an observation that re-reads it after every commit, for a list nothing shows.
    @ObservationIgnored public var mirrorsTranscript = true {
        didSet {
            guard !mirrorsTranscript, oldValue else { return }
            transcriptToken?.cancel()
            transcriptToken = nil
            transcript = []
        }
    }
    /// Last composer docking duration (signpost `composerDock`), seconds.
    public private(set) var lastDockDuration: Double?
    private var transcriptToken: ObservationToken?

    public struct PendingDelete: Equatable {
        public enum Anchor: Equatable { case row, toolbar, chatsPage }
        public var ids: [String]
        public var title: String
        public var anchor: Anchor
    }

    public init(service: ChatListService, enabledPacks: Set<SuggestionPack> = SuggestionProvider.enabledPacks(),
                seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.service = service
        self.enabledPacks = enabledPacks
        headlineSeed = seed
        headline = EmptyHeadline.pick(seed: seed)
        suggestions = SuggestionProvider.suggestions(enabled: enabledPacks, seed: seed)
        // M2.T20 step 6: the first chat after onboarding (this window existed, hidden, while onboarding ran).
        firstChatObserver = NotificationCenter.default.addObserver(forName: StarterSuggestions.didFinish, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.applyFirstChat() }
        }
    }

    @ObservationIgnored private var firstChatObserver: NSObjectProtocol?

    isolated deinit {  // fix/selection-hang: a discarded instance no longer leaves its registration behind
        if let firstChatObserver { NotificationCenter.default.removeObserver(firstChatObserver) }
    }

    /// R-201 AC7: `empty.headline` + the three StarterSuggestions chips on the shown new chat.
    func applyFirstChat() {
        guard route == .newChat, StarterSuggestions.consumeFirstChat() else { return }
        headline = CopyKey("empty.headline")
        suggestions = StarterSuggestions.chips(packs: StarterSuggestions.chosenPacks() ?? enabledPacks)
    }

    /// Starts the sidebar observation (MainWindow's `onAppear`; idempotent). Kept out of `init` because SwiftUI may
    /// build a `WindowState` more than once for one window.
    public func activate() {
        if sidebarToken == nil { startSidebar() }
    }

    // MARK: Derived

    public var currentChatID: String? {
        if case let .chat(id) = route { return id }
        if route == .incognito { return incognito?.chatID }
        return nil
    }

    // MARK: Incognito (M1.T20)

    /// The window's incognito session while `route == .incognito` (one per window).
    public private(set) var incognito: IncognitoSession?
    /// The Personalized / Unpersonalized choice shown before the first message (step 2).
    public var incognitoPersonalization: IncognitoPersonalization = .personalized {
        didSet { incognito?.setPersonalization(incognitoPersonalization) }
    }
    /// The close confirmation is showing (`incognito.close.confirm`) and what follows a confirm.
    public var pendingIncognitoLeave: IncognitoLeaveIntent?
    /// M8.T08 (R-091 AC4): Settings › Privacy & Data › "New chats are incognito" (read at each ⌘N / new chat).
    @ObservationIgnored public var newChatsIncognito: @MainActor () -> Bool = { Defaults[.newChatsIncognito] }
    /// M8.T08 (R-090): the Personalized / Unpersonalized choice a new incognito chat starts with.
    @ObservationIgnored public var incognitoPersonalizationDefault: @MainActor () -> IncognitoPersonalization = {
        IncognitoPersonalization(rawValue: Defaults[.incognitoPersonalizationDefault]) ?? .personalized
    }
    /// Creates a session (the host: `IncognitoSession(app: environment)`); nil = incognito unavailable.
    @ObservationIgnored public var makeIncognito: (@MainActor () throws -> IncognitoSession)?
    /// A session ended (the host drops its conversation model; the session is discarded right after).
    @ObservationIgnored public var onIncognitoClosed: (@MainActor (IncognitoSession) -> Void)?
    /// Closes the window after a confirmed ⌘W (the host's window guard).
    @ObservationIgnored public var closeWindow: (@MainActor () -> Void)?
    /// M1.T24: the conversation of the chat this window shows (⌘F find bar, transcript-only ⌘A); set by the host.
    @ObservationIgnored public var conversation: (@MainActor () -> ConversationModel?)?
    /// M8.T13: takes over a conversation started in the quick panel (set by the host: ChatSessions.adopt).
    @ObservationIgnored public var adoptConversation: (@MainActor (ConversationModel) -> Void)?
    /// M8.T13: the menu bar's Start Voice clicks this window's VoiceButton (the just-in-time microphone flow).
    @ObservationIgnored public var startVoice: (@MainActor () -> Void)?
    /// Answers a held quit (`NSApp.reply(toApplicationShouldTerminate:)`).
    @ObservationIgnored public var answerQuit: (@MainActor (Bool) -> Void)?

    public var isIncognito: Bool { route == .incognito }
    /// M2.T17: the mode of what the window shows (the shown chat's, or the new chat's switch): frame + badge.
    public var shownMode: ComposerChatMode = .normal
    /// M2.T17: ⇧⌘E — the next new chat starts in this mode (consumed by the composer).
    public var newChatMode: ComposerChatMode?
    /// M8.T04: the window's projects (nil when the host has none, e.g. tests and harnesses).
    @ObservationIgnored public var projects: ProjectsModel?
    /// M8.T04: "New chat in project" — the next new chat is created in this project (cleared by a plain new chat).
    public var newChatProjectID: String?
    /// M8.T04: chat ⋯ → Move to project › New project… (the sheet creates the project and moves this chat).
    public var pendingNewProjectForChat: String?

    /// The incognito chat has messages (closing it asks first).
    /// Docked = a message is on screen (also a held send that is not written yet).
    public var hasIncognitoContent: Bool {
        guard isIncognito, let incognito else { return false }
        return isDocked || incognito.hasContent
    }

    /// The toolbar IncognitoButton is enabled: on an empty chat only (components.md: disabled inside a non-empty chat).
    public var canToggleIncognito: Bool { !isDocked || (isIncognito && !hasIncognitoContent) }

    /// ⇧⌘N, ⌘K "New incognito chat", the toolbar button: opens a fresh incognito chat (an empty one stays).
    public func newIncognitoChat() {
        if isIncognito, !hasIncognitoContent { return }
        guard mayLeaveIncognito(.newIncognito) else { return }
        openIncognitoNow()
    }

    /// The toolbar IncognitoButton: on → a new incognito chat; off (an empty incognito chat) → back to a new chat.
    public func toggleIncognito() {
        if isIncognito { newRegularChat() } else { newIncognitoChat() }
    }

    /// Closing the window (⌘W, close button): true = close now; false = the confirmation is showing.
    public func requestCloseWindow() -> Bool {
        guard hasIncognitoContent else {
            discardIncognito()
            return true
        }
        pendingIncognitoLeave = .closeWindow
        return false
    }

    /// Quitting: true = quit now; false = the confirmation is showing (the host holds the quit).
    public func requestQuit() -> Bool {
        guard hasIncognitoContent else {
            discardIncognito()
            return true
        }
        pendingIncognitoLeave = .quit
        return false
    }

    public func confirmIncognitoLeave() {
        guard let intent = pendingIncognitoLeave else { return }
        pendingIncognitoLeave = nil
        switch intent {
        case .navigate(let r): leaveIncognito { navigate(to: r) }
        case .newChat: leaveIncognito { startNewChat(seed: UInt64.random(in: 0...UInt64.max)) }
        case .newIncognito: openIncognitoNow()
        case .back: leaveIncognito { popBack() }
        case .forward: leaveIncognito { popForward() }
        case .closeWindow:
            discardIncognito()
            closeWindow?()
        case .quit:
            discardIncognito()
            answerQuit?(true)
        }
    }

    public func cancelIncognitoLeave() {
        let intent = pendingIncognitoLeave
        pendingIncognitoLeave = nil
        if intent == .quit { answerQuit?(false) }
    }

    /// True when the window may leave the incognito chat now (none shown, or it has no message: it is discarded
    /// when the route changes); false = the confirmation is showing with `intent`.
    private func mayLeaveIncognito(_ intent: IncognitoLeaveIntent) -> Bool {
        guard hasIncognitoContent else { return true }
        pendingIncognitoLeave = intent
        return false
    }

    /// Runs the navigation away from the incognito chat, then discards the session.
    private func leaveIncognito(_ go: () -> Void) {
        go()
        if route != .incognito { discardIncognito() }
    }

    private func openIncognitoNow() {
        discardIncognito()
        guard let makeIncognito else { return }
        do {
            incognito = try makeIncognito()
        } catch {
            AppLog.logger(.ui).error("incognito open failed: \(String(describing: error), privacy: .public)")
            return
        }
        incognitoPersonalization = incognitoPersonalizationDefault()
        composerText = ""
        navigate(to: .incognito)
    }

    /// Ends the session (no confirmation): the conversation model goes, the store and the temp directory too.
    public func discardIncognito() {
        guard let s = incognito else { return }
        incognito = nil
        backStack.removeAll { $0 == .incognito }
        forwardStack.removeAll { $0 == .incognito }
        onIncognitoClosed?(s)
        s.discard()
        if route == .incognito { startNewChat(seed: UInt64.random(in: 0...UInt64.max)) }
    }

    public var currentChat: ChatSummary? {
        guard let id = currentChatID else { return nil }
        return sidebar.first { $0.id == id } ?? (try? service.chat(id)) ?? nil
    }

    /// NFR-U2: the chat the toolbar shows (title, Outputs, Share, the ⋯ menu). It follows `currentChatID`
    /// (`syncToolbarChat`, from MainWindow), one frame late after a new chat's first send: that send's ack frame adds
    /// the bubble, the pending reply, Stop and the sidebar row, and the toolbar's new items and title were a quarter of
    /// it (NSToolbarView relayout). Actions read `currentChatID` itself, never this.
    public private(set) var toolbarChatID: String?
    /// The send that created the shown chat asked for the toolbar to follow after its ack frame.
    @ObservationIgnored private var toolbarAfterCommit = false

    /// The toolbar's chat (see `toolbarChatID`).
    public var toolbarChat: ChatSummary? {
        guard let id = toolbarChatID else { return nil }
        return sidebar.first { $0.id == id } ?? (try? service.chat(id)) ?? nil
    }

    /// Brings `toolbarChatID` to `currentChatID`: at once, or after the current frame commits when a new chat's
    /// first send just docked (that frame is the send's acknowledgement).
    public func syncToolbarChat() {
        guard toolbarAfterCommit else {
            if toolbarChatID != currentChatID { toolbarChatID = currentChatID }
            return
        }
        toolbarAfterCommit = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.toolbarChatID != self.currentChatID else { return }
                self.toolbarChatID = self.currentChatID
            }
        }
        CATransaction.commit()
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Sidebar sections: chats outside projects (project chats sit under their project, M8.T04).
    public func groups(now: Date = Date()) -> [SidebarGroup] {
        SidebarGrouping.group(sidebar.filter { $0.projectID == nil }, now: now)
    }

    // MARK: Navigation

    /// Opens a fresh new chat (⌘N): new headline + suggestions; no database row until the first send.
    /// ⇧⌘E (R-210 AC1): a new chat whose switch starts on Evil.
    public func newEvilChat() {
        newChatMode = .evil
        newRegularChat()
    }

    /// ⌘N, the toolbar's new chat, the sidebar's: an incognito chat when "New chats are incognito" is on (M8.T08).
    public func newChat(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        if newChatsIncognito(), makeIncognito != nil { return newIncognitoChat() }
        newRegularChat(seed: seed)
    }

    /// A saved (non-incognito) new chat whatever the setting: leaving incognito with the toolbar button, ⇧⌘E.
    public func newRegularChat(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        guard mayLeaveIncognito(.newChat) else { return }
        newChatProjectID = nil
        leaveIncognito { startNewChat(seed: seed) }
    }

    /// M8.T04 step 3: a new chat that is created inside `projectID` at its first send.
    public func newChat(inProject projectID: String) {
        guard mayLeaveIncognito(.newChat) else { return }
        leaveIncognito {
            startNewChat(seed: UInt64.random(in: 0...UInt64.max))
            newChatProjectID = projectID
        }
    }

    private func startNewChat(seed: UInt64) {
        headlineSeed = seed
        headline = EmptyHeadline.pick(seed: seed)
        suggestions = SuggestionProvider.suggestions(enabled: enabledPacks, seed: seed)
        composerText = ""
        navigate(to: .newChat)
    }

    public func open(_ route: WindowRoute) {
        guard route != .incognito else { return newIncognitoChat() }
        guard route != self.route || route == .newChat else { return }
        guard mayLeaveIncognito(.navigate(route)) else { return }
        leaveIncognito { navigate(to: route) }
    }

    public func goBack() {
        guard canGoBack, mayLeaveIncognito(.back) else { return }
        leaveIncognito { popBack() }
    }

    public func goForward() {
        guard canGoForward, mayLeaveIncognito(.forward) else { return }
        leaveIncognito { popForward() }
    }

    private func popBack() {
        guard let previous = backStack.popLast() else { return }
        if route != .incognito { forwardStack.append(route) }
        apply(previous)
    }

    private func popForward() {
        guard let next = forwardStack.popLast() else { return }
        if route != .incognito { backStack.append(route) }
        apply(next)
    }

    private func navigate(to newRoute: WindowRoute) {
        guard newRoute != route || newRoute == .newChat else { return }
        // M1.T20: the incognito chat never enters the history (it is discarded when the window leaves it).
        if route != .incognito, route != .newChat || newRoute != .newChat { backStack.append(route) }
        forwardStack.removeAll()
        apply(newRoute)
    }

    /// `created`: the chat this window's send has just created (the new-chat dock). It has no unread flag to clear, so
    /// the chat open's main-thread write is skipped in the send's ack frame (fix/t05-u2-u5, NFR-U2).
    private func apply(_ newRoute: WindowRoute, created: Bool = false) {
        route = newRoute
        transcriptToken?.cancel()
        transcriptToken = nil
        transcript = []
        if newRoute == .incognito {
            isDocked = incognito?.hasContent ?? false
        } else if case let .chat(id) = newRoute {
            ChatOpenSignpost.begin(id)  // M9.T05 NFR-U11: ends when the chat's conversation column is drawn
            if !created { markRead(id) }
            if mirrorsTranscript {
                transcript = (try? service.transcript(id)) ?? []
                transcriptToken = service.observeTranscript(id) { [weak self] items in self?.transcript = items }
            }
            isDocked = true
        } else {
            isDocked = false
        }
    }

    /// Window width changed: auto-collapse the sidebar under 900 pt, restore it when wider again (MainWindow narrow).
    public func windowWidthChanged(_ width: CGFloat) {
        windowWidth = width
        if width < 900 {
            if columnVisibility != .detailOnly {
                columnVisibility = .detailOnly
                autoCollapsed = true
            }
        } else if autoCollapsed {
            columnVisibility = .all
            autoCollapsed = false
        }
    }

    /// VQ-M10 round 65 (S-15; Claude's artifact panel): the side panel opened or closed. When the sidebar, the panel
    /// (`panelWidth`) and a comfortable conversation (`SidePanelModel.comfortableChatWidth`) do not all fit, opening
    /// the panel collapses the sidebar, and closing it brings the sidebar back. Before, the chat was squeezed to a
    /// ~250 pt column beside a 766 pt panel.
    public func sidePanelChanged(open: Bool, panelWidth: CGFloat) {
        if open {
            guard columnVisibility != .detailOnly, windowWidth > 0,
                  windowWidth - Layout.sidebarWidth - panelWidth < SidePanelModel.comfortableChatWidth else { return }
            columnVisibility = .detailOnly
            panelCollapsed = true
        } else if panelCollapsed {
            panelCollapsed = false
            if columnVisibility == .detailOnly, !autoCollapsed { columnVisibility = .all }
        }
    }

    public func toggleSidebar() {
        autoCollapsed = false
        panelCollapsed = false
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    // MARK: Composer

    /// Clicking a suggestion fills the composer (does not send).
    public func useSuggestion(_ s: Suggestion) { composerText = s.text }

    /// Sends `text` (+ paste cards): on a new chat creates the row first and docks the composer in one ≤ 300 ms
    /// animation (`dockAnimation`, none under Reduce Motion; signpost `composerDock`). `turn` runs the reply
    /// (`MainWindowSlots.startTurn` → `ConversationModel.send`); without it the send only persists the user message.
    public func send(_ text: String, pastedTexts: [String] = [], hasFiles: Bool = false, reduceMotion: Bool = false,
                     turn: (@MainActor (String, String, [String]) -> Void)? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || ((!pastedTexts.isEmpty || hasFiles) && turn != nil) else { return }
        if route == .incognito {
            sendIncognito(body, pastedTexts: pastedTexts, reduceMotion: reduceMotion, turn: turn)
            return
        }
        do {
            let chatID: String
            if let id = currentChatID {
                chatID = id
            } else {
                // M1.T19 step 1: the row carries the prompt's first 60 characters from the first frame on (the
                // observation replaces this optimistic row with the stored one a moment later).
                var chat = try service.create(firstPrompt: body.isEmpty ? (pastedTexts.first ?? "") : body)
                chatID = chat.id
                if let pid = newChatProjectID {  // M8.T04: before the first turn freezes the instructions
                    try ProjectStore(database: service.database).move(chatID: chatID, to: pid)
                    chat.projectID = pid
                    newChatProjectID = nil
                }
                beginMutation()
                if !sidebar.contains(where: { $0.id == chatID }) {
                    sidebar.insert(chat, at: sidebar.firstIndex(where: { !$0.pinned }) ?? sidebar.count)
                }
            }
            composerText = ""
            if let turn {
                turn(chatID, body, pastedTexts)
            } else {
                try service.appendUserMessage(chatID, text: body)
            }
            if route == .newChat { dock(into: chatID, reduceMotion: reduceMotion) }
        } catch {
            AppLog.logger(.ui).error("send failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// M1.T20: the incognito chat's send: its row is created in the session's in-memory store (never in the sidebar,
    /// title stays `title.incognito`), then the composer docks in place (the route stays `.incognito`).
    private func sendIncognito(_ body: String, pastedTexts: [String], reduceMotion: Bool,
                               turn: (@MainActor (String, String, [String]) -> Void)?) {
        guard let session = incognito, let turn else { return }
        do {
            let chatID = try session.createChat()
            toolbarAfterCommit = true  // NFR-U2: the toolbar follows after the send's ack frame
            composerText = ""
            turn(chatID, body, pastedTexts)
            guard !isDocked else { return }
            if reduceMotion { isDocked = true } else { withAnimation(Self.dockAnimation) { isDocked = true } }
        } catch {
            AppLog.logger(.ui).error("incognito send failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// M1.T07 step 2 names `.smooth(duration: 0.3)`; a spring's completion lands ≈ 100 ms after its nominal
    /// duration (measured 0.35–0.40 s in the probe), so a fixed ease-out curve of the same shape ends inside the
    /// AT-001 ≤ 300 ms bound measured from the send (A-M1-T07a: a 0.26 s curve measured 0.31–0.33 s end to end, so 0.2 s).
    static let dockAnimation = Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.2)

    private func dock(into chatID: String, reduceMotion: Bool) {
        toolbarAfterCommit = true  // NFR-U2: the toolbar follows after the send's ack frame
        let state = Signposts.begin(.composerDock, on: Signposts.ui)
        let start = ContinuousClock.now
        let finish: @MainActor () -> Void = { [weak self] in
            Signposts.end(.composerDock, state, on: Signposts.ui)
            let d = ContinuousClock.now - start
            self?.lastDockDuration = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        // Route change without history noise: the new chat becomes this chat.
        if reduceMotion {
            route = .chat(chatID)
            apply(.chat(chatID), created: true)
            finish()
        } else {
            withAnimation(Self.dockAnimation) {
                apply(.chat(chatID), created: true)
            } completion: {
                finish()
            }
        }
    }

    // MARK: Chat operations (row menu, title-bar ⋯, Chats page)

    public func rename(_ id: String, to title: String) {
        renamingChatID = nil
        perform { try self.service.rename(id, to: title) }
    }

    /// M1.T19 step 2: an auto title arrived; shown at once (the observation confirms it from the database).
    public func applyTitle(_ id: String, title: String) {
        guard let i = sidebar.firstIndex(where: { $0.id == id }) else { return }
        sidebar[i].title = title
        sidebar[i].titlePending = false
    }

    /// M1.T19 step 3: a new chat whose only send was cancelled before the model was ready has no row any more:
    /// the window returns to a new chat and the sidebar drops it at once.
    public func emptyChatRemoved(_ id: String) {
        if let session = incognito, session.owns(id) {  // M1.T20: the incognito chat stays open, empty again
            session.chatRemoved()
            isDocked = false
            return
        }
        sidebar.removeAll { $0.id == id }
        leaveIfRemoved([id])
    }

    /// M1.T19 step 4: opening a chat clears its unread dot: at once in the sidebar, the row's write enqueued on the
    /// database writer (the main thread never waits for the writer, which a streaming save or the indexer may hold:
    /// AT-NFR-S3; the 8-h soak's chat opens stalled up to 3.5 s). Failures are logged by the store.
    public func markRead(_ id: String) {
        if let i = sidebar.firstIndex(where: { $0.id == id }), sidebar[i].unread { sidebar[i].unread = false }
        service.setUnreadLater(id, false)
    }

    public func togglePin(_ id: String) {
        let pinned = sidebar.first { $0.id == id }?.pinned ?? false
        perform { try self.service.setPinned(id, !pinned) }
    }

    public func archive(_ ids: [String]) {
        perform { try self.service.archive(ids) }
        leaveIfRemoved(ids)
    }

    public func requestDelete(_ ids: [String], anchor: PendingDelete.Anchor) {
        let title = ids.count == 1 ? (sidebar.first { $0.id == ids[0] }?.title ?? "") : ""
        pendingDelete = PendingDelete(ids: ids, title: title, anchor: anchor)
    }

    public func confirmDelete() {
        guard let p = pendingDelete else { return }
        pendingDelete = nil
        perform { try self.service.delete(p.ids) }
        leaveIfRemoved(p.ids)
    }

    public func export(_ id: String, as format: ChatExportFormat) -> (data: Data, name: String)? {
        guard let data = try? service.export(id, as: format) else { return nil }
        let title = sidebar.first { $0.id == id }?.title ?? ""
        return (data, ChatListService.exportFileName(title: title, format: format))
    }

    private func leaveIfRemoved(_ ids: [String]) {
        if let current = currentChatID, ids.contains(current) {
            backStack.removeAll { if case let .chat(id) = $0 { return ids.contains(id) } else { return false } }
            forwardStack.removeAll { if case let .chat(id) = $0 { return ids.contains(id) } else { return false } }
            newChat()
        }
    }

    private func perform(_ op: @escaping () throws -> Void) {
        beginMutation()
        do { try op() } catch {
            pendingMutation = nil
            AppLog.logger(.ui).error("chat operation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func beginMutation() {
        pendingMutation = (ContinuousClock.now, Signposts.begin(.sidebarUpdate, on: Signposts.ui))
    }

    // MARK: Sidebar observation

    /// Loads the next page of sidebar rows (scrolled to the end of a long list).
    public func loadMoreSidebar() {
        guard sidebar.count >= sidebarLimit else { return }
        sidebarLimit += ChatListService.sidebarPageSize
        startSidebar()
    }

    private func startSidebar() {
        sidebarToken?.cancel()
        sidebarToken = service.observeSidebar(limit: sidebarLimit) { [weak self] rows in
            self?.applySidebar(rows)
        }
    }

    private func applySidebar(_ rows: [ChatSummary]) {
        sidebar = rows
        if let m = pendingMutation {
            pendingMutation = nil
            Signposts.end(.sidebarUpdate, m.state, on: Signposts.ui)
            let d = ContinuousClock.now - m.start
            lastSidebarUpdateLatency = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
    }
}
