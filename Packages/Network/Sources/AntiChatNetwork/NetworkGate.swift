// The outbound gate (architecture.md §3 rule 5; M0.T14 minimal version, M2.T02 full: R-297, G-056, P-platform-08).
// The only place that creates a URLSession. Every session carries the category's GateURLProtocol (deny mode:
// disabled categories fail in-process with `network.blockedByOfflineOnly`) and, where the gate owns the delegate,
// records one `NetworkEvent` per finished task (the `network_activity` rows and the turn's globe chip, M2.T03).
// The ObjC swizzle (GateObjC) is deferred to M11 (D-026, B1): InjectionCoverageTests prove every dependency's
// session comes from here or from its package hook.
import Foundation
import AntiChatFoundation

/// One finished (or refused) request, as the Network activity list and the turn ledger see it.
public struct NetworkEvent: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable { case ok, httpError, failed, blocked }
    public var ts: Date
    public var category: NetworkCategory
    public var host: String
    /// Request + response bytes on the wire (from URLSessionTaskMetrics); 0 when blocked.
    public var bytes: Int64
    public var outcome: Outcome
    public var status: Int?
    /// The turn that started the request (`TurnContext.requestID` when the request was tagged), if any.
    public var turnID: String?
    /// Incognito events are delivered to the turn ledger only, never persisted (architecture §5.1).
    public var incognito: Bool

    public init(ts: Date = Date(), category: NetworkCategory, host: String, bytes: Int64, outcome: Outcome,
                status: Int? = nil, turnID: String? = nil, incognito: Bool) {
        self.ts = ts; self.category = category; self.host = host; self.bytes = bytes; self.outcome = outcome
        self.status = status; self.turnID = turnID; self.incognito = incognito
    }
}

public enum NetworkGate {
    // MARK: Sessions

    /// Shared session for `category` (never invalidated; replaces `URLSession.shared`). Its delegate is the gate's
    /// recorder, so every task on it produces a `NetworkEvent`.
    public static func session(for category: NetworkCategory) -> URLSession {
        shared.session(for: category)
    }

    /// A new session for `category` with `delegate`. `configuration` (nil = the gate default) gets the gate's
    /// policy applied; the caller owns the session and invalidates it. The caller's delegate is wrapped so the gate
    /// still sees task metrics (every other delegate message is forwarded unchanged).
    public static func session(
        for category: NetworkCategory,
        configuration: URLSessionConfiguration? = nil,
        delegate: (any URLSessionDelegate)?
    ) -> URLSession {
        let recorder = Recorder(category: category, incognito: false, inner: delegate)
        return URLSession(configuration: apply(configuration ?? defaultConfiguration(), category: category),
                          delegate: recorder, delegateQueue: nil)
    }

    /// A tagging wrapper (`ac.category`, `ac.policy`, `ac.turn` on every request) over `session(for:)`.
    public static func gated(_ category: NetworkCategory, policy: NetworkPolicyStore = .shared) -> GatedSession {
        GatedSession(session: session(for: category), category: category, policy: policy)
    }

    /// A gated configuration for a dependency that builds its own session from a configuration (EventSource,
    /// swift-sdk `HTTPClientTransport(configuration:)`): the category's protocol class tags every task.
    public static func configuration(for category: NetworkCategory) -> URLSessionConfiguration {
        apply(defaultConfiguration(), category: category)
    }

    /// The gate's default configuration: no cookies, no credential storage, no URL cache on disk.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        return c
    }

    /// M1.T20 (P-shell-14, IncognitoGuards guard 6): an incognito chat's configuration: `.ephemeral` (no cookie,
    /// credential or cache store on disk) with an explicit memory-only `URLCache` (disk capacity 0). Requests made
    /// with it never write a `network_activity` row.
    public static func incognitoConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        return c
    }

    /// A session for an incognito chat (`incognitoConfiguration`); the caller owns and invalidates it.
    public static func incognitoSession(for category: NetworkCategory, delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        let recorder = Recorder(category: category, incognito: true, inner: delegate)
        return URLSession(configuration: apply(incognitoConfiguration(), category: category, incognito: true), delegate: recorder,
                          delegateQueue: nil)
    }

    /// Whether a request may be recorded in `network_activity` (architecture §5.1: never for incognito).
    public static func recordsActivity(incognito: Bool) -> Bool { !incognito }

    /// Gate policy: the category's deny-mode protocol first, a User-Agent, and (DEBUG `-TestProxy`) the proxy.
    static func apply(_ configuration: URLSessionConfiguration, category: NetworkCategory = .other,
                      incognito: Bool = false) -> URLSessionConfiguration {
        configuration.protocolClasses = [GateURLProtocol.protocolClass(for: category, incognito: incognito)] + (configuration.protocolClasses ?? [])
            .filter { !($0 is GateURLProtocol.Type) }
        var headers = configuration.httpAdditionalHeaders ?? [:]
        if headers["User-Agent"] == nil { headers["User-Agent"] = userAgent }
        configuration.httpAdditionalHeaders = headers
        if let proxy = testProxy { configuration.connectionProxyDictionary = proxy }
        return configuration
    }

    static let userAgent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "AntiChat/\(v)"
    }()

    /// DEBUG `-TestProxy host:port` (M2.T03 proxy-logger destinations test): every gated session goes through it.
    nonisolated(unsafe) public static var testProxy: [AnyHashable: Any]?

    // MARK: Tagging

    /// `request` with the gate's in-process properties (never on the wire): category, policy store, turn.
    public static func tag(_ request: URLRequest, category: NetworkCategory, policy: NetworkPolicyStore = .shared) -> URLRequest {
        let m = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(category.rawValue, forKey: GateURLProtocol.categoryKey, in: m)
        URLProtocol.setProperty(policy.id, forKey: GateURLProtocol.policyKey, in: m)
        if let t = TurnContext.requestID { URLProtocol.setProperty(t, forKey: GateURLProtocol.turnKey, in: m) }
        return m as URLRequest
    }

    // MARK: Errors

    static let errorDomain = "app.antichat.network.gate"

    static func blockedError(_ c: NetworkCategory) -> NSError {
        NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "blocked: \(c.rawValue)", "category": c.rawValue])
    }

    /// `network.blockedByOfflineOnly` (copy key; recovery: open Privacy & Data).
    public static func blocked(_ c: NetworkCategory) -> AntiChatError {
        AntiChatError(domain: .network, code: "blockedByOfflineOnly", userMessageKey: "network.blockedByOfflineOnly",
                      recovery: [.openSettings(path: "privacy")], detail: c.rawValue)
    }

    /// Maps a URLSession error to the gate's typed error when the gate refused the request.
    public static func map(_ error: any Error) -> AntiChatError? {
        var e: NSError? = error as NSError
        while let n = e {
            if n.domain == errorDomain, n.code == 1 {
                return blocked(NetworkCategory(rawValue: n.userInfo["category"] as? String ?? "") ?? .other)
            }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    // MARK: Events

    /// Every event (persisting sink: the `network_activity` writer, installed at the composition root).
    nonisolated(unsafe) public static var activitySink: (@Sendable (NetworkEvent) -> Void)?
    private static let observers = Observers()

    /// Subscribe to events (the turn ledger, tests). Returns a token; pass it to `removeObserver`.
    @discardableResult
    public static func addObserver(_ f: @escaping @Sendable (NetworkEvent) -> Void) -> UUID { observers.add(f) }
    public static func removeObserver(_ id: UUID) { observers.remove(id) }

    static func emit(_ e: NetworkEvent) {
        if recordsActivity(incognito: e.incognito) { activitySink?(e) }
        observers.send(e)
    }

    static func record(_ metrics: URLSessionTaskMetrics, task: URLSessionTask, category: NetworkCategory, incognito: Bool) {
        let req = task.originalRequest
        let cat = req.map { GateURLProtocol.category(of: $0, session: category) } ?? category
        let turn = req.flatMap { URLProtocol.property(forKey: GateURLProtocol.turnKey, in: $0) as? String }
        if let e = task.error, map(e) != nil { return }  // already emitted as `.blocked` by GateURLProtocol
        // One row per host the task reached (M2.T25, R-297 AC2): a followed redirect — Hugging Face `/resolve/` →
        // its CDN (`*.cdn.hf.co`) — is its own destination, so the ledger names it with its own bytes.
        let origin = req?.url?.host ?? ""
        var order: [String] = []
        var bytesByHost: [String: Int64] = [:]
        for t in metrics.transactionMetrics {
            let h = t.request.url?.host ?? origin
            if bytesByHost[h] == nil { order.append(h) }
            bytesByHost[h, default: 0] += t.countOfRequestHeaderBytesSent + t.countOfRequestBodyBytesSent
                + t.countOfResponseHeaderBytesReceived + t.countOfResponseBodyBytesReceived
        }
        if order.isEmpty { order = [origin] }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let outcome: NetworkEvent.Outcome = task.error != nil ? .failed : (status.map { $0 >= 400 } ?? false) ? .httpError : .ok
        for h in order {
            emit(NetworkEvent(category: cat, host: h, bytes: bytesByHost[h] ?? 0, outcome: outcome, status: status,
                              turnID: turn, incognito: incognito))
        }
    }

    private final class Observers: @unchecked Sendable {
        private let lock = NSLock()
        private var fs: [UUID: @Sendable (NetworkEvent) -> Void] = [:]
        func add(_ f: @escaping @Sendable (NetworkEvent) -> Void) -> UUID {
            let id = UUID(); lock.lock(); fs[id] = f; lock.unlock(); return id
        }
        func remove(_ id: UUID) { lock.lock(); fs[id] = nil; lock.unlock() }
        func send(_ e: NetworkEvent) {
            lock.lock(); let all = Array(fs.values); lock.unlock()
            for f in all { f(e) }
        }
    }

    private final class Sessions: @unchecked Sendable {
        private let lock = NSLock()
        private var byCategory: [NetworkCategory: URLSession] = [:]

        func session(for category: NetworkCategory) -> URLSession {
            lock.lock()
            defer { lock.unlock() }
            if let s = byCategory[category] { return s }
            let s = URLSession(configuration: NetworkGate.apply(NetworkGate.defaultConfiguration(), category: category),
                               delegate: Recorder(category: category, incognito: false, inner: nil), delegateQueue: nil)
            byCategory[category] = s
            return s
        }
    }

    private static let shared = Sessions()
}

/// The gate's session delegate: records `didFinishCollecting` metrics, forwards every message to the caller's
/// delegate (ObjC forwarding, so URLSession sees exactly the optional methods the caller implements).
final class Recorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let category: NetworkCategory
    let incognito: Bool
    let inner: (any URLSessionDelegate)?

    init(category: NetworkCategory, incognito: Bool, inner: (any URLSessionDelegate)?) {
        self.category = category; self.incognito = incognito; self.inner = inner
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        NetworkGate.record(metrics, task: task, category: category, incognito: incognito)
        (inner as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (inner as? NSObject)?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let inner = inner as? NSObject, inner.responds(to: aSelector) { return inner }
        return super.forwardingTarget(for: aSelector)
    }
}

/// A gated session that tags each request (`NetworkGate.tag`) before handing it to URLSession, and maps the
/// gate's refusal to `AntiChatError(.network, "blockedByOfflineOnly")`.
public struct GatedSession: Sendable {
    public let session: URLSession
    public let category: NetworkCategory
    public let policy: NetworkPolicyStore

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: NetworkGate.tag(request, category: category, policy: policy)) } catch {
            throw NetworkGate.map(error) ?? error
        }
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) { try await data(for: URLRequest(url: url)) }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await session.bytes(for: NetworkGate.tag(request, category: category, policy: policy)) } catch {
            throw NetworkGate.map(error) ?? error
        }
    }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        do { return try await session.download(for: NetworkGate.tag(request, category: category, policy: policy)) } catch {
            throw NetworkGate.map(error) ?? error
        }
    }

    public func dataTask(with request: URLRequest) -> URLSessionDataTask {
        session.dataTask(with: NetworkGate.tag(request, category: category, policy: policy))
    }
}
