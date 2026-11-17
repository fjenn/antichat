// Settings → Connections (R-081, R-255; `conn.title`): the apps AntiChat can work with, laid out like an app
// directory (owner 2026-11-16). The header stays put: title, search ("Search 1,547 apps"), [Add] (a custom
// connection) and one line saying what connecting does. Under it, scrolling: "Connected" (the linked apps and the
// connections the user added by address), then one section per category of the catalogue (`ComposioCatalog`) with its
// first six apps in two columns — a category with more says how many and "See all" — and, last, "Browse all N apps".
// Both open the whole list: every app from A to Z, with one chip per category to narrow it. Typing in the search
// field replaces everything with one flat list of matches from the whole catalogue (and the user's own connections).
// A row (`AppRow`): logo tile, name, one line, and one glyph — `+` goes straight to the browser sign-in (a small
// spinner while that runs, "Waiting for sign-in…" under the name), `⋯` on a connected app holds Disconnect. Rows read
// `ConnectFlow.shared`, as the in-chat Connect card does, so a connect started in either shows in both; the linked
// apps are re-read when the page appears and when a window becomes key again (back from the browser).
// [Add] opens AddConnectionSheet (a tool that is not in the list, by its server address); what it adds is a
// `ConnectionRow` under "Connected", whose `⋯` opens ConnectionDetailSheet (its tools and permissions) or removes it.
// Without a deployed relay (RelayClient.isAvailable false) the directory still shows, with one line saying apps
// cannot be connected and no `+`; custom connections work as always.
import AntiChatDesign
import AntiChatFoundation
import AntiChatTools
import AppKit
import SwiftUI

struct ConnectionsPage: View {
    /// The apps a category shows on the overview (three per column).
    static let preview = 6

    @State private var model: ConnectionsModel
    @State private var query: String
    /// The whole list is showing (false = the overview), narrowed to `category` (nil = every app, A to Z).
    @State private var browsing: Bool
    @State private var category: String?
    @State private var adding: Bool
    /// The add sheet's Allow was pressed (closing it then must not decline the pending connection).
    @State private var allowed = false
    /// The custom connection whose details are showing.
    @State private var detail: Detail?
    @State private var catalog: ComposioCatalog
    /// The page shows `ComposioCatalog.shared` and re-reads it when the live list of apps changes (false = a fixed
    /// catalogue was passed in).
    private let followsLive: Bool
    private let availableOverride: Bool?

    struct Detail: Identifiable { let id: String }

    /// `flow`, `catalog`, `query`, `category`, `browseAll`, `servers`, `available`: a fixed page to draw (snapshots).
    init(flow: ConnectFlow = .shared, catalog: ComposioCatalog? = nil, query: String = "", category: String? = nil,
         browseAll: Bool = false, servers: [ConnectionsModel.ServerView]? = nil, available: Bool? = nil) {
        _model = State(initialValue: servers.map { ConnectionsModel(host: nil, flow: flow, servers: $0) } ?? ConnectionsModel(flow: flow))
        _query = State(initialValue: query)
        _category = State(initialValue: category)
        _browsing = State(initialValue: browseAll || category != nil)
        _adding = State(initialValue: false)
        _catalog = State(initialValue: catalog ?? .shared)
        followsLive = catalog == nil
        availableOverride = available
    }

    private var search: String { query.trimmingCharacters(in: .whitespaces) }
    /// Apps can be connected (a relay is deployed); custom connections never need it.
    private var available: Bool { availableOverride ?? model.composioAvailable }
    /// The categories that hold an app (an empty "Other" never shows).
    private var categories: [ComposioCatalog.Category] { catalog.categories.filter { !catalog.apps(in: $0.id).isEmpty } }
    private var appCount: [String: String] { ["count": catalog.apps.count.formatted()] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DirectoryHeader(section: .connections, query: $query,
                            search: (CopyText(CopyKey("conn.search"), appCount), "connections.search")) {
                Button { model.resetCheck(); allowed = false; adding = true } label: {
                    Label { Text(CopyKey("set.add")) } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.primary)
                .help(CopyKey("conn.mcp.add").string())
                .accessibilityLabel(Text(CopyKey("conn.mcp.add")))
                .probeID("connections.add")
            }
            .directoryHeaderPadding()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space6) { content }
                    .directoryContentPadding()
            }
            .id(search.isEmpty ? (browsing ? "all.\(category ?? "")" : "") : "search")  // a new list starts at its top
        }
        .sheet(isPresented: $adding, onDismiss: {
            // Closed without Allow (Cancel, Esc) after the check: nothing is stored, the dry session is torn down.
            if !allowed, model.pending != nil { Task { await model.decline() } }
        }) {
            AddConnectionSheet(model: model, onAllow: { p in
                allowed = true
                adding = false
                query = ""; browsing = false; category = nil  // the new row is under "Connected"
                Task { await model.confirm(p) }
            }, onCancel: { adding = false })
        }
        .sheet(item: $detail) { d in ConnectionDetailSheet(model: model, id: d.id) { detail = nil } }
        .task {
            await model.flow.refresh()
            // The connected apps are known now: one the live list dropped stays in the catalogue.
            if followsLive { catalog = .shared }
        }
        // The list of apps that exist comes from the relay: asked when the page opens with a list a day old (also
        // before any app is connected: opening this page is the user looking at connections).
        .task { if followsLive { await LiveAppCatalog.live?.refresh(userOpened: true) } }
        .onReceive(NotificationCenter.default.publisher(for: DirectoryCatalogs.didChange)) { note in
            if followsLive, note.userInfo?["kind"] as? String == LiveAppCatalog.kind { catalog = .shared }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.flow.refresh(maxAge: .seconds(5)) }
        }
    }

    // MARK: Content

    /// The linked apps by name (an app the catalogue does not list still shows, to disconnect).
    private var connected: [ComposioCatalog.App] {
        model.flow.linked.keys.map { catalog.app($0) ?? .init(slug: $0, name: ComposioApps.title($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The user's own connections; the apps' Composio connection is one only while there is no relay (to remove it).
    private var custom: [ConnectionsModel.ServerView] { available ? model.custom : model.servers }

    @ViewBuilder private var content: some View {
        Group {
            if !search.isEmpty {
                let found = catalog.search(search)
                let mine = custom.filter { $0.row.name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                if found.isEmpty, mine.isEmpty {
                    Text(CopyText(CopyKey("conn.search.none"), ["query": search]))
                        .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                        .directoryInset()
                        .probeID("connections.search.none")
                } else {
                    grid(found, custom: mine)
                }
            } else if browsing {
                VStack(alignment: .leading, spacing: Spacing.space4) {
                    DirectoryBackTitle(title: CopyKey("conn.all.title").string(), id: "connections.back") { browsing = false; category = nil }
                    DirectoryChips(categories: categories.map { ($0.id, $0.title) }, selection: $category, id: "connections.chip")
                    grid(category.map { catalog.apps(in: $0) } ?? Self.alphabetical(catalog.apps))
                }
            } else {
                overview
            }
        }
        // M9.T03: a lazy grid is an unnamed "Other" to accessibility; the rows sit in a named group.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CopyKey("conn.title")))
        .probeID("connections.composio")
    }

    @ViewBuilder private var overview: some View {
        if !available {
            Label { Text(CopyKey("conn.apps.unavailable")).fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "info.circle") }
                .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                .directoryInset()
                .probeID("connections.unavailable")
        }
        // An add that failed after Allow (the sheet is closed by then): say why here (P6 only logged it).
        if !adding, let e = model.checkError {
            Text(CopyText(CopyKey("conn.mcp.failed"), ["reason": e])).typeStyle(.callout).foregroundStyle(Color.danger)
                .fixedSize(horizontal: false, vertical: true)
                .directoryInset()
                .probeID("connections.error")
        }
        let connected = connected, custom = custom
        if !connected.isEmpty || !custom.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                DirectorySectionTitle(title: Text(CopyKey("conn.connected.title")), id: "connections.section.connected").directoryInset()
                grid(connected, custom: custom)
            }
        }
        // A catalogue of one category (the built-in eight apps) shows it whole.
        let preview = categories.count > 1 ? Self.preview : .max
        ForEach(categories) { c in
            let all = catalog.apps(in: c.id)
            VStack(alignment: .leading, spacing: Spacing.space3) {
                DirectorySectionTitle(title: Text(verbatim: c.title), id: "connections.section.\(c.id)", count: all.count,
                                      action: all.count > preview ? { category = c.id; browsing = true } : nil)
                    .directoryInset()
                grid(Array(all.prefix(preview)))
            }
        }
        if categories.count > 1 {
            DirectoryBrowseAll(title: CopyText(CopyKey("conn.browseAll"), appCount), id: "connections.browseAll") {
                category = nil; browsing = true
            }
        }
    }

    static func alphabetical(_ apps: [ComposioCatalog.App]) -> [ComposioCatalog.App] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func grid(_ apps: [ComposioCatalog.App], custom: [ConnectionsModel.ServerView] = []) -> some View {
        DirectoryGrid {
            ForEach(apps) { a in
                AppRow(app: a, phase: model.flow.phase(a.slug), canConnect: available,
                       onConnect: { Task { await model.flow.connect(a.slug) } },
                       onDisconnect: { Task { await model.flow.disconnect(a.slug) } })
            }
            ForEach(custom) { s in
                ConnectionRow(server: s, onOpen: { detail = Detail(id: s.id) },
                              onSignIn: { Task { await model.signIn(s.id) } },
                              onRemove: { Task { await model.remove(s.id) } })
            }
        }
    }
}

/// One app: its logo in a rounded square, its name, one line (what it is for; "Waiting for sign-in…"; why a connect
/// failed) and the one thing to do — `+` connects, a spinner while that runs, `⋯` on a connected app (Disconnect, also
/// the row's context menu). The phase is `ConnectFlow`'s, the one the in-chat Connect card shows.
struct AppRow: View {
    let app: ComposioCatalog.App
    let phase: ConnectFlow.Phase
    var pinnedHover: Bool?
    /// false = no relay: an app that is not connected has nothing to press.
    var canConnect = true
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    private var detail: (text: String, color: Color, id: String?) {
        switch phase {
        case .failed(let key): (CopyText(CopyKey(key), ["app": app.name]).string, .warning, "composio.error")
        case .starting, .waiting: (CopyKey("conn.waiting").string(), .textSecondary, nil)
        case .idle, .connected: (app.summary, .textSecondary, nil)
        }
    }

    var body: some View {
        let detail = detail
        DirectoryRow(title: app.name, detail: detail.text, detailColor: detail.color, detailID: detail.id,
                     tile: AppLogo.colorLogo(app.slug) == nil ? .surfaceRaised : .white, pinnedHover: pinnedHover) {
            AppLogo(toolkit: app.slug, name: app.name, size: 26, color: true)
        } trailing: {
            switch phase {
            case .idle, .failed:
                if canConnect {
                        DirectoryGlyphButton(symbol: "plus", label: "\(CopyKey("conn.connect").string()) \(app.name)",
                                         id: "connections.add.\(app.slug)", action: onConnect)
                }
            case .starting, .waiting:
                ProgressView().controlSize(.small).probeID("connections.waiting.\(app.slug)")
            case .connected:
                DirectoryMenu(label: "\(CopyKey("chat.more").string()), \(app.name)") { disconnect }
                    .probeID("connections.menu.\(app.slug)")
            }
        }
        .contextMenu { if phase == .connected { disconnect } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: app.name))
        .probeID("connections.row.\(app.slug)")
    }

    private var disconnect: some View {
        Button(role: .destructive, action: onDisconnect) { Text(CopyKey("conn.disconnect")) }
            .probeID("connections.disconnect.\(app.slug)")
    }
}
