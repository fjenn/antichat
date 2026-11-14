// M7.T11 AT-255 c2-app / c5-app (R-255 AC2, A-M7-06): the install ID exists only after the first Connections use and
// stays the same; the relay client sends the §8.2 headers on `.relay` and maps relay error bodies to the `relay.*`
// copy keys. A stub URLProtocol stands in for the relay (no network). The live leg against `make relay-dev` + mock
// Composio runs when ANTICHAT_RELAY_URL is set (integration-stub).
import AntiChatFoundation
@testable import AntiChatNetwork
@testable import AntiChatTools
import Foundation
import Testing

final class RelayStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var host: String; var method: String; var path: String; var headers: [String: String] }
    /// Per relay host (each suite uses its own loopback host, so suites running in parallel don't mix).
    nonisolated(unsafe) static var seenAll: [Seen] = []
    nonisolated(unsafe) static var answers: [String: (Int, String, [String: String])] = [:]
    static func seen(_ host: String) -> [Seen] { lock.withLock { seenAll.filter { $0.host == host } } }
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host() ?? ""
        let (status, body, headers) = Self.lock.withLock {
            Self.seenAll.append(Seen(host: host, method: request.httpMethod ?? "", path: request.url?.path ?? "",
                                     headers: request.allHTTPHeaderFields ?? [:]))
            return Self.answers[host] ?? (200, #"{"ok":true}"#, [:])
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct RelayIdentityTests {
    static let host = "127.0.0.1"

    static func client(_ secrets: MemorySecrets) -> RelayClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayStub.self]
        let s = URLSession(configuration: cfg)
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        return RelayClient(baseURL: URL(string: "http://127.0.0.1:3000")!, installID: InstallID(secrets: secrets),
                           session: { GatedSession(session: s, category: .relay, policy: policy) }, version: "1.0")
    }

    static func reset(_ answer: (Int, String, [String: String]) = (200, #"{"ok":true}"#, [:]), host: String = host) {
        RelayStub.lock.withLock { RelayStub.seenAll.removeAll { $0.host == host }; RelayStub.answers[host] = answer }
    }

    @Test func noInstallIDBeforeFirstUseThenStable() async throws {
        let secrets = MemorySecrets()
        let relay = Self.client(secrets)
        Self.reset()
        #expect(InstallID(secrets: secrets).existing == nil)
        #expect(try await relay.health())  // /health carries no install header and creates nothing
        #expect(InstallID(secrets: secrets).existing == nil)
        try await relay.forget()  // nothing to forget: no request
        #expect(RelayStub.seen(Self.host).count == 1)
        try await relay.createSession()  // first Connections use
        let id = try #require(InstallID(secrets: secrets).existing)
        #expect(InstallID.isUUIDv4(id))
        try await relay.createSession()
        let seen = RelayStub.seen(Self.host)
        #expect(seen[0].headers["X-AntiChat-Install"] == nil)
        #expect(seen[1].headers["X-AntiChat-Install"] == id && seen[2].headers["X-AntiChat-Install"] == id)
        #expect(seen[1].headers["X-AntiChat-Version"] == "1.0" && seen[1].headers["User-Agent"] == "AntiChat/1.0")
        #expect(secrets.all.keys.contains("\(InstallID.service)/\(InstallID.account)"))
        // Remove everything: /v1/forget, then the local ID is gone; the next use makes a new one
        try await relay.forget()
        #expect(InstallID(secrets: secrets).existing == nil)
        try await relay.createSession()
        #expect(InstallID(secrets: secrets).existing != id)
    }

    @Test func relayErrorsMapToCopyKeys() async throws {
        let relay = Self.client(MemorySecrets())
        for (status, body, key) in [(429, #"{"code":"relay.rateLimited"}"#, "relay.rateLimited"),
                                    (503, #"{"code":"relay.notConfigured"}"#, "relay.notConfigured"),
                                    (503, #"{"code":"relay.disabled"}"#, "relay.disabled"),
                                    (426, #"{"code":"relay.updateRequired"}"#, "relay.updateRequired"),
                                    (429, "", "relay.rateLimited")] {
            Self.reset((status, body, ["Retry-After": "60"]))
            do {
                try await relay.createSession()
                Issue.record("expected \(key)")
            } catch let e as AntiChatError {
                #expect(e.domain == .relay && e.userMessageKey == key)
                #expect(CopyDeckKeys.contains(key))
            }
        }
    }

    @Test func connectionsAndLinkDecode() async throws {
        let relay = Self.client(MemorySecrets())
        Self.reset((200, #"{"toolkits":["gmail","slack"],"connections":[{"id":"ca_1","toolkit":"gmail","status":"ACTIVE"}]}"#, [:]))
        let c = try await relay.connections()
        #expect(c.toolkits == ["gmail", "slack"] && c.connections.first?.isActive == true)
        Self.reset((200, #"{"url":"https://connect.composio.dev/link/abc","id":"lr_1"}"#, [:]))
        #expect(try await relay.link(toolkit: "gmail").host() == "connect.composio.dev")
        Self.reset((200, #"{"url":"javascript:alert(1)"}"#, [:]))
        await #expect(throws: AntiChatError.self) { try await relay.link(toolkit: "gmail") }
    }

    /// Live leg (integration-stub): against `make relay-dev` (relay/.env.test + mock Composio).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_RELAY_URL"] != nil))
    func liveRelayDev() async throws {
        let base = try #require(URL(string: ProcessInfo.processInfo.environment["ANTICHAT_RELAY_URL"]!))
        let secrets = MemorySecrets()
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        let relay = RelayClient(baseURL: base, installID: InstallID(secrets: secrets),
                                session: { GatedSession(session: URLSession(configuration: .ephemeral), category: .relay, policy: policy) })
        #expect(try await relay.health())
        try await relay.createSession()
        let c = try await relay.connections()
        #expect(!c.toolkits.isEmpty)
        #expect(try await relay.link(toolkit: c.toolkits.first { $0 != "*" } ?? "gmail").scheme != nil)
    }
}

/// The copy keys the relay maps to (copy-deck §8).
enum CopyDeckKeys {
    static let relay: Set<String> = ["relay.notConfigured", "relay.rateLimited", "relay.overCapacity", "relay.disabled", "relay.updateRequired"]
    static func contains(_ k: String) -> Bool { relay.contains(k) }
}

/// Release 2: the release build shows the Composio section iff `RelayClient.isAvailable`, which in Release is
/// `isDeployed(endpoint(bundle:))`. With the shipped Config/Endpoints.plist that is the production relay; an empty
/// RelayURL (release 1) falls back to loopback and hides it.
@Suite struct RelayReleaseGateTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func bundle(relayURL: String?) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appending(path: "relay-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appending(path: "Endpoints.plist")
        if let relayURL {
            try PropertyListSerialization.data(fromPropertyList: ["RelayURL": relayURL], format: .xml, options: 0).write(to: dst)
        } else {
            try FileManager.default.copyItem(at: repo.appending(path: "Config/Endpoints.plist"), to: dst)
        }
        return try #require(Bundle(url: dir))
    }

    @Test func shippedEndpointsShowComposioInRelease() throws {
        let url = RelayClient.endpoint(options: LaunchOptions.parse([]), bundle: try Self.bundle(relayURL: nil))
        #expect(url.absoluteString == "https://antichat-relay.vercel.app")
        #expect(RelayClient.isDeployed(url))
    }

    @Test func emptyOrLoopbackRelayHidesComposio() throws {
        for s in ["", "http://127.0.0.1:3000", "https://localhost:3000"] {
            let url = RelayClient.endpoint(options: LaunchOptions.parse([]), bundle: try Self.bundle(relayURL: s))
            #expect(!RelayClient.isDeployed(url), "\(s)")
        }
    }
}
