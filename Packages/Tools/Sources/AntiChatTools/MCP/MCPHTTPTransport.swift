// M7.T06 step 1 (R-081, R-297; cross-task rule 1): MCP Streamable HTTP (spec 2025-11-25 §Transports) through the
// gate. swift-sdk's `HTTPClientTransport(configuration:)` builds its own URLSession, so its requests are gated but
// leave no `network_activity` row (the gate's recorder is a session delegate). This transport sends every request
// on `NetworkGate.session(for: .mcp)` (an incognito chat's calls on the incognito session: no row), tagged `.mcp`,
// so each POST / GET / DELETE is one ledger row. Behaviour follows the swift-sdk transport at the A-M7-02 pin
// (design reference, no code copied): POST JSON-RPC with `Accept: application/json, text/event-stream`, a JSON or SSE
// answer, `Mcp-Session-Id` from the initialize response on every later request, `MCP-Protocol-Version` = the
// negotiated version (read from the initialize result), 401/403 → the OAuth authorizer (M7.T07) or a typed error,
// 202 for notifications, an optional GET SSE stream for server notifications (`notifications/tools/list_changed`;
// 405 = the server has none), DELETE on disconnect. Legacy HTTP+SSE servers are read through the same SSE parser.
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import Logging
import MCP

/// Per-call context (TaskLocal; Client's internal tasks inherit it): an incognito chat's call leaves no row.
public enum MCPCallContext {
    @TaskLocal public static var incognito = false
}

/// Why a connection failed, as the Connections row shows it.
public enum MCPTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 401 without a usable credential: `wwwAuthenticate` is the challenge (OAuth discovery input).
    case unauthorized(status: Int, wwwAuthenticate: String?)
    case http(Int)
    case sessionExpired
    case notConnected
    case badResponse

    public var description: String {
        switch self {
        case .unauthorized(let s, _): "unauthorized (\(s))"
        case .http(let s): "HTTP \(s)"
        case .sessionExpired: "session expired"
        case .notConnected: "not connected"
        case .badResponse: "bad response"
        }
    }
}

public actor MCPHTTPTransport: Transport {
    public nonisolated let logger: Logging.Logger
    public let endpoint: URL
    private let session: URLSession
    private let incognitoSession: @Sendable () -> URLSession
    private let streaming: Bool
    /// Extra headers per request (a pasted bearer token: `Authorization: Bearer …`), read on every request.
    private let headers: @Sendable () -> [String: String]
    private let authorizer: (any HTTPClientAuthorizer)?
    /// The gate category every request is tagged with: `.mcp`, or `.relay` for the Composio relay (M7.T11).
    public nonisolated let category: NetworkCategory
    /// The policy every request is tagged with, and watched: RC review P2-6.
    public nonisolated let policy: NetworkPolicyStore

    public private(set) var sessionID: String?
    public private(set) var protocolVersion: String
    private var connected = false
    private var getTask: Task<Void, Never>?
    /// The open GET stream's data task, cancelled directly when the policy turns the category off.
    private var getDataTask: URLSessionTask?
    /// The GET stream was closed by the policy (reopened when the category is allowed again).
    private var getPausedByPolicy = false
    private var policyObserver: (any NSObjectProtocol)?
    private let stream: AsyncThrowingStream<Data, any Swift.Error>
    private let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    public init(endpoint: URL, session: URLSession = NetworkGate.session(for: .mcp),
                incognitoSession: @escaping @Sendable () -> URLSession = { MCPHTTPTransport.sharedIncognito },
                streaming: Bool = true, protocolVersion: String = Version.latest,
                headers: @escaping @Sendable () -> [String: String] = { [:] },
                authorizer: (any HTTPClientAuthorizer)? = nil, category: NetworkCategory = .mcp,
                policy: NetworkPolicyStore = .shared) {
        self.category = category
        self.policy = policy
        self.endpoint = endpoint
        self.session = session
        self.incognitoSession = incognitoSession
        self.streaming = streaming
        self.protocolVersion = protocolVersion
        self.headers = headers
        self.authorizer = authorizer
        self.logger = Logging.Logger(label: "app.antichat.mcp.http", factory: { _ in SwiftLogNoOpLogHandler() })
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    /// One incognito `.mcp` session for the process (memory-only caches; never a `network_activity` row).
    public static let sharedIncognito = NetworkGate.incognitoSession(for: .mcp)
    /// The same for the Composio relay (`.relay`, M7.T11).
    public static let sharedIncognitoRelay = NetworkGate.incognitoSession(for: .relay)

    /// The Composio relay's MCP endpoint: `.relay` sessions and tags (M7.T11; cross-task rule 1).
    public static func relay(endpoint: URL, headers: @escaping @Sendable () -> [String: String],
                             policy: NetworkPolicyStore = .shared) -> MCPHTTPTransport {
        MCPHTTPTransport(endpoint: endpoint, session: NetworkGate.session(for: .relay),
                         incognitoSession: { MCPHTTPTransport.sharedIncognitoRelay }, headers: headers, category: .relay,
                         policy: policy)
    }

    private var currentSession: URLSession { MCPCallContext.incognito ? incognitoSession() : session }

    public func connect() async throws {
        connected = true
        if policyObserver == nil {
            policyObserver = NotificationCenter.default.addObserver(forName: NetworkPolicyStore.didChange, object: policy, queue: nil) {
                [weak self] _ in
                Task { await self?.policyDidChange() }
            }
        }
    }

    /// RC review P2-6: the gate checks a request only when it starts, so the long-lived GET stream (timeout 24 h)
    /// outlived Offline only or the category being switched off. It closes as soon as the policy forbids it.
    func policyDidChange() {
        if !policy.isEnabled(category) {
            guard getTask != nil else { return }
            closeGETStream()
            getPausedByPolicy = true
        } else if getPausedByPolicy, sessionID != nil {
            getPausedByPolicy = false
            startGETStreamIfNeeded()
        }
    }

    private func closeGETStream() {
        getDataTask?.cancel()
        getDataTask = nil
        getTask?.cancel()
        getTask = nil
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        if let policyObserver { NotificationCenter.default.removeObserver(policyObserver) }
        policyObserver = nil
        getPausedByPolicy = false
        closeGETStream()
        if let sessionID {  // best effort: tell the server the session is over
            var r = request(method: "DELETE")
            r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await currentSession.data(for: NetworkGate.tag(r, category: category, policy: policy))
        }
        continuation.finish()
    }

    public func receive() -> AsyncThrowingStream<Data, any Swift.Error> { stream }

    private func request(method: String) -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = method
        r.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers() { r.setValue(v, forHTTPHeaderField: k) }
        if let auth = authorizer?.authorizationHeader(for: endpoint) { r.setValue(auth, forHTTPHeaderField: "Authorization") }
        return r
    }

    public func send(_ data: Data) async throws {
        guard connected else { throw MCPTransportError.notConnected }
        if let authorizer {
            try authorizer.validateEndpointSecurity(for: endpoint)
            try? await authorizer.prepareAuthorization(for: endpoint, session: currentSession)
        }
        let method = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["method"] as? String
        var attempts = 0
        while true {
            var r = request(method: "POST")
            r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = data
            let (bytes, response) = try await currentSession.bytes(for: NetworkGate.tag(r, category: category, policy: policy))
            guard let http = response as? HTTPURLResponse else { throw MCPTransportError.badResponse }
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), sid != sessionID {
                sessionID = sid
                startGETStreamIfNeeded()
            }
            switch http.statusCode {
            case 200..<300:
                try await deliver(bytes, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "", method: method)
                if method == "initialize", sessionID == nil { startGETStreamIfNeeded() }
                return
            case 401, 403:
                let headers = Self.headers(of: http)
                if let authorizer, attempts < authorizer.maxAuthorizationAttempts,
                   try await authorizer.handleChallenge(statusCode: http.statusCode, headers: headers, endpoint: endpoint,
                                                        operationKey: method, session: currentSession) {
                    attempts += 1
                    continue
                }
                throw MCPTransportError.unauthorized(status: http.statusCode, wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate"))
            case 404 where sessionID != nil:
                sessionID = nil
                throw MCPTransportError.sessionExpired
            case 426, 429, 503 where category == .relay:
                // Q-015 r7 (AT-255 c5-app): the relay's own refusals (`{code:"relay.rateLimited"}` + Retry-After, ...)
                // as the relay error, so the Connections page can say "Connections are busy" instead of "HTTP 429".
                var body = Data()
                for try await b in bytes { body.append(b); if body.count >= 4096 { break } }
                throw RelayClient.error(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            default:
                throw MCPTransportError.http(http.statusCode)
            }
        }
    }

    static func headers(of r: HTTPURLResponse) -> [String: String] {
        var h: [String: String] = [:]
        for (k, v) in r.allHeaderFields { if let k = k as? String, let v = v as? String { h[k] = v } }
        return h
    }

    /// A 2xx body: one JSON message (or batch), or an SSE stream of messages; 202 has none.
    private func deliver(_ bytes: URLSession.AsyncBytes, contentType: String, method: String?) async throws {
        if contentType.contains("text/event-stream") {
            var parser = SSEParser()
            for try await line in bytes.lines {
                if let event = parser.feed(line) { yieldMessage(event, initialize: method == "initialize") }
            }
            if let event = parser.finish() { yieldMessage(event, initialize: method == "initialize") }
        } else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            if !body.isEmpty { yieldMessage(body, initialize: method == "initialize") }
        }
    }

    private func yieldMessage(_ data: Data, initialize: Bool) {
        if initialize, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = (o["result"] as? [String: Any])?["protocolVersion"] as? String {
            protocolVersion = v  // later requests carry the negotiated version
        }
        continuation.yield(data)
    }

    /// The server-to-client stream (GET). Optional per spec: 405 or any failure just ends it.
    private func startGETStreamIfNeeded() {
        guard streaming, getTask == nil, connected else { return }
        guard policy.isEnabled(category) else { getPausedByPolicy = true; return }
        getTask = Task { [weak self] in await self?.runGETStream() }
    }

    private func runGETStream() async {
        var r = request(method: "GET")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 24 * 3600
        do {
            let (bytes, response) = try await currentSession.bytes(for: NetworkGate.tag(r, category: category, policy: policy))
            guard !Task.isCancelled else { bytes.task.cancel(); return }
            getDataTask = bytes.task
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") else { return }
            var parser = SSEParser()
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                if let event = parser.feed(line) { continuation.yield(event) }
            }
        } catch {
            AppLog.log(.tools, .debug, "mcp GET stream ended: \(error)")
        }
    }
}

/// Server-sent events (WHATWG): `data:` lines join with "\n" until a blank line; only `message` events (or unnamed)
/// carry JSON-RPC. `bytes.lines` drops blank lines, so an event also ends when the next `id:`/`event:` or a new
/// `data:` after a complete JSON value arrives.
struct SSEParser {
    private var data: [String] = []
    private var event = "message"

    mutating func feed(_ line: String) -> Data? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let (field, value) = Self.split(line)
        switch field {
        case "data":
            // `lines` swallowed the blank separator: a new data line after a complete JSON value starts a new event.
            if !data.isEmpty, Self.isCompleteJSON(data.joined(separator: "\n")) {
                let out = flush()
                data = [value]
                return out
            }
            data.append(value)
            if Self.isCompleteJSON(data.joined(separator: "\n")) { return flush() }
        case "event":
            let out = data.isEmpty ? nil : flush()
            event = value.isEmpty ? "message" : value
            return out
        default:
            break
        }
        return nil
    }

    mutating func finish() -> Data? { data.isEmpty ? nil : flush() }

    private mutating func flush() -> Data? {
        defer { data = []; event = "message" }
        guard !data.isEmpty, event == "message" else { return nil }
        let text = data.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Data(text.utf8)
    }

    static func split(_ line: String) -> (String, String) {
        guard let i = line.firstIndex(of: ":") else { return (line, "") }
        var v = line[line.index(after: i)...]
        if v.first == " " { v = v.dropFirst() }
        return (String(line[..<i]), String(v))
    }

    static func isCompleteJSON(_ s: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) != nil
    }
}
