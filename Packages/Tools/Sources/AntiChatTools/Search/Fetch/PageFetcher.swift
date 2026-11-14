// M7.T02 step 2 (R-249 AC1; blueprint B §B1.2 step 5): fetch result pages through the gate (`.search`, an
// ephemeral cookie-less session; incognito: the gate's incognito session, no activity rows), SSRF-checked before the
// request, on every redirect (≤ 5, followed by hand) and against the address the connection actually used. Limits:
// 5 s per page, 3 MB, HTML / XHTML / PDF / plain text only, 6 in parallel. UA `AntiChat/<ver> (+https://antichat.app/bot)`;
// robots.txt `Disallow` is honoured for the `AntiChat` token only (K-NEW-SEARCH-5 default). No reader service:
// the only hosts contacted are the pages' own hosts (NoReaderServiceTests).
import AntiChatNetwork
import Foundation

public struct FetchedPage: Sendable, Equatable {
    public var requestedURL: URL
    public var url: URL
    public var status: Int
    public var contentType: String
    public var data: Data
    public var fetchedAt: Date
    public var fromCache: Bool
}

public enum FetchFailure: Error, Sendable, Equatable {
    case refused(SSRFGuard.Refusal), robots, tooLarge, contentType(String), http(Int), network(String), timeout
    /// M9.T05 (AT-254 T3): the page had not arrived by the fetch deadline; the turn uses its snippet (its fetch goes on
    /// in the background and fills the page cache).
    case late
}

public struct PageFetchResult: Sendable {
    public var url: URL
    public var page: FetchedPage?
    public var failure: FetchFailure?
    /// Seconds from the start of the fetch call until this page was done (diagnostics; nil for `.late`).
    public var seconds: Double?
}

/// One GET without following redirects; returns the response, the body (≤ `maxBytes`, else `.tooLarge`) and the
/// remote address the connection used (nil when unknown).
public protocol PageTransport: Sendable {
    func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?)
}

public struct PageFetchLimits: Sendable, Equatable {
    public var timeout: TimeInterval = 5
    public var maxBytes = 3 * 1024 * 1024
    public var parallel = 6
    /// M7 final: a 429 / 503 answer is asked once more after its `Retry-After` (seconds; 1 s when absent) when that is
    /// at most this long; a longer wait is a failure, as before. Never more than one retry per page.
    public var retryAfterMax: TimeInterval = 2
    /// M7 final: the pause between two requests to the same host in one fetch (requests to one host never overlap).
    public var sameHostGap: TimeInterval = 0.25
    public init() {}
}

public struct PageFetcher: Sendable {
    public static let acceptedTypes = ["text/html", "application/xhtml+xml", "application/pdf", "text/plain"]
    public static var userAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "AntiChat/\(v) (+https://antichat.app/bot)"
    }

    public let ssrf: SSRFGuard
    public let transport: any PageTransport
    public let cache: any WebCache
    public let limits: PageFetchLimits
    let robots: RobotsCache

    public init(ssrf: SSRFGuard = SSRFGuard(), transport: any PageTransport = GatedPageTransport(),
                cache: any WebCache = MemoryWebCache(), limits: PageFetchLimits = PageFetchLimits()) {
        self.ssrf = ssrf; self.transport = transport; self.cache = cache; self.limits = limits; robots = RobotsCache()
    }

    /// Fetches `urls` (order kept), at most `limits.parallel` hosts at a time.
    /// M7 final (politeness; AT-248 c1): one request at a time per host, `limits.sameHostGap` apart — support.apple.com
    /// answered a second page fetched in parallel from it with 429 (the first was served), so its page that states
    /// the current version reached the evidence as a snippet only. Different hosts still fetch in parallel.
    /// `images`: M7.T03 favicons (`image/*` instead of the page types).
    public func fetch(_ urls: [URL], images: Bool = false) async -> [PageFetchResult] {
        await fetchAll(urls, images: images) { _, _ in }
    }

    /// M9.T05 (AT-254 T3 first token, cold page caches): like `fetch`, but returns once every page is in or `deadline`
    /// seconds after the call, whichever comes first. A page not in by then comes back as `.late` (the caller uses its
    /// snippet); its fetch is not cancelled — it finishes in the background (same per-host politeness) and fills the
    /// page cache, so a follow-up turn reads it. nil = wait for every page (`fetch`). Production assistants answer from
    /// the pages that arrived in time the same way.
    public func fetch(_ urls: [URL], images: Bool = false, deadline: TimeInterval?) async -> [PageFetchResult] {
        guard let deadline, !urls.isEmpty else { return await fetch(urls, images: images) }
        let (stream, sink) = AsyncStream.makeStream(of: (Int, PageFetchResult).self)
        let fetcher = self
        Task.detached {
            _ = await fetcher.fetchAll(urls, images: images) { i, r in sink.yield((i, r)) }
            sink.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: .milliseconds(Int(deadline * 1000)))
            sink.finish()  // later pages are dropped from this stream (still cached by their fetch)
        }
        defer { timer.cancel() }
        var out = [PageFetchResult?](repeating: nil, count: urls.count), got = 0
        for await (i, r) in stream {
            if out[i] == nil { got += 1 }
            out[i] = r
            if got == urls.count { break }
        }
        return urls.indices.map { out[$0] ?? PageFetchResult(url: urls[$0], page: nil, failure: .late) }
    }

    /// Fetches every page; `arrived` is called as each one is done (index into `urls`, result).
    func fetchAll(_ urls: [URL], images: Bool, arrived: @escaping @Sendable (Int, PageFetchResult) -> Void) async -> [PageFetchResult] {
        let start = ContinuousClock.now
        var groups: [[Int]] = [], byHost: [String: Int] = [:]
        for (i, u) in urls.enumerated() {
            let host = u.host()?.lowercased() ?? ""
            if let g = byHost[host] { groups[g].append(i) } else { byHost[host] = groups.count; groups.append([i]) }
        }
        let gap = limits.sameHostGap, cache = self.cache
        return await withTaskGroup(of: [(Int, PageFetchResult)].self) { group in
            var next = 0, out = [PageFetchResult?](repeating: nil, count: urls.count)
            func add() {
                guard next < groups.count else { return }
                let g = groups[next]
                next += 1
                group.addTask {
                    var rs: [(Int, PageFetchResult)] = []
                    for (k, i) in g.enumerated() {
                        if k > 0, gap > 0, cache.get(urls[i]) == nil { try? await Task.sleep(for: .milliseconds(Int(gap * 1000))) }
                        var r = await fetchOne(urls[i], images: images)
                        let d = ContinuousClock.now - start
                        r.seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                        arrived(i, r)
                        rs.append((i, r))
                    }
                    return rs
                }
            }
            for _ in 0..<min(limits.parallel, groups.count) { add() }
            for await rs in group {
                for (i, r) in rs { out[i] = r }
                add()
            }
            return out.compactMap { $0 }
        }
    }

    func fetchOne(_ url: URL, images: Bool = false) async -> PageFetchResult {
        if let hit = cache.get(url) { return PageFetchResult(url: url, page: hit, failure: nil) }
        var current = url, retried = false, hops = 0
        do {
            while hops <= SSRFGuard.maxRedirects {
                try ssrf.check(current)
                if await robots.disallows(current, fetcher: self) { return PageFetchResult(url: url, page: nil, failure: .robots) }
                let hop = request(current), transport = self.transport, maxBytes = limits.maxBytes
                let (resp, data, remote) = try await withTimeout(limits.timeout) {
                    try await transport.get(hop, maxBytes: maxBytes)
                }
                if let remote, !SSRFGuard.isPublic(remote) { throw FetchFailure.refused(.privateAddress(remote)) }
                if (300..<400).contains(resp.statusCode), let loc = resp.value(forHTTPHeaderField: "Location"),
                   let nextURL = URL(string: loc, relativeTo: current)?.absoluteURL {
                    current = nextURL
                    hops += 1
                    continue
                }
                // M7 final (AT-248 c1: support.apple.com answered the app's page fetch with 429 in bursts): honour the
                // server's back-off once — wait its Retry-After (≤ retryAfterMax), then ask again; same request.
                if !retried, let wait = Self.retryWait(resp, max: limits.retryAfterMax) {
                    retried = true
                    try await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                    continue
                }
                guard resp.statusCode == 200 else { throw FetchFailure.http(resp.statusCode) }
                let type = (resp.value(forHTTPHeaderField: "Content-Type") ?? "text/html").split(separator: ";").first
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/html"
                guard images ? type.hasPrefix("image/") : Self.acceptedTypes.contains(type) else { throw FetchFailure.contentType(type) }
                let page = FetchedPage(requestedURL: url, url: current, status: 200, contentType: type, data: data,
                                       fetchedAt: Date(), fromCache: false)
                cache.put(page)
                return PageFetchResult(url: url, page: page, failure: nil)
            }
            throw FetchFailure.refused(.tooManyRedirects)
        } catch let f as FetchFailure {
            return PageFetchResult(url: url, page: nil, failure: f)
        } catch let r as SSRFGuard.Refusal {
            return PageFetchResult(url: url, page: nil, failure: .refused(r))
        } catch let e as URLError where e.code == .timedOut {
            return PageFetchResult(url: url, page: nil, failure: .timeout)
        } catch {
            return PageFetchResult(url: url, page: nil, failure: .network("\(error.localizedDescription)"))
        }
    }

    /// The wait before the one retry of a 429 / 503 answer: its `Retry-After` in seconds (1 s when absent or an
    /// HTTP date), nil when it asks for longer than `max`.
    static func retryWait(_ resp: HTTPURLResponse, max: TimeInterval) -> TimeInterval? {
        guard resp.statusCode == 429 || resp.statusCode == 503 else { return nil }
        let wait = resp.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? 1
        return wait >= 0 && wait <= max ? wait : nil
    }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: limits.timeout)
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        return r
    }

    /// The robots.txt body for `url`'s origin (same host, same checks; failures = allow).
    func robotsBody(for url: URL) async -> String? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.path = "/robots.txt"; c.query = nil; c.fragment = nil
        guard let r = c.url, (try? ssrf.check(r)) != nil,
              case let req = request(r), case let transport = self.transport,
              let (resp, data, remote) = try? await withTimeout(limits.timeout, { try await transport.get(req, maxBytes: 512 * 1024) }),
              resp.statusCode == 200, remote.map(SSRFGuard.isPublic) ?? true else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Per-origin robots.txt rules for the `AntiChat` token (only that group; `*` is not applied, K-NEW-SEARCH-5).
final class RobotsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [String: [String]] = [:]

    func disallows(_ url: URL, fetcher: PageFetcher) async -> Bool {
        let origin = "\(url.scheme ?? "")://\(url.host ?? "")"
        var prefixes = lock.withLock { rules[origin] }
        if prefixes == nil {
            let body = await fetcher.robotsBody(for: url) ?? ""
            let parsed = Self.antiChatDisallows(body)
            lock.withLock { rules[origin] = parsed }
            prefixes = parsed
        }
        let path = url.path.isEmpty ? "/" : url.path
        return prefixes!.contains { !$0.isEmpty && path.hasPrefix($0) }
    }

    /// `Disallow` paths of every group whose `User-agent` names `antichat`.
    static func antiChatDisallows(_ robots: String) -> [String] {
        var out: [String] = [], inGroup = false, lastWasAgent = false
        for raw in robots.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "user-agent" {
                let match = value.lowercased().contains("antichat")
                inGroup = lastWasAgent ? (inGroup || match) : match
                lastWasAgent = true
            } else {
                lastWasAgent = false
                if inGroup, key == "disallow" { out.append(value) }
            }
        }
        return out
    }
}

/// Runs `body`, failing with `FetchFailure.timeout` after `seconds` (the whole fetch, not only the first byte).
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await body() }
        g.addTask {
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            throw FetchFailure.timeout
        }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}

/// The gate's `.search` session with an ephemeral configuration (no cookies, no disk cache), redirects not followed
/// (the fetcher re-checks each hop), the connection's remote address read from the task metrics. One session per
/// request so the metrics belong to that request; the gate's recorder still writes the activity row.
public struct GatedPageTransport: PageTransport {
    public let incognito: Bool
    public init(incognito: Bool = false) { self.incognito = incognito }

    public func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?) {
        let probe = TaskProbe()
        let session = incognito ? NetworkGate.incognitoSession(for: .search, delegate: probe)
            : NetworkGate.session(for: .search, configuration: .ephemeral, delegate: probe)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: NetworkGate.tag(request, category: .search))
        guard let http = response as? HTTPURLResponse else { throw FetchFailure.network("not HTTP") }
        if http.expectedContentLength > Int64(maxBytes) { throw FetchFailure.tooLarge }
        // A redirect's (small) body is read too (M7.T16 review #13): the task then completes, so its metrics — the
        // connected address the fetcher checks on every hop — exist before the next hop is requested.
        var data = Data()
        let redirect = (300..<400).contains(http.statusCode)
        for try await b in bytes {
            if redirect { if data.count < 65_536 { data.append(b) }; continue }
            data.append(b)
            if data.count > maxBytes { throw FetchFailure.tooLarge }
        }
        if redirect { data = Data() }
        return (http, data, await probe.waitForAddress())
    }

    final class TaskProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var addr: String?
        private var collected = false
        var remoteAddress: String? { lock.withLock { addr } }
        /// The connected address once the task's metrics arrived (they follow the last byte; up to 1 s).
        func waitForAddress() async -> String? {
            for _ in 0..<100 {
                if lock.withLock({ collected }) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return remoteAddress
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)  // the fetcher follows redirects itself, SSRF-checking each hop
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            // Through an HTTP(S) proxy (a system proxy, or the test recorder) the peer is the proxy, which resolves the
            // host itself: only the pre-request resolution check applies then.
            defer { lock.withLock { collected = true } }
            guard let t = metrics.transactionMetrics.last, !t.isProxyConnection else { return }
            let a = t.remoteAddress
            lock.withLock { addr = a }
        }
    }
}
