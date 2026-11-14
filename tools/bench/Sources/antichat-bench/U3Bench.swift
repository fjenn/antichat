// `antichat-bench u3` (M9.T05, AT-NFR-U3): a message sent while the chat model is still loading. Each run evicts
// everything, then sends one turn through the real TurnController over XPC (fresh on-disk store), so the send itself
// triggers the load (ModelScheduler.ensureLoaded). Per run:
//   accepted_s   send → the turn's rows are written (accepted update: the message is queued, never dropped)
//   status_s     send → `modelLoading(true)`, the update the status line turns into "Loading model…" (bar ≤ 2 s)
//   ready_s      send → `modelLoading(false)` (weights resident)
//   ttft_s       send → first answer token (bar: NFR-M1 band for the weights + NFR-C1, checked in tools/perf/run.py)
// Run 0 is discarded (Metal pipeline cache, as `load`). The file cache stays warm unless --purge and `sudo -n purge`
// works (P-SUDO, labelled [WARM-CACHE] in run.py). Not covered: the app's ReadinessQueue (the window shows the same
// `status.loadingModel` from its own load observer before the engine reports; unit-tested in ReadinessQueueTests).
//   antichat-bench u3 --model <key> --cap <tier> --runs N --json <out> [--purge]
import AntiChatHarness
import AntiChatStorage
import Foundation

enum U3Bench {
    static func run(_ a: BenchArgs) async throws {
        let key = a["model"] ?? "chat-9b-q4"
        let cap = a["cap"] ?? "T1"
        guard let gb = DevSlots.tierB[cap] else { throw BenchError("--cap \(cap): unknown tier") }
        let slot = DevSlots.slot(key)
        let runs = a.int("runs", 20)
        let client = EngineClient(appBuild: "antichat-bench-u3")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9)))
        let purge = a["purge"] != nil && LoadBench.sh(["/usr/bin/sudo", "-n", "/usr/sbin/purge"]) == 0
        say("u3: helper pid=\(ack.helperPID) model=\(slot.key) cap=\(cap) purge=\(purge) runs=\(runs)")
        var rows: [[String: Any]] = []
        for i in 0...runs {
            for await _ in client.evict() {}
            if purge { _ = LoadBench.sh(["/usr/bin/sudo", "-n", "/usr/sbin/purge"]) }
            var r = try await turn(client: client, slot: slot)
            r["run"] = i
            r["discarded"] = i == 0
            rows.append(r)
            say("run \(i) accepted \(SearchE2E.fmt(r["accepted_s"])) status \(SearchE2E.fmt(r["status_s"])) ready \(SearchE2E.fmt(r["ready_s"])) "
                + "ttft \(SearchE2E.fmt(r["ttft_s"])) \(r["status"] ?? "")\(i == 0 ? " (discarded)" : "")")
        }
        for await _ in client.evict() {}
        let out: [String: Any] = [
            "cmd": "u3", "model": slot.key, "cap": cap, "budget_b": UInt64(gb * 1e9), "weights_bytes": slot.footprintBytes,
            "runs": runs, "purge": purge, "helper_pid": Int(ack.helperPID), "date": ISO8601DateFormatter().string(from: Date()),
            "load_avg": SearchAvailability.loadAverage(), "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        guard let path = a["json"] else { FileHandle.standardOutput.write(data); return }
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        say("wrote \(path)")
    }

    static func turn(client: EngineClient, slot: ModelSlot) async throws -> [String: Any] {
        let work = FileManager.default.temporaryDirectory.appending(path: "u3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: work.appending(path: "antichat.sqlite"))
        let c = TurnController(chatID: StorageID.make(), database: db, engine: client,
                               sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: 48, seed: 7)) { slot }
        let aid = StorageID.make()
        let t0 = ContinuousClock.now
        let watch = Task { () -> [String: Double] in
            var t: [String: Double] = [:]
            func mark(_ k: String) { if t[k] == nil { t[k] = Stats.secs(ContinuousClock.now - t0) } }
            for await u in c.updates where u.assistantID == aid {
                switch u.kind {
                case .accepted: mark("accepted_s")
                case .modelLoading(true), .phase(.loading): mark("status_s")
                case .modelLoading(false): mark("ready_s")
                case .textDelta(let d) where !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: mark("ttft_s")
                case .finished(let r):
                    mark("complete_s")
                    t["ok"] = r.status == .done ? 1 : 0
                    return t
                default: break
                }
            }
            return t
        }
        await c.start(.send(userID: StorageID.make(), text: "Say hello in one short sentence.", parentID: nil, attachmentIDs: []),
                      assistantID: aid)
        let t = await watch.value
        var row: [String: Any] = ["status": (t["ok"] ?? 0) == 1 ? "complete" : "not-complete"]
        for k in ["accepted_s", "status_s", "ready_s", "ttft_s", "complete_s"] { row[k] = t[k] ?? -1 }
        return row
    }
}
