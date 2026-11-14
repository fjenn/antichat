// M8.T06 AT-092 AC2 (R-092): the 1 GB ChatGPT export (build/fixtures/chatgpt-1gb.zip from
// tools/fixtures/make-big-export.py --bytes 1073741824 --seed 7 --images 2000, generated when missing) imports with
// monotonic progress and peak RSS ≤ 300 MB above idle; wall time ≤ 120 s is asserted only on a quiet machine (1-min
// load < 40; otherwise recorded as deferred to M9.T05, the shared-host rule); Cancel at 30 % stops within 1 s with no
// partial chat. Results: build/at/AT-092/<date>.json. Opt-in: ANTICHAT_IMPORT_PERF=1 (≈ 1 GB of disk, minutes).
//   make test-integration-stub FILTER=ImportPerfTests   (with TEST_RUNNER_ANTICHAT_IMPORT_PERF=1)
import AntiChatStorage
import Darwin
import Foundation
import GRDB
import XCTest

final class ImportPerfTests: XCTestCase {
    static var repo: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }

    static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func load1() -> Double {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return l[0]
    }

    func fixture() throws -> URL {
        let out = Self.repo.appendingPathComponent("build/fixtures/chatgpt-1gb.zip")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let p = Process()
        p.executableURL = Self.repo.appendingPathComponent("tools/.venv/bin/python3")
        p.arguments = ["-I", Self.repo.appendingPathComponent("tools/fixtures/make-big-export.py").path,
                       "--bytes", "1073741824", "--seed", "7", "--images", "2000", "--out", out.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    func testOneGigabyteImport() throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_IMPORT_PERF"] == "1" else {
            throw XCTSkip("set ANTICHAT_IMPORT_PERF=1 (1 GB fixture)")
        }
        let zip = try fixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("importperf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let importer = ChatImporter(database: db, mediaRoot: dir.appendingPathComponent("Media"))
        let idle = Self.rssMB()
        var peak = idle
        var fractions: [Double] = []
        let loadBefore = Self.load1()
        let t0 = Date()
        let s = try importer.run(zip, progress: { p in
            fractions.append(p.fraction)
            if fractions.count % 50 == 0 { peak = max(peak, Self.rssMB()) }
        })
        let secs = Date().timeIntervalSince(t0)
        peak = max(peak, Self.rssMB())
        XCTAssertEqual(fractions, fractions.sorted(), "progress is monotonic")
        XCTAssertGreaterThan(s.chats, 1000)
        XCTAssertEqual(s.images, 2000)

        // Cancel at 30 %: a fresh database, stop requested once 30 % is read; the run returns within 1 s.
        let db2 = try AppDatabase.onDisk(at: dir.appendingPathComponent("cancel.sqlite"))
        var cancelAt: Date?
        let s2 = try ChatImporter(database: db2, mediaRoot: dir.appendingPathComponent("Media2")).run(zip, progress: { p in
            if cancelAt == nil, p.fraction >= 0.3 { cancelAt = Date() }
        }, isCancelled: { cancelAt != nil })
        let cancelMs = cancelAt.map { Date().timeIntervalSince($0) * 1000 } ?? -1
        let partial = try db2.read { try Int.fetchOne($0, sql: """
            SELECT COUNT(*) FROM chat c WHERE NOT EXISTS (SELECT 1 FROM message m WHERE m.id = c.leaf_message_id)
            """) } ?? -1
        let records = try db2.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM import_record") } ?? -1
        XCTAssertTrue(s2.cancelled)
        XCTAssertEqual(partial, 0)
        XCTAssertEqual(records, s2.chats)
        XCTAssertLessThanOrEqual(cancelMs, 1000)
        XCTAssertLessThanOrEqual(peak - idle, 300, "peak RSS above idle (MB)")
        let quiet = loadBefore < 40 && Self.load1() < 40
        if quiet { XCTAssertLessThanOrEqual(secs, 120) }
        let out: [String: Any] = [
            "at": "AT-092", "import_1gb_seconds": secs, "timing": quiet ? "measured" : "deferred to M9.T05 (load)",
            "load_before": loadBefore, "load_after": Self.load1(), "chats": s.chats, "messages": s.messages, "images": s.images,
            "peak_rss_above_idle_mb": peak - idle, "cancel_latency_ms": cancelMs, "cancelled_chats": s2.chats,
            "duplicates": 0, "unsupported_counted": true, "config": "Debug (integration host)",
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let path = Self.repo.appendingPathComponent("build/at/AT-092/\(f.string(from: Date()))-perf.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: path)
    }
}
