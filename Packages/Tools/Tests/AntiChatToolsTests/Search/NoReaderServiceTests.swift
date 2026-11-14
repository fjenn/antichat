// M7.T02 step 5 (AT-249 c1, R-249 AC1): fetching pages contacts exactly the pages' own hosts (the page and its
// robots.txt); there is no code path to a reader service (r.jina.ai, Firecrawl, Diffbot …). Also: content-type and
// size limits, robots.txt for the AntiChat token only, the cache (incognito = memory only).
@testable import AntiChatTools
import Foundation
import Testing

struct NoReaderServiceTests {
    static let resolver = SSRFGuard(resolve: { _ in ["93.184.216.34"] })

    @Test func hostsContactedAreExactlyThePageHosts() async throws {
        let pages = ["https://a.test/one", "https://b.test/two?x=1", "https://c.test/three"]
        var script: [String: ScriptedPageTransport.Answer] = [:]
        for p in pages { script[p] = .page("<html><body><p>hello</p></body></html>") }
        let t = ScriptedPageTransport(script)
        let r = await PageFetcher(ssrf: Self.resolver, transport: t).fetch(pages.map { URL(string: $0)! })
        #expect(r.allSatisfy { $0.page != nil })
        let hosts = Set(t.requested.compactMap { URL(string: $0)?.host() })
        #expect(hosts == ["a.test", "b.test", "c.test"])
        #expect(t.requested.filter { !$0.hasSuffix("/robots.txt") }.sorted() == pages.sorted())
    }

    @Test func noReaderServiceIsNamedInTheSearchCode() throws {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let src = dir.appending(path: "Sources/AntiChatTools/Search")
        let files = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" || $0.pathExtension == "json" } ?? []
        #expect(!files.isEmpty)
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8).lowercased()
            for needle in ["r.jina.ai", "firecrawl", "diffbot", "mercury.postlight", "readability-api", "scrapingbee"] {
                #expect(!s.contains(needle), "\(f.lastPathComponent) names \(needle)")
            }
        }
    }

    @Test func limitsTypesAndStatus() async {
        let t = ScriptedPageTransport([
            "https://t.test/img": .typed("image/png", Data([1, 2])), "https://t.test/big": .big(4 * 1024 * 1024),
            "https://t.test/404": .status(404), "https://t.test/pdf": .typed("application/pdf", Data("%PDF".utf8)),
            "https://t.test/txt": .typed("text/plain; charset=utf-8", Data("plain".utf8)),
        ])
        let r = await PageFetcher(ssrf: Self.resolver, transport: t).fetch(
            ["img", "big", "404", "pdf", "txt"].map { URL(string: "https://t.test/\($0)")! })
        #expect(r[0].failure == .contentType("image/png"))
        #expect(r[1].failure == .tooLarge)
        #expect(r[2].failure == .http(404))
        #expect(r[3].page?.contentType == "application/pdf" && r[4].page?.contentType == "text/plain")
    }

    @Test func robotsDisallowForTheAntiChatTokenOnly() async {
        let robots = "User-agent: *\nDisallow: /\n\nUser-agent: AntiChat\nDisallow: /private\n"
        let t = ScriptedPageTransport([
            "https://r.test/robots.txt": .typed("text/plain", Data(robots.utf8)),
            "https://r.test/private/x": .page("<html>p</html>"), "https://r.test/public": .page("<html>ok</html>"),
        ])
        let r = await PageFetcher(ssrf: Self.resolver, transport: t).fetch(
            [URL(string: "https://r.test/private/x")!, URL(string: "https://r.test/public")!])
        #expect(r[0].failure == .robots)
        #expect(r[1].page != nil, "the `*` group is not applied (K-NEW-SEARCH-5)")
        #expect(!t.requested.contains("https://r.test/private/x"))
        #expect(RobotsCache.antiChatDisallows("User-agent: Googlebot\nUser-agent: antichat\nDisallow: /a\nDisallow: /b") == ["/a", "/b"])
    }

    @Test func cacheServesRepeatsAndIncognitoStaysInMemory() async throws {
        let t = ScriptedPageTransport(["https://k.test/p": .page("<html>cached</html>")])
        let mem = MemoryWebCache()
        let f = PageFetcher(ssrf: Self.resolver, transport: t, cache: mem)
        _ = await f.fetch([URL(string: "https://k.test/p")!])
        let again = await f.fetch([URL(string: "https://k.test/p")!])
        #expect(again.first?.page?.fromCache == true)
        #expect(t.requested.filter { $0 == "https://k.test/p" }.count == 1)

        let dir = FileManager.default.temporaryDirectory.appending(path: "webcache-\(UUID().uuidString)")
        let disk = DiskWebCache(directory: dir, ttl: 3600, maxBytes: 600)
        let page = FetchedPage(requestedURL: URL(string: "https://k.test/p")!, url: URL(string: "https://k.test/p")!, status: 200,
                               contentType: "text/html", data: Data("0123456789".utf8), fetchedAt: Date(), fromCache: false)
        disk.put(page)
        #expect(disk.get(page.requestedURL)?.data == page.data)
        for i in 0..<10 { var p = page; p.requestedURL = URL(string: "https://k.test/\(i)")!; disk.put(p) }
        let size = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        #expect(size <= 600, "evicted to the cap")
    }
}
