// `antichat-bench fresh-hint` (M7.T05 step 5; AT-NFR-U12, AT-228 c5; R-228 AC5): precision / recall of
// FreshnessHintPolicy.shouldShow with web search off over fresh-vs-stable-200, and that the run used no network
// (NetworkGate observer count = 0). Detector legs: date rule (the model's knowledge cutoff) + the term list; the
// router leg (`web_needed` score) runs only with `--router` (needs the engine helper's embed model, still local).
//   antichat-bench fresh-hint --fixture fixtures/prompts/fresh-vs-stable-200.jsonl [--model chat-9b-q4] [--router]
//                             --out build/at/AT-NFR-U12/<date>.json
// Bars (nfr.md NFR-U12): precision ≥ 0.80, recall ≥ 0.70.
import AntiChatHarness
import AntiChatNetwork
import AntiChatTools
import Foundation

enum FreshHint {
    struct Row: Decodable { var id: String; var lang: String; var prompt: String; var label: String }

    static func run(_ a: BenchArgs) async throws {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture <fresh-vs-stable-200.jsonl> is required") }
        let rows = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        guard let detector = FreshnessDetector.bundled else { throw BenchError("fresh-terms.json missing from the Harness bundle") }
        let model = a["model"] ?? "chat-9b-q4"
        let cutoff = detector.cutoff(forModel: model)
        let net = SearchE2E.HostSet()
        let obs = NetworkGate.addObserver { e in net.add(e.host) }
        defer { NetworkGate.removeObserver(obs) }
        var router: PreRouter?
        if a["router"] != nil {
            let client = EngineClient(appBuild: "antichat-bench-fresh-hint")
            _ = try await client.ensureConnected()
            let embedSlot = DevSlots.slot("embed")
            let emb = DeferredRouteEmbedding()
            emb.set(HelperEmbedder(engine: client, embedSlot: { embedSlot }))
            router = PreRouter.bundled(embedding: emb)
            if let s = router?.scorer { await s.prepare() }
        }
        var tp = 0, fp = 0, fn = 0, tn = 0, byReason: [String: Int] = [:], out: [[String: Any]] = []
        for r in rows {
            var score: Float?
            if let router { score = await router.decide(userText: r.prompt, hasImage: false, chips: [], tools: [], tier: .t1).scores[.webNeeded] }
            let reason = detector.hit(r.prompt, cutoff: cutoff, webNeededScore: score)
            let shown = FreshnessHintPolicy.shouldShow(prompt: r.prompt, detector: detector, cutoff: cutoff, webNeededScore: score,
                                                       search: .switchedOff, dismissed: false, suggestEnabled: true)
            let fresh = r.label == "fresh"
            switch (shown, fresh) {
            case (true, true): tp += 1
            case (true, false): fp += 1
            case (false, true): fn += 1
            case (false, false): tn += 1
            }
            if let reason, shown { byReason[reason.rawValue, default: 0] += 1 }
            out.append(["id": r.id, "lang": r.lang, "label": r.label, "shown": shown, "reason": reason?.rawValue ?? "",
                        "web_needed": score.map { Double($0) } ?? -1, "prompt": r.prompt])
        }
        let precision = tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp)
        let recall = tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn)
        let pass = precision >= 0.80 && recall >= 0.70 && net.all.isEmpty
        let report: [String: Any] = [
            "cmd": "fresh-hint", "fixture": fixture, "model": model, "cutoff": cutoff ?? "", "router": router != nil,
            "tp": tp, "fp": fp, "fn": fn, "tn": tn, "precision": precision, "recall": recall,
            "bars": ["precision": 0.80, "recall": 0.70], "network_hosts": net.all, "network_requests_zero": net.all.isEmpty,
            "by_reason": byReason, "pass": pass, "date": ISO8601DateFormatter().string(from: Date()),
            "misses": out.filter { ($0["shown"] as? Bool) != (($0["label"] as? String) == "fresh") }, "rows": out,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let o = a["out"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: o).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: o))
            say("wrote \(o)")
        }
        say("fresh-hint: precision \(String(format: "%.3f", precision)) recall \(String(format: "%.3f", recall)) "
            + "(tp \(tp) fp \(fp) fn \(fn) tn \(tn)) network \(net.all.isEmpty ? "none" : net.all.joined(separator: ",")) \(pass ? "PASS" : "FAIL")")
    }
}
