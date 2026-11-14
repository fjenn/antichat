// Internal gate for R-208 AC5 (M1.T04 step 6; closes in AT-208): `antichat-storage-torture` streams into one
// on-disk database with upserts every 50 ms and is killed with SIGKILL at a random point, 100 times. After every
// kill the database is reopened and must pass `PRAGMA integrity_check`, `foreign_key_check`, the FTS5
// integrity check and the tree invariants. ANTICHAT_CRASH_ITERATIONS overrides the count (default 100);
// ANTICHAT_CRASH_REPORT=<path> writes a JSON summary.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

/// The torture binary sits next to the test bundle (same SwiftPM products directory).
func tortureBinary() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["ANTICHAT_TORTURE_BIN"] { return URL(fileURLWithPath: path) }
    var candidates: [URL] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("antichat-storage-torture"))
    }
    if let exe = Bundle.main.executableURL {
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("antichat-storage-torture"))
    }
    candidates.append(repoRoot.appendingPathComponent(".build/debug/antichat-storage-torture"))
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw StorageError.notFound("antichat-storage-torture (looked in \(candidates.map(\.path)))")
    }
    return found
}

@Suite("CrashInjectionTests", .serialized) struct CrashInjectionTests {
    struct Iteration: Codable {
        var n: Int
        var killAfterMs: Int
        var chats: Int
        var messages: Int
        var interrupted: Int
        var errors: [String]
    }

    @Test func killNineAtRandomPoints() throws {
        let iterations = ProcessInfo.processInfo.environment["ANTICHAT_CRASH_ITERATIONS"].flatMap(Int.init) ?? 100
        let binary = try tortureBinary()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("antichat.sqlite")
        var results: [Iteration] = []

        for n in 1...iterations {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--db", dbURL.path, "--interval-ms", "50", "--seed", "\(n)"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Wait for `ready` (DB open, migrations and launch recovery committed), then kill mid-write.
            let ready = out.fileHandleForReading.availableData
            #expect(String(decoding: ready, as: UTF8.self).contains("ready"), "iteration \(n): torture did not start")
            let killAfter = Int.random(in: 20...1500)
            usleep(UInt32(killAfter) * 1000)
            #expect(process.isRunning, "iteration \(n): torture exited early (\(process.terminationStatus))")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            #expect(process.terminationReason == .uncaughtSignal)

            let database = try AppDatabase.onDisk(at: dbURL)
            var errors: [String] = []
            let stats = try database.write { db -> (Int, Int, Int) in
                let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                if integrity != ["ok"] { errors.append("integrity_check: \(integrity.prefix(3))") }
                do {
                    try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('integrity-check', 1)")
                    try db.execute(sql: "INSERT INTO chat_fts(chat_fts, rank) VALUES('integrity-check', 1)")
                } catch {
                    errors.append("fts integrity-check: \(error)")
                }
                errors += try TreeInvariants.violations(db)
                return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat") ?? 0,
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0,
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE status IN ('streaming', 'pending')") ?? 0)
            }
            #expect(errors.isEmpty, "iteration \(n) (kill after \(killAfter) ms): \(errors)")
            results.append(Iteration(n: n, killAfterMs: killAfter, chats: stats.0, messages: stats.1,
                                     interrupted: stats.2, errors: errors))
        }
        let failed = results.filter { !$0.errors.isEmpty }.count
        #expect(failed == 0)
        #expect(results.last.map { $0.messages > 0 } == true, "the torture never wrote a message")
        let summary = "CrashInjectionTests: \(results.count - failed)/\(results.count) iterations with 0 integrity errors; "
            + "final DB \(results.last?.chats ?? 0) chats, \(results.last?.messages ?? 0) messages; "
            + "streaming at kill (recovered as interrupted next launch): \(results.filter { $0.interrupted > 0 }.count)"
        print(summary)
        if let path = ProcessInfo.processInfo.environment["ANTICHAT_CRASH_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: path))
        }
    }
}
