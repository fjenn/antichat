// `antichat-bench search-e2e` (M7.T03 step 10; AT-248 c1, AT-254; R-248 AC1, R-254): real turns with the Web search
// chip on, a real chat model over XPC and the LIVE keyless engines through NetworkGate (the app's WebSearchTools:
// SearchBroker → PageFetcher → Extractor → EvidenceRanker with the helper's embed model → EvidenceBudget →
// WebResultsBlock), a fresh on-disk store per run (no Keychain item is read; the engines need no key). Per run:
//   activity_s       send → the "Searching the web" activity update (the line the window draws in that frame or the
//                    next; the frame part is the -SearchProbe chip leg's `activityMs`)
//   results_s        the engines' race (signpost `searchResults`)       fetch_extract_s  pages (signpost `fetchExtract`)
//   ttft_s           send → the first answer token (signpost `ttftSearch` in the app)
//   complete_s       send → answer complete                             pills            rendered pills (fetched only)
// Engines that answer with a bot check are never retried (K-search-blocking); a run whose engines all fail answers
// without the web (`search.failed`) and counts as a miss of the pill check, never as a skipped run.
//   antichat-bench search-e2e --tier T1 [--model chat-9b-q4] [--runs 20] [--query "What's the latest macOS version?"]
//                             [--queries <search-availability-100.jsonl> (first --runs rows)] [--pace 2] --out <json>
//                             [--offset 20 (start at that row of --queries)] [--web-cache <dir> (a private page cache:
//                             cold-cache runs without touching the user's shared cache)]
//                             [--web-cache-per-run <dir> (M9.T05: a new empty private page cache for every query, so no
//                             query reads a page another one fetched; the gate's sessions keep no URLCache at all)]
// Every row records its cache state: `cache` (shared | private | private-fresh-per-run), `source_urls`, and
// `overlap_prev_urls` (source URLs an earlier query of this process also cited: the only possible warm page hits
// when the cache is shared across queries).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation

enum SearchE2E {
    static func run(_ a: BenchArgs) async throws {
        let tierName = a["tier"] ?? "T1"
        let key = a["model"] ?? (tierName.hasPrefix("T3") ? "chat-35b-q4" : "chat-9b-q4")
        let runs = a.int("runs", 20)
        var queries = [a["query"] ?? "What's the latest macOS version?"]
        if let f = a["queries"] {
            queries = try String(contentsOf: URL(fileURLWithPath: f), encoding: .utf8).split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["query"] as? String
            }
        }
        guard !queries.isEmpty else { throw BenchError("no queries") }
        queries = Array(queries.dropFirst(a.int("offset", 0)))
        guard !queries.isEmpty else { throw BenchError("no queries after --offset") }
        // M9.T05 (AT-254 cold): a private on-disk page cache (never the shared ~/Library/Caches/AntiChat/web).
        let pipeline = a["web-cache"].map {
            WebSearchPipeline(fetcher: PageFetcher(cache: DiskWebCache(directory: URL(fileURLWithPath: $0, isDirectory: true))),
                              ranker: WebSearchTools.appRanker)
        } ?? WebSearchPipeline(ranker: WebSearchTools.appRanker)
        let perRunCache = a["web-cache-per-run"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let cacheState = perRunCache != nil ? "private-fresh-per-run" : a["web-cache"] != nil ? "private" : "shared"
        var seenURLs: Set<String> = []
        // Signposts → this run's perf log (read back per run).
        let log = FileManager.default.temporaryDirectory.appending(path: "search-e2e-\(UUID().uuidString).jsonl")
        setenv("ANTICHAT_PERF_LOG", log.path, 1)
        let tier = DeviceTier(rawValue: tierName.hasPrefix("T3") ? "T3" : tierName) ?? .t1
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-search-e2e")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        let cap = tierName == "T2" ? "T2-24" : tierName == "T3" ? "T3-48" : tierName
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let embedSlot = DevSlots.slot("embed")
        if FileManager.default.fileExists(atPath: embedSlot.path) {
            WebSearchTools.useEmbedder(HelperEmbedder(engine: client, embedSlot: { embedSlot }))
        }
        let hosts = HostSet()
        let obs = NetworkGate.addObserver { e in hosts.add(e.host) }
        defer { NetworkGate.removeObserver(obs) }
        let pace = Double(a["pace"] ?? "2") ?? 2
        var rows: [[String: Any]] = []
        say("search-e2e: \(runs) runs, \(key) on \(tierName) (cap \(cap)), live engines \(EngineRegistry.shared.enabled)")
        // One unmeasured warm turn (model load + first prefill are not the search path).
        _ = try await turn(client: client, slot: slot, tier: tier, tierName: tierName, text: "Say OK.", chips: [], pipeline: pipeline)
        for i in 0..<runs {
            let before = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").count ?? 0
            let q = queries[i % queries.count]
            var runPipeline = pipeline
            if let base = perRunCache {  // M9.T05: a fresh empty page cache (and robots cache) for this query alone
                let dir = base.appending(path: "run-\(i)-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                runPipeline = WebSearchPipeline(fetcher: PageFetcher(cache: DiskWebCache(directory: dir)), ranker: WebSearchTools.appRanker)
            }
            let r = try await turn(client: client, slot: slot, tier: tier, tierName: tierName, text: q, chips: ["web"], pipeline: runPipeline)
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").dropFirst(before)
            func interval(_ name: String) -> Double? {
                lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    .first { ($0["name"] as? String) == name }.flatMap { ($0["dur_ns"] as? NSNumber)?.doubleValue }.map { $0 / 1e9 }
            }
            var row = r
            row["run"] = i
            row["query"] = q
            row["results_s"] = interval("searchResults") ?? -1
            row["fetch_extract_s"] = interval("fetchExtract") ?? -1
            // M9.T05: per page of each fetched window, seconds until it was done ("late" = after the fetch deadline).
            row["page_s"] = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { ($0["name"] as? String) == "fetchExtract" }.compactMap { ($0["meta"] as? [String: String])?["page_s"] }
            row["rank_s"] = interval("searchRank") ?? -1
            row["ttft_search_signpost_s"] = interval("ttftSearch") ?? -1
            row["load_avg"] = SearchAvailability.loadAverage()
            let urls = (r["source_urls"] as? [String]) ?? []
            row["cache"] = cacheState
            row["overlap_prev_urls"] = urls.filter { seenURLs.contains($0) }.count
            seenURLs.formUnion(urls)
            rows.append(row)
            say("\(i + 1)/\(runs) act \(fmt(r["activity_s"])) res \(fmt(row["results_s"])) fetch \(fmt(row["fetch_extract_s"])) "
                + "ttft \(fmt(r["ttft_s"])) done \(fmt(r["complete_s"])) pills \(r["pills"] ?? 0) step \(r["step_state"] ?? "")")
            if pace > 0 { try await Task.sleep(for: .milliseconds(Int(pace * 1000))) }
        }
        func p50(_ k: String) -> Double? {
            let xs = rows.compactMap { ($0[k] as? NSNumber)?.doubleValue }.filter { $0 >= 0 }
            return xs.isEmpty ? nil : Stats.quantile(xs, 0.5)
        }
        let pillsOK = rows.filter { ($0["pills"] as? Int ?? 0) >= 2 }.count
        let summary: [String: Any] = [
            "cmd": "search-e2e", "tier": tierName, "model": key, "runs": runs, "date": ISO8601DateFormatter().string(from: Date()),
            "engines_enabled": EngineRegistry.shared.enabled, "hosts": hosts.all,
            "web_results_tokens_p50": p50("web_results_tokens") as Any,
            "p50": ["activity_s": p50("activity_s") as Any, "results_s": p50("results_s") as Any, "fetch_extract_s": p50("fetch_extract_s") as Any,
                    "ttft_s": p50("ttft_s") as Any, "complete_s": p50("complete_s") as Any],
            "runs_with_2_pills": pillsOK, "load_avg": SearchAvailability.loadAverage(), "rows": rows, "cache": cacheState,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        if let out = a["out"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out))
            say("wrote \(out)")
        }
        say("p50 activity \(fmt(p50("activity_s"))) results \(fmt(p50("results_s"))) fetch \(fmt(p50("fetch_extract_s"))) "
            + "ttft \(fmt(p50("ttft_s"))) complete \(fmt(p50("complete_s"))); ≥ 2 pills in \(pillsOK)/\(runs)")
    }

    static func fmt(_ v: Any?) -> String { (v as? Double).map { String(format: "%.2f", $0) } ?? "-" }

    /// One turn on a fresh on-disk store with the app's web tools; times from the controller's updates.
    static func turn(client: EngineClient, slot: ModelSlot, tier: DeviceTier, tierName: String, text: String,
                     chips: [String], pipeline: WebSearchPipeline) async throws -> [String: Any] {
        let work = FileManager.default.temporaryDirectory.appending(path: "search-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: work.appending(path: "antichat.sqlite"))
        let registry = ToolRegistry([])
        let observers = WebSearchTools.install(into: registry, pipeline: pipeline, tier: { tierName })
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let rt = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(tier), selection: .standard,
                             tier: { tier })
        let c = TurnController(chatID: StorageID.make(), database: db, engine: client,
                               sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: 600, seed: 7), tools: rt) { slot }
        await c.setChips(chips)
        let aid = StorageID.make()
        let t0 = ContinuousClock.now
        let watch = Task { () -> (act: Double?, ttft: Double?, res: TurnResult?) in
            var act: Double?, ttft: Double?
            for await u in c.updates where u.assistantID == aid {
                switch u.kind {
                case .activity(let a) where act == nil && WebSearchTools.names.contains(a.tool):
                    act = Stats.secs(ContinuousClock.now - t0)
                case .textDelta(let d) where ttft == nil && !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    ttft = Stats.secs(ContinuousClock.now - t0)
                case .finished(let r): return (act, ttft, r)
                default: break
                }
            }
            return (act, ttft, nil)
        }
        await c.start(.send(userID: StorageID.make(), text: text, parentID: nil, attachmentIDs: []), assistantID: aid)
        let (act, ttft, res) = await watch.value
        let complete = Stats.secs(ContinuousClock.now - t0)
        // M9.T05 (AT-254 profile): per engine request — prompt / cached tokens, engine prefill and first-token time.
        let steps = await c.lastStepUsages.map { u -> [String: Any] in
            ["prompt": u.promptTokens, "cached": u.cachedTokens, "out": u.completionTokens, "prefill_s": u.promptTime,
             "engine_ttft_s": u.ttftMs / 1000, "decode_s": u.generateTime]
        }
        let prov = try db.read { try MessageRecord.fetchOne($0, key: aid) }?.provenance
        let sources = (prov?.sources ?? []).map {
            WebSource(n: $0.n, url: $0.url, title: $0.title, site: $0.site, date: $0.date, snippet: $0.snippet, fetched: $0.fetched)
        }
        let answer = (res?.text ?? "").replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        let v = CitationValidator.validate(answer, sources: sources)
        let acts = ToolActivity.activities(in: (try? MessageRepository(db).parts(of: aid)) ?? []).filter { WebSearchTools.names.contains($0.tool) }
        // M9.T05 prep (AT-248 c1 / AT-254): the size of every `<web_results>` block the model prefilled this turn, in the
        // chat model's own tokens (engine CountTokens), so a large evidence block is visible before any latency tuning.
        let blocks = webResultsBlocks(try db.read { try MessagePartRecord.fetchAll($0) }.map(\.body))
        let blockTokens = blocks.isEmpty ? [] : await client.countTokens(blocks, slot: slot)
        return ["steps": steps, "activity_s": act ?? -1, "web_results_blocks": blocks.count, "web_results_tokens": blockTokens.reduce(0, +),
                "web_results_tokens_max": blockTokens.max() ?? 0, "web_results_chars": blocks.reduce(0) { $0 + $1.count }, "ttft_s": ttft ?? -1, "complete_s": complete, "pills": v.citations.count,
                "dropped": v.dropped, "sources": sources.count, "fetched": sources.filter(\.fetched).count,
                "source_urls": sources.map(\.url),
                "step_state": acts.first?.state.rawValue ?? "none", "status": res.map { "\($0.status)" } ?? "none",
                "answer_chars": answer.count, "answer_head": String(answer.prefix(160))]
    }

    /// `<web_results …>…</web_results>` blocks in stored part bodies (plain text, or string values of a JSON body).
    static func webResultsBlocks(_ bodies: [String]) -> [String] {
        func strings(_ v: Any) -> [String] {
            if let s = v as? String { return [s] }
            if let a = v as? [Any] { return a.flatMap(strings) }
            if let d = v as? [String: Any] { return d.values.flatMap(strings) }
            return []
        }
        var out: [String] = []
        for b in bodies where b.contains("<web_results") {
            let texts = (try? JSONSerialization.jsonObject(with: Data(b.utf8), options: [.fragmentsAllowed])).map(strings) ?? [b]
            for t in texts {
                var rest = Substring(t)
                while let start = rest.range(of: "<web_results") {
                    let tail = rest[start.lowerBound...]
                    let end = tail.range(of: "</web_results>")?.upperBound ?? tail.endIndex
                    out.append(String(tail[..<end]))
                    rest = tail[end...]
                }
            }
        }
        return out
    }

    final class HostSet: @unchecked Sendable {
        private let lock = NSLock()
        private var set: Set<String> = []
        func add(_ h: String) { lock.withLock { _ = set.insert(h) } }
        var all: [String] { lock.withLock { set.sorted() } }
    }
}
