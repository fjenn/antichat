// MainWindow (M1.T07 step 1; screens.md S-05/S-08, components.md §1; ChatGPT `001`/`003`): a NavigationSplitView
// with the sidebar (260 pt, collapsible, auto-collapsed under 900 pt) and the chat column, under a unified
// toolbar: traffic lights, sidebar toggle, centred ToolbarTitle, ⋯ chat menu (Back ⌘[ / Forward ⌘] are View menu items).
// No icon rail and no product switcher (R-001 AC1). Owns the composer docking (step 2) and the disclaimer (step 3);
// the composer and the message list come in through `MainWindowSlots` (live: `ChatSessions.slots`).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import SwiftUI

public struct MainWindow: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    @State private var state: WindowState
    /// M1.T11: the window's ⌘K palette (sidebar Search, ⌘K command, `palettePanel` overlay).
    @State private var palette: PaletteController
    /// M6.T13: the window's side panel (artifacts, file previews) beside the chat column; one per window.
    @State private var panel = SidePanelModel(windowID: "main")
    @State private var showsOutputs = false
    /// The window's scrim under a conversation sheet (VQ round 65, S-09).
    @State private var scrim = ModalScrim()
    /// M5.T13: the window's Library page state (built on first use from the window's database).
    @State private var library: LibraryModel?
    /// Settings is shown inside this window, over the chat (`SettingsPresenter`).
    private let settings = SettingsPresenter.shared
    private var showsSettings: Bool { settings.isShown(in: state) }
    private let slots: MainWindowSlots
    private let onSearch: () -> Void
    private let onReady: (WindowState) -> Void

    @Namespace private var composerSpace
    @EffectiveReduceMotion private var reduceMotion

    public init(state: WindowState, slots: MainWindowSlots = .standIns, onSearch: @escaping () -> Void = {},
                palette: PaletteController? = nil, onReady: @escaping (WindowState) -> Void = { _ in }) {
        _state = State(initialValue: state)
        // M9.T05 (NFR-U11): the conversation slot shows the chats; the plain transcript list is not drawn.
        if slots.conversation != nil, state.mirrorsTranscript { state.mirrorsTranscript = false }
        _palette = State(initialValue: palette ?? PaletteController())
        self.slots = slots
        self.onSearch = onSearch
        self.onReady = onReady
    }

    public var body: some View {
        #if DEBUG
        let _ = ViewWork.evaluated.append("mainWindow")
        #endif
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(state: state, onSearch: { onSearch(); palette.toggle() })
                .modifier(OpaqueFill())  // as the detail column below: the column's minimum size is never its content's
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: Layout.sidebarWidthMin, ideal: Layout.sidebarWidth,
                                                max: Layout.sidebarWidthMax)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The split view sizes each column to at least its content's minimum size (a zero proposal), even
                // when that is taller than the window: one row that pins its wrapped text's height
                // (`fixedSize(vertical:)`: F6's offline notice, then the notifications explainer) made the whole
                // split view ~1,500 pt tall in a 1,000 pt window, its top and bottom off screen and both lists
                // unscrollable to their start. A column fills what it is given and never answers with its content's
                // size; the window's minimum is `Layout.windowMin` (ExplainerBannerWindowHeightTests).
                .modifier(OpaqueFill())
                .background(Color.surfaceCanvas)
                // The toolbar strip is opaque canvas: scrolled messages do not show through behind the title and the
                // toolbar buttons (a zero-height row whose background reaches up into the top safe area).
                .overlay(alignment: .top) {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                        .background(Color.surfaceCanvas, ignoresSafeAreaEdges: .top)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                // …and the system's own edge effect is the hard one on every route (chat, side panel, Library,
                // Projects): the soft one draws the scrolled content, blurred, over the bar and over the cover above.
                .scrollEdgeEffectStyle(.hard, for: .top)
                .splitColumnAccessibilityLabel(CopyKey("a11y.mainContent").string())  // M9.T03: the column's group
                // M9.T03: a Help sheet is modal; while one is up the content under it is out of the accessibility tree
                // (VoiceOver stays in the sheet; the audit measured the covered text, S-22). Not under the ⌘K palette:
                // the composer keeps the AX focus there, and a hidden focused element is an orphan (S-18 audit).
                .accessibilityHidden(state.presentedSheet != nil)
        }
        .navigationSplitViewStyle(.balanced)
        .overlay { ModalScrimOverlay(scrim: scrim) }  // VQ round 65 (S-09): under the Versions / report sheets
        .environment(\.modalScrim, scrim)
        .toolbar(removing: .sidebarToggle)
        .toolbar { if !showsSettings { toolbarContent } }
        // Settings covers the whole window; the chat under it keeps its state (draft, scroll position, a streaming
        // answer) but takes no clicks, keys or VoiceOver focus meanwhile.
        .disabled(showsSettings)
        .accessibilityHidden(showsSettings)
        .overlay { settingsOverlay }
        .onChange(of: state.route) { if showsSettings { settings.dismiss() } }  // a chat was opened (⌘N, a notification)
        .onDisappear { settings.windowDisappeared(state) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.windowWidthChanged($0) }
        .frame(minWidth: Layout.windowMin.width, minHeight: Layout.windowMin.height)
        .palettePanel(palette)
        .incognitoFrame(state)  // M1.T20: grey frame, close confirmation, window guards
        .evilFrame(state.shownMode == .evil && !state.isIncognito)  // M2.T17 R-210 AC3
        .windowAccessibilityTitle(WindowAccessibilityTitle.text(chatTitle: state.currentChat?.title,  // M9.T01 NFR-A2
                                                                evil: state.shownMode == .evil, incognito: state.isIncognito))
        // A sheet (⌘/ shortcuts, Help, …) replaces the ⌘K palette instead of opening over it (M9.T03, S-22).
        .onChange(of: state.presentedSheet) { _, sheet in if sheet != nil, palette.isPresented { palette.dismiss() } }
        .sheet(item: $state.presentedSheet) { sheet in  // M1.T24: Help menu sheets
            switch sheet {
            case .shortcuts: ShortcutListSheet { state.presentedSheet = nil }
            case .legal: LegalSheet { state.presentedSheet = nil }  // M10.T06
            case .help: HelpGuideSheet { state.presentedSheet = nil }  // M10.T07
            case .whatsNew:  // M10.T07
                if let notes = WhatsNewNotes.load(version: WhatsNewProvider.currentVersion) {
                    WhatsNewSheet(notes: notes) { state.presentedSheet = nil }
                }
            case .report: ReportProblemSheet(database: state.service.database) { state.presentedSheet = nil }
            case .exportLogs: ExportLogsSheet(database: state.service.database) { state.presentedSheet = nil }
            case .crashPrompt:
                CrashPromptSheet(reports: DiagnosticsCenter.shared.pendingReports, controller: DiagnosticsCenter.shared.controller) {
                    state.presentedSheet = nil
                }
            case .uninstall: UninstallSheet(database: state.service.database) { state.presentedSheet = nil }
            case .uninstallHelp: UninstallHelpSheet { state.presentedSheet = nil }
            case .filesInChat:
                FilesInChatSheet(files: state.currentChatID.flatMap { id in slots.chatFiles?(id) } ?? [],
                                 onSelect: { f in state.presentedSheet = nil; panel.open(f) },
                                 onClose: { state.presentedSheet = nil })
            }
        }
        .task {  // M10.T07 (R-303 AC2): What's new once after an update (never in tests/probes or during onboarding)
            guard !BackgroundRun.isOn, state.presentedSheet == nil,
                  WhatsNewProvider.notesToShow(onboarding: OnboardingGate.shouldShow()) != nil else { return }
            state.presentedSheet = .whatsNew
        }
        .webSearchConsentSheet(.main)  // M7.T03 step 2: the composer's Web search row while search is off
        .sheet(isPresented: Binding(get: { state.pendingNewProjectForChat != nil },
                                    set: { if !$0 { state.pendingNewProjectForChat = nil } })) {
            NewProjectSheet { name, icon in  // M8.T04: Move to project › New project…
                if let chat = state.pendingNewProjectForChat, let p = state.projects?.create(name: name, icon: icon) {
                    state.projects?.move(chatID: chat, to: p.id)
                }
                state.pendingNewProjectForChat = nil
            } onCancel: { state.pendingNewProjectForChat = nil }
        }
        .onChange(of: state.currentChatID) { panel.close() }  // the panel belongs to the shown chat
        .onChange(of: state.currentChatID, initial: true) { state.syncToolbarChat() }  // NFR-U2: the toolbar's chat
        // The panel collapses the sidebar on a narrow window only (and gives it back when it closes).
        .onChange(of: panel.isOpen) { _, open in state.sidePanelChanged(open: open) }
        .onReceive(NotificationCenter.default.publisher(for: .antichatShowInLibrary)) { note in  // M5.T13 (D-026)
            guard let url = note.object as? URL, !state.isIncognito else { return }
            state.open(.library)
            ensureLibrary().show(url: url)
        }
        .toast(Binding(get: { AppToasts.shared.current }, set: { AppToasts.shared.current = $0 }))  // M8.T12 quit.waiting
        .focusedSceneValue(\.windowState, state)
        .focusedSceneValue(\.paletteController, palette)
        .onAppear {
            state.activate()
            palette.attach(state)
            onReady(state)
            settings.windowAppeared(state)  // ⌘, with no window on screen opened this one
            // M8.T09 step 3: crash handlers + the next-launch prompt (once per process, never during onboarding).
            DiagnosticsCenter.shared.database = DiagnosticsCenter.shared.database ?? state.service.database
            if DiagnosticsCenter.shared.checkAtLaunch(), state.presentedSheet == nil { state.presentedSheet = .crashPrompt }
        }
    }

    // MARK: Settings

    /// Settings, full-window over the chat (owner 2026-11-16: in the app itself, not a window of its own).
    @ViewBuilder private var settingsOverlay: some View {
        if showsSettings {
            SettingsRootView(context: SettingsContext(chats: state.service)) { settings.dismiss() }
        }
    }

    // MARK: Toolbar

    /// A chat or a new chat is shown (a page — Library, Projects, a project — has its own heading).
    private var showsChatTitle: Bool { state.route == .newChat || state.toolbarChatID != nil }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { state.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .help(Text(CopyKey("menu.view.sidebar")))
                .accessibilityLabel(Text(CopyKey("menu.view.sidebar")))
                .probeID("sidebarToggle")
            if state.columnVisibility == .detailOnly {  // the sidebar's New chat is out of reach while it is collapsed
                Button { state.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .help(Text(verbatim: "\(CopyKey("side.newChat").string()) ⌘N"))
                    .accessibilityLabel(Text(CopyKey("side.newChat")))
                    .probeID("toolbarNewChat")
            }
        }
        // ux/simplify: the chat's mode, a quiet text button beside the sidebar toggle (no glass capsule). Only where a
        // composer is shown (a chat or a new chat), and only while Evil Mode is on and not hidden.
        if showsChatTitle || state.isIncognito, let picker = slots.modePicker?() {
            ToolbarItem(placement: .navigation) { picker }
                .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem(placement: .principal) {
            Group {
                if state.isIncognito {
                    IncognitoBadge()  // M1.T20: "Incognito" instead of the title
                } else {
                    HStack(spacing: Spacing.space2) {
                    // Without the picker (Evil Mode off or hidden) an Evil chat still says so by its title (R-210 AC3).
                    if state.shownMode == .evil, slots.modePicker?() == nil { EvilBadge() }
                    // A page (Library, Projects, a project) shows its own heading: no toolbar title there.
                    if showsChatTitle {
                    ToolbarTitle(chat: state.toolbarChat,  // NFR-U2: `toolbarChatID`, the shown chat (one frame late)
                                 renaming: state.toolbarChatID != nil && state.renamingChatID == state.toolbarChatID,
                                 onBeginRename: { state.renamingChatID = state.currentChatID },
                                 onRename: { if let id = state.currentChatID { state.rename(id, to: $0) } },
                                 onCancel: { state.renamingChatID = nil })
                    }
                    }
                }
            }
            .centeredInWindow()
        }
        // No glass capsule behind the title (ChatGPT `001`): the capsule would stay put while the title is shifted.
        .sharedBackgroundVisibility(.hidden)
        // VQ round 65 (S-05): Outputs and Share belong to a chat; a new, empty chat shows neither (ChatGPT and Claude
        // show no copy or share control there). The ⋯ menu stays (disabled) so the toolbar keeps its anchor.
        if state.toolbarChatID != nil {
        ToolbarItem(placement: .primaryAction) {  // M6.T13 R-016 AC5: Outputs
            Button { showsOutputs.toggle() } label: { Image(systemName: "doc.on.doc") }
                .disabled(state.toolbarChatID == nil || slots.chatFiles == nil)
                .help(Text(CopyKey("panel.outputs")))
                .accessibilityLabel(Text(CopyKey("panel.outputs")))
                .probeID("outputsButton")
                .popover(isPresented: $showsOutputs, arrowEdge: .bottom) {
                    OutputsListView(files: state.currentChatID.flatMap { id in slots.chatFiles?(id) } ?? []) { f in
                        showsOutputs = false
                        panel.open(f)
                    }
                    .popoverSurface()
                }
        }
        if FeatureFlag.exportAll.isEnabled() {  // M8.T07 step 5 (R-019): Share ▾
            ToolbarItem(placement: .primaryAction) {
                ShareToolbarButton(chatID: state.toolbarChatID, database: state.service.database)
            }
        }
        }
        ToolbarItem(placement: .primaryAction) {
            IncognitoButton(isOn: state.isIncognito, isEnabled: state.canToggleIncognito) { state.toggleIncognito() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let chat = state.toolbarChat {
                    ChatMenuItems(chat: chat, state: state, deleteAnchor: .toolbar, showsExport: false)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .tint(.primary)  // M9.T08: menu items take the accent by default; match the plain toolbar buttons
            .disabled(state.toolbarChat == nil)
            .help(Text(CopyKey("chat.more")))
            .accessibilityLabel(Text(CopyKey("chat.more")))
            .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
            .probeID("chatMoreMenu")
            .popover(isPresented: Binding(get: { state.pendingDelete?.anchor == .toolbar },
                                          set: { if !$0 { state.pendingDelete = nil } })) {
                DeleteConfirmation(title: state.pendingDelete?.title ?? "", onConfirm: { state.confirmDelete() },
                                   onCancel: { state.pendingDelete = nil })
                    .popoverSurface()
            }
        }
    }

    // MARK: Detail column

    @ViewBuilder private var detail: some View {
        switch state.route {
        case .newChat, .chat, .incognito:
            SidePanelContainer(model: panel) {  // M6.T13: cards open here; produced files open it automatically
                chatColumn.chatTypography()  // M1.T23: text size + chat font for transcript and composer
                    .fileDropOverlay(slots.dropFiles)  // M6.T01: drop files anywhere on the chat column
            }
            .environment(\.sidePanel, panel)
        case .library:
            if let library {  // M5.T13 (R-022)
                LibraryView(model: library)
            } else {
                Color.clear.onAppear { _ = ensureLibrary() }
            }
        case .projects:
            if let projects = state.projects {  // M8.T04
                ProjectsListView(model: projects) { state.open(.project($0)) }
            } else {
                PlaceholderPage(title: CopyKey("side.projects"), body: CopyKey("projects.empty"), symbol: "folder")
            }
        case .project(let id):
            if let projects = state.projects {
                ProjectPageView(projectID: id, projects: projects, onNewChat: { state.newChat(inProject: $0) },
                                onOpenChat: { state.open(.chat($0)) }, onDeleted: { state.open(.projects) })
                    .id(id)
            }
        }
    }

    /// The Library page's model (one per window; "Open chat" navigates this window). Called from actions only.
    private func ensureLibrary() -> LibraryModel {
        if let library { return library }
        let m = LibraryModel(database: state.service.database)
        m.onOpenChat = { [state] chat, _ in state.open(.chat(chat)) }
        library = m
        return m
    }

    private var composer: some View {
        WindowComposer(state: state, slots: slots, reduceMotion: reduceMotion)
            .matchedGeometryEffect(id: "composer", in: composerSpace)
            .accessibilityElement(children: .contain)
            .probeID("composer")
    }

    @ViewBuilder private var chatColumn: some View {
        Group {
            if state.isDocked {
                VStack(spacing: 0) {
                    if let conversation = slots.conversation, let chatID = state.currentChatID {
                        conversation(chatID, state.currentChat?.createdAt)
                            .id(chatID)
                    } else {
                        TranscriptList(items: state.transcript, startDate: state.currentChat?.createdAt) {
                            slots.transcriptRow($0)
                        }
                    }
                    VStack(spacing: Spacing.space2) {
                        NotificationExplainerBanner()  // a calm row above the composer; never over a reply
                        composer
                            .frame(maxWidth: readingWidth)
                        Text(CopyKey("composer.disclaimer"))
                            .typeStyle(.footnote)
                            .foregroundStyle(Color.textTertiary)  // quiet, centred under the field
                            .multilineTextAlignment(.center)
                            .probeID("composerDisclaimer")
                    }
                    .padding(.horizontal, Spacing.space6)
                    .padding(.bottom, Spacing.space3)
                }
            } else if state.isIncognito {
                IncognitoEmptyState(personalization: $state.incognitoPersonalization) { composer }
            } else if state.shownMode == .evil {
                EvilEmptyState(modeControl: slots.emptyModeControl?()) { composer }  // M2.T17 S-06
            } else {
                EmptyStateView(headline: state.headline, suggestions: state.suggestions,
                               onSuggestion: { state.useSuggestion($0) },
                               modeControl: slots.emptyModeControl?()) { composer }
            }
        }
        .accessibilityElement(children: .contain)
        .probeID("chatColumn")
    }
}

/// The window's composer slot (NFR-U2). Its context is made here, not in MainWindow's body: a `Binding` reads its
/// value when it is made, so `$state.composerText` in MainWindow's body made the whole window (split view, toolbar and
/// its menus, both columns) depend on the composer text, re-evaluated on every keystroke and on a send's clear.
struct WindowComposer: View {
    let state: WindowState
    let slots: MainWindowSlots
    let reduceMotion: Bool

    var body: some View {
        #if DEBUG
        let _ = ViewWork.evaluated.append("windowComposer")
        #endif
        let state = state, slots = slots, reduceMotion = reduceMotion
        slots.composer(ComposerSlotContext(
            text: Bindable(state).composerText,
            send: { state.send($0, pastedTexts: $1, hasFiles: $2, reduceMotion: reduceMotion, turn: slots.startTurn) },
            isEmptyState: !state.isDocked, chatID: state.currentChatID, isIncognito: state.isIncognito,
            newChatMode: state.newChatMode))
    }
}

/// Library / Projects until M5/M8 fill them: title + one empty-state line.
struct PlaceholderPage: View {
    let title: CopyKey
    let body_: CopyKey
    let symbol: String

    init(title: CopyKey, body: CopyKey, symbol: String) {
        self.title = title
        body_ = body
        self.symbol = symbol
    }

    var body: some View {
        VStack(spacing: Spacing.space3) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.textTertiary)
            Text(title)
                .typeStyle(.title3)
                .foregroundStyle(Color.textPrimary)
            Text(body_)
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(Spacing.space6)
        .accessibilityElement(children: .combine)
        .probeID("placeholderPage")
    }
}

public extension FocusedValues {
    /// The focused window's state (menu commands: New Chat ⌘N; M1.T24 adds the rest).
    @Entry var windowState: WindowState?
    /// The focused window's ⌘K palette (M1.T11; the Search ⌘K command).
    @Entry var paletteController: PaletteController?
}
