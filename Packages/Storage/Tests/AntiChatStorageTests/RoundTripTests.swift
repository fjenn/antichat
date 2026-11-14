// M8.T07 AT-093 AC2 (R-093) step 4: lossless round trip. gen-chats.py seeds 1,000 chats (branches, a 1,000-message
// chat, 50 pictures, 2 projects × 4 files, 30 memories, 1 Evil chat) → canonical dump A (tools/ci/db-canon.py
// --roundtrip) → export (media on) → a new, empty container → import → canonical dump B; A and B must be identical.
// Then the same with media off: chats and turns still identical, every blob reported as missing. A second import of
// the same zip adds nothing (dedup by chat id). Log: build/at/AT-093/<date>.log (`canonical_diff_lines=0`).
//   make test-unit FILTER=RoundTripTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

func at093Log(_ line: String) {
    let dir = repoRoot.appendingPathComponent("build/at/AT-093")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(Date().formatted(.iso8601.year().month().day())).log")
    let data = Data((line + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
}

/// db-canon.py --roundtrip of a checkpointed database file.
func canonRoundtrip(_ url: URL) throws -> [String] {
    try runPython("tools/ci/db-canon.py", [url.path, "--roundtrip"]).components(separatedBy: "\n")
}

func checkpoint(_ db: AppDatabase) throws {
    try db.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
}

/// Lines of `a` and `b` that differ (a multiset diff: order is already canonical).
func diffLines(_ a: [String], _ b: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for l in a { counts[l, default: 0] += 1 }
    for l in b { counts[l, default: 0] -= 1 }
    let out = counts.filter { $0.value != 0 }.map { "\($0.value > 0 ? "-" : "+")\($0.key)" }.sorted()
    return out.isEmpty && a != b ? ["(same lines, different order)"] : out
}

@Suite("RoundTripTests", .serialized) struct RoundTripTests {
    static let args = ["--chats", "1000", "--projects", "2", "--project-files", "4", "--memories", "30", "--memory-topics", "6",
                       "--evil", "1", "--images", "50"]

    @Test func exportImportIsLossless() throws {
        let dir = try tempContainer("roundtrip")
        let seedURL = try generateChats(in: dir, Self.args)
        let a = try canonRoundtrip(seedURL)
        let source = try AppDatabase.onDisk(at: seedURL)
        let (summaryA, _) = try source.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM chat")!, try Int.fetchOne(db, sql: "SELECT count(*) FROM message")!)
        }
        #expect(summaryA == 1000)

        let zip = dir.appendingPathComponent("export.zip")
        let t0 = Date()
        let exported = try ExportAllWriter(database: source).write(to: zip, options: ExportOptions(includeMedia: true))
        let exportS = Date().timeIntervalSince(t0)
        #expect(exported.counts.chats == 1000 && exported.counts.media == 58 && exported.missingMedia == 0)

        // A new container (the old one "wiped": a different folder, a fresh migrated database, an empty media store).
        let target = try tempContainer("roundtrip-target")
        let dbURL = target.appendingPathComponent("antichat.sqlite")
        let fresh = try AppDatabase.onDisk(at: dbURL)
        let t1 = Date()
        let summary = try AntiChatImporter(database: fresh, mediaRoot: target.appendingPathComponent("Media")).run(zip)
        let importS = Date().timeIntervalSince(t1)
        #expect(summary.chats == 1000 && summary.skipped == 0 && summary.projects == 2 && summary.memories == 30)
        #expect(summary.images == 58 && summary.missingMedia == 0)
        try checkpoint(fresh)
        let b = try canonRoundtrip(dbURL)
        let diff = diffLines(a, b)
        #expect(diff.isEmpty, "\(diff.prefix(20))")
        // The restored files are byte-identical (by sha256) and readable at their new paths.
        let missing = try fresh.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM file_blob").filter { !FileManager.default.fileExists(atPath: $0) }
        }
        #expect(missing.isEmpty)

        // Re-import: nothing new (dedup by chat id through import_record).
        let again = try AntiChatImporter(database: fresh, mediaRoot: target.appendingPathComponent("Media")).run(zip)
        #expect(again.chats == 0 && again.skipped == 1000 && again.projects == 0 && again.memories == 0)
        try checkpoint(fresh)
        #expect(diffLines(a, try canonRoundtrip(dbURL)).isEmpty)
        let records = try fresh.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM import_record WHERE source = 'antichat'") }
        #expect(records == 1000)

        let zipMB = Double((try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0) / 1e6
        at093Log(String(format: "%@ round trip: chats=1000 messages=%d export_s=%.2f import_s=%.2f zip_mb=%.1f canonical_lines=%d canonical_diff_lines=%d",
                        Date().formatted(.iso8601), exported.counts.messages, exportS, importS, zipMB, a.count, diff.count))
    }

    @Test func mediaOffKeepsChatsAndReportsMissing() throws {
        let dir = try tempContainer("roundtrip-nomedia")
        let seedURL = try generateChats(in: dir, ["--chats", "60", "--long", "0:0", "--turns", "30", "--projects", "1",
                                                  "--project-files", "2", "--memories", "5", "--evil", "1", "--images", "6"])
        let a = try canonRoundtrip(seedURL)
        let source = try AppDatabase.onDisk(at: seedURL)
        let zip = dir.appendingPathComponent("export.zip")
        _ = try ExportAllWriter(database: source).write(to: zip, options: ExportOptions(includeMedia: false))
        let target = try tempContainer("roundtrip-nomedia-target")
        let dbURL = target.appendingPathComponent("antichat.sqlite")
        let fresh = try AppDatabase.onDisk(at: dbURL)
        let summary = try AntiChatImporter(database: fresh, mediaRoot: target.appendingPathComponent("Media")).run(zip)
        #expect(summary.chats == 60 && summary.missingMedia == 8 && summary.images == 0)
        try checkpoint(fresh)
        let b = try canonRoundtrip(dbURL)
        // Chats, messages, parts, attachments, projects and memory are identical; only the media files are absent.
        let diff = diffLines(a, b)
        #expect(diff.isEmpty, "\(diff.prefix(20))")
        at093Log("\(Date().formatted(.iso8601)) media off: chats=60 missing_media=\(summary.missingMedia) canonical_diff_lines=\(diff.count)")
    }
}
