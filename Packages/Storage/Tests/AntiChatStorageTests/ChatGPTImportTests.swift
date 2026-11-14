// M8.T06 AT-092 (R-092 AC1/AC3) on `chatgpt-export/export.zip` through the streaming ChatImporter: every
// conversation of the three LibreChat fixtures keeps its node count and active leaf (`*.expected.json`), titles and
// timestamps to the second, images resolved to blobs whose sha256 equals the zip entry's, tagged `chat.source =
// chatgpt`; tool calls / outputs, code and the canvas are kept as `[Imported …]` text and counted. Also the
// streamer's string / escape / chunk-boundary handling.
//   make test-unit FILTER=ChatGPTImportTests
import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import AntiChatStorage

/// A fixture file: the shared checkout (ANTICHAT_FIXTURES) when it has it, else this tree's `fixtures/`.
func importFixture(_ rel: String) -> URL {
    let shared = fixturesRoot.appendingPathComponent(rel)
    return FileManager.default.fileExists(atPath: shared.path) ? shared : repoRoot.appendingPathComponent("fixtures").appendingPathComponent(rel)
}

struct ImportRig {
    let dir: URL
    let db: AppDatabase
    var media: URL { dir.appendingPathComponent("Media") }
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
    }
    var importer: ChatImporter { ChatImporter(database: db, mediaRoot: media) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite(.serialized) struct ChatGPTImportTests {
    @Test func exportZipImportsTreesImagesAndKeptParts() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let zip = importFixture("chats/chatgpt-export/export.zip")
        #expect(ChatImporter.detect(zip) == .chatGPT)
        var fractions: [Double] = []
        let s = try rig.importer.run(zip, progress: { fractions.append($0.fraction) })
        #expect(s.format == .chatGPT && s.chats == 5 && s.skipped == 0 && !s.cancelled)
        #expect(fractions == fractions.sorted() && fractions.last == 1)
        #expect(s.images == 3)
        #expect(s.kept["code"] == 1 && s.kept["code output"] == 1 && s.kept["canvas"] == 1)
        #expect((s.kept["browsing result"] ?? 0) > 0 && (s.kept["tool call"] ?? 0) > 0)  // LibreChat browsing calls + results

        // Trees: node count + active leaf of every fixture conversation (as the M1 AT-296 expected files).
        for name in ["chatgpt-export", "chatgpt-tree", "chatgpt-citations"] {
            let exp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: importFixture("chats/chatgpt-export/\(name).expected.json"))) as? [String: Any])
            for c in exp["conversations"] as? [[String: Any]] ?? [] {
                let id = try #require(c["id"] as? String) + (name == "chatgpt-citations" ? "-citations" : "")
                let row = try #require(try rig.db.read { try Row.fetchOne($0, sql: """
                    SELECT c.id, c.source, (SELECT COUNT(*) FROM message m WHERE m.chat_id = c.id) AS n,
                           (SELECT m.source_id FROM message m WHERE m.id = c.leaf_message_id) AS leaf
                    FROM chat c WHERE c.source_id = ?
                    """, arguments: [id]) })
                #expect(row["source"] == "chatgpt")
                #expect(row["n"] == c["nodes"] as? Int, "\(name) \(id)")
                #expect(row["leaf"] == c["active_leaf"] as? String, "\(name) \(id)")
            }
        }
        // The synthetic conversation: title, timestamps to the second, images, model slug, kept text.
        let chat = try #require(try rig.db.read { try ChatRecord.filter(Column("source_id") == "sy-0000-synthetic").fetchOne($0) })
        #expect(chat.title == "Pictures, code and a canvas")
        #expect(Int(chat.createdAt.timeIntervalSince1970) == 1_761_800_000 && Int(chat.updatedAt.timeIntervalSince1970) == 1_761_800_020)
        let archive = try Archive(url: zip, accessMode: .read)
        func sha(_ path: String) throws -> String {
            var d = Data()
            _ = try archive.extract(try #require(archive[path])) { d.append($0) }
            return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        let blobs = try rig.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.sha256, b.origin, m.role FROM attachment a JOIN file_blob b ON b.id = a.blob_id JOIN message m ON m.id = a.message_id
                WHERE m.chat_id = ? ORDER BY a.created_at
                """, arguments: [chat.id])
        }
        #expect(Set(blobs.map { $0["sha256"] as String }) == Set([try sha("file-Aa11Bb22-sunset.png"), try sha("file-Cc33Dd44-lake.webp"),
                                                                    try sha("dalle-generations/file-Ee55Ff66-kiln.webp")]))
        #expect(blobs.allSatisfy { ($0["origin"] as String) == "import" })
        let bodies = try rig.db.read { db in
            try String.fetchAll(db, sql: "SELECT p.body FROM message_part p JOIN message m ON m.id = p.message_id WHERE m.chat_id = ?",
                                arguments: [chat.id])
        }
        #expect(bodies.contains { $0.hasPrefix("[Imported canvas]\n") && $0.contains("kiln_notes") })
        #expect(bodies.contains { $0.hasPrefix("[Imported code output]") && $0.contains("3072") })
        let models = try rig.db.read { try String.fetchAll($0, sql: "SELECT DISTINCT model_id FROM message WHERE chat_id = ? AND model_id IS NOT NULL", arguments: [chat.id]) }
        #expect(models == ["imported:gpt-4o"])
    }

    @Test func unsupportedFilesAreRefused() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let f = rig.dir.appendingPathComponent("x.json")
        try Data(#"[{"hello": 1}]"#.utf8).write(to: f)
        #expect(ChatImporter.detect(f) == .unsupported)
        #expect(throws: ImportError.noConversations) { try rig.importer.run(f) }
    }

    @Test func streamerHandlesStringsEscapesAndChunkBoundaries() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let items = [#"{"a":"x ] } [ { \" \\"}"#, #"{"b":[1,[2,{"c":"\\\""}]],"d":"]"}"#, #"{"e":"\\\\"}"#]
        let f = rig.dir.appendingPathComponent("a.json")
        try Data(("[\n" + items.joined(separator: ",\n ") + "\n]").utf8).write(to: f)
        for size in [1, 2, 3, 7, 64, 1 << 20] {
            var got: [String] = []
            try JSONArrayStreamer(url: f, readSize: size).forEach { d, _ in got.append(String(decoding: d, as: UTF8.self)); return true }
            #expect(got == items, "readSize \(size)")
        }
        var first: [String] = []
        try JSONArrayStreamer(url: f).forEach { d, _ in first.append(String(decoding: d, as: UTF8.self)); return false }
        #expect(first.count == 1)
    }
}
