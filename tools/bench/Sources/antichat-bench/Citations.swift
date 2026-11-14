// `antichat-bench citations` (M7.T03 step 11; AT-250 c2, R-250 AC2, A-M7-05): judged support of cited sentences.
//
//   --capture: records, per question, what the app's own pipeline saw live (SearchBroker over the gate with the
//     keyless engines → PageFetcher top 6 hits) under `<root>/<qid>/serp/<engine>.<status>` and `<root>/<qid>/pages/`
//     (DiskWebCache files). Bot checks are saved as returned; an engine is skipped after 3 blocked answers in a row
//     (never retried or worked around). Paced 1.5 s per question.
//       antichat-bench citations --capture --fixture fixtures/prompts/citation-qa-100.jsonl --root fixtures/web/citation-qa-100
//   --stage answer: per question a real turn on the tier's model (TurnController, `web_search` forced by the Web
//     search chip like the app; the tool replays the snapshots, nothing leaves the Mac) → CitationValidator.
//   --stage judge: the judge model answers "Is sentence S supported by passage P? yes/no" for every cited sentence
//     (P = the evidence of the cited sources the answering model saw). Writes the report + spotcheck-20.csv.
//       antichat-bench citations --fixture … --root … --tier T1 --stage answer --answers build/at/AT-250/answers.json
//       antichat-bench citations --stage judge --answers … --judge chat-122b --out build/at/AT-250/<date>.json
//   Pass: supported_cited_sentences / cited_sentences ≥ 0.90 and pills_unfetched == 0.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import OsaurusVendored

enum Citations {
    struct Item: Decodable { var id: String; var category: String?; var question: String; var query: String }

    static func run(_ a: BenchArgs) async throws {
        if a["capture"] != nil { return try await capture(a) }
        switch a["stage"] ?? "answer" {
        case "answer": try await answer(a)
        case "judge": try await judge(a)
        case "citecheck-eval": try await citecheckEval(a)
        case "verifier-eval": try await verifierEval(a)
        case "grounding-replay": try groundingReplay(a)
        case "attach-replay": try attachReplay(a)
        case "pipeline-replay": try await pipelineReplay(a)
        case "recency-check": try await recencyCheck(a)
        case "live-window": try await liveWindow(a)
        case "fetch-timing": try await fetchTiming(a)
        default: throw BenchError("--stage answer|judge|citecheck-eval|verifier-eval|grounding-replay")
        }
    }

    /// M7 verifier: which recorded questions SearchRecency touches (intent on the question or its query; the fetched
    /// window of `--pages` (default 6, the capture's) changed by the promotion), over the recorded SERPs. No model.
    ///   antichat-bench citations --stage recency-check --fixture … --root … [--pages 6] [--out f.json]
    static func recencyCheck(_ a: BenchArgs) async throws {
        let rows = try items(a), root = try root(a), pages = a.int("pages", 6)
        var out: [[String: Any]] = [], changed = 0, intent = 0
        for it in rows {
            let qs = [it.query, it.question]
            guard SearchRecency.asksLatest(qs) else { continue }
            intent += 1
            let broker = SearchBroker(registry: EngineRegistry(), transport: ReplayTransport(dir: root.appending(path: it.id)), safeSearch: { false })
            let set = await broker.search(queries: SearchRecency.queries([it.query]))
            let before = set.hits.prefix(pages).map(\.url), after = SearchRecency.promote(set.hits, window: pages).prefix(pages).map(\.url)
            if before != after { changed += 1 }
            out.append(["id": it.id, "question": it.question, "window_changed": before != after, "promoted": after.filter { !before.contains($0) }])
        }
        try write(["fixture": a["fixture"] ?? "", "intent": intent, "window_changed": changed, "rows": out], a["out"] ?? "recency-check.json")
        say("recency intent \(intent), window changed \(changed)")
    }

    /// M7 final (AT-248 c1 retrieval analysis): the app's live search step (gate, keyless engines, the app ranker, the
    /// tier's pages / evidence budget) for `--query` (`|`-separated, the model's queries), `--repeat` times (paced
    /// `--pace` s; a fresh memory page cache each time). Per run: every source (url, title, in the fetched window,
    /// page text or snippet in the evidence, fetch failure) and the evidence text per source. No model.
    ///   antichat-bench citations --stage live-window --query "latest macOS version" [--tier T1] [--repeat 5] [--out f.json]
    static func liveWindow(_ a: BenchArgs) async throws {
        if let u = a["probe-url"].flatMap(URL.init(string:)) {  // one page through the app's own fetcher and transport
            let f = PageFetcher(cache: MemoryWebCache())
            guard let r = await f.fetch([u]).first else { return }
            say("fetcher: \(r.page.map { "\($0.status) \($0.data.count) bytes" } ?? "failure \(r.failure.map { "\($0)" } ?? "?")")")
            var req = URLRequest(url: u)
            req.setValue(PageFetcher.userAgent, forHTTPHeaderField: "User-Agent")
            if let (resp, data, _) = try? await GatedPageTransport().get(req, maxBytes: 3 << 20) {
                say("transport: \(resp.statusCode) \(data.count) bytes retry-after=\(resp.value(forHTTPHeaderField: "Retry-After") ?? "-") \(resp.statusCode == 200 ? "" : String(decoding: data.prefix(300), as: UTF8.self))")
            }
            return
        }
        let qs = (a["query"] ?? "latest macOS version").split(separator: "|").map(String.init)
        let b = WebSearchTools.budget(tier: a["tier"] ?? "T1")
        var runs: [[String: Any]] = []
        for i in 0..<a.int("repeat", 1) {
            let pipeline = WebSearchPipeline(fetcher: PageFetcher(cache: MemoryWebCache()), ranker: WebSearchTools.appRanker)
            let r = await pipeline.search(queries: qs, budget: b.budget)
            var ev: [Int: String] = [:]
            for c in r.evidence { ev[c.source, default: ""] += c.text + "\n" }
            let src: [[String: Any]] = r.sources.map { s in
                ["n": s.n, "url": s.url, "title": s.title, "window": s.n <= b.budget.pages, "in_evidence": s.fetched,
                 "page_text": s.n <= b.budget.pages && r.fetchFailures[s.url] == nil, "failure": r.fetchFailures[s.url] ?? "",
                 "states_latest": SearchRecency.statesLatest(SearchHit(title: s.title, url: s.url, snippet: s.snippet, engine: ""))]
            }
            say("run \(i): engines \(r.engines) blocked \(r.blockedEngines) queries \(r.queries)")
            for s in src { say("  \(s["n"]!) win=\(s["window"]!) ev=\(s["in_evidence"]!) fail=\(s["failure"]!) \(s["url"]!) | \(s["title"]!)") }
            runs.append(["run": i, "queries": r.queries, "engines": r.engines, "blocked": r.blockedEngines, "sources": src,
                         "evidence": Dictionary(uniqueKeysWithValues: ev.map { (String($0.key), $0.value) })])
            if i + 1 < a.int("repeat", 1) { try await Task.sleep(for: .seconds(Double(a["pace"] ?? "3") ?? 3)) }
        }
        try write(["queries": qs, "tier": a["tier"] ?? "T1", "runs": runs], a["out"] ?? "live-window.json")
    }

    static func items(_ a: BenchArgs) throws -> [Item] {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture <citation-qa-100.jsonl> is required") }
        return try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }.prefix(a.int("limit", 1000)).map { $0 }
    }

    static func root(_ a: BenchArgs) throws -> URL {
        guard let r = a["root"] else { throw BenchError("--root <fixtures/web/citation-qa-100> is required") }
        return URL(fileURLWithPath: r, isDirectory: true)
    }

    static func pageCache(_ dir: URL) -> DiskWebCache {
        DiskWebCache(directory: dir.appending(path: "pages"), ttl: .greatestFiniteMagnitude, maxBytes: 64 * 1024 * 1024)
    }

    // MARK: Capture

    final class RecordingTransport: SearchTransport, @unchecked Sendable {
        let inner = GatedSearchTransport()
        let lock = NSLock()
        var dir: URL?
        var blockedRun: [String: Int] = [:]
        var log: [[String: Any]] = []

        static func blocked(_ status: Int, _ data: Data) -> Bool {
            guard status == 200 else { return true }
            let s = String(decoding: data.prefix(200_000), as: UTF8.self).lowercased()
            return s.contains("captcha") || s.contains("anubis") || s.contains("verifying your request")
        }

        func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
            guard let dir = lock.withLock({ dir }) else { return (0, Data()) }
            if lock.withLock({ blockedRun[engine, default: 0] }) >= 3 {
                lock.withLock { log.append(["qid": dir.lastPathComponent, "engine": engine, "skipped": true]) }
                return (0, Data())
            }
            let (status, data) = try await inner.send(request, engine: engine, query: query)
            let serp = dir.appending(path: "serp")
            try? FileManager.default.createDirectory(at: serp, withIntermediateDirectories: true)
            try? data.write(to: serp.appending(path: "\(engine).\(status)"))
            let b = Self.blocked(status, data)
            lock.withLock {
                blockedRun[engine] = b ? blockedRun[engine, default: 0] + 1 : 0
                log.append(["qid": dir.lastPathComponent, "engine": engine, "status": status, "bytes": data.count, "blocked": b])
            }
            return (status, data)
        }
    }

    static func capture(_ a: BenchArgs) async throws {
        let rows = try items(a), root = try root(a)
        let rec = RecordingTransport()
        let broker = SearchBroker(registry: EngineRegistry(), transport: rec, safeSearch: { false })
        var perItem: [[String: Any]] = []
        say("citations --capture: \(rows.count) questions → \(root.path) (engines \(EngineRegistry().enabled))")
        for (i, it) in rows.enumerated() {
            let dir = root.appending(path: it.id)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            rec.lock.withLock { rec.dir = dir }
            let pipeline = WebSearchPipeline(broker: broker, fetcher: PageFetcher(cache: pageCache(dir)))
            let r = await pipeline.search(queries: [it.query], budget: WebSearchBudget(pages: 6, evidenceTokens: 16000))
            let fetched = r.sources.filter(\.fetched).count
            perItem.append(["id": it.id, "sources": r.sources.count, "fetched": fetched, "failed": r.failed ?? ""])
            say("\(i + 1)/\(rows.count) \(it.id) sources=\(r.sources.count) fetched=\(fetched) \(r.failed ?? "")")
            try await Task.sleep(for: .milliseconds(1500))
        }
        let log: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "engines": EngineRegistry().enabled,
                                  "items": perItem, "requests": rec.lock.withLock { rec.log }]
        try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "capture-log.json"))
        say("wrote \(root.appending(path: "capture-log.json").path)")
    }

    // MARK: Replay

    /// Every engine request of a question answers with that question's recorded SERP (whatever the model's query).
    struct ReplayTransport: SearchTransport {
        let dir: URL
        func send(_ request: URLRequest, engine: String, query: String) async throws -> (status: Int, data: Data) {
            let serp = dir.appending(path: "serp")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: serp.path)) ?? []
            guard let f = files.first(where: { $0.hasPrefix(engine + ".") }), let status = Int(f.dropFirst(engine.count + 1)),
                  let d = try? Data(contentsOf: serp.appending(path: f)) else { return (0, Data()) }
            return (status, d)
        }
    }

    /// Pages come only from the recorded cache; nothing leaves the Mac.
    struct NoNetworkPages: PageTransport {
        func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?) {
            throw FetchFailure.network("replay: page not recorded")
        }
    }

    static func replayPipeline(_ dir: URL, delays: [String: Double]? = nil) -> WebSearchPipeline {
        let broker = SearchBroker(registry: EngineRegistry(), transport: ReplayTransport(dir: dir), safeSearch: { false })
        guard let delays, !delays.isEmpty else {
            return WebSearchPipeline(broker: broker, fetcher: PageFetcher(transport: NoNetworkPages(), cache: pageCache(dir)),
                                     ranker: WebSearchTools.appRanker)
        }
        let snap = pageCache(dir)
        let fetcher = PageFetcher(ssrf: SSRFGuard(resolve: { _ in ["93.184.216.34"] }), transport: DelayedSnapshotPages(snapshot: snap, delays: delays),
                                  cache: HidingCache(inner: snap, hidden: Set(delays.keys)))
        return WebSearchPipeline(broker: broker, fetcher: fetcher, ranker: WebSearchTools.appRanker)
    }

    // MARK: Page arrival times (M9.T05, AT-254 T3 fetch deadline → AT-250 c2)

    /// The snapshot cache with some pages hidden, so their fetch goes to `DelayedSnapshotPages` (the rest are cache
    /// hits, as in the plain replay).
    final class HidingCache: WebCache, @unchecked Sendable {
        let inner: DiskWebCache, hidden: Set<String>
        init(inner: DiskWebCache, hidden: Set<String>) { self.inner = inner; self.hidden = hidden }
        func get(_ url: URL) -> FetchedPage? { hidden.contains(url.absoluteString) ? nil : inner.get(url) }
        func put(_ page: FetchedPage) {}
        func clear() {}
    }

    /// Serves a recorded page after the time its live cold fetch took (`fetch-timing`); a page whose live fetch failed
    /// (delay < 0) never arrives within the 5 s page timeout. robots.txt: none. Nothing leaves the Mac.
    struct DelayedSnapshotPages: PageTransport {
        let snapshot: DiskWebCache, delays: [String: Double]
        func get(_ request: URLRequest, maxBytes: Int) async throws -> (response: HTTPURLResponse, data: Data, remoteAddress: String?) {
            guard let url = request.url else { throw FetchFailure.network("replay: no url") }
            if url.path == "/robots.txt" { return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data(), nil) }
            let d = delays[url.absoluteString] ?? 0
            try await Task.sleep(for: .milliseconds(Int((d < 0 ? 30 : d) * 1000)))
            guard let p = snapshot.get(url) else { throw FetchFailure.network("replay: page not recorded") }
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": p.contentType])!
            return (resp, p.data, nil)
        }
    }

    /// `--page-delays <fetch-timing.json>`: question id → (page url → seconds of its live cold fetch, -1 = failed).
    static func pageDelays(_ a: BenchArgs) throws -> [String: [String: Double]] {
        guard let f = a["page-delays"] else { return [:] }
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f))) as? [String: Any] ?? [:]
        var out: [String: [String: Double]] = [:]
        for r in o["rows"] as? [[String: Any]] ?? [] {
            guard let id = r["id"] as? String, let pages = r["pages"] as? [String: Double] else { continue }
            out[id] = pages
        }
        return out
    }

    /// M9.T05: for every question, the fetched window the replay's search picks (recorded SERP, recency promotion, the
    /// tier's `--pages`, default 6) fetched LIVE now with an empty in-memory page cache (cold), and the seconds from the
    /// fetch start until each page was done (-1 = the live fetch failed: the replay treats it as never arriving in
    /// time). Pages only (the engines are not asked); paced `--pace` s (default 1.5) per question.
    ///   antichat-bench citations --stage fetch-timing --fixture … --root … [--pages 6] --out fetch-timing.json
    static func fetchTiming(_ a: BenchArgs) async throws {
        let rows = try items(a), root = try root(a), pages = a.int("pages", 6), pace = Double(a["pace"] ?? "1.5") ?? 1.5
        var out: [[String: Any]] = []
        for (i, it) in rows.enumerated() {
            let broker = SearchBroker(registry: EngineRegistry(), transport: ReplayTransport(dir: root.appending(path: it.id)), safeSearch: { false })
            let qs = [it.question]
            let recency = SearchRecency.asksLatest(qs)
            let set = await broker.search(queries: recency ? SearchRecency.queries(qs) : qs)
            let hits = recency ? SearchRecency.promote(set.hits, window: pages) : set.hits
            let urls = hits.prefix(pages).compactMap { URL(string: $0.url) }
            let fetched = await PageFetcher(cache: MemoryWebCache()).fetch(urls, deadline: 10)
            var secs: [String: Double] = [:]
            for r in fetched { secs[r.url.absoluteString] = r.page != nil ? (r.seconds ?? -1) : -1 }
            out.append(["id": it.id, "pages": secs])
            say("\(i + 1)/\(rows.count) \(it.id) " + fetched.map { r in r.page != nil ? String(format: "%.2f", r.seconds ?? -1) : "fail" }.joined(separator: " "))
            if pace > 0 { try await Task.sleep(for: .milliseconds(Int(pace * 1000))) }
        }
        try write(["fixture": a["fixture"] ?? "", "pages": pages, "date": ISO8601DateFormatter().string(from: Date()), "rows": out],
                  a["out"] ?? "fetch-timing.json")
    }

    // MARK: Answer stage

    /// Cited sentences of a validated answer: (sentence without markers, cited source numbers).
    static func citedSentences(_ v: CitationValidator.Result) -> [(String, [Int])] {
        let ns = v.text as NSString
        var marked = "", cursor = 0
        for c in v.citations {
            // locations are in the cleaned text; the marker `[n,m]` starts there
            let m = CitationValidatorMarker.at(ns, c.location)
            marked += ns.substring(with: NSRange(location: cursor, length: c.location - cursor))
            marked += "\u{1}" + c.sources.map(String.init).joined(separator: ",") + "\u{2}"
            cursor = c.location + m
        }
        marked += ns.substring(from: min(cursor, ns.length))
        var sentences: [(String, [Int])] = []
        var cur = "", cites: [Int] = []
        func close() {
            let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 1 { sentences.append((s, cites)) } else if !cites.isEmpty, !sentences.isEmpty { sentences[sentences.count - 1].1 += cites }
            cur = ""; cites = []
        }
        var chars = Array(marked), i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\u{1}" {
                var j = i + 1, num = ""
                while j < chars.count, chars[j] != "\u{2}" { num.append(chars[j]); j += 1 }
                let ns = num.split(separator: ",").compactMap { Int($0) }
                if cur.trimmingCharacters(in: .whitespaces).isEmpty, !sentences.isEmpty { sentences[sentences.count - 1].1 += ns } else { cites += ns }
                i = j + 1
                continue
            }
            if ch == "\n" { close(); i += 1; continue }
            cur.append(ch)
            if ".!?".contains(ch), i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\n" || chars[i + 1] == "\u{1}" {
                if ch == ".", CitationGrounding.endsAbbreviation(cur) { i += 1; continue }
                // a marker right after the full stop belongs to this sentence
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == "\u{1}" { i += 1; continue }
                close()
            }
            i += 1
        }
        close()
        return sentences.filter { !$0.1.isEmpty }.compactMap { s in
            let claim = CitationGrounding.cleanClaim(s.0)
                .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
            return claim.count > 1 ? (claim, Array(Set(s.1)).sorted()) : nil
        }
    }

    /// Evidence text per source number from a `<web_results>` tool result (blocks separated by blank lines).
    static func evidence(_ block: String) -> [Int: String] {
        var out: [Int: String] = [:]
        let clean = block.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 != "</web_results>" && $0 != WebResultsBlock.citeReminder && $0 != WebResultsBlock.atomicRule }.joined(separator: "\n")
        let body = clean.components(separatedBy: "\n\n").dropFirst(2)  // header + Sources list
        for part in body {
            guard let m = part.firstMatch(of: /^\[(\d+)\] ([\s\S]*)$/), let n = Int(m.output.1) else { continue }
            out[n, default: ""] += (out[n] == nil ? "" : "\n") + String(m.output.2)
        }
        return out
    }

    /// `body`'s value, or nil once `limit` passes (the body keeps running unawaited; the caller stops the turn).
    static func firstOf<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (k: CheckedContinuation<T?, Never>) in
            Task { let v = await body(); if once.claim() { k.resume(returning: v) } }
            Task { try? await Task.sleep(for: limit); if once.claim() { k.resume(returning: nil) } }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    static func answer(_ a: BenchArgs) async throws {
        let rows = try items(a), root = try root(a)
        // M9.T05: --page-delays replays each recorded page after its measured live cold fetch time, so the tier's fetch
        // deadline drops the same pages to snippets as it would live (without it every page is an instant cache hit).
        let delays = try pageDelays(a)
        let tierName = a["tier"] ?? "T1", key = a["model"] ?? "chat-9b-q4"
        let tier = DeviceTier(rawValue: tierName) ?? .t1
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-citations")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        let cap = a["cap"] ?? (tierName == "T2" ? "T2-24" : tierName)  // --cap T2-32 for a T2-32 model (chat-g26)
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        // The app's ranker: hybrid BM25 + the helper's embedding model (as ChatEnvironment wires it).
        let embedSlot = DevSlots.slot("embed")
        let embedder: (any Embedder)? = FileManager.default.fileExists(atPath: embedSlot.path)
            ? HelperEmbedder(engine: client, embedSlot: { embedSlot }) : nil
        WebSearchTools.useEmbedder(embedder)
        // A-M7-T03c: the citation entailment check (catalog `cite-check`, Core ML on CPU + ANE in the helper) unless
        // --no-cite-check; --cite-check <dir> overrides the dev models dir.
        let citeDir = a["cite-check"] ?? DevSlots.view("cite-check").path
        let citeSlot = ModelSlot(engine: .coreml, key: "cite-check", path: citeDir, footprintBytes: 800_000_000)
        let citeOn = a["no-cite-check"] == nil && FileManager.default.fileExists(atPath: citeDir)
        CiteCheck.use(citeOn ? CiteCheck.helper(engine: client, slot: { citeSlot }) : nil)
        defer { CiteCheck.use(nil) }
        // The first load compiles the Core ML package (~10 s, then cached); the app pays it once per install. Warm it
        // here so question 1 is measured like the others (the turn's check has a 6 s bound).
        if citeOn, let warm = CiteCheck.scorer {
            let t = ContinuousClock.now
            _ = try? await warm([CitationEntailment.Pair(claim: "Warm-up.", premise: "Warm-up.")])
            say("cite-check warm-up \(Stats.secs(ContinuousClock.now - t)) s")
        }
        var entChecked = 0, entUncited = 0, entNarrowed = 0, entPairs = 0
        var entMillis: [Double] = []
        // attempt 6: the generative verifier on the answering model (unless --no-verify)
        let verifyOn = a["no-verify"] == nil
        CiteVerify.use(verifyOn)
        defer { CiteVerify.use(false) }
        var verChecked = 0, verUncited = 0, verUnverified = 0, forcedFallbacks = 0
        var verMillis: [Double] = []
        let gate = Counter()
        let obs = NetworkGate.addObserver { e in gate.add(e.host) }
        defer { NetworkGate.removeObserver(obs) }
        var out: [[String: Any]] = []
        var pillsTotal = 0, pillsUnfetched = 0, dropped = 0, groundChecked = 0, groundUncited = 0
        let start = ContinuousClock.now
        // Resumable: every finished item is appended to `<answers>.partial.jsonl`; a restart skips those items.
        let partial = URL(fileURLWithPath: (a["answers"] ?? "citations-answers.json") + ".partial.jsonl")
        let previous = ((try? String(contentsOf: partial, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        for r in previous {
            out.append(r)
            pillsTotal += r["pills"] as? Int ?? 0
            pillsUnfetched += r["pills_unfetched"] as? Int ?? 0
            dropped += r["dropped"] as? Int ?? 0
            groundChecked += r["grounding_checked"] as? Int ?? 0
            groundUncited += r["grounding_uncited"] as? Int ?? 0
            entChecked += r["entailment_checked"] as? Int ?? 0
            entUncited += r["entailment_uncited"] as? Int ?? 0
            entNarrowed += r["entailment_narrowed"] as? Int ?? 0
            entPairs += r["entailment_pairs"] as? Int ?? 0
            if let ms = r["entailment_ms"] as? Double, ms > 0 { entMillis.append(ms) }
            verChecked += r["verify_checked"] as? Int ?? 0
            forcedFallbacks += r["forced_search"] as? Int ?? 0
            verUncited += r["verify_uncited"] as? Int ?? 0
            verUnverified += r["verify_unverified"] as? Int ?? 0
            if let ms = r["verify_ms"] as? Double, ms > 0 { verMillis.append(ms) }
        }
        let done = Set(previous.compactMap { $0["id"] as? String })
        if !done.isEmpty { say("resuming: \(done.count) items already answered (\(partial.path))") }
        for (i, it) in rows.enumerated() where !done.contains(it.id) {
            // On disk: an in-memory store is an incognito chat, whose pipeline is the live incognito one.
            let work = FileManager.default.temporaryDirectory.appending(path: "citations-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let db = try AppDatabase.onDisk(at: work.appending(path: "antichat.sqlite"))
            let registry = ToolRegistry([])
            let observers = WebSearchTools.install(into: registry, pipeline: replayPipeline(root.appending(path: it.id), delays: delays[it.id]),
                                                   availability: WebSearchAvailability(fixed: .available), tier: { tierName })
            defer { observers.forEach(NotificationCenter.default.removeObserver) }
            // --trailer: try a citation-rule wording at the END of the block (experiment only; the app's wording is
            // WebResultsBlock's). Applied by wrapping the registered tool's run.
            if let trailer = a["trailer"], var t = registry.tool(named: "web_search") {
                let inner = t.run
                t.run = { args in
                    let out = try await inner(args)
                    return out.replacingOccurrences(of: "</web_results>", with: trailer + "\n</web_results>")
                }
                registry.register(t)
            }
            let rt = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(tier),
                                 selection: .standard, tier: { tier })
            let chat = StorageID.make(), aid = StorageID.make()
            let c = TurnController(chatID: chat, database: db, engine: client,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: a.int("max-tokens", 700), seed: 7),
                                   tools: rt) { slot }
            await c.setChips(["web"])  // the Web search chip: one forced web_search step (M7.T03 step 3)
            let trace = a["trace"] != nil
            // bars-2 (S1): a headless run cannot approve; an ApprovalCard (a read_url outside the turn's results, under
            // untrusted context) is answered Deny at once and counted (`approvals_denied`), so no question waits on it.
            let denied = Counter()
            let done = Task { () -> TurnResult? in
                for await u in c.updates {
                    if u.assistantID == aid, case .approval(let card?) = u.kind {
                        denied.add(card.tool)
                        say("\(it.id): approval for \(card.tool) answered Deny (headless)")
                        await c.answerApproval(callID: card.id, .deny)
                    }
                    if trace {  // --trace: the turn's phases, tool activity and approval cards (hang diagnosis)
                        switch u.kind {
                        case .phase, .activity, .approval, .modelLoading, .rejected: say("trace \(it.id): \(u.kind)")
                        default: break
                        }
                    }
                    if u.assistantID == aid, case .finished(let res) = u.kind { return res }
                }
                return nil
            }
            let t = ContinuousClock.now
            await c.start(.send(userID: StorageID.make(), text: it.question, parentID: nil, attachmentIDs: []), assistantID: aid)
            // Watchdog (M7 bars, a hung T3 run held a GPU slot for 3 h): a question gets `--question-timeout` seconds
            // (default 900) for its answer and as long again for its citation verdict; past that the turn is stopped,
            // the row is marked `timeout` and the run goes on (the runner script also kills a run that stops writing).
            let limit = Duration.seconds(a.int("question-timeout", 900))
            // Not a task group: a group waits for every child at its end, and `done.value` cannot be cancelled.
            let res: TurnResult? = (await Self.firstOf(limit) { await done.value }) ?? nil
            var timedOut = false
            if res == nil {
                timedOut = true
                await c.stop()
                done.cancel()
                say("\(it.id): no answer within \(limit); stopped (row marked timeout)")
            }
            let answered = ContinuousClock.now - t
            // M7 bars: the citation checks settle after the final write (no whole-answer bound); wait for the verdict.
            let settled = await Self.firstOf(limit) { await c.citationsSettled(aid); return true } ?? false
            if !settled { timedOut = true; say("\(it.id): citation verdict not settled within \(limit)") }
            let grounding = await c.lastGrounding
            groundChecked += grounding?.checked ?? 0
            groundUncited += grounding?.uncited ?? 0
            let ent = await c.lastEntailment
            entChecked += ent?.checked ?? 0
            entUncited += ent?.uncited ?? 0
            entNarrowed += ent?.narrowed ?? 0
            entPairs += ent?.pairs ?? 0
            if let ent, ent.pairs > 0 { entMillis.append(ent.millis) }
            let ver = await c.lastVerification
            let forced = await c.forcedSearchFallbacks
            let spreadAdded = await c.lastSpread
            let attachedAdded = await c.lastAttached
            let modelText = await c.lastModelText
            forcedFallbacks += forced
            verChecked += ver?.checked ?? 0
            verUncited += ver?.uncited ?? 0
            verUnverified += ver?.unverified ?? 0
            if let ver, ver.checked + ver.unverified > 0 { verMillis.append(ver.millis) }
            let settledText = (try? MessageRepository(db).parts(of: aid))?.first(where: { $0.kind == .text })?.body
            let text = (settledText ?? res?.text ?? "").replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            // finalize moved the turn's sources into the reply's provenance (and cleared TurnWebSources)
            let stored = (try? db.read { try MessageRecord.fetchOne($0, key: aid) })??.provenance?.sources ?? []
            let sources = stored.map { WebSource(n: $0.n, url: $0.url, title: $0.title, site: $0.site, date: $0.date,
                                                 snippet: $0.snippet, fetched: $0.fetched) }
            let parts = (try? MessageRepository(db).parts(of: aid)) ?? []
            var ev: [Int: String] = [:]
            // `tool_result` parts are stored as {"id", "name", "result"} JSON (StreamPersister.appendToolResult)
            for p in parts where p.kind == .toolResult {
                let obj = (try? JSONSerialization.jsonObject(with: Data(p.body.utf8))) as? [String: Any]
                ev.merge(evidence((obj?["result"] as? String) ?? p.body)) { $0 + "\n" + $1 }
            }
            guard !ev.isEmpty || CitationValidator.validate(text, sources: sources).citations.isEmpty else { throw BenchError("\(it.id): no evidence parsed from the tool result") }
            let v = CitationValidator.validate(text, sources: sources)
            let fetched = Set(sources.filter { $0.fetched }.map { $0.n })
            let pills = v.citations.flatMap { $0.sources }
            pillsTotal += pills.count
            let unfetched = pills.filter { !fetched.contains($0) }.count
            pillsUnfetched += unfetched
            dropped += v.dropped
            var cited: [[String: Any]] = []
            for (s, ns) in citedSentences(v) {
                var urls: [String] = [], passages: [String] = []
                for n in ns {
                    if let src = sources.first(where: { $0.n == n }) { urls.append(src.url) }
                    if let e = ev[n] { passages.append("[\(n)] " + e) }
                }
                // The whole text the model saw for the cited sources: a cut passage made the judge and the labeller
                // miss details that were in the evidence (attempt 4: 136 of 231 T3 passages hit the old 8000 cap).
                let passage = String(passages.joined(separator: "\n\n").prefix(Self.passageCap))
                cited.append(["sentence": s, "n": ns, "urls": urls, "passage": passage])
            }
            out.append(["id": it.id, "question": it.question, "answer": text, "status": res.map { "\($0.status)" } ?? "none",
                        "sources": sources.count, "fetched": fetched.count, "evidence_sources": ev.keys.sorted(), "pills": pills.count, "pills_unfetched": unfetched, "dropped": v.dropped,
                        "cited": cited, "grounding_checked": grounding?.checked ?? 0, "grounding_uncited": grounding?.uncited ?? 0,
                        "grounding_missing": grounding?.missing ?? [],
                        "entailment_checked": ent?.checked ?? 0, "entailment_uncited": ent?.uncited ?? 0,
                        "entailment_narrowed": ent?.narrowed ?? 0, "entailment_pairs": ent?.pairs ?? 0,
                        "entailment_ms": ent?.millis ?? 0, "entailment_scores": ent?.scores ?? [],
                        "entailment_skipped": ent?.skipped ?? "",
                        "verify_checked": ver?.checked ?? 0, "verify_uncited": ver?.uncited ?? 0,
                        "verify_unverified": ver?.unverified ?? 0, "verify_ms": ver?.millis ?? 0, "forced_search": forced, "approvals_denied": denied.snapshot.0, "spread_added": spreadAdded, "attached_added": attachedAdded,
                        "verify_sentence_ms": ver?.sentenceMillis ?? [], "verify_skipped": ver?.skipped ?? "",
                        "load_avg": SearchAvailability.loadAverage(), "timeout": timedOut, "answer_secs": Stats.secs(answered), "secs": Stats.secs(ContinuousClock.now - t)])
            // bars-3 (--dump-evidence, dev diagnostics): what attach / spread saw: the model's text, every source's
            // evidence and the fetched set
            if a["dump-evidence"] != nil, var row = out.popLast() {
                row["model_text"] = modelText ?? ""
                row["evidence"] = Dictionary(uniqueKeysWithValues: ev.map { (String($0.key), $0.value) })
                row["fetched_ns"] = fetched.sorted()
                out.append(row)
            }
            if let row = out.last, let line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
                if let h = try? FileHandle(forWritingTo: partial) { h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close() }
            }
            say("\(i + 1)/\(rows.count) \(it.id) pills=\(pills.count) dropped=\(v.dropped) cited=\(cited.count) fetched=\(fetched.count)")
        }
        let (n, hosts) = gate.snapshot
        let report: [String: Any] = [
            "cmd": "citations", "stage": "answer", "tier": tierName, "model": key, "model_revision": revision(key),
            "items": rows.count, "trailer": a["trailer"] ?? "", "grounding_checked": groundChecked,
            "cite_check": citeOn ? "cite-check (\(citeDir)) threshold \(CitationEntailment.threshold)" : "off",
            "entailment_checked": entChecked, "entailment_uncited": entUncited, "entailment_narrowed": entNarrowed,
            "entailment_pairs": entPairs, "entailment_ms_p50": Self.pct(entMillis, 0.5), "entailment_ms_p95": Self.pct(entMillis, 0.95),
            "entailment_ms_max": entMillis.max() ?? 0,
            "verifier": verifyOn ? "\(key) batches of \(CitationVerifier.batchSize), \(CitationVerifier.passageChars) chars per sentence, budget \(CitationVerifier.budget.map { "\($0)" } ?? "none (settles after the final write)")" : "off",
            "forced_search_fallbacks": forcedFallbacks,
            "verify_checked": verChecked, "verify_uncited": verUncited, "verify_unverified": verUnverified,
            "verify_ms_p50": Self.pct(verMillis, 0.5), "verify_ms_p95": Self.pct(verMillis, 0.95), "verify_ms_max": verMillis.max() ?? 0, "grounding_uncited": groundUncited, "embedder": embedder != nil, "pills_total": pillsTotal, "pills_unfetched": pillsUnfetched, "dropped_markers": dropped,
            "gate_events": n, "gate_hosts": hosts, "load_avg": SearchAvailability.loadAverage(),
            "seconds": Stats.secs(ContinuousClock.now - start), "date": ISO8601DateFormatter().string(from: Date()), "rows": out,
        ]
        let path = a["answers"] ?? "citations-answers.json"
        try write(report, path)
        say("answers: pills \(pillsTotal) (unfetched \(pillsUnfetched)), gate events \(n) → \(path)")
    }

    // MARK: Grounding replay (bars-3)

    /// M7 bars-3: replays the current CitationGrounding (deterministic, after generation, it only removes markers) on a
    /// labelled run: every answer's final text with its cited sources' texts as evidence. A labelled sentence whose
    /// marker the current checks remove would no longer be shown cited; the labels of the others are unchanged.
    /// Final label per item: --final <csv item,label> when given, else supported only when every labels*.csv given
    /// with --labelsets (comma list of dirs, first one holds label-input.jsonl) says supported (adjudication-labels.csv
    /// of the first dir overrides).
    ///   antichat-bench citations --stage grounding-replay --answers T1-answers.json --labelsets dirA,dirB [--out f.json]
    static func groundingReplay(_ a: BenchArgs) throws {
        guard let answers = a["answers"], let sets = a["labelsets"]?.split(separator: ",").map(String.init), let first = sets.first
        else { throw BenchError("--answers <answers.json> --labelsets <first>[,<strict>] required") }
        func csvLabels(_ path: String) -> [String: String] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
            var out: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let f = line.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
                if f.count >= 2, f[0].hasPrefix("f"), f[0].count <= 5 { out[f[0]] = f[1].lowercased() }
            }
            return out
        }
        let passes = sets.map { csvLabels($0 + "/labels.csv") }
        let adj = csvLabels(first + "/adjudication-labels.csv")
        let ans = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: answers))) as! [String: Any]
        var removedBy: [String: [String]] = [:], lackBy: [String: [[String]]] = [:]
        for r in ans["rows"] as? [[String: Any]] ?? [] {
            guard let id = r["id"] as? String, let text = r["answer"] as? String else { continue }
            var evidence: [Int: String] = [:]
            for c in r["cited"] as? [[String: Any]] ?? [] {
                let ns = (c["n"] as? [Int]) ?? [], passage = c["passage"] as? String ?? ""
                var rest = passage
                for (k, n) in ns.enumerated() {
                    guard rest.hasPrefix("[\(n)] ") else { break }
                    rest = String(rest.dropFirst("[\(n)] ".count))
                    if k + 1 < ns.count, let r2 = rest.range(of: "\n\n[\(ns[k + 1])] ") {
                        evidence[n] = String(rest[..<r2.lowerBound]); rest = String(rest[r2.lowerBound...].dropFirst(2))
                    } else { evidence[n] = rest }
                }
            }
            let g = CitationGrounding.apply(text, evidence: evidence)
            removedBy[id] = g.removedClaims
            lackBy[id] = g.missing
        }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: #"\[\d+(?:\s*,\s*\d+)*\]|\*\*|[^a-z0-9]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var rows: [[String: Any]] = []
        var keptSup = 0, kept = 0, cited = 0, sup = 0, lostSup = 0, lostNot = 0
        for line in try String(contentsOfFile: first + "/label-input.jsonl", encoding: .utf8).split(separator: "\n") {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let item = o["item"] as? String, let qid = o["qid"] as? String, let sentence = o["sentence"] as? String else { continue }
            let ls = passes.map { $0[item] ?? "?" }
            let label = adj[item] ?? (ls.allSatisfy { $0 == "n/a" } ? "n/a" : ls.allSatisfy { $0 == "supported" } ? "supported" : "partial")
            guard label != "n/a" else { continue }
            let s = norm(sentence)
            let k = (removedBy[qid] ?? []).firstIndex { let c = norm($0); return !c.isEmpty && (c == s || s.hasSuffix(c) || c.hasSuffix(s)) }
            cited += 1
            if label == "supported" { sup += 1 }
            if let k {
                if label == "supported" { lostSup += 1 } else { lostNot += 1 }
                rows.append(["item": item, "qid": qid, "label": label, "sentence": sentence, "lack": lackBy[qid]?[k] ?? []])
            } else {
                kept += 1
                if label == "supported" { keptSup += 1 }
            }
        }
        let report: [String: Any] = ["answers": answers, "labelsets": sets, "cited": cited, "supported": sup,
                                     "ratio_before": Double(sup) / Double(max(cited, 1)), "kept": kept, "kept_supported": keptSup,
                                     "ratio_after": Double(keptSup) / Double(max(kept, 1)), "lost_supported": lostSup,
                                     "lost_not_supported": lostNot, "removed": rows]
        try write(report, a["out"] ?? first + "/grounding-replay.json")
        say("cited \(cited) sup \(sup) (\(String(format: "%.3f", Double(sup) / Double(max(cited, 1))))) → kept \(kept) sup \(keptSup) (\(String(format: "%.3f", Double(keptSup) / Double(max(kept, 1))))); removed supported \(lostSup), not supported \(lostNot)")
    }

    /// M7 bars-3 (dev diagnostics): for answers of a `--dump-evidence` run, replays grounding + attach on the model's
    /// text and lists, per answer citing fewer than two sources, each uncited factual sentence with what every fetched
    /// source lacks for it (the deterministic check), so the attach step can be judged on dev data.
    ///   antichat-bench citations --stage attach-replay --answers dev-h4/T1-answers.json [--out f.json]
    static func attachReplay(_ a: BenchArgs) throws {
        guard let answers = a["answers"] else { throw BenchError("--answers required") }
        let data = try Data(contentsOf: URL(fileURLWithPath: answers))
        let rows: [[String: Any]]
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { rows = o["rows"] as? [[String: Any]] ?? [] }
        else { rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        var report: [[String: Any]] = []
        for r in rows {
            // --on answer: the settled answer (the app attaches after the checks); default: the model's text
            guard let text = (a["on"] == "answer" ? r["answer"] : r["model_text"]) as? String,
                  let evs = r["evidence"] as? [String: String] else { continue }
            let ev = Dictionary(uniqueKeysWithValues: evs.compactMap { k, v in Int(k).map { ($0, v) } })
            let fetched = Set((r["fetched_ns"] as? [Int]) ?? [])
            let g = CitationGrounding.apply(text, evidence: ev)
            let at = CitationGrounding.attach(g.text, evidence: ev, candidates: fetched)
            report.append(["id": r["id"] ?? "", "attached": at.attached.map { ["claim": $0.claim, "source": $0.source] },
                           "diagnosis": CitationGrounding.attachDiagnosis(g.text, evidence: ev, candidates: fetched)])
        }
        try write(["answers": answers, "rows": report], a["out"] ?? answers + ".attach-replay.json")
        say("\(report.count) answers, \(report.filter { !(($0["attached"] as? [Any]) ?? []).isEmpty }.count) with an attached source")
    }

    /// M7 at248-2 (dev diagnostics): replays the app's whole finalize pipeline (TurnController.finalize + settle) on
    /// captured turns — the model's own text, the evidence it saw, the fetched sources — with the real MiniCheck
    /// (helper `cite_check`) and the real verifier (the tier's chat model), and records per marker where it died:
    /// grounding (what the passage lacked), MiniCheck (claim scores), verifier (raw verdict), attach (diagnosis + checks).
    /// Input: an AT-248 probe.json (runs[].diag.{model_text,evidence}, runs[].fetched_ns) or a `--dump-evidence`
    /// answers.json (rows[].{model_text,evidence,fetched_ns}).
    ///   antichat-bench citations --stage pipeline-replay --answers build/at/AT-248/<dir>/probe.json [--model chat-9b-q4] [--out f.json]
    static func pipelineReplay(_ a: BenchArgs) async throws {
        guard let path = a["answers"] else { throw BenchError("--answers <probe.json|answers.json> required") }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] ?? [:]
        var items: [(id: String, text: String, ev: [Int: String], fetched: Set<Int>)] = []
        for r in (obj["runs"] as? [[String: Any]]) ?? (obj["rows"] as? [[String: Any]]) ?? [] {
            let d = (r["diag"] as? [String: Any]) ?? r
            guard let text = d["model_text"] as? String, let evs = d["evidence"] as? [String: String] else { continue }
            let ev = Dictionary(uniqueKeysWithValues: evs.compactMap { k, v in Int(k).map { ($0, v) } })
            let id = (r["id"] as? String) ?? "run-\((r["run"] as? Int) ?? items.count)"
            items.append((id, text, ev, Set((r["fetched_ns"] as? [Int]) ?? [])))
        }
        let only = a["only"].map { Set($0.split(separator: ",").map(String.init)) }
        if let only { items = items.filter { only.contains($0.id) } }
        let key = a["model"] ?? "chat-9b-q4", cap = a["cap"] ?? "T1"
        let client = EngineClient(appBuild: "antichat-bench-pipeline-replay")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        let citeDir = a["cite-check"] ?? DevSlots.view("cite-check").path
        let citeSlot = ModelSlot(engine: .coreml, key: "cite-check", path: citeDir, footprintBytes: 800_000_000)
        let base = CiteCheck.helper(engine: client, slot: { citeSlot })
        let noVerifier = a["no-verifier"] != nil
        var generate: CitationVerifier.Generator? = nil
        if !noVerifier {
            let slot = DevSlots.slot(key)
            if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
            if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
            generate = CiteVerify.generator(engine: client, slot: { slot })
            _ = try? await generate!("Say OK.", 4)
        }
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var pairs: [[String: Any]] = [], verifier: [[String: Any]] = []
            func add(pairs p: [CitationEntailment.Pair], _ s: [Float]) {
                lock.withLock { for (x, y) in zip(p, s) { pairs.append(["claim": x.claim, "premise_head": String(x.premise.prefix(80)), "score": y]) } }
            }
            func add(prompt: String, reply: String) { lock.withLock { verifier.append(["prompt": prompt, "reply": reply]) } }
        }
        func markersOf(_ t: String) -> [[String: Any]] {
            let ns = t as NSString
            var out: [[String: Any]] = [], cursor = 0
            for m in CitationGrounding.markers(in: t) {
                let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                cursor = NSMaxRange(m.range)
                out.append(["claim": CitationGrounding.lastSentence(before), "marker": ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)])
            }
            return out
        }
        var rows: [[String: Any]] = []
        var twoPills = 0
        for it in items {
            let log = Log()
            let scorer: CitationEntailment.Scorer = { p in let s = try await base(p); log.add(pairs: p, s); return s }
            var verify: CitationVerifier.Generator? = nil
            if let gen = generate {
                verify = { @Sendable (q: String, n: Int) async throws -> String in
                    let r = try await gen(q, n)
                    log.add(prompt: q, reply: r)
                    return r
                }
            }
            var g = CitationGrounding.apply(it.text, evidence: it.ev)
            let removed = zip(g.removedClaims, g.missing).map { ["claim": $0.0, "lack": $0.1] as [String: Any] }
            let spread = CitationGrounding.spread(g.text, evidence: it.ev, candidates: it.fetched)
            g.text = spread.text
            let afterGrounding = g.text
            let r = await TurnController.entail(g.text, evidence: it.ev, scorer: scorer)
            let afterMini = r?.text ?? g.text
            var final = afterMini
            var v: CitationVerifier.Result?
            if let verify { v = await CitationVerifier.apply(afterMini, evidence: it.ev, generate: verify); final = v!.text }
            let preAttachLog = (log.pairs.count, log.verifier.count)
            let diagnosis = CitationGrounding.attachDiagnosis(final, evidence: it.ev, candidates: it.fetched)
            var attached: [[String: Any]] = []
            if let verify, !it.fetched.isEmpty {
                let att = CitationGrounding.attach(final, evidence: it.ev, candidates: it.fetched)
                attached = att.attached.map { ["claim": $0.claim, "source": $0.source] }
                let rejected = CitationGrounding.pairs(afterGrounding).subtracting(CitationGrounding.pairs(final))
                let kept = await TurnController.attachChecked(final, evidence: it.ev, candidates: it.fetched, scorer: scorer, verify: verify, gate: nil, rejected: rejected)
                final = kept.text
                attached = attached.map { var x = $0; x["kept"] = kept.attached.contains(CitationGrounding.Attached(claim: $0["claim"] as! String, source: $0["source"] as! Int)); return x }
            }
            let pills = CitationGrounding.markers(in: final).filter { m in
                let nums = (final as NSString).substring(with: m.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) }
                return !Set(nums).isDisjoint(with: it.fetched)
            }.count
            if pills >= 2 { twoPills += 1 }
            say("\(it.id): pills \(pills) (grounding removed \(g.uncited)/\(g.checked), mini removed \(r?.uncited ?? -1), verifier removed \(v?.uncited ?? -1), attached kept \(attached.filter { $0["kept"] as? Bool == true }.count)/\(attached.count))")
            rows.append(["id": it.id, "pills": pills, "model_text": it.text, "grounding_removed": removed, "after_grounding": markersOf(afterGrounding),
                         "after_minicheck": markersOf(afterMini), "after_verifier": markersOf(v?.text ?? afterMini), "final": final,
                         "final_markers": markersOf(final), "attached": attached, "attach_diagnosis": diagnosis,
                         "minicheck_pairs": Array(log.pairs.prefix(preAttachLog.0)), "verifier_calls": Array(log.verifier.prefix(preAttachLog.1)),
                         "attach_minicheck_pairs": Array(log.pairs.dropFirst(preAttachLog.0)), "attach_verifier_calls": Array(log.verifier.dropFirst(preAttachLog.1))])
        }
        try write(["answers": path, "model": key, "runs": rows.count, "runs_with_2_pills": twoPills, "rows": rows], a["out"] ?? path + ".pipeline-replay.json")
        say("\(twoPills)/\(rows.count) with >= 2 pills")
    }

    // MARK: Judge stage

    /// A-M7-T03c attempt 6: scores independently labelled sentences (label-input.jsonl + labels.csv of a labels dir)
    /// with the cite-check model, whole sentence vs claim decomposition, and writes the kept-supported share per mode.
    ///   antichat-bench citations --stage citecheck-eval --labels build/at/AT-250/attempt5/labels-T3 [--out f.json]
    static func citecheckEval(_ a: BenchArgs) async throws {
        guard let dir = a["labels"] else { throw BenchError("--labels <dir> is required") }
        let client = EngineClient(appBuild: "antichat-bench-citecheck-eval")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        let citeDir = a["cite-check"] ?? DevSlots.view("cite-check").path
        let slot = ModelSlot(engine: .coreml, key: "cite-check", path: citeDir, footprintBytes: 800_000_000)
        let scorer = CiteCheck.helper(engine: client, slot: { slot })
        var labels: [String: String] = [:]
        // labels.tsv (item<TAB>label, written by tools/at/at250-labels.py score; CSV reasons can span lines)
        for line in try String(contentsOfFile: dir + "/labels.tsv", encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            if f.count >= 2 { labels[f[0]] = f[1].trimmingCharacters(in: .whitespaces).lowercased() }
        }
        var rows: [[String: Any]] = []
        for line in try String(contentsOfFile: dir + "/label-input.jsonl", encoding: .utf8).split(separator: "\n") {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let item = o["item"] as? String, let sentence = o["sentence"] as? String, let passage = o["passage"] as? String,
                  let label = labels[item], label != "n/a" else { continue }
            // per-source premises: "[n] text" blocks joined by blank lines (bench order)
            let premises = passage.components(separatedBy: #"\n\n["#).enumerated().map { $0.offset == 0 ? $0.element : "[" + $0.element }
                .map { $0.replacingOccurrences(of: #"^\[\d+\] "#, with: "", options: .regularExpression) }
            let claims = CitationEntailment.claims(sentence)
            var pairs: [CitationEntailment.Pair] = []
            for c in claims { for p in premises { pairs.append(.init(claim: c, premise: p)) } }
            let scores = try await scorer(pairs)
            let k = premises.count
            let best = (0..<claims.count).map { c in scores[(c * k)..<((c + 1) * k)].max() ?? 0 }
            rows.append(["item": item, "label": label, "whole": best[0], "decomposed": best.min() ?? 0, "claims": claims,
                         "claim_scores": best])
        }
        func share(_ key: String) -> [String: Any] {
            let kept = rows.filter { ($0[key] as? Float ?? 0) >= CitationEntailment.threshold }
            let sup = kept.filter { $0["label"] as? String == "supported" }.count
            return ["kept": kept.count, "kept_supported": sup, "ratio": Double(sup) / Double(max(kept.count, 1))]
        }
        let report: [String: Any] = ["labels": dir, "items": rows.count, "threshold": CitationEntailment.threshold,
                                     "whole": share("whole"), "decomposed": share("decomposed"), "rows": rows]
        try write(report, a["out"] ?? dir + "/citecheck-eval.json")
        say("whole \(share("whole")) decomposed \(share("decomposed"))")
    }

    /// A-M7-T03c attempt 6: runs the generative verifier (CitationVerifier, the tier's chat model) on independently
    /// labelled sentences that the current pipeline would still show cited — not dropped by the attempt-5 grounding
    /// checks (replay-attempt5.json) and ≥ threshold on decomposed MiniCheck (citecheck-eval.json) — and writes the
    /// kept-supported share and kept count, plus the time per sentence and per answer (sum over a question's sentences).
    ///   antichat-bench citations --stage verifier-eval --labels build/at/AT-250/attempt5/labels-T3 --model chat-35b-q4 --cap T3-48
    static func verifierEval(_ a: BenchArgs) async throws {
        guard let dir = a["labels"] else { throw BenchError("--labels <dir> is required") }
        let key = a["model"] ?? "chat-9b-q4", cap = a["cap"] ?? "T1"
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-verifier-eval")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let generate = CiteVerify.generator(engine: client, slot: { slot })
        _ = try? await generate("Say OK.", 4)  // first request compiles kernels; not measured
        // dev tuning only: --prompt-file (template with {{SOURCES}} {{SENTENCES}} {{COUNT}}), --batch-size, --passage-chars
        var config = CitationVerifier.Config()
        if let f = a["prompt-file"] { config.template = try String(contentsOfFile: f, encoding: .utf8) }
        config.batchSize = a.int("batch-size", config.batchSize)
        config.passageChars = a.int("passage-chars", config.passageChars)
        var labels: [String: String] = [:]
        for line in try String(contentsOfFile: dir + "/labels.tsv", encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            if f.count >= 2 { labels[f[0]] = f[1].trimmingCharacters(in: .whitespaces).lowercased() }
        }
        func json(_ f: String) -> [String: Any] {
            (FileManager.default.contents(atPath: dir + "/" + f).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        }
        let dropped = Set(((json("replay-attempt5.json")["dropped"] as? [[Any]]) ?? []).compactMap { $0.first as? String })
        var mini: [String: Double] = [:]
        for r in (json("citecheck-eval.json")["rows"] as? [[String: Any]]) ?? [] {
            if let i = r["item"] as? String { mini[i] = (r["decomposed"] as? Double) ?? (r["decomposed"] as? NSNumber)?.doubleValue }
        }
        // the sentences the current pipeline still shows cited, grouped per question (= per answer), in order
        var groups: [(qid: String, rows: [(item: String, label: String, item0: CitationVerifier.Item)])] = []
        for line in try String(contentsOfFile: dir + "/label-input.jsonl", encoding: .utf8).split(separator: "\n") {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let item = o["item"] as? String, let qid = o["qid"] as? String, let sentence = o["sentence"] as? String,
                  let passage = o["passage"] as? String, let label = labels[item], label != "n/a" else { continue }
            guard !dropped.contains(item), (mini[item] ?? 1) >= Double(CitationEntailment.threshold) else { continue }
            var sources: [(n: Int, text: String)] = []
            for blk in passage.components(separatedBy: "\n\n[").enumerated().map({ $0.offset == 0 ? $0.element : "[" + $0.element }) {
                if let m = blk.firstMatch(of: /^\[(\d+)\] ([\s\S]*)$/), let n = Int(m.output.1) { sources.append((n, String(m.output.2))) }
            }
            let it = CitationVerifier.Item(sentence: sentence, sources: sources)
            if groups.last?.qid == qid { groups[groups.count - 1].rows.append((item, label, it)) } else { groups.append((qid, [(item, label, it)])) }
        }
        var rows: [[String: Any]] = [], answerMs: [Double] = [], batchMs: [Double] = []
        let start = ContinuousClock.now
        for (gi, g) in groups.enumerated() {
            var total = 0.0
            var b = 0
            while b < g.rows.count {
                let chunk = Array(g.rows[b..<min(g.rows.count, b + config.batchSize)])
                let t = ContinuousClock.now
                // the same request verifyBatch makes, with the raw reply kept for the report
                let q = CitationVerifier.batchPrompt(chunk.map(\.item0), config: config)
                let raw = (try? await generate(q, CitationVerifier.tokens(count: chunk.count))) ?? ""
                let v = CitationVerifier.parseBatch(raw, count: chunk.count)
                let ms = Stats.secs(ContinuousClock.now - t) * 1000
                total += ms; batchMs.append(ms)
                for (k, r) in chunk.enumerated() {
                    rows.append(["item": r.item, "qid": g.qid, "label": r.label, "pre": true,
                                 "verdict": v[k].map { $0 ? "supported" : "missing" } ?? "none", "batch": chunk.count,
                                 "batch_ms": ms, "prompt_chars": q.count, "raw": k == 0 ? raw : ""])
                }
                b += chunk.count
            }
            answerMs.append(total)
            say("\(gi + 1)/\(groups.count) \(g.qid) \(g.rows.count) sentences \(Int(total)) ms")
        }
        func share(_ keep: ([String: Any]) -> Bool) -> [String: Any] {
            let kept = rows.filter(keep)
            let sup = kept.filter { $0["label"] as? String == "supported" }.count
            return ["kept": kept.count, "kept_supported": sup, "ratio": Double(sup) / Double(max(kept.count, 1))]
        }
        let ver: ([String: Any]) -> Bool = { $0["verdict"] as? String != "missing" }
        let report: [String: Any] = [
            "labels": dir, "model": key, "cap": cap, "items": rows.count, "batch_size": config.batchSize,
            "passage_chars": config.passageChars, "no_verdict": rows.filter { $0["verdict"] as? String == "none" }.count,
            "before_verifier": share { _ in true }, "after_verifier": share(ver),
            "batch_ms_p50": Self.pct(batchMs, 0.5), "batch_ms_p95": Self.pct(batchMs, 0.95),
            "answer_ms_p50": Self.pct(answerMs, 0.5), "answer_ms_p95": Self.pct(answerMs, 0.95), "answer_ms_max": answerMs.max() ?? 0,
            "answers": answerMs.count, "load_avg": SearchAvailability.loadAverage(), "seconds": Stats.secs(ContinuousClock.now - start),
            "prompt": config.template, "rows": rows,
        ]
        try write(report, a["out"] ?? dir + "/verifier-eval-\(key).json")
        say("before \(share { _ in true }) after \(share(ver)) answer p50 \(Self.pct(answerMs, 0.5)) p95 \(Self.pct(answerMs, 0.95)) ms")
    }

    static func judge(_ a: BenchArgs) async throws {
        guard let ap = a["answers"], let data = FileManager.default.contents(atPath: ap),
              var ans = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = ans["rows"] as? [[String: Any]] else { throw BenchError("--answers <answers.json> (stage answer) required") }
        let key = a["judge"] ?? "chat-122b"
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-citations-judge")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        if let gb = DevSlots.tierB[a["judge-cap"] ?? "T4"], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("judge warmup: \(err)") }
        let composer = PromptComposer()
        var judged: [[String: Any]] = [], outRows: [[String: Any]] = []
        var total = 0, supported = 0
        let start = ContinuousClock.now
        for (i, r) in rows.enumerated() {
            var row = r
            var cited = (r["cited"] as? [[String: Any]]) ?? []
            for j in cited.indices {
                let s = cited[j]["sentence"] as? String ?? "", p = cited[j]["passage"] as? String ?? ""
                let prompt = "P: \(p)\n\nS: \(s)\n\nIs sentence S supported by passage P? Answer yes or no."
                let req = composer.compose(PromptInputs(), context: VolatileContext()).request(
                    sessionID: UUID(), modelSlot: slot, conversation: [ChatMessage(role: .user, content: prompt)],
                    sampling: Sampling(temperature: 0, topP: 1, maxTokens: 12, seed: 7))
                var text = ""
                for try await e in client.chat(req) { if case .textDelta(let d) = e { text += d } }
                let verdict = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let yes = verdict.hasPrefix("yes")
                cited[j]["judge"] = yes ? "yes" : "no"
                cited[j]["judge_raw"] = verdict
                total += 1
                if yes { supported += 1 }
                judged.append(["qid": r["id"] ?? "", "sentence": s, "n": cited[j]["n"] ?? [], "urls": cited[j]["urls"] ?? [],
                               "passage": p, "judge": yes ? "yes" : "no"])
            }
            row["cited"] = cited
            outRows.append(row)
            say("\(i + 1)/\(rows.count) \(r["id"] ?? "") judged \(cited.count) running \(supported)/\(total)")
        }
        let ratio = Double(supported) / Double(max(total, 1))
        ans["rows"] = outRows
        ans["stage"] = "judge"
        ans["judge"] = key
        ans["judge_revision"] = revision(key)
        if let final = a["judge-final"], final != key {  // a stand-in judge until the specified one is installed
            ans["judge_provisional"] = true
            ans["judge_final"] = "\(final) pending download"
        }
        ans["judge_load_avg"] = SearchAvailability.loadAverage()
        ans["judge_seconds"] = Stats.secs(ContinuousClock.now - start)
        ans["cited_sentences"] = total
        ans["supported_cited_sentences"] = supported
        ans["ratio"] = ratio
        ans["bar"] = 0.90
        ans["pass"] = ratio >= 0.90 && (ans["pills_unfetched"] as? Int ?? 1) == 0
        ans["judge_prompt"] = "P: <passage>\\n\\nS: <sentence>\\n\\nIs sentence S supported by passage P? Answer yes or no."
        let out = a["out"] ?? "citations.json"
        try write(ans, out)
        // A-M7-05: random 20 % of the judged sentences (seed 11) for the human spot-check.
        var rng = SplitMix(seed: 11)
        let pick = judged.indices.shuffled(using: &rng).prefix(Int((Double(judged.count) * 0.2).rounded(.up))).sorted()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "qid,sentence,n,source_url,passage,judge,human_label\n"
        for k in pick {
            let j = judged[k]
            csv += [q("\(j["qid"] ?? "")"), q(j["sentence"] as? String ?? ""), q(((j["n"] as? [Int]) ?? []).map(String.init).joined(separator: " ")),
                    q(((j["urls"] as? [String]) ?? []).joined(separator: " ")), q(j["passage"] as? String ?? ""), q(j["judge"] as? String ?? ""), ""]
                .joined(separator: ",") + "\n"
        }
        let csvPath = URL(fileURLWithPath: out).deletingLastPathComponent().appending(path: "spotcheck-20.csv")
        try csv.write(to: csvPath, atomically: true, encoding: .utf8)
        say("supported \(supported)/\(total) = \(ratio) (bar 0.90) \(ratio >= 0.90 ? "PASS" : "FAIL") → \(out); spotcheck \(pick.count) → \(csvPath.path)")
    }

    // MARK: Helpers

    /// Upper bound on a cited sentence's passage (characters): far above any tier's evidence budget.
    static let passageCap = 200_000

    static func pct(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
    }

    static func write(_ obj: [String: Any], _ path: String) throws {
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: u)
    }

    /// `repo@commit` of a dev catalog model (catalog/dev-catalog.json), or "" when unknown.
    static func revision(_ key: String) -> String {
        guard let d = FileManager.default.contents(atPath: "catalog/dev-catalog.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = (j["models"] as? [String: Any])?[key] as? [[String: Any]] else { return "" }
        return m.compactMap { $0["repo"] as? String }.joined(separator: " ")
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0, hosts = Set<String>()
        func add(_ h: String) { lock.withLock { n += 1; hosts.insert(h) } }
        var snapshot: (Int, [String]) { lock.withLock { (n, hosts.sorted()) } }
    }
}

/// Length of the `[n,m]` marker that starts at `location` in a validated answer.
enum CitationValidatorMarker {
    static func at(_ s: NSString, _ location: Int) -> Int {
        let r = s.range(of: #"^\[\d{1,3}(?:,\d{1,3})*\]"#, options: .regularExpression,
                        range: NSRange(location: location, length: s.length - location))
        return r.location == NSNotFound ? 0 : r.length
    }
}
