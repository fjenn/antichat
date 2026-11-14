// M7.T06 (R-081, R-258; G-030): owns the app's MCP connections. Nothing connects until the user adds a server
// (R-081 AC1): at launch `resume()` reconnects only enabled `mcp_server` rows, so a fresh container makes zero
// `.mcp` requests. Adding is two steps: `preview` (a dry initialize + `tools/list`, torn down again; the consent
// sheet lists the tools, NFR-SEC4) and, after consent, `add` (row + Keychain token + tool rows + live session).
// Tool lists are stored in `mcp_tool` with their digest; `notifications/tools/list_changed` re-lists, and the review
// (ToolHashReview, M7.T08) decides what the user must look at again. Every request goes through MCPHTTPTransport
// (`.mcp`, one ledger row each). Observers (`didChange`) hear about every row change (registry, Connections page).
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import MCP

/// A connection's auth as the add form collects it.
public enum MCPAuthInput: Sendable, Equatable {
    case none
    case token(String)
    /// OAuth 2.1 (M7.T07): CIMD → DCR automatically.
    case oauth
    /// OAuth with a client ID the user pasted (`conn.mcp.clientId`, after CIMD and DCR were both unavailable).
    case oauthClientID(String)

    public var isOAuth: Bool {
        switch self {
        case .oauth, .oauthClientID: true
        default: false
        }
    }
}

/// How OAuth sign-ins run: the settings (CIMD URL, redirect) and the presenter (browser sheet; DEBUG headless).
public struct MCPOAuthEnvironment: Sendable {
    public var settings: MCPOAuthSettings
    public var presenter: any MCPAuthPresenter
    public init(settings: MCPOAuthSettings = MCPOAuthSettings(), presenter: any MCPAuthPresenter = WebAuthPresenter()) {
        self.settings = settings
        self.presenter = presenter
    }

    /// The app's: the browser sheet; `-OAuthHeadless YES` (DEBUG) signs in without one, loopback AS allowed.
    public static var app: MCPOAuthEnvironment {
        #if DEBUG  // Debug builds accept a loopback-http AS (the local reference AS, `tools/mcp-ref`)
        let settings = MCPOAuthSettings(allowLoopbackHTTP: true)
        return MCPOAuthEnvironment(settings: settings,
                                   presenter: LaunchOptions.current.oauthHeadless ? HeadlessAuthPresenter() : WebAuthPresenter())
        #else
        return MCPOAuthEnvironment()
        #endif
    }
}

/// The consent sheet's input: what the dry run found.
public struct MCPPreview: Sendable, Equatable {
    public var url: URL
    public var protocolVersion: String
    public var serverInfo: String
    public var tools: [MCPListedTool]
}

public actor MCPHost {
    public static let didChange = Notification.Name("app.antichat.mcp.didChange")
    /// Builds the transport for a server URL + per-request headers (+ the server id; nil for a preview).
    public typealias TransportFactory = @Sendable (_ url: URL, _ headers: @escaping @Sendable () -> [String: String], _ serverID: String?,
                                                   _ authorizer: (any HTTPClientAuthorizer)?) -> any Transport

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// `-ScriptedMCP <file>` / tests: every connection answers from the recorded session (a fresh server each time).
    public static func scriptedFactory(jsonl: String) -> TransportFactory { { _, _, _, _ in ScriptedMCPTransport(jsonl: jsonl) } }
    #endif

    public nonisolated let repository: MCPRepository
    let secrets: any MCPSecretStore
    /// Builds the transport for a server URL + headers (tests: a scripted transport).
    let makeTransport: TransportFactory
    /// M7.T11: the Composio relay's transport (`.relay`; tests: scripted). Gets the relay MCP URL + §8.2 headers.
    public typealias RelayTransportFactory = @Sendable (_ url: URL, _ headers: @escaping @Sendable () -> [String: String]) -> any Transport
    let makeRelayTransport: RelayTransportFactory
    private var connections: [String: MCPConnection] = [:]
    private let now: @Sendable () -> Date
    /// The `.mcp` category is off on a fresh container (R-209 AC3) and turned on by the user's first add.
    let policy: NetworkPolicyStore
    let oauth: MCPOAuthEnvironment
    /// OAuth records signed in during a preview (keyed by URL), moved into the Keychain by `add`. Memory only.
    private var previewOAuth: [String: MCPOAuthRecord] = [:]
    /// The live authorizer per server (tests read the PKCE method).
    public private(set) var authorizers: [String: MCPOAuthAuthorizer] = [:]

    public init(database: AppDatabase, secrets: any MCPSecretStore = KeychainSecrets(),
                makeTransport: TransportFactory? = nil, policy: NetworkPolicyStore = .shared,
                oauth: MCPOAuthEnvironment = .app, now: @escaping @Sendable () -> Date = { Date() },
                makeRelayTransport: RelayTransportFactory? = nil) {
        self.policy = policy
        self.makeRelayTransport = makeRelayTransport ?? { url, headers in MCPHTTPTransport.relay(endpoint: url, headers: headers, policy: policy) }
        self.repository = MCPRepository(database)
        self.secrets = secrets
        self.makeTransport = makeTransport ?? { url, headers, _, authorizer in
            MCPHTTPTransport(endpoint: url, headers: headers, authorizer: authorizer, policy: policy)
        }
        self.oauth = oauth
        self.now = now
    }

    func oauthStore(_ id: String) -> KeychainTokenStorage { KeychainTokenStorage(serverID: id, secrets: secrets) }

    // MARK: Adding

    static func headers(for auth: MCPAuthInput) -> @Sendable () -> [String: String] {
        switch auth {
        case .token(let t): { ["Authorization": "Bearer \(t)"] }
        case .none, .oauth, .oauthClientID: { [:] }
        }
    }

    /// Dry run for the consent sheet: initialize + `tools/list`, then the session is torn down (declining leaves
    /// nothing behind: no row, no token).
    public func preview(url: URL, auth: MCPAuthInput) async throws -> MCPPreview {
        if !policy.storedValue(.mcp) { policy.setEnabled(.mcp, true) }  // the user is adding a connection
        var authorizer: MCPOAuthAuthorizer?
        if auth.isOAuth {  // the sign-in happens here, interactively; the tokens wait in memory for `add`
            var pasted: String?
            if case .oauthClientID(let p) = auth { pasted = p }
            authorizer = MCPOAuthAuthorizer(settings: oauth.settings, store: MemoryOAuthStore(), presenter: oauth.presenter,
                                            pastedClientID: pasted, interactive: true)
        }
        let c = MCPConnection(serverID: "preview", transport: makeTransport(url, Self.headers(for: auth), nil, authorizer))
        do {
            let v = try await c.open()
            let tools = try await c.listTools()
            let info = await c.serverInfo ?? url.host() ?? ""
            await c.close()
            if let authorizer { previewOAuth[url.absoluteString] = authorizer.store.loadRecord() }
            return MCPPreview(url: url, protocolVersion: v, serverInfo: info, tools: tools)
        } catch {
            await c.close()
            throw error
        }
    }

    /// After consent: stores the row (and the token in the Keychain), the tools as reviewed, and connects.
    @discardableResult
    public func add(name: String, url: URL, auth: MCPAuthInput, curatedID: String? = nil,
                    preview: MCPPreview? = nil) async throws -> MCPServerRecord {
        if !policy.storedValue(.mcp) { policy.setEnabled(.mcp, true) }  // the user added a connection
        let id = UUID().uuidString.lowercased()
        var authRef: String?
        let kind: MCPServerRecord.AuthKind
        switch auth {
        case .none: kind = .none
        case .oauth, .oauthClientID:
            kind = .oauth
            authRef = KeychainTokenStorage.service
            var r = previewOAuth.removeValue(forKey: url.absoluteString) ?? MCPOAuthRecord()
            if case .oauthClientID(let p) = auth, r.identity == nil { r.identity = .pasted(p) }
            oauthStore(id).saveRecord(r)
        case .token(let t):
            kind = .token
            let service = MCPSecretNames.tokenService(id)
            try secrets.write(t, service: service, account: MCPSecretNames.tokenAccount)
            authRef = service
        }
        let t = now()
        let row = MCPServerRecord(id: id, name: name, urlOrCmd: url.absoluteString, authKind: kind, authRef: authRef,
                                  curatedID: curatedID, protocolVersion: preview?.protocolVersion, state: .connecting,
                                  createdAt: t, updatedAt: t)
        try repository.save(row)
        if let preview { try store(tools: preview.tools, server: id, accept: true) }
        notify()
        await connect(id, acceptListed: preview == nil, interactive: true)
        return try repository.server(id) ?? row
    }

    /// The consent sheet was declined: with no connection left, `.mcp` goes back off.
    public func declined() {
        previewOAuth = [:]
        disableCategoryIfUnused()
    }

    func disableCategoryIfUnused() {
        let rows = (try? repository.servers()) ?? []
        if !rows.contains(where: { $0.kind != .composio }), policy.storedValue(.mcp) { policy.setEnabled(.mcp, false) }
        if !rows.contains(where: { $0.kind == .composio }), policy.storedValue(.relay) { policy.setEnabled(.relay, false) }
    }

    // MARK: Composio (M7.T11)

    /// The Composio row, if the user added it.
    public func composioServer() -> MCPServerRecord? { ((try? repository.servers()) ?? []).first { $0.kind == .composio } }

    /// After the Composio consent sheet: turns `.relay` on (the user's action), creates the relay session (this
    /// creates the install ID: first Connections use, R-255 AC2), stores the row (`kind = composio`, URL = the relay's
    /// `/v1/mcp`, no secret: the relay holds the Composio key) and connects. A relay error (e.g. `relay.notConfigured`
    /// with the stub key) leaves no row and turns `.relay` back off.
    @discardableResult
    public func addComposio(relay: RelayClient) async throws -> MCPServerRecord {
        if let row = composioServer() { await connect(row.id, interactive: true); return try repository.server(row.id) ?? row }
        if !policy.storedValue(.relay) { policy.setEnabled(.relay, true) }
        do { try await relay.createSession() } catch {
            disableCategoryIfUnused()
            throw error
        }
        let t = now()
        let row = MCPServerRecord(id: UUID().uuidString.lowercased(), kind: .composio, name: "Composio",
                                  urlOrCmd: relay.mcpURL.absoluteString, state: .connecting, createdAt: t, updatedAt: t)
        try repository.save(row)
        notify()
        await connect(row.id, acceptListed: true, interactive: true)
        return try repository.server(row.id) ?? row
    }

    // MARK: Sessions

    func headers(for row: MCPServerRecord) -> @Sendable () -> [String: String] {
        if row.kind == .composio {  // §8.2: the install ID (only read here; `addComposio` created it)
            let id = InstallID(secrets: secrets), v = RelayClient.appVersion
            return { id.existing.map { ["X-AntiChat-Install": $0, "X-AntiChat-Version": v, "User-Agent": "AntiChat/\(v)"] } ?? [:] }
        }
        guard row.authKind == .token, let ref = row.authRef else { return { [:] } }
        let secrets = secrets
        return { secrets.read(service: ref, account: MCPSecretNames.tokenAccount).map { ["Authorization": "Bearer \($0)"] } ?? [:] }
    }

    /// Opens (or re-opens) the session of server `id` and refreshes its tools. Errors land on the row. Only an
    /// `interactive` connect (the user added the server or pressed Sign in again) may open the OAuth sign-in.
    public func connect(_ id: String, acceptListed: Bool = false, interactive: Bool = false) async {
        guard let row = try? repository.server(id), let url = URL(string: row.urlOrCmd), row.enabled else { return }
        if let old = connections.removeValue(forKey: id) { await old.close() }
        setState(id, .connecting, error: nil)
        var authorizer: MCPOAuthAuthorizer?
        if row.authKind == .oauth {
            let identity = oauthStore(id).loadRecord().identity
            var pasted: String?
            if case .pasted(let p) = identity { pasted = p }
            authorizer = MCPOAuthAuthorizer(settings: oauth.settings, store: oauthStore(id), presenter: oauth.presenter,
                                            pastedClientID: pasted, interactive: interactive)
            authorizers[id] = authorizer
        }
        let transport = row.kind == .composio ? makeRelayTransport(url, headers(for: row))
            : makeTransport(url, headers(for: row), id, authorizer)
        let c = MCPConnection(serverID: id, transport: transport)
        await c.setOnToolsChanged { [weak self] in await self?.refreshTools(id) }
        do {
            let v = try await c.open()
            connections[id] = c
            try? repository.update(id) { $0.protocolVersion = v }
            let tools = try await c.listTools()
            try store(tools: tools, server: id, accept: acceptListed)
            setState(id, .connected, error: nil)
        } catch {
            await c.close()
            connections[id] = nil
            setState(id, Self.state(for: error), error: Self.code(for: error))
        }
        authorizer?.setInteractive(false)  // later 401s (expired refresh) end in "needs re-auth", not a browser
    }

    /// [Sign in again] on a row that needs re-auth (step 6).
    public func signIn(_ id: String) async { await connect(id, interactive: true) }

    static func state(for error: any Error) -> MCPServerRecord.State {
        if case MCPTransportError.unauthorized = error { return .needsReauth }
        if let e = oauthError(error) { return e == .needsClientID ? .error : .needsReauth }
        return .error
    }

    static func code(for error: any Error) -> String {
        switch error {
        case MCPTransportError.unauthorized: "mcp.authExpired"
        case let e as AntiChatError where e.domain == .relay: e.userMessageKey  // `relay.*` (Q-015 r7)
        case _ where oauthError(error) != nil: oauthError(error)!.code
        case let e as MCPConnectionError: "\(e)"
        case let e as MCPTransportError: "\(e)"
        default: "\(error)"
        }
    }

    /// An OAuth failure, also when the MCP client wrapped it.
    static func oauthError(_ error: any Error) -> MCPOAuthError? {
        if let e = error as? MCPOAuthError { return e }
        return nil
    }

    /// `notifications/tools/list_changed` (or the daily / manual refresh): re-list and store.
    public func refreshTools(_ id: String) async {
        guard let c = connections[id] else { return }
        do {
            try store(tools: try await c.listTools(), server: id, accept: false)
        } catch {
            setState(id, Self.state(for: error), error: Self.code(for: error))
        }
    }

    /// Launch: reconnect the enabled servers the user added (none on a fresh container: zero requests).
    public func resume() async {
        for s in (try? repository.servers()) ?? [] where s.enabled { await connect(s.id) }
    }

    public func setEnabled(_ id: String, _ on: Bool) async {
        try? repository.update(id) { $0.enabled = on; if !on { $0.state = .notConnected } }
        if on { await connect(id) } else if let c = connections.removeValue(forKey: id) { await c.close() }
        notify()
    }

    /// Removes the server: session, row, tools, permission rows and its Keychain token.
    public func remove(_ id: String) async {
        if let c = connections.removeValue(forKey: id) { await c.close() }
        if let row = try? repository.server(id), row.authKind == .token, let ref = row.authRef {
            secrets.delete(service: ref, account: MCPSecretNames.tokenAccount)
        }
        if let row = try? repository.server(id), row.authKind == .oauth { oauthStore(id).deleteAll() }
        authorizers[id] = nil
        try? repository.delete(id)
        disableCategoryIfUnused()
        notify()
    }

    public func isConnected(_ id: String) -> Bool { connections[id] != nil }

    /// One `tools/call`. Reconnects once when the session expired.
    public func call(server id: String, tool: String, argumentsJSON: String) async throws -> MCPCallResult {
        if connections[id] == nil { await connect(id) }
        guard let c = connections[id] else { throw MCPTransportError.notConnected }
        do {
            return try await c.call(tool, argumentsJSON: argumentsJSON)
        } catch MCPTransportError.sessionExpired {
            await connect(id)
            guard let c2 = connections[id] else { throw MCPTransportError.notConnected }
            return try await c2.call(tool, argumentsJSON: argumentsJSON)
        }
    }

    // MARK: Rows

    private func setState(_ id: String, _ s: MCPServerRecord.State, error: String?) {
        try? repository.update(id) { $0.state = s; $0.errorCode = error }
        notify()
    }

    /// Stores a `tools/list` result (ToolHashReview.apply decides what changed; `accept` = the user just consented
    /// to exactly this list).
    func store(tools: [MCPListedTool], server id: String, accept: Bool) throws {
        try ToolHashReview.apply(listed: tools, server: id, database: repository.database, accept: accept, now: now())
        notify()
    }

    nonisolated func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func closeAll() async {
        for (_, c) in connections { await c.close() }
        connections = [:]
    }
}
