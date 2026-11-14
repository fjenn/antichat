// Minimal HTTP/1.1 client over a unix-domain socket (M0.T04 step 5). URLSession cannot dial a unix
// socket, so requests go over `NWConnection(to: .unix(path:), using: .tcp)`; the decoded body bytes
// are an AsyncSequence<UInt8> that EventSource 1.5.1 parses with `AsyncSequence.events`
// (mattt/EventSource@86b5096:Sources/EventSource/AsyncSequence+Events.swift → AsyncServerSentEventsSequence).
// Cancelling the consumer cancels the connection = HTTP abort (architecture §4.3).
import Foundation
import Network

public struct UnixHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<UInt8, Error>
    /// The body as received chunks (filled only by `UnixHTTPClient.fetch`).
    public var chunks: AsyncThrowingStream<[UInt8], Error> = AsyncThrowingStream { $0.finish() }

    /// Collects the whole body (non-streaming endpoints).
    public func data() async throws -> Data {
        var d = Data()
        for try await b in body { d.append(b) }
        return d
    }
}

public enum UnixHTTPError: Error, Sendable {
    case connect(String)
    case malformed(String)
    case closed
}

public struct UnixHTTPClient: Sendable {
    public let socketPath: String
    public let apiKey: String?

    public init(socketPath: String, apiKey: String?) {
        self.socketPath = socketPath
        self.apiKey = apiKey
    }

    public func get(_ path: String) async throws -> UnixHTTPResponse {
        try await send(method: "GET", path: path, body: nil)
    }

    public func post(_ path: String, json: Data) async throws -> UnixHTTPResponse {
        try await send(method: "POST", path: path, body: json)
    }

    /// M4.T05: one non-streaming exchange collected into `Data` chunk by chunk (sd-server's multi-MB base64 previews
    /// and results; `data()` on the byte stream would cost one async hop per byte).
    /// `timeout`: the whole exchange fails with `UnixHTTPError.connect("timeout")` (and the connection is cancelled)
    /// when it has not completed in time — a server busy loading a model must never hang the caller.
    public func fetch(method: String, path: String, body: Data?, timeout: TimeInterval? = nil) async throws -> (status: Int, body: Data) {
        let r = try await send(method: method, path: path, body: body, chunked: true, timeout: timeout)
        var d = Data()
        for try await chunk in r.chunks { d.append(contentsOf: chunk) }
        return (r.status, d)
    }

    public func send(method: String, path: String, body: Data?) async throws -> UnixHTTPResponse {
        try await send(method: method, path: path, body: body, chunked: false, timeout: nil)
    }

    /// M5.T03: a streaming exchange with extra request headers (the video runtime's SSE `Last-Event-ID`).
    public func send(method: String, path: String, body: Data?, headers: [String: String]) async throws -> UnixHTTPResponse {
        try await send(method: method, path: path, body: body, chunked: false, timeout: nil, headers: headers)
    }

    /// M5.T03: `fetch` with extra request headers.
    public func fetch(method: String, path: String, body: Data?, headers: [String: String], timeout: TimeInterval? = nil) async throws -> (status: Int, body: Data) {
        let r = try await send(method: method, path: path, body: body, chunked: true, timeout: timeout, headers: headers)
        var d = Data()
        for try await chunk in r.chunks { d.append(contentsOf: chunk) }
        return (r.status, d)
    }

    func send(method: String, path: String, body: Data?, chunked: Bool, timeout: TimeInterval?,
              headers extra: [String: String] = [:]) async throws -> UnixHTTPResponse {
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        let parser = HTTPResponseParser()
        let queue = DispatchQueue(label: "app.antichat.engine.unixhttp")
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAccept: */*\r\n"
        if let apiKey { head += "Authorization: Bearer \(apiKey)\r\n" }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var requestBytes = Data(head.utf8)
        if let body { requestBytes.append(body) }
        let request = requestBytes

        return try await withCheckedThrowingContinuation { (headCont: CheckedContinuation<UnixHTTPResponse, Error>) in
            let state = ConnState(headCont: headCont)
            let (bodyStream, bodyCont) = AsyncThrowingStream<UInt8, Error>.makeStream(bufferingPolicy: .unbounded)
            let (chunkStream, chunkCont) = AsyncThrowingStream<[UInt8], Error>.makeStream(bufferingPolicy: .unbounded)
            bodyCont.onTermination = { _ in conn.cancel() }
            chunkCont.onTermination = { _ in conn.cancel() }

            @Sendable func finish(throwing e: Error? = nil) {
                if let e { bodyCont.finish(throwing: e); chunkCont.finish(throwing: e) } else { bodyCont.finish(); chunkCont.finish() }
            }

            @Sendable func fail(_ e: Error) {
                if let c = state.takeHead() { c.resume(throwing: e) }
                finish(throwing: e)
                conn.cancel()
            }

            @Sendable func deliver(_ out: HTTPResponseParser.Output) {
                if let h = out.head, let c = state.takeHead() {
                    var r = UnixHTTPResponse(status: h.status, headers: h.headers, body: bodyStream)
                    r.chunks = chunkStream
                    c.resume(returning: r)
                }
                if chunked {
                    if !out.body.isEmpty { chunkCont.yield(out.body) }
                } else {
                    for b in out.body { bodyCont.yield(b) }
                }
                if out.finished {
                    finish()
                    conn.cancel()
                }
            }

            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        do { deliver(try parser.feed(data)) } catch { fail(error); return }
                    }
                    if let error {
                        fail(UnixHTTPError.connect("\(error)"))
                        return
                    }
                    if isComplete {
                        let out = parser.finish()
                        if state.headPending || out.truncated {
                            // EOF before the head, or inside a Content-Length / chunked body: the server died
                            // mid-response; surface it instead of ending the stream as if it were complete.
                            fail(UnixHTTPError.closed)
                        } else {
                            deliver(out)
                            finish()
                        }
                        conn.cancel()
                        return
                    }
                    receive()
                }
            }

            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    state.markReady()
                    conn.send(content: request, completion: .contentProcessed { err in
                        if let err { fail(UnixHTTPError.connect("\(err)")) }
                    })
                    receive()
                case .failed(let e):
                    // After `ready` the pending receive owns the outcome: a peer that closes right after a complete
                    // response can surface here as `.failed(ENETDOWN)` while that response is still queued for
                    // receive (seen under load on sd-server, M4.T05 real leg); the receive then delivers it, or
                    // reports the error / truncation itself.
                    if !state.isReady { fail(UnixHTTPError.connect("\(e)")) }
                case .waiting(let e):
                    fail(UnixHTTPError.connect("waiting: \(e)"))
                default: break
                }
            }
            if let timeout { queue.asyncAfter(deadline: .now() + timeout) { fail(UnixHTTPError.connect("timeout")) } }
            conn.start(queue: queue)
        }
    }
}

private final class ConnState: @unchecked Sendable {
    private let lock = NSLock()
    private var headCont: CheckedContinuation<UnixHTTPResponse, Error>?
    private var ready = false

    func markReady() { lock.lock(); ready = true; lock.unlock() }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    init(headCont: CheckedContinuation<UnixHTTPResponse, Error>) { self.headCont = headCont }

    func takeHead() -> CheckedContinuation<UnixHTTPResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = headCont
        headCont = nil
        return c
    }

    var headPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return headCont != nil
    }
}

/// Incremental HTTP/1.1 response parser: status line, headers, then identity / Content-Length /
/// chunked body. Only touched from the connection's serial queue.
final class HTTPResponseParser: @unchecked Sendable {
    struct Head {
        var status: Int
        var headers: [String: String]
    }

    struct Output {
        var head: Head?
        var body: [UInt8] = []
        var finished = false
        /// `finish()` only: the connection closed before a framed body was complete.
        var truncated = false
    }

    private enum Phase { case head, identity(remaining: Int?), chunkSize, chunkData(Int), chunkDataCRLF, trailer, done }

    private var buf: [UInt8] = []
    private var phase: Phase = .head

    func feed(_ data: Data) throws -> Output {
        buf.append(contentsOf: data)
        var out = Output()
        loop: while true {
            switch phase {
            case .head:
                guard let r = find(crlfcrlf, in: buf) else { break loop }
                let headText = String(decoding: buf[..<r], as: UTF8.self)
                buf.removeFirst(r + 4)
                var lines = headText.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst()
                let parts = statusLine.split(separator: " ")
                guard parts.count >= 2, let code = Int(parts[1]) else { throw UnixHTTPError.malformed(statusLine) }
                var headers: [String: String] = [:]
                for l in lines {
                    guard let c = l.firstIndex(of: ":") else { continue }
                    headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
                out.head = Head(status: code, headers: headers)
                if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                    phase = .chunkSize
                } else if let cl = headers["content-length"].flatMap(Int.init) {
                    guard cl >= 0 else { throw UnixHTTPError.malformed("content-length \(cl)") }
                    phase = .identity(remaining: cl)
                    if cl == 0 { phase = .done; out.finished = true; break loop }
                } else {
                    phase = .identity(remaining: nil)
                }
            case .identity(let remaining):
                guard !buf.isEmpty else { break loop }
                if let remaining {
                    let n = min(remaining, buf.count)
                    out.body.append(contentsOf: buf[..<n])
                    buf.removeFirst(n)
                    if remaining - n == 0 {
                        phase = .done
                        out.finished = true
                        break loop
                    }
                    phase = .identity(remaining: remaining - n)
                } else {
                    out.body.append(contentsOf: buf)
                    buf.removeAll()
                }
            case .chunkSize:
                guard let r = find(crlf, in: buf) else { break loop }
                let line = String(decoding: buf[..<r], as: UTF8.self)
                buf.removeFirst(r + 2)
                let hex = line.split(separator: ";").first.map(String.init) ?? line
                guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw UnixHTTPError.malformed("chunk size \(line)")
                }
                phase = size == 0 ? .trailer : .chunkData(size)
            case .chunkData(let size):
                guard !buf.isEmpty else { break loop }
                let n = min(size, buf.count)
                out.body.append(contentsOf: buf[..<n])
                buf.removeFirst(n)
                phase = size - n == 0 ? .chunkDataCRLF : .chunkData(size - n)
            case .chunkDataCRLF:
                guard buf.count >= 2 else { break loop }
                buf.removeFirst(2)
                phase = .chunkSize
            case .trailer:
                phase = .done
                out.finished = true
                break loop
            case .done:
                break loop
            }
        }
        return out
    }

    func finish() -> Output {
        var out = Output()
        switch phase {
        case .identity(nil):
            out.body = buf
            buf.removeAll()
        case .head, .identity, .chunkSize, .chunkData, .chunkDataCRLF:
            out.truncated = true
        case .trailer, .done:
            break
        }
        phase = .done
        out.finished = true
        return out
    }

    private let crlf: [UInt8] = [13, 10]
    private let crlfcrlf: [UInt8] = [13, 10, 13, 10]

    private func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = 0
        while i <= hay.count - needle.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}
