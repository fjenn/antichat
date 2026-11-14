// M7.T16 review #13: the gated page transport reports the connected address on a redirect hop too (it used to read
// the task metrics before they existed, so a redirect hop skipped the connected-address check).
//   make test-unit FILTER=PageTransportAddressTests
@testable import AntiChatTools
import Foundation
import Network
import Testing

/// Loopback HTTP/1.1 server that answers every request with a 302 to /next.
final class RedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "redirect-server")
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue] c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let resp = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 5\r\nConnection: close\r\n\r\nmoved"
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
}

struct PageTransportAddressTests {
    @Test func redirectHopReportsTheConnectedAddress() async throws {
        let server = try RedirectServer()
        let req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!)
        let (resp, data, remote) = try await GatedPageTransport().get(req, maxBytes: 1_000_000)
        #expect(resp.statusCode == 302 && data.isEmpty)
        #expect(remote == "127.0.0.1", "the redirect hop's peer is known before the next hop")
    }
}
