// Sidebar (M1.T07 step 5; screens.md S-05, components.md §1): SidebarHeader (New chat ⌘N, Search ⌘K), nav items
// Library / Projects / Chats, sections Pinned · Today · Previous 7 days · Older, SidebarFooter (Settings).
// No icon rail and no product switcher (R-001 AC1).
import AntiChatDesign
import AntiChatHarness
import AntiChatKnowledge
import SwiftUI

struct SidebarView: View {
    @Bindable var state: WindowState
    var onSearch: () -> Void

    var body: some View {
        // M9.T05 (NFR-U2 / U11): what singles out a row (selection, spinner, rename, pending delete) is read here,
        // once, and handed to each row as a plain value; the rows compare by value (`SidebarChatRow`). Before, every
        // row read the window state itself, so a chat open or a send re-evaluated every row and the List diffed and
        // reconfigured all of them (T05 perf profile: SidebarView.row + OutlineListCoordinator.diffRows in each
        // send's ack frame and ~140 ms of every 500-turn chat open).
        #if DEBUG
        let _ = ViewWork.evaluated.append("sidebar")
        #endif
        let marks = SidebarChatRow.Marks(state)
        List {
            Section {
                SidebarNavItem(symbol: "square.and.pencil", title: CopyKey("side.newChat"), id: "sidebar.newChat",
                               selected: state.route == .newChat) { state.newChat() }
                    .help(Text(verbatim: "\(CopyKey("side.newChat").string()) ⌘N"))
                SidebarNavItem(symbol: "magnifyingglass", title: CopyKey("side.search"), id: "sidebar.search",
                               selected: false, action: onSearch)
                    .help(Text(verbatim: "\(CopyKey("side.search").string()) ⌘K"))
                SidebarNavItem(symbol: "books.vertical", title: CopyKey("side.library"), id: "sidebar.library",
                               selected: state.route == .library) { state.open(.library) }
                SidebarNavItem(symbol: "folder", title: CopyKey("side.projects"), id: "sidebar.projects",
                               selected: state.route == .projects) { state.open(.projects) }
                SidebarNavItem(symbol: "bubble.left.and.bubble.right", title: CopyKey("chats.page.title"),
                               id: "sidebar.chats", selected: state.route == .chats) { state.open(.chats) }
            }
            if let projects = state.projects, !projects.projects.isEmpty {  // M8.T04: ProjectRows above Recents
                Section {
                    ForEach(projects.projects) { p in
                        ProjectRow(project: p, selected: state.route == .project(p.id)) { state.open(.project(p.id)) }
                            .dropDestination(for: String.self) { ids, _ in
                                for id in ids { projects.move(chatID: id, to: p.id) }
                                return !ids.isEmpty
                            }
                    }
                }
            }
            ForEach(state.groups()) { group in
                Section {
                    // Q-015 r4: the section title is the section's first row, not a `header:`. A List section header
                    // sits in an unnamed AXGroup that SwiftUI owns (audit: "Element has no description"); a row's
                    // content is the row's own element, as for the chat rows.
                    Text(group.section.title)
                        .typeStyle(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Spacing.space2)
                        .probeAnchor("sidebarSection.\(group.section.rawValue)")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sidebarSection.\(group.section.rawValue)")
                        .accessibilityAddTraits(.isHeader)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.space3, bottom: 0, trailing: Spacing.space1))
                    ForEach(group.chats) { chat in
                        SidebarChatRow(state: state, chat: chat, selected: marks.selected == chat.id,
                                       activity: marks.streaming.contains(chat.id) ? .streaming : .idle,
                                       renaming: marks.renaming == chat.id, deleting: marks.deleting == chat.id)
                            .equatable()
                            // List row traits on the row itself (inside the equatable body they were not applied).
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.space1, bottom: 0, trailing: Spacing.space1))
                            .listRowSeparator(.hidden)
                            .onAppear { if chat.id == state.sidebar.last?.id { state.loadMoreSidebar() } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.surfaceSidebar)
        // Before the footer inset: on the outer view SwiftUI stamps "sidebar" over the footer buttons' own identifiers
        // (sidebar.settings, footer.*), which XCUITest then cannot find (Q-015 catch-up).
        .probeID("sidebar")
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }
}

/// M9.T05: one chat row of the sidebar, compared by value. Its inputs are the chat and the values the parent read once
/// (`Marks`); the actions' closures are made in `body`, so a row whose inputs did not change is not re-evaluated when
/// another row's selection, spinner, rename or delete state changes.
struct SidebarChatRow: View, Equatable {
    let state: WindowState
    let chat: ChatSummary
    let selected: Bool
    let activity: ChatRowActivity
    let renaming: Bool
    let deleting: Bool

    /// The row-singling window values, read once per sidebar pass.
    struct Marks {
        var selected: String?
        var renaming: String?
        var deleting: String?
        var streaming: Set<String> = []

        @MainActor init(_ state: WindowState) {
            selected = state.currentChatID
            renaming = state.renamingChatID
            if let p = state.pendingDelete, p.anchor == .row, p.ids.count == 1 { deleting = p.ids[0] }
            if let activity = state.rowActivity {
                streaming = Set(state.sidebar.lazy.map(\.id).filter { activity($0) == .streaming })
            }
        }
    }

    #if DEBUG
    /// Row bodies evaluated, by chat id (tests).
    nonisolated(unsafe) static var evaluated: [String] = []
    #endif

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.state === b.state && a.chat == b.chat && a.selected == b.selected && a.activity == b.activity
            && a.renaming == b.renaming && a.deleting == b.deleting
    }

    var body: some View {
        #if DEBUG
        let _ = Self.evaluated.append(chat.id)
        #endif
        let chat = chat, state = state
        ChatRow(
            chat: chat,
            selected: selected,
            activity: activity,  // M1.T19 spinner
            renaming: renaming,
            deleting: deleting,
            onRename: { state.rename(chat.id, to: $0) },
            onCancelRename: { state.renamingChatID = nil },
            onConfirmDelete: { state.confirmDelete() },
            onCancelDelete: { state.pendingDelete = nil },
            menu: { AnyView(ChatRowMenuButton(chat: chat, state: state)) }
        )
        .onTapGesture { state.open(.chat(chat.id)) }
        .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space opens the chat
        .accessibilityAction { state.open(.chat(chat.id)) }
        .contextMenu { ChatMenuItems(chat: chat, state: state) }
        .draggable(chat.id)  // M8.T04: drop on a ProjectRow to move it
    }
}

/// SidebarNavItem / SidebarHeader button (components.md §1): icon + label, default · selected · focused.
struct SidebarNavItem: View {
    let symbol: String
    let title: CopyKey
    let id: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label { Text(title).typeStyle(.subhead) } icon: {
                Image(systemName: symbol).frame(width: 18)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, Spacing.space2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected ? Color.surfaceSelected : (hovering ? Color.surfaceHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.space1, bottom: 0, trailing: Spacing.space1))
        .listRowSeparator(.hidden)
        .probeID(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// M8.T04 step 2: a project in the sidebar (icon, name, chat count); a chat row dropped on it moves the chat there.
struct ProjectRow: View {
    let project: ProjectSummary
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: project.icon).frame(width: 18).foregroundStyle(Color.textSecondary)
                Text(verbatim: project.name).typeStyle(.subhead).foregroundStyle(Color.textPrimary).lineLimit(1)
                Spacer(minLength: Spacing.space1)
                if project.chatCount > 0 {
                    Text(verbatim: "\(project.chatCount)").typeStyle(.caption).foregroundStyle(Color.textTertiary).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, Spacing.space2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(selected || targeted ? Color.surfaceSelected : (hovering ? Color.surfaceHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.space1, bottom: 0, trailing: Spacing.space1))
        .listRowSeparator(.hidden)
        .probeID("sidebar.project.\(project.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
