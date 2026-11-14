// M7.T02 step 1 (AT-NFR-SEC5 part, DoD: ≥ 15 cases): every refused range, the scheme rule, a redirect to a private
// address, the address the connection used, and DNS rebinding (first answer public, second private).
@testable import AntiChatTools
import Foundation
import Testing

struct SSRFGuardTests {
    static func fixed(_ map: [String: [String]]) -> SSRFGuard { SSRFGuard(resolve: { map[$0] ?? [] }) }

    @Test(arguments: [
        "127.0.0.1", "127.8.9.10", "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.1",
        "169.254.169.254", "100.64.0.1", "100.127.255.255", "0.0.0.0", "224.0.0.1", "255.255.255.255", "198.18.0.1",
        "192.0.2.5", "::1", "::", "fc00::1", "fd12:3456::1", "fe80::1", "fe80::1%en0", "fec0::1", "ff02::1",
        "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:169.254.169.254", "::127.0.0.1", "64:ff9b::a00:1",
        "2002:7f00:0001::1", "2002:c0a8:0101::1", "2001:db8::1",
    ])
    func refusedAddresses(_ a: String) {
        #expect(!SSRFGuard.isPublic(a), "\(a) must be refused")
    }

    @Test(arguments: ["93.184.216.34", "1.1.1.1", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700:4700::1111",
                      "::ffff:93.184.216.34", "2002:5db8:d822::1"])
    func publicAddresses(_ a: String) {
        #expect(SSRFGuard.isPublic(a), "\(a) must be allowed")
    }

    @Test func schemesOtherThanHTTPAreRefused() {
        let g = Self.fixed([:])
        for u in ["file:///etc/passwd", "data:text/html,hi", "ftp://example.com/x", "javascript:alert(1)", "gopher://x/"] {
            #expect(throws: SSRFGuard.Refusal.self, "\(u)") { try g.check(URL(string: u)!) }
        }
    }

    @Test func literalAndResolvedHosts() throws {
        let g = Self.fixed(["good.test": ["93.184.216.34"], "inner.test": ["10.1.2.3"], "mixed.test": ["93.184.216.34", "127.0.0.1"]])
        #expect(try g.check(URL(string: "https://good.test/page")!) == ["93.184.216.34"])
        #expect(throws: SSRFGuard.Refusal.privateAddress("10.1.2.3")) { try g.check(URL(string: "http://inner.test/")!) }
        #expect(throws: SSRFGuard.Refusal.privateAddress("127.0.0.1")) { try g.check(URL(string: "http://mixed.test/")!) }
        #expect(throws: SSRFGuard.Refusal.self) { try g.check(URL(string: "http://[::1]:8080/")!) }
        #expect(throws: SSRFGuard.Refusal.self) { try g.check(URL(string: "http://127.0.0.1/")!) }
        #expect(throws: SSRFGuard.Refusal.unresolvable("nowhere.test")) { try g.check(URL(string: "http://nowhere.test/")!) }
    }

    /// The fetcher re-checks every redirect hop and the connected address.
    @Test func redirectToAPrivateAddressIsRefused() async {
        let t = ScriptedPageTransport([
            "https://good.test/a": .redirect("http://inner.test/admin"),
            "http://inner.test/admin": .page("<html>secret</html>"),
        ])
        let f = PageFetcher(ssrf: Self.fixed(["good.test": ["93.184.216.34"], "inner.test": ["192.168.0.10"]]), transport: t)
        let r = await f.fetch([URL(string: "https://good.test/a")!])
        #expect(r.first?.failure == .refused(.privateAddress("192.168.0.10")))
        #expect(!t.requested.contains("http://inner.test/admin"), "the private hop is never requested")
    }

    @Test func dnsRebindingIsCaughtAtTheConnectedAddress() async {
        // The check resolves to a public address; the connection then lands on a private one (second resolution).
        let t = ScriptedPageTransport(["https://rebind.test/x": .page("<html>x</html>")], remote: ["https://rebind.test/x": "127.0.0.1"])
        let f = PageFetcher(ssrf: Self.fixed(["rebind.test": ["93.184.216.34"]]), transport: t)
        let r = await f.fetch([URL(string: "https://rebind.test/x")!])
        #expect(r.first?.failure == .refused(.privateAddress("127.0.0.1")))
    }

    @Test func tooManyRedirects() async {
        var script: [String: ScriptedPageTransport.Answer] = [:]
        for i in 0..<8 { script["https://loop.test/\(i)"] = .redirect("https://loop.test/\(i + 1)") }
        let f = PageFetcher(ssrf: Self.fixed(["loop.test": ["93.184.216.34"]]), transport: ScriptedPageTransport(script))
        let r = await f.fetch([URL(string: "https://loop.test/0")!])
        #expect(r.first?.failure == .refused(.tooManyRedirects))
    }
}

/// Answers by absolute URL; records every request URL (and host) in order.
final class ScriptedPageTransport: PageTransport, @unchecked Sendable {
    enum Answer: Sendable { case page(String), redirect(String), status(Int), typed(String, Data), big(Int), slow(Double, String) }
    let script: [String: Answer]
    let remote: [String: String]
    private let lock = NSLock()
    private var log: [String] = []
    var requested: [String] { lock.withLock { log } }

    init(_ script: [String: Answer], remote: [String: String] = [:]) { self.script = script; self.remote = remote }

    func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?) {
        let u = request.url!.absoluteString
        lock.withLock { log.append(u) }
        func resp(_ code: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let addr = remote[u] ?? "93.184.216.34"
        switch script[u] ?? .status(404) {
        case .page(let h): return (resp(200, ["Content-Type": "text/html; charset=utf-8"]), Data(h.utf8), addr)
        case .redirect(let to): return (resp(302, ["Location": to]), Data(), addr)
        case .status(let s): return (resp(s, [:]), Data(), addr)
        case .typed(let t, let d): return (resp(200, ["Content-Type": t]), d, addr)
        case .big(let n): if n > maxBytes { throw FetchFailure.tooLarge }; return (resp(200, ["Content-Type": "text/html"]), Data(count: n), addr)
        case .slow(let s, let h):
            try await Task.sleep(for: .milliseconds(Int(s * 1000)))
            return (resp(200, ["Content-Type": "text/html; charset=utf-8"]), Data(h.utf8), addr)
        }
    }
}

/// M7 final: a 429 / 503 page answer is asked once more after its Retry-After (≤ 2 s); never twice, never a long wait.
@Suite struct PageFetchRetryTests {
    final class Flaky: PageTransport, @unchecked Sendable {
        let answers: [(Int, [String: String])]
        private let lock = NSLock()
        private var n = 0
        var calls: Int { lock.withLock { n } }
        init(_ answers: [(Int, [String: String])]) { self.answers = answers }
        func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?) {
            if request.url!.path == "/robots.txt" {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data(), "93.184.216.34")
            }
            let i = lock.withLock { n += 1; return n - 1 }
            let (code, headers) = answers[min(i, answers.count - 1)]
            var h = headers
            if code == 200 { h["Content-Type"] = "text/html" }
            return (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: h)!,
                    Data(code == 200 ? "<html>ok</html>".utf8 : "slow down".utf8), "93.184.216.34")
        }
    }
    static func fetcher(_ t: Flaky) -> PageFetcher {
        PageFetcher(ssrf: SSRFGuardTests.fixed(["rl.test": ["93.184.216.34"]]), transport: t)
    }
    static let url = URL(string: "https://rl.test/page")!

    @Test func a429IsRetriedOnceAfterItsRetryAfter() async {
        let t = Flaky([(429, ["Retry-After": "0"]), (200, [:])])
        let r = await Self.fetcher(t).fetch([Self.url])
        #expect(r.first?.page?.status == 200 && t.calls == 2)
    }

    @Test func aSecond429FailsAndThereIsNoThirdRequest() async {
        let t = Flaky([(503, ["Retry-After": "0"]), (429, ["Retry-After": "0"]), (200, [:])])
        let r = await Self.fetcher(t).fetch([Self.url])
        #expect(r.first?.failure == .http(429) && t.calls == 2)
    }

    @Test func aLongRetryAfterIsNotWaitedFor() async {
        let t = Flaky([(429, ["Retry-After": "120"]), (200, [:])])
        let r = await Self.fetcher(t).fetch([Self.url])
        #expect(r.first?.failure == .http(429) && t.calls == 1)
        let other = Flaky([(404, [:]), (200, [:])])
        #expect(await Self.fetcher(other).fetch([Self.url]).first?.failure == .http(404) && other.calls == 1)
    }
}

/// M7 final: requests to one host never overlap within a fetch; other hosts still run in parallel; order is kept.
@Suite struct PageFetchPerHostTests {
    final class Tracking: PageTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var active: [String: Int] = [:]
        private var maxActive: [String: Int] = [:]
        private var total = 0, maxTotal = 0
        func peak(_ h: String) -> Int { lock.withLock { maxActive[h] ?? 0 } }
        var peakTotal: Int { lock.withLock { maxTotal } }
        func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?) {
            let h = request.url!.host()!
            if request.url!.path == "/robots.txt" {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data(), "93.184.216.34")
            }
            lock.withLock { active[h, default: 0] += 1; maxActive[h] = max(maxActive[h] ?? 0, active[h]!); total += 1; maxTotal = max(maxTotal, total) }
            try? await Task.sleep(for: .milliseconds(40))
            lock.withLock { active[h]! -= 1; total -= 1 }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!,
                    Data("<html>\(request.url!.path)</html>".utf8), "93.184.216.34")
        }
    }

    @Test func oneRequestAtATimePerHost() async {
        let t = Tracking()
        var limits = PageFetchLimits(); limits.sameHostGap = 0.01
        let f = PageFetcher(ssrf: SSRFGuardTests.fixed(["a.test": ["93.184.216.34"], "b.test": ["93.184.216.34"], "c.test": ["93.184.216.34"]]),
                            transport: t, limits: limits)
        let urls = ["https://a.test/1", "https://b.test/1", "https://a.test/2", "https://c.test/1", "https://a.test/3"].map { URL(string: $0)! }
        let r = await f.fetch(urls)
        #expect(r.map(\.url) == urls && r.allSatisfy { $0.page?.status == 200 })
        #expect(t.peak("a.test") == 1)
        #expect(t.peakTotal >= 2, "different hosts still fetch in parallel")
    }
}
