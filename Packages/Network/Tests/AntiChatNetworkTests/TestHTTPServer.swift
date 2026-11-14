// Test-only loopback HTTP/1.1 server (Network.framework NWListener): answers every request with 200 and a fixed
// body, and counts the requests it saw, so a blocked request can be proven to have reached nobody.
import Foundation
import Network

final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http-server")
    private let lock = NSLock()
    private var _hits: [String] = []
    let body: Data
    private(set) var port: UInt16 = 0

    var hits: [String] { lock.lock(); defer { lock.unlock() }; return _hits }

    init(body: Data = Data("ok".utf8)) throws {
        self.body = body
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    self.lock.lock(); self._hits.append(head.components(separatedBy: "\r\n").first ?? ""); self.lock.unlock()
                    var resp = Data("HTTP/1.1 200 OK\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n".utf8)
                    resp.append(self.body)
                    c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                } else if done || error != nil {
                    c.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    deinit { listener.cancel() }
}
