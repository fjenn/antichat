// `antichat-bench search-availability` (M7.T01 step 9, AT-248 c3; R-248 AC3): the app's SearchBroker over the
// 100-query fixture with one engine forced to answer 403 (the `-SearchBlockEngine` rule), live through NetworkGate
// or replayed from the saved SERPs (offline, deterministic).
//   antichat-bench search-availability --fixture fixtures/prompts/search-availability-100.jsonl --block duckduckgo \
//       [--replay fixtures/web/serp-snapshots] [--pace 1.0] [--hits (each query's hit list)] --out build/at/AT-248/<date>-blocked-ddg.json
// Pass: results_nonempty / 100 ≥ 0.95 (printed and in the JSON).
import AntiChatTools
import Foundation
import OsaurusVendored

enum SearchAvailability {
    static func run(_ a: BenchArgs) async throws {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture <search-availability-100.jsonl> is required") }
        let rows = try String(contentsOf: URL(fileURLWithPath: fixture), encoding: .utf8).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
        let blocked = Set((a["block"] ?? "").split(separator: ",").map(String.init))
        let qids = Dictionary(rows.compactMap { r in r["query"].flatMap { q in r["id"].map { (q, $0) } } }, uniquingKeysWith: { a, _ in a })
        let inner: any SearchTransport = a["replay"].map { ReplaySearchTransport(root: URL(fileURLWithPath: $0), qids: qids) }
            ?? GatedSearchTransport()
        let broker = SearchBroker(registry: EngineRegistry(), transport: BlockingSearchTransport(inner: inner, blocked: blocked),
                                  safeSearch: { false })
        let pace = Double(a["pace"] ?? (a["replay"] == nil ? "1.0" : "0")) ?? 0
        say("search-availability: \(rows.count) queries, blocked \(blocked.sorted()), \(a["replay"] == nil ? "live" : "replay")")
        var perQuery: [[String: Any]] = [], nonEmpty = 0, latencies: [Double] = []
        var engineWins: [String: Int] = [:], failures: [String: Int] = [:]
        for r in rows {
            let q = r["query"] ?? ""
            let res = await broker.search(queries: [q])
            if !res.hits.isEmpty { nonEmpty += 1 }
            latencies.append(res.elapsed)
            for e in res.engines { engineWins[e, default: 0] += 1 }
            for at in res.attempts where !at.ok || at.count == 0 { failures["\(at.provider):\(at.kind.rawValue)", default: 0] += 1 }
            perQuery.append(["id": r["id"] ?? "", "hits": res.hits.count, "engines": res.engines, "elapsed_s": res.elapsed,
                             "attempts": res.attempts.map { ["engine": $0.provider, "ok": $0.ok, "count": $0.count, "kind": $0.kind.rawValue] }]
                            .merging(a["hits"] == nil ? [:] : ["hit_list": res.hits.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet, "engine": $0.engine] }]) { x, _ in x })
            if pace > 0 { try await Task.sleep(for: .milliseconds(Int(pace * 1000))) }
        }
        let rate = Double(nonEmpty) / Double(max(rows.count, 1))
        let report: [String: Any] = [
            "cmd": "search-availability", "fixture": fixture, "blocked": blocked.sorted(), "mode": a["replay"] == nil ? "live" : "replay",
            "date": ISO8601DateFormatter().string(from: Date()), "queries": rows.count, "results_nonempty": nonEmpty,
            "rate": rate, "pass": rate >= 0.95, "bar": 0.95, "engines_enabled": EngineRegistry().enabled,
            "engine_wins": engineWins, "failures": failures, "elapsed_s": Stats.summary(latencies),
            "load_avg": loadAverage(), "per_query": perQuery,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let out = a["out"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out))
            say("wrote \(out)")
        }
        say("results_nonempty \(nonEmpty)/\(rows.count) = \(rate) (bar 0.95) \(rate >= 0.95 ? "PASS" : "FAIL"); wins \(engineWins)")
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }
}
