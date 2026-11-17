// The live list of apps (LiveAppCatalog): the merge with the bundled curated catalogue, the refresh against a stubbed
// relay (RelayStub, no network; temp folders), the derived one-line summary (AppSummary), the category mapping and
// the logo host allow-list and folder (AppLogoCache).
import AntiChatFoundation
@testable import AntiChatNetwork
@testable import AntiChatTools
import Foundation
import Testing

@Suite(.serialized) struct LiveAppCatalogTests {
    static let today = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!

    /// The curated snapshot: three apps, a category map and one excluded slug.
    static let bundled = ComposioCatalog(data: Data(#"""
    {"generated":"2026-11-16",
     "categories":[{"id":"popular","title":"Popular"},{"id":"communication","title":"Communication"},{"id":"sales","title":"Sales & CRM"},{"id":"other","title":"Other"}],
     "category_map":{"crm":"sales","team chat":"communication","model context protocol":"other"},
     "exclude":["composio_search"],
     "apps":[
      {"slug":"gmail","name":"Gmail","summary":"Read and manage Gmail","categories":["popular","communication"],"auth":"oauth","popular":1,"logo":true},
      {"slug":"slack","name":"Slack","summary":"Team chat","categories":["communication"],"auth":"oauth","popular":null,"logo":true},
      {"slug":"hackernews","name":"Hacker News","summary":"Tech news and discussion","categories":["other"],"auth":"none","popular":null,"logo":true}
     ]}
    """#.utf8))

    static func toolkit(_ slug: String, _ name: String, _ description: String = "", categories: [String] = [], auth: String = "oauth",
                        logo: String? = nil) -> RelayToolkit {
        RelayToolkit(slug: slug, name: name, description: description, categories: categories, auth: auth,
                     logo: logo ?? "https://logos.composio.dev/api/\(slug)")
    }

    static let acme = toolkit("acme_crm", "Acme CRM MCP", "Acme CRM is a powerful platform that helps teams track deals and close more business. More.",
                              categories: ["Model Context Protocol", "CRM"], auth: "apikey")

    static func body(_ toolkits: [RelayToolkit], generated: String = "2026-11-20T09:00:00.000Z") -> String {
        let rows = toolkits.map { t in
            let o: [String: Any] = ["slug": t.slug, "name": t.name, "description": t.description, "categories": t.categories, "auth": t.auth, "logo": t.logo]
            return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
        }
        return #"{"generated":"\#(generated)","toolkits":[\#(rows.joined(separator: ","))]}"#
    }

    // MARK: Merge

    @Test func theCuratedEntryWinsAndANewAppGetsADerivedOne() {
        let live = [Self.toolkit("gmail", "Google Mail (Composio)", "Composio's own words about Gmail.", categories: ["CRM"]), Self.acme]
        let c = LiveAppCatalog.merge(bundled: Self.bundled, live: live, generated: "2026-11-20T09:00:00.000Z")
        #expect(c.apps.map(\.slug) == ["gmail", "acme_crm"])  // popular first
        #expect(c.app("gmail") == Self.bundled.app("gmail"))  // name, summary, categories, rank: ours
        #expect(c.app("gmail")?.logoURL == nil)  // and the bundled logo
        let new = try! #require(c.app("acme_crm"))
        #expect(new.name == "Acme CRM")  // Composio's, without the trailing " MCP"
        #expect(new.summary == "Platform")
        #expect(new.categories == ["sales"] && new.popular == nil)
        #expect(new.logoURL == URL(string: "https://logos.composio.dev/api/acme_crm"))
        #expect(c.generated == "2026-11-20T09:00:00.000Z")
        #expect(c.categories == Self.bundled.categories && c.categoryMap == Self.bundled.categoryMap && c.excluded == ["composio_search"])
        #expect(c.search("acme").map(\.slug) == ["acme_crm"] && c.slug(named: "Acme CRM") == "acme_crm")
    }

    @Test func aRemovedAppDisappearsUnlessItIsConnected() {
        let live = [Self.toolkit("gmail", "Gmail")]
        #expect(LiveAppCatalog.merge(bundled: Self.bundled, live: live).apps.map(\.slug) == ["gmail"])
        let c = LiveAppCatalog.merge(bundled: Self.bundled, live: live, connected: ["slack", "old_tool", "../x"])
        #expect(c.apps.map(\.slug) == ["gmail", "old_tool", "slack"])
        #expect(c.app("slack") == Self.bundled.app("slack"))  // still ours, to disconnect
        #expect(c.app("old_tool")?.name == "Old Tool" && c.app("old_tool")?.categories == ["other"])
    }

    @Test func whatTheBundledCatalogueLeavesOutStaysOut() {
        let live = [
            Self.toolkit("composio_search", "Composio Search", "Search."),  // on the exclude list
            Self.toolkit("clock", "Clock", "Tells the time.", auth: "none"),  // a no-sign-in utility we did not pick
            Self.toolkit("hackernews", "Hacker News", auth: "none"),  // one we did pick: the bundled entry
            Self.toolkit("oldapi", "Old API", "Deprecated: use New API."),
            Self.toolkit("Bad Slug", "Bad"), Self.toolkit("gmail", "Gmail"), Self.toolkit("gmail", "Gmail again"),
            Self.toolkit("misc", "Misc", "Something useful for everyone.", categories: ["Unheard Of", "Model Context Protocol"]),
        ]
        let c = LiveAppCatalog.merge(bundled: Self.bundled, live: live)
        #expect(c.apps.map(\.slug) == ["gmail", "hackernews", "misc"])
        #expect(c.app("misc")?.categories == ["other"])  // an unknown category
        #expect(c.apps(in: "other").map(\.slug) == ["hackernews", "misc"])
        #expect(c.apps(in: "sales").isEmpty)  // the page hides an empty category
    }

    @Test func categoriesMapThroughTheTable() throws {
        let map = Self.bundled.categoryMap
        #expect(LiveAppCatalog.category(["CRM"], map: map) == "sales")
        #expect(LiveAppCatalog.category([" team chat ", "CRM"], map: map) == "communication")
        #expect(LiveAppCatalog.category(["Model Context Protocol", "CRM"], map: map) == "sales")
        #expect(LiveAppCatalog.category(["Model Context Protocol"], map: map) == "other")
        #expect(LiveAppCatalog.category([], map: map) == "other" && LiveAppCatalog.category(["Nope"], map: map) == "other")
        #expect(LiveAppCatalog.displayName("  Notion   MCP ", slug: "notion_mcp") == "Notion")
        #expect(LiveAppCatalog.displayName("MCP", slug: "mcp") == "MCP" && LiveAppCatalog.displayName("", slug: "my_app") == "My App")

        // The shipped catalogue carries the table and the exclude list of tools/composio/overrides.json, and every
        // target is a category it has.
        let shipped = ComposioCatalog.bundled
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../../tools/composio/overrides.json").standardizedFileURL
        let ov = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any])
        #expect(shipped.categoryMap == ov["category_map"] as? [String: String] && shipped.categoryMap.count > 50)
        #expect(shipped.excluded == Set(ov["exclude"] as? [String] ?? []) && !shipped.excluded.isEmpty)
        let ids = Set(shipped.categories.map(\.id))
        #expect(shipped.categoryMap.values.allSatisfy(ids.contains) && ids.contains("other"))
        #expect(shipped.apps.count > 1000 && shipped.apps.allSatisfy { !shipped.excluded.contains($0.slug) && $0.logoURL == nil })
    }

    // MARK: Summary

    @Test func theSummaryIsDerivedLikeTheCatalogueTool() {
        // Expected values are what `generated_summary` of tools/composio/build-catalog.py answers for the same input.
        let cases: [(String, String, String)] = [
            ("Acme CRM", "Acme CRM is a powerful platform that helps teams track deals and close more business. It also does X.", "Platform"),
            ("Gmail", "Gmail is Google's email service, featuring spam protection, search functions, and seamless integration with other G Suite apps for productivity", "Google's email service"),
            ("Linear", "Linear is a streamlined issue tracking and project planning tool for modern teams, featuring fast workflows, keyboard shortcuts, and GitHub integrations", "Streamlined issue tracking and project"),
            ("Foo", "The Foo API (beta) provides developers a simple way to send SMS messages worldwide; it is fast.", "Way to send SMS messages worldwide"),
            ("Zed", "Zed.", "Zed"),
            ("Qux", "An AI-powered, open-source assistant that summarises long meetings and writes the notes for you", "Assistant"),
            ("Nimbus", "Weather data  and\nforecasts. Updated hourly.", "Weather data and forecasts"),
            ("Mixpanel", "Mixpanel's analytics help you understand users", "Analytics help you understand users"),
            ("X", "", ""),
            // The tool strips a leading "s" here ("Cheduling…"): a slip of its `lstrip`, not a rule.
            ("Bar Tool", "BarTool: scheduling for busy salons and spas", "Scheduling for busy salons and spas"),
        ]
        for (name, description, want) in cases {
            let got = AppSummary.derive(name: name, description: description)
            #expect(got == want, "\(name)")
            #expect(got.count <= AppSummary.limit && !got.hasSuffix(".") && !got.hasSuffix(" "))
        }
        #expect(AppSummary.firstSentence("Works with Node.js and more. Second.") == "Works with Node.js and more")
        #expect(AppSummary.clip("Capture growth experiment ideas, manage tests and share results") == "Capture growth experiment ideas")
        #expect(AppSummary.clip("Read and send email") == "Read and send email")
        #expect(AppSummary.clip("Send transactional email and marketing campaigns to everyone") == "Send transactional email and marketing")
        #expect(AppSummary.clip("Send transactional email with templates and more") == "Send transactional email with templates")
        #expect(AppSummary.clip("Supercalifragilisticexpialidocious-and-then-some-more-letters") == "Supercalifragilisticexpialidocious-and-then-s")
        #expect(AppSummary.clip(String(repeating: "x", count: 60)).count == 45)
        #expect(AppSummary.clip("Short one.") == "Short one")
    }

    // MARK: Refresh

    final class Harness: @unchecked Sendable {
        let host: String
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-apps-tests-\(UUID().uuidString)")
        let secrets = MemorySecrets()
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        private let clock = NSLock()
        private var time = LiveAppCatalogTests.today

        /// `connected`: the install has a Composio connection (the relay category is on; it is off by default).
        init(_ name: String, connected: Bool = false) {
            host = "live-apps-\(name).test"
            if connected { policy.setEnabled(.relay, true) }
            answer(200, "{}")
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        var now: Date { clock.withLock { time } }
        func advance(_ seconds: TimeInterval) { clock.withLock { time += seconds } }
        func answer(_ status: Int, _ body: String, etag: String? = nil) {
            RelayStub.lock.withLock { RelayStub.answers[host] = (status, body, etag.map { ["ETag": $0] } ?? [:]) }
        }
        var seen: [RelayStub.Seen] { RelayStub.seen(host) }
        var relay: RelayClient {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [RelayStub.self]
            let s = URLSession(configuration: cfg)
            return RelayClient(baseURL: URL(string: "http://\(host)")!, installID: InstallID(secrets: secrets),
                               session: { [policy] in GatedSession(session: s, category: .relay, policy: policy) }, version: "1.0")
        }
        func catalog(bundled: ComposioCatalog = LiveAppCatalogTests.bundled) -> LiveAppCatalog {
            LiveAppCatalog(directory: dir, relay: relay, bundled: bundled, now: { [self] in now })
        }
        func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    }

    @Test func theLiveListIsFetchedStoredAndAskedForOnceADay() async throws {
        let h = Harness("daily")
        h.answer(200, Self.body([Self.toolkit("gmail", "Gmail"), Self.acme]), etag: "\"v1\"")
        let c = h.catalog()
        #expect(!c.isLive && c.catalog.apps.map(\.slug) == ["gmail", "hackernews", "slack"])  // the bundled one until the relay answered

        let posted = OSAllocatedCounter()
        let token = NotificationCenter.default.addObserver(forName: DirectoryCatalogs.didChange, object: c, queue: nil) { note in
            if note.userInfo?["kind"] as? String == LiveAppCatalog.kind { posted.add() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Never connected an app + launch (or the daily timer): nothing is asked and no relay ID is made.
        #expect(await c.refresh(userOpened: false, force: true) == .noInstall)
        #expect(await c.refresh(userOpened: false) == .noInstall)
        #expect(h.seen.isEmpty && InstallID(secrets: h.secrets).existing == nil && h.files().isEmpty)

        // Never connected an app + the Connections page opens: one request with the relay's usual headers.
        #expect(await c.refresh(userOpened: true) == .updated)
        let id = try #require(InstallID(secrets: h.secrets).existing)
        #expect(h.seen.map(\.path) == ["/v1/toolkits"] && h.seen[0].method == "GET")
        #expect(h.seen[0].headers["X-AntiChat-Install"] == id && h.seen[0].headers["X-AntiChat-Version"] == "1.0")
        #expect(h.seen[0].headers["User-Agent"] == "AntiChat/1.0" && h.seen[0].headers["If-None-Match"] == nil)
        #expect(c.isLive && c.catalog.apps.map(\.slug) == ["gmail", "acme_crm"])  // slack and hackernews are gone, acme_crm is new
        #expect(posted.value == 1)
        #expect(h.files() == ["relay-toolkits-state.json", "relay-toolkits.json"])

        // Within the day: no request when the page opens again; the timer still asks nothing without a connection,
        // relay ID or not.
        h.advance(23 * 3600)
        #expect(await c.refresh(userOpened: true) == .fresh)
        #expect(await c.refresh(userOpened: false, force: true) == .noInstall)
        #expect(h.seen.count == 1)
        h.policy.setEnabled(.relay, true)  // the first app is connected: the daily timer takes part from here on
        #expect(await c.refresh(userOpened: false) == .fresh)
        #expect(h.seen.count == 1)

        // A day later: a conditional request; not modified changes nothing.
        h.advance(2 * 3600)
        h.answer(304, "", etag: "\"v1\"")
        #expect(await c.refresh(userOpened: false) == .notModified)
        #expect(h.seen.count == 2 && h.seen[1].headers["If-None-Match"] == "\"v1\"")
        #expect(c.catalog.apps.map(\.slug) == ["gmail", "acme_crm"] && posted.value == 1)
        #expect(await c.refresh(userOpened: true) == .fresh)

        // Another day: the same apps under a new ETag are stored without a notification; changed ones announce.
        h.advance(25 * 3600)
        h.answer(200, Self.body([Self.toolkit("gmail", "Gmail"), Self.acme], generated: "2026-11-22T14:00:00.000Z"), etag: "\"v2\"")
        #expect(await c.refresh(userOpened: true) == .same)
        #expect(posted.value == 1)
        h.answer(200, Self.body([Self.toolkit("gmail", "Gmail"), Self.toolkit("slack", "Slack")], generated: "2026-11-22T15:00:00.000Z"), etag: "\"v3\"")
        #expect(await c.refresh(userOpened: true, force: true) == .updated)
        #expect(h.seen.last?.headers["If-None-Match"] == "\"v2\"")
        #expect(c.catalog.apps.map(\.slug) == ["gmail", "slack"] && posted.value == 2)

        // The next launch shows the stored list before any request; a newer bundled catalogue beats an older stored list.
        let before = h.seen.count
        let next = h.catalog()
        await next.loadCached()
        #expect(next.isLive && next.catalog.apps.map(\.slug) == ["gmail", "slack"])
        let newer = ComposioCatalog(categories: Self.bundled.categories, apps: Self.bundled.apps, generated: "2026-11-23")
        let updated = h.catalog(bundled: newer)
        await updated.loadCached()
        #expect(!updated.isLive && updated.catalog.apps.count == 3)
        #expect(h.seen.count == before)
    }

    @Test func aConnectedAppTheListDroppedStaysInTheCatalogue() async {
        let h = Harness("connected")
        h.answer(200, Self.body([Self.toolkit("gmail", "Gmail")]), etag: "\"v1\"")
        let connected = OSAllocatedUnfairLockBox<Set<String>>([])
        let relay = h.relay
        let c = LiveAppCatalog(directory: h.dir, source: "test", bundled: Self.bundled, fetch: { try await relay.toolkits(etag: $0, userOpened: $1) },
                               hasConnection: { true }, online: { true }, connected: { connected.value }, now: { h.now })
        #expect(await c.refresh(userOpened: false) == .updated)
        #expect(c.catalog.apps.map(\.slug) == ["gmail"])
        connected.value = ["slack"]
        #expect(c.catalog.apps.map(\.slug) == ["gmail", "slack"])
        connected.value = []
        #expect(c.catalog.apps.map(\.slug) == ["gmail"])
    }

    @Test func anOldRelayOrAFailureKeepsTheBundledCatalogueSilently() async {
        let h = Harness("old")
        h.answer(404, "The page could not be found\n\nNOT_FOUND\n")  // a relay from before /v1/toolkits
        let c = h.catalog()
        #expect(await c.refresh(userOpened: true) == .failed)
        #expect(!c.isLive && c.catalog.apps.map(\.slug) == ["gmail", "hackernews", "slack"])
        #expect(h.files().isEmpty)
        // Not asked again at once (the page may open many times); an hour later it is.
        #expect(await c.refresh(userOpened: true) == .fresh)
        #expect(h.seen.count == 1)
        h.advance(3601)
        for (status, body) in [(502, #"{"code":"relay.upstream"}"#), (429, #"{"code":"relay.rateLimited"}"#), (200, "not json"),
                               (200, #"{"generated":"2026-11-20T09:00:00Z","toolkits":[]}"#),
                               (200, #"{"generated":"2031-01-01T00:00:00Z","toolkits":[{"slug":"gmail","name":"Gmail"}]}"#),
                               (200, #"{"generated":"2026-11-20T09:00:00Z","toolkits":[{"slug":"../x","name":"X"}]}"#)] {
            h.answer(status, body, etag: "\"bad\"")
            #expect(await c.refresh(userOpened: true, force: true) == .failed, "\(status) \(body)")
            #expect(!c.isLive && c.catalog.apps.count == 3 && h.files().isEmpty)
        }

        // A list that worked stays in use when the relay fails later.
        h.answer(200, Self.body([Self.toolkit("gmail", "Gmail"), Self.acme]), etag: "\"v1\"")
        #expect(await c.refresh(userOpened: true, force: true) == .updated)
        h.advance(25 * 3600)
        h.answer(404, "NOT_FOUND")
        #expect(await c.refresh(userOpened: true) == .failed)
        #expect(c.isLive && c.catalog.apps.map(\.slug) == ["gmail", "acme_crm"])
    }

    @Test func offlineOnlyMakesNoRequest() async {
        let h = Harness("offline")
        h.answer(200, Self.body([Self.toolkit("gmail", "Gmail")]), etag: "\"v1\"")
        h.policy.offlineOnly = true
        let c = h.catalog()
        #expect(await c.refresh(userOpened: true) == .offline)
        #expect(await c.refresh(userOpened: true, force: true) == .offline)
        #expect(h.seen.isEmpty && InstallID(secrets: h.secrets).existing == nil && h.files().isEmpty)
        #expect(!c.isLive && c.catalog.apps.count == 3)
        h.policy.offlineOnly = false
        #expect(await c.refresh(userOpened: true) == .updated)
        #expect(h.seen.count == 1)

        // Offline only also stops the timer of an install with connected apps.
        let other = Harness("offline-connected", connected: true)
        _ = try? other.relay.headers()  // it has its relay ID
        other.policy.offlineOnly = true
        #expect(await other.catalog().refresh(userOpened: false, force: true) == .offline)
        #expect(other.seen.isEmpty)
    }

    // MARK: Logos

    @Test func logosComeOnlyFromComposiosLogoHostOverHTTPS() {
        for ok in ["https://logos.composio.dev/api/gmail", "https://LOGOS.composio.dev:443/api/x"] {
            #expect(AppLogoCache.logoURL(ok) != nil, "\(ok)")
        }
        for bad in ["", "http://logos.composio.dev/api/gmail", "https://evil.example/gmail.png", "https://composio.dev.evil.example/x.png",
                    "https://evilcomposio.dev/x.png", "https://composio.dev/logo.svg", "https://x.logos.composio.dev/a",
                    "https://logo.clearbit.com/x.com", "https://cdn.jsdelivr.net/gh/ComposioHQ/open-logos@master/gmail.svg", "https://user:pw@logos.composio.dev/x", "https://logos.composio.dev:8443/x",
                    "https://cdn.jsdelivr.net/gh/someone/else/x.svg", "https://cdn.jsdelivr.net/npm/x", "file:///etc/passwd",
                    "data:image/png;base64,AAAA", "//logos.composio.dev/x", "https://logos.composio.dev/" + String(repeating: "a", count: 300)] {
            #expect(AppLogoCache.logoURL(bad) == nil, "\(bad)")
        }
        let c = LiveAppCatalog.merge(bundled: Self.bundled, live: [Self.toolkit("a", "A", logo: "https://evil.example/a.png"), Self.toolkit("b", "B", logo: "")])
        #expect(c.app("a") != nil && c.app("a")?.logoURL == nil && c.app("b")?.logoURL == nil)  // shown with their initial
    }

    @Test func theLogoFolderHitsMissesAndStaysWithinTheCap() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "live-apps-logos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = { (n: Int) in Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: UInt8(n), count: 992) }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8"/></svg>"#.utf8)
        let served = OSAllocatedUnfairLockBox<[String: Data]>([:])
        let asked = OSAllocatedUnfairLockBox<[String]>([])
        let online = OSAllocatedUnfairLockBox(true)
        let cache = AppLogoCache(directory: dir, capBytes: 2500, allowed: { online.value }, loader: { request in
            asked.value += [request.url!.absoluteString]
            guard let d = served.value[request.url!.absoluteString] else { return .init(data: Data(), status: 404) }
            return .init(data: d, status: 200)
        })
        func url(_ s: String) -> URL { URL(string: "https://logos.composio.dev/api/\(s)")! }
        served.value = [url("app1").absoluteString: png(1), url("app3").absoluteString: png(3), url("app4").absoluteString: png(4),
                        url("vec").absoluteString: svg, url("html").absoluteString: Data("<html>not an image at all</html>".utf8),
                        url("none").absoluteString: Data(#"<svg id="composio-fallback" viewBox="0 0 8 8"></svg>"#.utf8),
                        url("huge").absoluteString: png(0) + Data(repeating: 0, count: AppLogoCache.maxLogoBytes)]

        online.value = false
        #expect(await cache.logo(slug: "app1", url: url("app1")) == nil && asked.value.isEmpty)  // Offline only: no request
        online.value = true
        #expect(await cache.logo(slug: "app1", url: url("app1")) == png(1))  // miss: one request
        #expect(await cache.logo(slug: "app1", url: url("app1")) == png(1))  // hit: from the folder
        #expect(asked.value == [url("app1").absoluteString])
        #expect(await cache.logo(slug: "vec", url: url("vec")) == svg)

        for bad in ["html", "none", "huge", "nope"] {
            #expect(await cache.logo(slug: bad, url: url(bad)) == nil, "\(bad)")  // not an image, the placeholder, too large, 404
            #expect(await cache.logo(slug: bad, url: url(bad)) == nil)  // and not asked again in this run
        }
        #expect(asked.value.count == 6)
        #expect(await cache.logo(slug: "../app1", url: url("app1")) == nil)  // never a path
        #expect(await cache.logo(slug: "app1", url: URL(string: "https://evil.example/app1.png")!) == nil)  // never another host
        #expect(asked.value.count == 6)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names.count == 2 && names[0].hasPrefix("app1.") && names[1].hasPrefix("vec.") && names.allSatisfy { $0.hasSuffix(".logo") })

        // The cap: 2500 bytes hold two logos; the least recently used go.
        for (name, age) in [(names[0], -7200.0), (names[1], -9000.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: age)], ofItemAtPath: dir.appending(path: name).path)
        }
        #expect(await cache.logo(slug: "app3", url: url("app3")) == png(3))
        #expect(await cache.logo(slug: "app4", url: url("app4")) == png(4))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).map { String($0.prefix(4)) }.sorted() == ["app3", "app4"])

        // A logo Composio lists at another address is fetched again and replaces the old file.
        let moved = URL(string: "https://logos.composio.dev/v2/app3")!
        served.value[moved.absoluteString] = png(9)
        #expect(await cache.logo(slug: "app3", url: moved) == png(9))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("app3.") }.count == 1)
    }
}

/// A value two threads may touch.
final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
