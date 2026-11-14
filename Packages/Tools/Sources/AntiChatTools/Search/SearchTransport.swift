// M7.T01: how engine requests leave the process. The default is the gate's `.search` session (Offline only, the
// category switch, Network activity rows and the turn ledger all apply). Decorators: the Debug/bench block rule
// (`-SearchBlockEngine`, AT-248 c3) and the snapshot replay (`--replay`, offline and deterministic).
import AntiChatFoundation
import AntiChatNetwork
import Foundation

public protocol SearchTransport: Sendable {
    func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data)
}

/// Every engine request through `NetworkGate` (category `.search`, tagged with the turn when one is current).
public struct GatedSearchTransport: SearchTransport {
    public let policy: NetworkPolicyStore
    public let incognito: Bool
    public init(policy: NetworkPolicyStore = .shared, incognito: Bool = false) { self.policy = policy; self.incognito = incognito }

    /// One incognito session for the process (memory-only cache, no `network_activity` rows).
    private static let incognitoSession = NetworkGate.incognitoSession(for: .search)

    public func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
        let session = incognito ? Self.incognitoSession : NetworkGate.session(for: .search)
        let (data, response) = try await session.data(for: NetworkGate.tag(request, category: .search, policy: policy))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// The availability test rule: the named engines answer 403 without a request leaving the Mac.
public struct BlockingSearchTransport: SearchTransport {
    public let inner: any SearchTransport
    public let blocked: Set<String>
    public init(inner: any SearchTransport, blocked: Set<String>) { self.inner = inner; self.blocked = blocked }
    public func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
        if blocked.contains(engine) { return (403, Data()) }
        return try await inner.send(request, engine: engine, query: query)
    }
}

/// `--replay <root>`: answers each engine request from `<root>/<engine>/<qid>.html|json` (the saved SERP for that
/// query); a query without a snapshot answers 404. Nothing leaves the Mac.
public struct ReplaySearchTransport: SearchTransport {
    public let root: URL
    public let qids: [String: String]
    public init(root: URL, qids: [String: String]) { self.root = root; self.qids = qids }
    public func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
        guard let qid = qids[query] else { return (404, Data()) }
        for ext in ["html", "json"] {
            let f = root.appending(path: engine).appending(path: "\(qid).\(ext)")
            if let d = try? Data(contentsOf: f) { return (200, d) }
        }
        return (404, Data())
    }
}

public enum SearchTransports {
    /// The app's transport: the gate, wrapped in the block rule when `-SearchBlockEngine` is set (Debug only).
    public static func app(incognito: Bool = false, options: LaunchOptions = .current) -> any SearchTransport {
        let gated = GatedSearchTransport(incognito: incognito)
        return options.searchBlockEngines.isEmpty ? gated : BlockingSearchTransport(inner: gated, blocked: options.searchBlockEngines)
    }
}
