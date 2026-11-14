// M8.T02 AT-242 AC3 real-model leg (`-Bench memory`): every fixtures/memory/paraphrase-100 pair and distinct-20 pair
// through MemoryUpdateDecider with the real `embed` model and the T1 chat model (`--model`, default chat-9b-q4) for
// the ambiguous band. Each pair runs on a fresh in-memory store: insert `existing` (with its vector), decide `new`.
// A paraphrase counts when the decider keeps one fact (UPDATE, or NONE on that fact); a distinct fact must be ADD.
// Writes build/at/AT-242/<date>.json. Run under `lockf /tmp/antichat-gpu.lock` (tools/at/at-242-real.sh).
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation

extension BenchMode {
    static func memory(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let fixtures = URL(fileURLWithPath: a.opts["fixtures"] ?? "fixtures/memory")
        guard let embedSlot = DevModels.searchSlot("embed") else { say("memory: no embed model"); return }
        let chat = DevModels.slot(a.opts["model"] ?? "chat-9b-q4")
        let embedder = HelperEmbedder(engine: client, embedSlot: { embedSlot }, rerankSlot: { nil })
        let model = EngineMemoryDecisionModel(engine: client, slot: { chat })
        var config = MemoryConfig.default
        if let u = a.opts["update-cosine"].flatMap(Float.init) { config.updateCosine = u }
        if let k = a.opts["ask-cosine"].flatMap(Float.init) { config.askCosine = k }
        func rows(_ name: String) throws -> [[String: String]] {
            try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
                .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        }
        var results: [[String: Any]] = []
        let started = Date()
        for (set, file) in [("paraphrase", "paraphrase-100.jsonl"), ("distinct", "distinct-20.jsonl")] {
            for r in try rows(file) {
                let db = try AppDatabase.inMemory()
                let store = MemoryStore(database: db)
                let existing = r["existing"]!, new = r["new"]!
                let v = try await embedder.embed([existing], kind: .document).first
                let (old, _) = try store.insert(topic: r["topic"]!, key: "fact", text: existing, origin: .tool, vector: v)
                let out = await MemoryUpdateDecider(store: store, embedder: embedder, model: model, config: config)
                    .decide(new: new, scope: .global, projectID: nil)
                let event: String, kept: Bool
                switch out.decision {
                case .add: (event, kept) = ("ADD", false)
                case .update(let id, _): (event, kept) = ("UPDATE", id == old.id)
                case .delete: (event, kept) = ("DELETE", false)
                case .none(let id): (event, kept) = ("NONE", id == old.id)
                }
                let correct = set == "paraphrase" ? kept : event == "ADD"
                let row: [String: Any] = ["set": set, "topic": r["topic"]!, "kind": r["kind"] ?? "", "existing": existing, "new": new,
                                          "event": event, "correct": correct, "cosine": Double(out.neighbours.first?.cosine ?? -1),
                                          "used_model": out.usedModel]
                results.append(row)
                raw.write(base.merging(row) { a, _ in a })
            }
        }
        let para = results.filter { $0["set"] as? String == "paraphrase" }, dist = results.filter { $0["set"] as? String == "distinct" }
        let rate = { (rs: [[String: Any]]) in Double(rs.filter { $0["correct"] as? Bool == true }.count) / Double(max(rs.count, 1)) }
        let updateOnly = Double(para.filter { $0["event"] as? String == "UPDATE" && $0["correct"] as? Bool == true }.count) / Double(max(para.count, 1))
        let summary: [String: Any] = [
            "at": "AT-242", "model": chat.key, "embed": embedSlot.key, "update_cosine": Double(config.updateCosine),
            "ask_cosine": Double(config.askCosine), "paraphrase_update_rate": rate(para), "paraphrase_update_only_rate": updateOnly,
            "distinct_add_rate": rate(dist), "model_calls": results.filter { $0["used_model"] as? Bool == true }.count,
            "seconds": Date().timeIntervalSince(started), "load_avg": ProcessInfo.processInfo.loadAverage1m, "rows": results,
        ]
        let day = Date().formatted(.iso8601.year().month().day())
        let out = URL(fileURLWithPath: a.opts["out"] ?? "build/at/AT-242/\(day).json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        say("AT-242 paraphrase_update_rate=\(rate(para)) (UPDATE only \(updateOnly)) distinct_add_rate=\(rate(dist)) model_calls=\(summary["model_calls"]!) → \(out.path)")
    }
}

extension ProcessInfo {
    var loadAverage1m: Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : -1
    }
}
