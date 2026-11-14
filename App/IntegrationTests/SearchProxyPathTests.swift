// M7.T01 AT-248 c2 (R-248 AC2): live keyless search from the app process through `tools/offline/proxy-logger.py`
// (host:port per connection, no TLS interception). Pass: every host contacted is an enabled engine's host, zero
// AntiChat-operated hosts (`*.vercel.app`, the relay, the site), no Google, and no child process during the search.
// Needs the network (Q-007); offline runs record "not run: network" and skip. Run: tools/at/at-248-proxy.sh. The page-fetch leg (testFetchHostsOnly,
// AT-249 c1) lands with M7.T02.
import AntiChatFoundation
import AntiChatNetwork
import AntiChatTools
import Darwin
import Foundation
import XCTest

final class SearchProxyPathTests: XCTestCase {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }()

    /// A gated `.search` session created after the test proxy is set (the shared one may predate it).
    struct ProxiedTransport: SearchTransport {
        let session = NetworkGate.session(for: .search, configuration: nil, delegate: nil)
        func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
            let (d, r) = try await session.data(for: NetworkGate.tag(request, category: .search))
            return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
        }
    }

    static func childPIDs() -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(getpid(), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(buf.prefix(Int(n))) : []
    }

    static func proxySettings() throws -> [AnyHashable: Any] {
        guard let proxyArg = ProcessInfo.processInfo.environment["ANTICHAT_SEARCH_PROXY"],
              let colon = proxyArg.lastIndex(of: ":"), let port = Int(proxyArg[proxyArg.index(after: colon)...]) else {
            throw XCTSkip("run via tools/at/at-248-proxy.sh (ANTICHAT_SEARCH_PROXY=host:port)")
        }
        let host = String(proxyArg[..<colon])
        return [kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port]
    }

    func testFetchHostsOnly() async throws {
        NetworkGate.testProxy = try Self.proxySettings()
        defer { NetworkGate.testProxy = nil }
        let registry = EngineRegistry(appVersion: "1.0.0")
        let result = await SearchBroker(registry: registry, transport: ProxiedTransport(), safeSearch: { false })
            .search(queries: ["history of the printing press"])
        guard !result.hits.isEmpty else { throw XCTSkip("not run: network (no results)") }
        let urls = result.hits.prefix(3).compactMap { URL(string: $0.url) }
        let fetched = await PageFetcher(cache: MemoryWebCache()).fetch(urls)
        let pages = fetched.compactMap(\.page)
        XCTAssertFalse(pages.isEmpty, "at least one page fetched: \(fetched.map { "\($0.failure as Any)" })")
        let allowed = registry.enabledHosts.union(fetched.flatMap { [$0.url.host(), $0.page?.url.host()] }.compactMap { $0 })
        // tools/at/at-248-proxy.sh reads this line and checks proxy.log against it.
        print("AT-249-ALLOWED-HOSTS: \(allowed.sorted().joined(separator: ","))")
    }

    func testSearchHostsAreEnginesOnly() async throws {
        // The hosted test cannot start the proxy itself (the app host may not spawn python or write the repo), so
        // tools/at/at-248-proxy.sh starts proxy-logger.py and passes it in; the script then checks proxy.log's hosts.
        guard let proxyArg = ProcessInfo.processInfo.environment["ANTICHAT_SEARCH_PROXY"],
              let colon = proxyArg.lastIndex(of: ":"), let port = Int(proxyArg[proxyArg.index(after: colon)...]) else {
            throw XCTSkip("run via tools/at/at-248-proxy.sh (ANTICHAT_SEARCH_PROXY=host:port)")
        }
        let host = String(proxyArg[..<colon])
        NetworkGate.testProxy = [kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host,
                                 kCFNetworkProxiesHTTPPort: port, kCFNetworkProxiesHTTPSEnable: true,
                                 kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port]
        defer { NetworkGate.testProxy = nil }

        let registry = EngineRegistry(appVersion: "1.0.0")
        let broker = SearchBroker(registry: registry, transport: ProxiedTransport(), safeSearch: { false })
        let before = Set(Self.childPIDs())
        let result = await broker.search(queries: ["history of the printing press", "how to grow tomatoes"])
        let during = Set(Self.childPIDs())
        if result.attempts.allSatisfy({ $0.kind == .network }) { throw XCTSkip("not run: network (no engine reachable)") }
        XCTAssertEqual(during.subtracting(before), [], "search must not start a process")
        EngineTestSupport.evidence("AT-248-c2-proxy", [
            "allowed": registry.enabledHosts.sorted(), "hits": result.hits.count, "engines_with_hits": result.engines,
            "attempts": result.attempts.map { "\($0.provider):\($0.kind.rawValue)" }, "new_child_processes": during.subtracting(before).count,
            "a_m7_01": "proposed (SearXNG name / 40 MB kit not met; native engines in-process)",
        ])
    }
}
