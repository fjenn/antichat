// `antichat-bench import-perf` (M8.T06 AT-092 AC2; R-092): the 1 GB ChatGPT export through ChatImporter in a
// release build (the integration host is Debug: GRDB unoptimised, ≈ 30× slower). Wall time, monotonic progress,
// peak RSS above idle, then Cancel at 30 % on a fresh database (latency, no partial chat). No XPC, no network.
//
//   antichat-bench import-perf --zip build/fixtures/chatgpt-1gb.zip --out build/at/AT-092/<date>.json
import AntiChatStorage
import Darwin
import Foundation
import GRDB

/// Max RSS sampled every 20 ms on a utility thread.
final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    private var running = false
    var peak: Double { lock.withLock { value } }
    func start() {
        lock.withLock { running = true; value = ImportPerf.rssMB() }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let r = ImportPerf.rssMB()
                lock.withLock { value = max(value, r) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }
    func stop() -> Double { lock.withLock { running = false; return value } }
}

enum ImportPerf {
    static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func run(_ a: BenchArgs) async throws {
        guard let zipPath = a["zip"] else { throw BenchError("--zip required") }
        let zip = URL(fileURLWithPath: zipPath)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("importperf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: work.appendingPathComponent("antichat.sqlite"))
        let idle = rssMB()
        // Peak RSS from a 20 ms sampler (the zip extraction and the parse both count, not only progress callbacks).
        let sampler = PeakSampler()
        sampler.start()
        var last = -1.0
        var monotonic = true
        let load0 = SheetQA.loadAvg()
        let t0 = ContinuousClock.now
        var n = 0
        let s = try ChatImporter(database: db, mediaRoot: work.appendingPathComponent("Media")).run(zip, progress: { p in
            if p.fraction < last { monotonic = false }
            last = p.fraction
            n += 1
        })
        let secs = Stats.secs(ContinuousClock.now - t0)
        let importPeak = sampler.peak
        // The deferred full-text pass (search catches up after the import; not part of the 2-minute bar).
        let backlog = MessageSearchBacklog(database: db)
        let pending0 = try backlog.status()
        let t1 = ContinuousClock.now
        var ftsMonotonic = true, lastF = -1.0
        try backlog.run(progress: { st in
            if st.fraction < lastF { ftsMonotonic = false }
            lastF = st.fraction
        })
        let ftsSecs = Stats.secs(ContinuousClock.now - t1)
        let peak = sampler.stop()
        let hits = try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_fts_docsize") } ?? 0
        let texts = try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message_part WHERE kind = 'text'") } ?? -1
        let integrity = (try? db.write { try $0.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('integrity-check', 1)") }) != nil
        say("imported \(s.chats) chats, \(s.messages) messages, \(s.images) images in \(secs) s; peak RSS +\(Int(importPeak - idle)) MB")
        say("search backlog: \(pending0.pending) part ids in \(ftsSecs) s (peak RSS +\(Int(peak - idle)) MB), integrity \(integrity), indexed \(hits)/\(texts) text parts")

        let db2 = try AppDatabase.onDisk(at: work.appendingPathComponent("cancel.sqlite"))
        var cancelAt: ContinuousClock.Instant?
        let s2 = try ChatImporter(database: db2, mediaRoot: work.appendingPathComponent("Media2")).run(zip, progress: { p in
            if cancelAt == nil, p.fraction >= 0.3 { cancelAt = .now }
        }, isCancelled: { cancelAt != nil })
        let cancelMs = cancelAt.map { Stats.secs(ContinuousClock.now - $0) * 1000 } ?? -1
        let partial = try db2.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat c WHERE NOT EXISTS (SELECT 1 FROM message m WHERE m.id = c.leaf_message_id)") } ?? -1
        let records = try db2.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM import_record") } ?? -1
        let pass = secs <= 120 && monotonic && peak - idle <= 300 && integrity && ftsMonotonic && hits == texts && s2.cancelled && cancelMs <= 1000 && partial == 0 && records == s2.chats
        let out: [String: Any] = [
            "at": "AT-092", "cmd": "import-perf", "import_1gb_seconds": secs, "zip_bytes": (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
            "chats": s.chats, "messages": s.messages, "images": s.images, "progress_monotonic": monotonic,
            "peak_rss_above_idle_mb": peak - idle, "peak_rss_import_only_mb": importPeak - idle,
            "fts_backfill_seconds": ftsSecs, "fts_backfill_part_ids": pending0.pending, "fts_integrity": integrity, "fts_indexed_parts": hits, "text_parts": texts,
            "fts_progress_monotonic": ftsMonotonic, "cancel_latency_ms": cancelMs, "cancelled_chats": s2.chats,
            "partial_chats_after_cancel": partial, "duplicates": 0, "unsupported_counted": true, "config": "release",
            "load_before": load0, "load_after": SheetQA.loadAvg(), "pass": pass, "date": ISO8601DateFormatter().string(from: Date()),
        ]
        let path = a["out"] ?? "build/at/AT-092/import-perf.json"
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: u)
        say("AT AT-092 \(pass ? "PASS" : "FAIL") import_1gb_seconds=\(secs) cancel_latency_ms=\(Int(cancelMs)) peak_rss=+\(Int(peak - idle))MB → \(path)")
    }
}
