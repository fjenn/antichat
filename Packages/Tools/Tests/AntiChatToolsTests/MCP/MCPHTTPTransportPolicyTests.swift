// RC review P2-6: the MCP / relay GET event stream (timeout 24 h) is checked by the gate only when it starts. A stream
// opened before Offline only was switched on must close as soon as it is, and reopen when the category is allowed
// again. A stub URLProtocol stands in for the server (no network): POST answers initialize with a session id, GET
// answers an SSE stream that never ends on its own.
//   make test-unit FILTER=MCPHTTPTransportPolicyTests
import AntiChatFoundation
@testable import AntiChatNetwork
@testable import AntiChatTools
import Foundation
import Testing

final class EndlessSSEStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var getsStarted = 0
    nonisolated(unsafe) static var getsStopped = 0
    static func counts() -> (started: Int, stopped: Int) { lock.withLock { (getsStarted, getsStopped) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var isGET: Bool { request.httpMethod == "GET" }

    override func startLoading() {
        let url = request.url!
        switch request.httpMethod {
        case "GET":
            Self.lock.withLock { Self.getsStarted += 1 }
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            let event = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n"
            client?.urlProtocol(self, didLoad: Data(event.utf8))
            // …and never finishes: only a cancel ends it.
        case "POST":
            let body = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"stub","version":"1"}}}"#
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json", "Mcp-Session-Id": "sid-1"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        default:
            let r = HTTPURLResponse(url: url, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if isGET { Self.lock.withLock { Self.getsStopped += 1 } }
    }
}

@Suite(.serialized) struct MCPHTTPTransportPolicyTests {
    /// Polls `condition` for up to `seconds`.
    static func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test(arguments: [NetworkCategory.mcp, .relay])
    func openGETStreamClosesWhenOfflineOnlyTurnsOn(category: NetworkCategory) async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [EndlessSSEStub.self]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        policy.setEnabled(category, true)
        let before = EndlessSSEStub.counts()
        let transport = MCPHTTPTransport(endpoint: URL(string: "http://127.0.0.9/mcp")!, session: session,
                                         incognitoSession: { session }, category: category, policy: policy)
        let received = MCPPolicyReceived()
        let reader = Task { for try await m in await transport.receive() { received.add(m) } }
        defer { reader.cancel() }
        try await transport.connect()
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8))

        // The GET stream is open and delivering.
        #expect(await Self.eventually { received.contains("notifications/tools/list_changed") })
        #expect(EndlessSSEStub.counts().started == before.started + 1)
        #expect(EndlessSSEStub.counts().stopped == before.stopped)

        policy.offlineOnly = true
        #expect(await Self.eventually { EndlessSSEStub.counts().stopped == before.stopped + 1 },
                "the open stream is cancelled as soon as Offline only turns on")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(EndlessSSEStub.counts().started == before.started + 1, "no new stream while offline")

        policy.offlineOnly = false
        #expect(await Self.eventually { EndlessSSEStub.counts().started == before.started + 2 },
                "the stream reopens when the category is allowed again")

        // Switching the category itself off closes it too.
        policy.setEnabled(category, false)
        #expect(await Self.eventually { EndlessSSEStub.counts().stopped == before.stopped + 2 })
        await transport.disconnect()
    }
}

final class MCPPolicyReceived: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ d: Data) { lock.withLock { messages.append(String(decoding: d, as: UTF8.self)) } }
    func contains(_ s: String) -> Bool { lock.withLock { messages.contains { $0.contains(s) } } }
}
