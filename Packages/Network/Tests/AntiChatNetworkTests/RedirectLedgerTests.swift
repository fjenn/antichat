// M2.T25 (R-297 AC2; found by tools/at/at-209-destinations.sh): a followed redirect reaches a second host (Hugging Face
// `/resolve/` → `us.aws.cdn.hf.co`); the ledger names every host the task reached, not only the first request's.
import Foundation
import Network
import Synchronization
import Testing
@testable import AntiChatNetwork

@Suite(.serialized) struct RedirectLedgerTests {
    /// HTTP on 127.0.0.1: `/a` → 302 to `http://localhost:<port>/b`; `/b` → 200 "ok".
    final class Server: @unchecked Sendable {
        let listener: NWListener
        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        }
        func start() async throws -> UInt16 {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let once = Mutex(false)
                listener.stateUpdateHandler = { s in
                    if case .ready = s, once.withLock({ let f = !$0; $0 = true; return f }) { k.resume() }
                }
                listener.start(queue: .global())
            }
            return listener.port!.rawValue
        }
        func serve(_ c: NWConnection) {
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
                let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let port = self?.listener.port?.rawValue ?? 0
                let reply = head.hasPrefix("GET /a")
                    ? "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(port)/b\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    : "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    @Test func redirectRecordsEveryHostReached() async throws {
        let server = try Server()
        let port = try await server.start()
        defer { server.listener.cancel() }
        let events = Mutex<[NetworkEvent]>([])
        let id = NetworkGate.addObserver { e in events.withLock { $0.append(e) } }
        defer { NetworkGate.removeObserver(id) }
        let s = NetworkGate.session(for: .catalog, configuration: NetworkGate.defaultConfiguration(), delegate: nil)
        defer { s.invalidateAndCancel() }
        // Tagged with a turn id of its own: other suites' requests to 127.0.0.1/localhost reach the same observers.
        let turn = UUID().uuidString
        let req = NSMutableURLRequest(url: URL(string: "http://127.0.0.1:\(port)/a")!)
        URLProtocol.setProperty(turn, forKey: GateURLProtocol.turnKey, in: req)
        let (data, response) = try await s.data(for: req as URLRequest)
        #expect(String(decoding: data, as: UTF8.self) == "ok" && (response as? HTTPURLResponse)?.statusCode == 200)
        for _ in 0..<200 where events.withLock({ $0 }).filter({ $0.turnID == turn }).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let mine = events.withLock { $0 }.filter { $0.turnID == turn }
        #expect(Set(mine.map(\.host)) == ["127.0.0.1", "localhost"])
        #expect(mine.allSatisfy { $0.category == mine[0].category && $0.outcome == .ok }, "\(mine.map { "\($0.host) \($0.category) \($0.outcome)" })")
        #expect(mine.first { $0.host == "localhost" }.map { $0.bytes > 0 } == true)
    }
}
