// M7.T01 step 10 (AT-248 c2/c3): the broker's race, merge/dedupe and fallback chain with stub engines (no network):
// timeouts, 403, zero results, all failing; plus the registry's compiled/enabled sets (no Google).
@testable import AntiChatTools
import Foundation
import OsaurusVendored
import Testing

/// Answers per engine id: HTML in the Mojeek result shape, a status, or a delay.
struct StubTransport: SearchTransport {
    enum Answer: Sendable { case hits([String]), status(Int), delay(Double, [String]), json(String) }
    let answers: [String: Answer]
    let calls: CallLog

    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(engine: String, url: URL)] = []
        func add(_ e: String, _ u: URL) { lock.withLock { items.append((e, u)) } }
        var all: [(engine: String, url: URL)] { lock.withLock { items } }
    }

    init(_ answers: [String: Answer], calls: CallLog = CallLog()) { self.answers = answers; self.calls = calls }

    static func page(_ urls: [String]) -> Data {
        let lis = urls.map { "<li><h2><a href=\"\($0)\">Title \($0)</a></h2><p class=\"s\">About \($0)</p></li>" }.joined()
        return Data("<html><body><ul class=\"results-standard\">\(lis)</ul></body></html>".utf8)
    }

    func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
        calls.add(engine, request.url!)
        switch answers[engine] ?? .status(500) {
        case .hits(let u): return (200, Self.page(u))
        case .status(let s): return (s, Data())
        case .delay(let d, let u):
            try await Task.sleep(for: .milliseconds(Int(d * 1000)))
            return (200, Self.page(u))
        case .json(let j): return (200, Data(j.utf8))
        }
    }
}

enum StubEngines {
    static func html(_ id: String) -> SearchEngineConfig {
        var c = MojeekEngine.config
        c.id = id; c.name = id.capitalized; c.urlTemplate = "https://\(id).test/search?q={q}"
        c.safeParam = .init(off: "safe=off", on: "safe=on")
        return c
    }
    static let registry = EngineRegistry(configs: ["a", "b", "c"].map(html) + [WikipediaDefinition.config!], appVersion: "1.0.0")
    static let wikiJSON = #"{"query":{"search":[{"title":"Printing press","snippet":"A <span class=\"searchmatch\">printing</span> press"}]}}"#
}

struct SearchBrokerTests {
    @Test func defaultRegistryIsTheFiveEnginesAndNoGoogle() {
        let r = EngineRegistry(appVersion: "1.0.0")
        #expect(r.enabled == ["duckduckgo", "brave", "mojeek", "startpage", "wikipedia"])
        #expect(EngineRegistry.allCompiled.contains("bing") && !r.enabled.contains("bing"))
        #expect(!EngineRegistry.allCompiled.contains { $0.lowercased().contains("google") })
        #expect(r.enabledNames == ["DuckDuckGo", "Brave", "Mojeek", "Startpage", "Wikipedia"])
        #expect(r.enabledHosts == ["html.duckduckgo.com", "search.brave.com", "www.mojeek.com", "www.startpage.com", "en.wikipedia.org"])
    }

    @Test func raceMergesRoundRobinAndDedupesByNormalizedURL() async {
        let t = StubTransport(["a": .hits(["https://x.test/1", "https://y.test/2"]),
                               "b": .hits(["https://www.x.test/1/", "https://z.test/3?utm_source=b"]),
                               "c": .hits(["https://z.test/3#frag"])])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false }).search(queries: ["q"])
        #expect(r.outcome == .ok)
        #expect(r.hits.map(\.url) == ["https://x.test/1", "https://z.test/3#frag", "https://y.test/2"])
        #expect(r.hits.map(\.engine) == ["a", "c", "a"])
        #expect(t.calls.all.allSatisfy { $0.engine != "wikipedia" }, "Wikipedia is the fallback tier, not raced")
    }

    @Test func blockedAndEmptyEnginesFallThroughToTheOthers() async {
        let t = StubTransport(["a": .status(403), "b": .hits([]), "c": .hits(["https://ok.test/"])])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false }).search(queries: ["q"])
        #expect(r.hits.map(\.url) == ["https://ok.test/"])
        let kinds = Dictionary(uniqueKeysWithValues: r.attempts.map { ($0.provider, $0.kind) })
        #expect(kinds["a"] == .providerAuth && kinds["b"] == .empty && kinds["c"] == .success)
    }

    @Test func slowEngineIsCutAtTheRaceBudget() async {
        // The slow engine would answer only after 600 s: the search returning with its attempt marked timeout is the
        // cut (order, not a wall-clock bar a loaded host stretches).
        let t = StubTransport(["a": .delay(600, ["https://slow.test/"]), "b": .hits(["https://fast.test/"]), "c": .status(500)])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false })
            .search(queries: ["q"], budget: SearchBudget(raceBudget: 0.3))
        #expect(r.hits.map(\.url) == ["https://fast.test/"])
        #expect(r.attempts.first { $0.provider == "a" }?.kind == .timeout)
    }

    @Test func allHTMLEnginesFailingFallsBackToWikipedia() async {
        let t = StubTransport(["a": .status(403), "b": .status(429), "c": .delay(600, ["https://late.test/"]),
                               "wikipedia": .json(StubEngines.wikiJSON)])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false })
            .search(queries: ["printing press"], budget: SearchBudget(raceBudget: 0.3))
        #expect(r.outcome == .ok)
        #expect(r.hits.first?.url == "https://en.wikipedia.org/wiki/Printing_press")
        #expect(r.hits.first?.snippet == "A printing press")
        #expect(r.hits.first?.engine == "wikipedia")
    }

    @Test func everythingFailingIsFailedWithTheKinds() async {
        let t = StubTransport(["a": .status(403), "b": .status(500), "c": .hits([]), "wikipedia": .status(503)])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false }).search(queries: ["q"])
        #expect(r.isFailed)
        if case .failed(let reason) = r.outcome { #expect(reason.contains("provider_auth") && reason.contains("empty")) }
        #expect(r.hits.isEmpty)
    }

    @Test func severalQueriesRunAndMerge() async {
        let t = StubTransport(["a": .hits(["https://one.test/"]), "b": .status(403), "c": .status(403)])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false })
            .search(queries: ["first", "second", "  "])
        #expect(t.calls.all.filter { $0.engine == "a" }.count == 2, "blank queries are dropped")
        #expect(r.hits.count == 1, "the same URL from two queries is kept once")
        let empty = await SearchBroker(registry: StubEngines.registry, transport: t).search(queries: [" "])
        #expect(empty.isFailed)
    }

    @Test func blockRuleAnswers403WithoutCallingTheInnerTransport() async throws {
        let inner = StubTransport(["a": .hits(["https://x.test/"])])
        let t = BlockingSearchTransport(inner: inner, blocked: ["a"])
        let (s, d) = try await t.send(URLRequest(url: URL(string: "https://a.test/")!), engine: "a", query: "q")
        #expect(s == 403 && d.isEmpty && inner.calls.all.isEmpty)
    }

    @Test func replayAnswersFromTheSnapshotOr404() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "a"), withIntermediateDirectories: true)
        try StubTransport.page(["https://r.test/"]).write(to: dir.appending(path: "a/q001.html"))
        let t = ReplaySearchTransport(root: dir, qids: ["hello": "q001"])
        let r = await SearchBroker(registry: StubEngines.registry, transport: t, safeSearch: { false }).search(queries: ["hello"])
        #expect(r.hits.map(\.url) == ["https://r.test/"])
        let (s, _) = try await t.send(URLRequest(url: URL(string: "https://a.test/")!), engine: "a", query: "other")
        #expect(s == 404)
    }

    @Test func normalizeKey() {
        #expect(SearchBroker.normalize("https://WWW.Example.com/a/?utm_medium=x#top") == "example.com/a")
        #expect(SearchBroker.normalize("http://example.com/a?b=1") == "example.com/a?b=1")
    }
}
