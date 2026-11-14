// M2.T08 (R-204 AC2–AC4, R-220 AC3, NFR-D6; blueprint E §E.2.5; P-platform-03): one file as parallel HTTP Range
// lanes into a sparse `partial/<sha256>.part`, resumable from `<sha256>.bitmap`, verified before it may become a blob.
//
// Lane design ported from osaurus@2922745:Packages/OsaurusCore/Services/ChunkedFileDownloader.swift (MIT;
// `TransferLane`, `ChunkQueue`, the per-chunk retry policy of `ModelDownloadService`): a fixed set of lanes, each
// one `URLSession` (one connection) reused across chunks, streaming each 206 straight to its offset. What differs
// (why it is a port and not more UP-OS patches on the vendored file): per-instance lanes/chunk size (4 × 64 MB),
// the in-chunk watermark (`ChunkBitmap`, so a resume re-fetches far less than a chunk per lane), per-chunk sha256
// from the catalog, `sources[]` fallback on 404/410, 429 → 2 lanes, and the commit into `BlobStore`.
// Every request goes through NetworkGate (category `.models`): `TransferEngine.gateSessions`. Anonymous only — no
// request here ever carries `Authorization` (D-007, R-300); URLs are the catalog's `/resolve/<commit>/` ones.
import AntiChatFoundation
import AntiChatNetwork
import Foundation

public struct TransferConfig: Sendable, Equatable {
    /// Parallel Range lanes per file (E.2.5: 4).
    public var lanes: Int
    /// Chunk size (E.2.5: 64 MB) — the retry and verification unit.
    public var chunkSize: Int64
    /// Attempts per chunk for transient errors (timeouts, connection loss, 408/429/5xx) before the job fails.
    public var perChunkAttempts: Int
    /// The bitmap is saved each time an in-flight chunk advances this much (bounds the re-fetch after kill -9).
    public var watermarkInterval: Int64
    /// Lanes after an HTTP 429 (E.2.5 / known failure mode "HF 429 → drop to 2 lanes").
    public var lanesAfter429: Int

    public static let mib: Int64 = 1024 * 1024

    public init(lanes: Int = 4, chunkSize: Int64 = 64 * TransferConfig.mib, perChunkAttempts: Int = 3,
                watermarkInterval: Int64? = nil, lanesAfter429: Int = 2) {
        self.lanes = max(1, lanes)
        self.chunkSize = max(64 * 1024, chunkSize)
        self.perChunkAttempts = max(1, perChunkAttempts)
        self.watermarkInterval = watermarkInterval ?? max(256 * 1024, chunkSize / 16)
        self.lanesAfter429 = max(1, lanesAfter429)
    }

    public static let standard = TransferConfig()
}

public enum TransferError: Error, Equatable, Sendable {
    /// Every source answered 404/410 (R-220 AC3 → `download.unavailable`).
    case unavailable
    /// The file (or a chunk) did not match its catalog sha256 after the one re-fetch (`download.failed`).
    case checksum(expected: String, actual: String)
    case http(Int)
    case paused
    /// The Network gate refused the request (Offline only / models category off).
    case blocked
}

/// Where a transfer is (the coordinator maps it to `DownloadJob.State`).
public enum TransferPhase: Sendable, Equatable {
    case transferring(source: Int)
    case verifying
    /// The first full-file mismatch: the part was deleted and is fetched once more (`download.verifyFailed`).
    case refetching(source: Int)
}

public final class TransferEngine: @unchecked Sendable {
    public typealias SessionFactory = @Sendable (any URLSessionDelegate) -> URLSession
    /// Gated sessions: one per lane (its own connection), category `.models`.
    public static let gateSessions: SessionFactory = { NetworkGate.session(for: .models, delegate: $0) }
    /// Diagnostics (RealStarterDownloadTests): every request as sent on the wire, redirect hops included (task metrics).
    nonisolated(unsafe) public static var observeWireRequest: (@Sendable (URLRequest) -> Void)?

    public let models: ModelsDirectory
    public let config: TransferConfig
    private let makeSession: SessionFactory
    /// Raw bytes received, every lane (re-fetch measurement, bench rate cap). Called on a delegate queue.
    private let onBytes: (@Sendable (Int) -> Void)?
    /// Sleeps between chunk retries (tests pass a fast one).
    private let sleep: @Sendable (Double) async throws -> Void

    private let lock = NSLock()
    private var lanes: [TransferLane] = []
    private var pauseRequested = false
    private var laneCap: Int

    public init(models: ModelsDirectory, config: TransferConfig = .standard, makeSession: @escaping SessionFactory = TransferEngine.gateSessions,
                onBytes: (@Sendable (Int) -> Void)? = nil,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.models = models
        self.config = config
        self.makeSession = makeSession
        self.onBytes = onBytes
        self.sleep = sleep
        laneCap = config.lanes
    }

    /// Stops every lane; the bitmap keeps what is on disk. `download` then throws `TransferError.paused`.
    public func pause() {
        let active = lock.withLock { pauseRequested = true; return lanes }
        for l in active { l.invalidate() }
    }

    var isPaused: Bool { lock.withLock { pauseRequested } }

    private func checkPaused() throws {
        if isPaused { throw TransferError.paused }
        if Task.isCancelled { throw TransferError.paused }
    }

    // MARK: Download

    /// Fetches `request` into `partial/<sha>.part` (resuming from its bitmap), verifies it and returns the part's URL,
    /// ready for `BlobStore.commit`. `progress` gets the bytes on disk; `phase` the stage. On a full-file mismatch the
    /// part is deleted and fetched once more from the next source; a second mismatch throws `.checksum`.
    public func download(_ request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void = { _ in },
                         phase: @escaping @Sendable (TransferPhase) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: models.partial, withIntermediateDirectories: true)
        guard Verify.isSHA256Hex(request.sha256) else { throw BlobStoreError.badDigest(request.sha256) }
        guard !request.sources.isEmpty else { throw TransferError.unavailable }
        lock.withLock { pauseRequested = false; laneCap = config.lanes }
        var source = 0
        var refetched = false
        while true {
            let part = try await transfer(request, from: &source, progress: progress, phase: phase)
            phase(.verifying)
            let actual = try await Self.hash(part, cancelled: { [weak self] in self?.isPaused ?? true })
            try checkPaused()
            if actual == request.sha256 {
                try? fm.removeItem(at: models.bitmap(request.sha256))
                return part
            }
            // R-204 AC4: delete the part, re-fetch once (from the next source when there is one), then fail.
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: models.bitmap(request.sha256))
            AppLog.log(.download, .error, "download: sha256 mismatch for \(request.sha256.prefix(12)) (got \(actual.prefix(12)))")
            if refetched { throw TransferError.checksum(expected: request.sha256, actual: actual) }
            refetched = true
            source = (source + 1) % request.sources.count
            phase(.refetching(source: source))
        }
    }

    private static func hash(_ url: URL, cancelled: @escaping @Sendable () -> Bool) async throws -> String {
        try await Task.detached(priority: .utility) { try Verify.sha256(url, cancelled: cancelled) }.value
    }

    /// Runs the lanes against `sources[source]`, moving on to the next source on 404/410 (the bitmap carries over:
    /// same sha256, same bytes). Returns the complete part.
    private func transfer(_ request: DownloadRequest, from source: inout Int, progress: @escaping @Sendable (Int64) -> Void,
                          phase: @escaping @Sendable (TransferPhase) -> Void) async throws -> URL {
        let part = models.part(request.sha256)
        let bitmapURL = models.bitmap(request.sha256)
        let chunkSize = request.chunk?.size ?? config.chunkSize
        let fm = FileManager.default
        var bitmap = ChunkBitmap.load(bitmapURL).flatMap {
            $0.matches(sha256: request.sha256, size: request.size, chunkSize: chunkSize) ? $0 : nil
        }
        if bitmap == nil || !fm.fileExists(atPath: part.path) {
            // A fresh sparse part (truncate = holes, no disk blocks until written).
            fm.createFile(atPath: part.path, contents: nil)
            let h = try FileHandle(forWritingTo: part)
            try h.truncate(atOffset: UInt64(request.size))
            try h.close()
            bitmap = ChunkBitmap(sha256: request.sha256, size: request.size, chunkSize: chunkSize)
            try bitmap!.save(bitmapURL)
        }
        let recorder = BitmapRecorder(bitmap: bitmap!, url: bitmapURL, interval: config.watermarkInterval, progress: progress)
        progress(recorder.bytesDone)
        if request.size == 0 { return part }
        let chunkHashes = request.chunk?.sha256
        while true {
            try checkPaused()
            let pending = recorder.pending
            if pending.isEmpty { return part }
            phase(.transferring(source: source))
            do {
                try await runLanes(url: request.sources[source], pending: pending, part: part, recorder: recorder, chunkHashes: chunkHashes)
                recorder.flush()
            } catch let e as SourceGone {
                recorder.flush()
                AppLog.log(.download, .info, "download: source \(source) answered \(e.status); trying the next")
                guard source + 1 < request.sources.count else { throw TransferError.unavailable }
                source += 1
            } catch {
                recorder.flush()
                if isPaused || error is CancellationError { throw TransferError.paused }
                if NetworkGate.map(error) != nil { throw TransferError.blocked }
                throw error
            }
        }
    }

    private func runLanes(url: URL, pending: [Int], part: URL, recorder: BitmapRecorder, chunkHashes: [String]?) async throws {
        let queue = ChunkQueue(pending)
        let count = min(lock.withLock { laneCap }, pending.count)
        let active = (0..<count).map { _ in TransferLane(makeSession: makeSession, onBytes: onBytes) }
        let paused = lock.withLock { () -> Bool in
            lanes = active
            return pauseRequested
        }
        if paused { throw TransferError.paused }
        defer {
            lock.withLock { lanes = [] }
            for l in active { l.invalidate() }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (n, lane) in active.enumerated() {
                group.addTask {
                    while let i = queue.next() {
                        if n >= self.lock.withLock({ self.laneCap }) {  // after a 429: fewer lanes
                            queue.putBack(i)
                            return
                        }
                        try await self.transferChunk(i, url: url, part: part, lane: lane, recorder: recorder,
                                                     expected: chunkHashes.flatMap { $0.indices.contains(i) ? $0[i] : nil })
                    }
                }
            }
            do { try await group.waitForAll() } catch {
                group.cancelAll()
                for l in active { l.invalidate() }
                throw error
            }
        }
    }

    /// One chunk, resumed from its watermark, retried for transient errors; checked against its sha256 when the catalog
    /// has one (a mismatch re-fetches the chunk once, then fails the file).
    private func transferChunk(_ i: Int, url: URL, part: URL, lane: TransferLane, recorder: BitmapRecorder, expected: String?) async throws {
        var attempt = 1
        var rehashed = false
        let range = recorder.range(i)
        while true {
            try checkPaused()
            let start = range.lowerBound + recorder.watermark(i)
            if start <= range.upperBound {
                do {
                    let handle = try FileHandle(forWritingTo: part)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(start))
                    try await lane.fetch(url: url, start: start, end: range.upperBound, fileSize: recorder.size, handle: handle) { n in
                        recorder.advance(i, by: n)
                    }
                } catch let e as SourceGone {
                    throw e
                } catch {
                    try checkPaused()
                    recorder.flush()
                    if NetworkGate.map(error) != nil { throw error }
                    guard attempt < config.perChunkAttempts, Self.isRetryable(error) else { throw error }
                    if let s = error as? HTTPStatus, s.code == 429 {
                        lock.withLock { laneCap = min(laneCap, config.lanesAfter429) }
                    }
                    let delay = Self.retryDelay(attempt: attempt, error: error)
                    attempt += 1
                    try await sleep(delay)
                    continue
                }
            }
            if let expected {
                let got = try Verify.sha256(part, offset: range.lowerBound, length: Int64(range.count))
                if got != expected {
                    recorder.reset(i)
                    AppLog.log(.download, .error, "download: chunk \(i) sha256 mismatch")
                    if rehashed { throw TransferError.checksum(expected: expected, actual: got) }
                    rehashed = true
                    continue
                }
            }
            recorder.markDone(i)
            return
        }
    }

    // Retry policy: osaurus@2922745 ModelDownloadService.isRetryableTransferError / transferRetryDelay (UP-OS-024 copy).
    static func isRetryable(_ error: any Error) -> Bool {
        if let s = error as? HTTPStatus { return s.code == 408 || s.code == 429 || (500...599).contains(s.code) }
        if error is ShortChunk { return true }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .notConnectedToInternet, .cannotDecodeContentData, .badServerResponse, .secureConnectionFailed:
                return true
            default: return false
            }
        }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain
    }

    /// Retry-After when the server sent one (≤ 120 s), else 1 → 2 → 4 … ≤ 15 s.
    static func retryDelay(attempt: Int, error: any Error) -> Double {
        if let s = error as? HTTPStatus, let after = s.retryAfter, after > 0 { return min(after, 120) }
        return min(pow(2, Double(attempt - 1)), 15)
    }
}

// MARK: - Errors inside a transfer

struct SourceGone: Error { let status: Int }
struct HTTPStatus: Error { let code: Int; let retryAfter: Double? }
struct ShortChunk: Error { let expected: Int64; let got: Int64 }

// MARK: - Bitmap recorder

/// The bitmap under a lock, written by every lane: watermarks advance per received block and are saved every
/// `interval` bytes per chunk; finished chunks are saved at once.
final class BitmapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bitmap: ChunkBitmap
    private var savedAt: [Int: Int64] = [:]
    private var done: Int64
    private var lastReport = Date.distantPast
    let url: URL
    let interval: Int64
    let progress: @Sendable (Int64) -> Void

    init(bitmap: ChunkBitmap, url: URL, interval: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.bitmap = bitmap; self.url = url; self.interval = interval; self.progress = progress
        done = bitmap.bytesDone
    }

    var size: Int64 { bitmap.size }
    var bytesDone: Int64 { lock.withLock { done } }
    var pending: [Int] { lock.withLock { bitmap.pending } }
    func range(_ i: Int) -> ClosedRange<Int64> { bitmap.range(i) }
    func watermark(_ i: Int) -> Int64 { lock.withLock { bitmap.watermarks[i] ?? 0 } }

    func advance(_ i: Int, by n: Int64) {
        var snapshot: ChunkBitmap?
        var report: Int64?
        lock.withLock {
            let w = (bitmap.watermarks[i] ?? 0) + n
            bitmap.watermarks[i] = w
            done += n
            if w - (savedAt[i] ?? 0) >= interval {
                savedAt[i] = w
                snapshot = bitmap
            }
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.1 { lastReport = now; report = done }
        }
        if let snapshot { try? snapshot.save(url) }
        if let report { progress(report) }
    }

    func markDone(_ i: Int) {
        let (snapshot, d) = lock.withLock { () -> (ChunkBitmap, Int64) in
            done += bitmap.length(i) - min(bitmap.watermarks[i] ?? 0, bitmap.length(i))
            bitmap.markDone(i)
            savedAt[i] = nil
            return (bitmap, done)
        }
        try? snapshot.save(url)
        progress(d)
    }

    func reset(_ i: Int) {
        let snapshot = lock.withLock { () -> ChunkBitmap in
            done -= min(bitmap.watermarks[i] ?? 0, bitmap.length(i))
            bitmap.reset(i)
            savedAt[i] = nil
            return bitmap
        }
        try? snapshot.save(url)
    }

    func flush() {
        let snapshot = lock.withLock { bitmap }
        try? snapshot.save(url)
    }
}

/// Hands the next pending chunk to whichever lane asks first (osaurus `ChunkQueue`), plus put-back for a lane
/// that retires after a 429.
final class ChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int]
    init(_ pending: [Int]) { self.pending = pending.reversed() }
    func next() -> Int? { lock.withLock { pending.popLast() } }
    func putBack(_ i: Int) { lock.withLock { pending.append(i) } }
}

// MARK: - Lane

/// One connection: a session reused across chunks, one request at a time, each response streamed to the part file.
/// Ported from osaurus@2922745 `TransferLane` (MIT).
final class TransferLane: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let makeSession: TransferEngine.SessionFactory
    private let onBytes: (@Sendable (Int) -> Void)?
    private var session: URLSession?
    private var invalidated = false
    private var handle: FileHandle?
    private var onData: (@Sendable (Int64) -> Void)?
    private var expected: Int64 = 0
    private var received: Int64 = 0
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var acceptFull = false

    init(makeSession: @escaping TransferEngine.SessionFactory, onBytes: (@Sendable (Int) -> Void)?) {
        self.makeSession = makeSession
        self.onBytes = onBytes
    }

    func fetch(url: URL, start: Int64, end: Int64, fileSize: Int64, handle: FileHandle, onData: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            lock.lock()
            guard !invalidated else {
                lock.unlock()
                c.resume(throwing: CancellationError())
                return
            }
            let s: URLSession
            if let existing = session { s = existing } else {
                s = makeSession(self)
                session = s
            }
            self.handle = handle
            self.onData = onData
            self.expected = end - start + 1
            self.received = 0
            self.failure = nil
            self.acceptFull = start == 0 && end == fileSize - 1
            self.continuation = c
            let task = s.dataTask(with: request)
            lock.unlock()
            task.resume()
        }
    }

    func invalidate() {
        let s = lock.withLock { () -> URLSession? in
            guard !invalidated else { return nil }
            invalidated = true
            return session
        }
        s?.invalidateAndCancel()
    }

    private func setFailure(_ e: any Error) { lock.withLock { if failure == nil { failure = e } } }

    private func finish(_ r: Result<Void, any Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            let c = continuation
            continuation = nil
            handle = nil
            onData = nil
            return c
        }
        c?.resume(with: r)
    }

    /// Cross-host redirects (HF → CDN) never carry Authorization (none is ever set; belt and braces).
    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var r = request
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(r)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            setFailure(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let full = lock.withLock { acceptFull }
        switch http.statusCode {
        case 206, 200 where full:
            completionHandler(.allow)
        case 404, 410:
            setFailure(SourceGone(status: http.statusCode))
            completionHandler(.cancel)
        default:
            // A 200 to a partial Range would stream the whole file into one chunk's offset: refused.
            setFailure(HTTPStatus(code: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)))
            completionHandler(.cancel)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        let (target, notify, room) = lock.withLock { (handle, onData, expected - received) }
        guard let target else { return }
        onBytes?(data.count)
        let slice = data.count > room ? data.prefix(Int(max(0, room))) : data
        do {
            try target.write(contentsOf: slice)
            lock.withLock { received += Int64(slice.count) }
            notify?(Int64(slice.count))
        } catch {
            setFailure(error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let observe = TransferEngine.observeWireRequest else { return }
        for t in metrics.transactionMetrics { observe(t.request) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (existing, got, want) = lock.withLock { (failure, received, expected) }
        if let existing { return finish(.failure(existing)) }
        if let error { return finish(.failure(error)) }
        guard got == want else { return finish(.failure(ShortChunk(expected: want, got: got))) }
        finish(.success(()))
    }
}
