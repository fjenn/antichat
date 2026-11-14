// M7.T06 step 4 (R-081): the Connections page's state over the app's MCPHost (MCPTools.host) and its rows. Reloads on
// every `MCPHost.didChange`. Add flow: `check` (dry `tools/list` via MCPHost.preview) → consent sheet → `confirm`
// (row + Keychain token + tools) or `decline` (nothing stored). Per-tool permissions are `tool_permission` rows
// `mcp:<server>:<tool>` (Always allow / Ask / Block); a stored row replaces the tool's default.
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Foundation
import Observation

@MainActor
@Observable
final class ConnectionsModel {
    struct ServerView: Identifiable, Equatable {
        var row: MCPServerRecord
        var tools: [MCPToolRecord]
        var id: String { row.id }
    }

    /// The pending add, between the dry run and the user's answer on the consent sheet.
    struct Pending: Equatable, Identifiable {
        var name: String
        var url: URL
        var auth: MCPAuthInput
        var curatedID: String?
        var preview: MCPPreview
        var id: String { url.absoluteString }
    }

    private(set) var servers: [ServerView] = []
    var pending: Pending?
    private(set) var checking = false
    var checkError: String?
    /// The OAuth server offers neither CIMD nor DCR: the add sheet shows `conn.mcp.clientId`.
    private(set) var needsClientID = false
    @ObservationIgnored private var token: NSObjectProtocol?
    let host: MCPHost?

    init(host: MCPHost? = MCPTools.host) {
        self.host = host
        reload()
        token = NotificationCenter.default.addObserver(forName: MCPHost.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var repository: MCPRepository? { host?.repository }
    var curated: [MCPCuratedEntry] { MCPCurated.Store.shared.entries() }

    func reload() {
        guard let repo = repository else { servers = []; return }
        servers = ((try? repo.servers()) ?? []).map { ServerView(row: $0, tools: (try? repo.tools(server: $0.id)) ?? []) }
    }

    /// Step 1 of adding: the dry run (the consent sheet opens on success).
    /// M9.T08: the `{reason}` of `conn.mcp.failed` — the system's sentence for a network error ("A server with the
    /// specified hostname could not be found."), not the NSError dump with its userInfo (filled the add sheet in red).
    static func reason(_ error: Error) -> String {
        if error is LocalizedError || (error as NSError).domain == NSURLErrorDomain {
            return error.localizedDescription
        }
        return "\(error)"
    }

    func check(name: String, url: String, auth: MCPAuthInput, curatedID: String? = nil) async {
        guard let host, let u = URL(string: url.trimmingCharacters(in: .whitespaces)), ["https", "http"].contains(u.scheme ?? "") else {
            checkError = "URL"
            return
        }
        checking = true
        checkError = nil
        defer { checking = false }
        do {
            let p = try await host.preview(url: u, auth: auth)
            needsClientID = false
            pending = Pending(name: name.isEmpty ? (u.host() ?? url) : name, url: u, auth: auth, curatedID: curatedID, preview: p)
        } catch {
            checkError = Self.reason(error)
            if let e = error as? MCPOAuthError, e == .needsClientID { needsClientID = true }
            await host.declined()
        }
    }

    /// `p` is the request the consent sheet showed: the sheet dismisses itself (clearing `pending`) before this Task
    /// runs, so reading `pending` here found nil and Allow added nothing (Q-015 r2).
    func confirm(_ shown: Pending? = nil) async {
        guard let host, let p = shown ?? pending else { return }
        pending = nil
        do {
            _ = try await host.add(name: p.name, url: p.url, auth: p.auth, curatedID: p.curatedID, preview: p.preview)
        } catch {
            // Allow used to fail silently (`try?`): nothing was added and nothing said why (Q-015 XCUITest catch-up).
            checkError = Self.reason(error)
            AppLog.log(.tools, .error, "MCP add failed: \(error)")
        }
        reload()
    }

    func decline() async {
        pending = nil
        await host?.declined()
    }

    // MARK: Composio (M7.T11)

    /// Apps the relay offers (the default list until it answered) and the linked ones (toolkit → connection id).
    private(set) var composioTiles: [String] = ComposioTiles.defaults
    private(set) var composioLinked: [String: String] = [:]
    /// The tile waiting for its browser sign-in; the copy key of the last relay error (`relay.*`).
    private(set) var composioWaiting: String?
    private(set) var composioError: String?
    /// The tile whose consent sheet is open (first Composio use only).
    var composioConsent: ComposioConsentItem?
    struct ComposioConsentItem: Identifiable, Equatable { var toolkit: String; var id: String { toolkit } }
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    /// No deployed relay (empty RelayURL, as in release 1) → no Composio tiles and no connect flow (an existing row still shows, to remove).
    let composioAvailable = RelayClient.isAvailable()
    var composio: ComposioConnection? { composioAvailable ? host.map { ComposioConnection(host: $0) } : nil }
    var hasComposio: Bool { servers.contains { $0.row.kind == .composio } }

    /// The relay's list (only once the Composio row exists: no install ID and no request before the user's first use).
    func refreshComposio() async {
        guard hasComposio, let c = composio else { return }
        do {
            let r = try await c.connections()
            let offered = r.toolkits.filter { $0 != "*" }
            composioTiles = offered.isEmpty ? ComposioTiles.defaults : offered
            composioLinked = Dictionary(r.connections.filter(\.isActive).map { ($0.toolkit, $0.id) }, uniquingKeysWith: { a, _ in a })
            composioError = nil
        } catch {
            composioError = Self.relayKey(error)
        }
    }

    /// Step 1, [Connect] on a tile: the consent sheet the first time, else straight to the browser.
    func connectTile(_ toolkit: String) {
        guard composioAvailable else { return }
        if hasComposio { Task { await beginComposio(toolkit) } } else { composioConsent = ComposioConsentItem(toolkit: toolkit) }
    }

    /// Step 2 ([Continue]) → step 3 (the browser): row + session, the sign-in link, then polling until it is linked.
    func beginComposio(_ toolkit: String) async {
        guard let c = composio else { return }
        composioError = nil
        do {
            let url = try await c.begin(toolkit: toolkit)
            openURL(url)
            composioWaiting = toolkit
            waitTask?.cancel()
            waitTask = Task { [weak self] in
                let ok = (try? await c.waitConnected(toolkit: toolkit)) ?? false
                guard let self, !Task.isCancelled else { return }
                composioWaiting = nil
                if ok { await refreshComposio() }
            }
        } catch {
            composioError = Self.relayKey(error)
        }
        reload()
    }

    func disconnectTile(_ toolkit: String) async {
        guard let c = composio, let id = composioLinked[toolkit] else { return }
        do { try await c.disconnect(id) } catch { composioError = Self.relayKey(error) }
        await refreshComposio()
    }

    /// The copy key for a relay failure (`relay.*`), or the generic connection error.
    static func relayKey(_ error: any Error) -> String {
        if let e = error as? AntiChatError, e.domain == .relay { return e.userMessageKey }
        return "conn.state.error"
    }

    func setEnabled(_ id: String, _ on: Bool) async { await host?.setEnabled(id, on) }
    func remove(_ id: String) async { await host?.remove(id) }
    /// [Sign in again] (M7.T07 step 6).
    func signIn(_ id: String) async { await host?.signIn(id) }

    func setToolEnabled(_ server: String, _ tool: String, _ on: Bool) {
        try? repository?.setToolEnabled(server: server, tool: tool, enabled: on)
        NotificationCenter.default.post(name: MCPHost.didChange, object: nil)
    }

    // MARK: Tool change review (M7.T08)

    func diff(_ id: String) -> ToolChangeDiff {
        guard let db = repository?.database else { return ToolChangeDiff() }
        return (try? ToolHashReview.diff(server: id, database: db)) ?? ToolChangeDiff()
    }

    func accept(_ id: String) {
        guard let db = repository?.database else { return }
        try? ToolHashReview.accept(server: id, database: db)
        NotificationCenter.default.post(name: MCPHost.didChange, object: nil)
    }

    // MARK: Permissions

    func permissions() -> ToolPermissionStore? { repository.map { ToolPermissionStore($0.database) } }

    /// The effective policy shown in the picker: the stored row, else the tool's default.
    func policy(_ t: MCPToolRecord, server: MCPServerRecord) -> ToolPermissionRecord.Policy {
        if let p = (try? permissions()?.policy(toolKey: t.permissionKey, chatID: nil)) ?? nil { return p }
        return ToolAnnotations(json: t.annotationsJSON).defaultPolicy(toolName: t.name,
                                                                       curatedVerified: MCPCurated.Store.shared.isVerified(server))
    }

    func setPolicy(_ p: ToolPermissionRecord.Policy, _ t: MCPToolRecord) {
        try? permissions()?.set(p, toolKey: t.permissionKey)
        NotificationCenter.default.post(name: MCPHost.didChange, object: nil)
    }
}
