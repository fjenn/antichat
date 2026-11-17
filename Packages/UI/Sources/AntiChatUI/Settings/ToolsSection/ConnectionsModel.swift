// M7.T06 step 4 (R-081): the Connections page's state over the app's MCPHost (MCPTools.host) and its rows. Reloads on
// every `MCPHost.didChange`. Apps (Composio, M7.T11) are `ConnectFlow.shared`'s: the page reads them from `flow`.
// Custom connections: `check` (dry `tools/list` via MCPHost.preview) → the consent step of the add sheet → `confirm`
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
    /// The server refused a check made without a sign-in: the add sheet opens its sign-in choices and says so.
    private(set) var needsAuth = false
    @ObservationIgnored private var token: NSObjectProtocol?
    @ObservationIgnored private let fixed: [ServerView]?
    let host: MCPHost?

    /// `servers`: a fixed list to draw (snapshots), never reloaded.
    init(host: MCPHost? = MCPTools.host, flow: ConnectFlow = .shared, servers: [ServerView]? = nil) {
        self.host = host
        self.flow = flow
        fixed = servers
        reload()
        token = NotificationCenter.default.addObserver(forName: MCPHost.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var repository: MCPRepository? { host?.repository }

    /// The connections the user added by address (the apps' own Composio connection is not one of them).
    var custom: [ServerView] { servers.filter { $0.row.kind != .composio } }

    func reload() {
        if let fixed { servers = fixed; return }
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

    /// The address as typed, as a URL: "example.com/mcp" means https; nil for anything that is not a web address
    /// (the add sheet then says so under the field).
    nonisolated static func address(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        guard let u = URL(string: t.contains("://") ? t : "https://\(t)"), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host(), host.contains(".") || host == "localhost" || host.contains(":"), !host.hasSuffix(".") else { return nil }
        return u
    }

    /// A new add sheet starts clean.
    func resetCheck() {
        checkError = nil
        needsAuth = false
        needsClientID = false
    }

    func check(name: String, url: String, auth: MCPAuthInput, curatedID: String? = nil) async {
        guard let host, let u = Self.address(url) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        checkError = nil
        needsAuth = false
        defer { checking = false }
        do {
            let p = try await host.preview(url: u, auth: auth)
            needsClientID = false
            pending = Pending(name: name.isEmpty ? (u.host() ?? url) : name, url: u, auth: auth, curatedID: curatedID, preview: p)
        } catch {
            if case MCPTransportError.unauthorized = error, auth == .none {
                needsAuth = true  // not a failure to show in red: the sheet asks how to sign in
            } else {
                checkError = Self.reason(error)
            }
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

    // MARK: Apps (Composio, M7.T11): a view over `ConnectFlow.shared`, the state the in-chat Connect card reads too

    @ObservationIgnored let flow: ConnectFlow
    /// No deployed relay (empty RelayURL) → no apps and no connect flow (an existing row still shows, to remove).
    var composioAvailable: Bool { flow.isAvailable }

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
