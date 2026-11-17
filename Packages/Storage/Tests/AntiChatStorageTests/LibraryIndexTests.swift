// M5.T13 (R-022 AC1–AC4, R-045 AC2; AT-022 AC3 `make test-unit FILTER=LibraryIndexTests`): the Library index —
// newest first; filters All / Images / Videos / Files; FTS search over names and prompts (v33 library_fts, kept in step
// by triggers: insert, rename, delete); incognito (in-memory) never listed; Evil items hidden unless shown, and the
// default rule (follows the Evil enable state until set); delete removes the rows and the file, a shared blob stays
// until its last reference goes; v33 upgrades a v32 database and backfills the index.
//   make test-unit FILTER=LibraryIndexTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite struct LibraryIndexTests {
    struct Env {
        let db: AppDatabase
        let dir: URL
    }

    static func env() throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("libidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Media/2026"), withIntermediateDirectories: true)
        return Env(db: try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite")), dir: dir)
    }

    /// A blob file under `Media/2026/<sha>.<ext>` + its row.
    @discardableResult
    static func blob(_ e: Env, _ db: Database, _ id: String, ext: String) throws -> String {
        let path = e.dir.appendingPathComponent("Media/2026/\(id).\(ext)").path
        try Data(id.utf8).write(to: URL(fileURLWithPath: path))
        try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES (?, ?, ?, ?, 0, 'generated')",
                       arguments: [id, String(repeating: String(id.prefix(1)), count: 60) + id, id.utf8.count, path])
        return path
    }

    static func chat(_ db: Database, _ id: String, mode: String = "normal") throws {
        try db.execute(sql: "INSERT INTO chat (id, title, mode, created_at, updated_at) VALUES (?, ?, ?, 0, 0)", arguments: [id, id, mode])
        try db.execute(sql: "INSERT INTO message (id, chat_id, role, created_at) VALUES (?, ?, 'user', 0)", arguments: ["m-\(id)", id])
    }

    static func artifact(_ db: Database, _ id: String, chat: String, kind: String, title: String, blob: String, prompt: String?,
                         at t: Double, extra: String = "") throws {
        try db.execute(sql: "INSERT INTO artifact (id, chat_id, kind, title, created_at) VALUES (?, ?, ?, ?, ?)", arguments: [id, chat, kind, title, t])
        let spec = prompt.map { #"{"prompt":"\#($0)"\#(extra)}"# }
        try db.execute(sql: """
            INSERT INTO artifact_version (id, artifact_id, n, blob_id, spec_json, created_by_message_id, created_at) VALUES (?, ?, 1, ?, ?, ?, ?)
            """, arguments: ["\(id)-v1", id, blob, spec, "m-\(chat)", t])
    }

    static func attachment(_ db: Database, _ id: String, chat: String, name: String, uti: String, blob: String, at t: Double) throws {
        try db.execute(sql: "INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [id, "m-\(chat)", blob, name, uti, t])
    }

    /// Normal chat n1 (image, video, pdf, photo attachment) + Evil chat e1 (one image).
    static func seeded() throws -> Env {
        let e = try env()
        try e.db.write { db in
            try chat(db, "n1")
            try chat(db, "e1", mode: "evil")
            try blob(e, db, "b1", ext: "png")
            try blob(e, db, "b2", ext: "mp4")
            try blob(e, db, "b3", ext: "pdf")
            try blob(e, db, "b4", ext: "jpg")
            try blob(e, db, "b5", ext: "png")
            try artifact(db, "img", chat: "n1", kind: "image", title: "image.png", blob: "b1", prompt: "a lighthouse at dusk", at: 100)
            try artifact(db, "vid", chat: "n1", kind: "video", title: "video.mp4", blob: "b2", prompt: "waves rolling onto a beach",
                         at: 300, extra: #","frames":81,"fps":24,"sound":true"#)
            try artifact(db, "doc", chat: "n1", kind: "pdf", title: "Quarterly report.pdf", blob: "b3", prompt: nil, at: 200)
            try attachment(db, "att", chat: "n1", name: "holiday-photo.jpg", uti: "public.jpeg", blob: "b4", at: 400)
            try artifact(db, "evil", chat: "e1", kind: "image", title: "image.png", blob: "b5", prompt: "a dragon", at: 500)
        }
        return e
    }

    @Test func newestFirstAndFilters() throws {
        let e = try Self.seeded()
        let idx = LibraryIndex(e.db)
        #expect(try idx.items(showEvil: false).map(\.id) == ["att", "vid", "doc", "img"])
        #expect(try idx.items(filter: .images, showEvil: false).map(\.id) == ["att", "img"])
        #expect(try idx.items(filter: .videos, showEvil: false).map(\.id) == ["vid"])
        #expect(try idx.items(filter: .files, showEvil: false).map(\.id) == ["doc"])
        let vid = try #require(try idx.items(filter: .videos, showEvil: false).first)
        #expect(vid.kind == .video && vid.hasSound == true && abs((vid.duration ?? 0) - 81.0 / 24) < 0.001)
        #expect(vid.prompt == "waves rolling onto a beach" && vid.messageID == "m-n1" && vid.chatID == "n1")
        #expect(vid.path.hasSuffix("Media/2026/b2.mp4"), "the documented data folder layout")
    }

    @Test func everyPictureVersionIsListed() throws {
        let e = try Self.seeded()
        try e.db.write { db in
            try Self.blob(e, db, "b9", ext: "png")
            try db.execute(sql: """
                INSERT INTO artifact_version (id, artifact_id, n, blob_id, spec_json, created_at) VALUES ('img-v2', 'img', 2, 'b9', '{"prompt":"a lighthouse in fog"}', 600)
                """)
        }
        let items = try LibraryIndex(e.db).items(filter: .images, showEvil: false)
        // A picture's edit is a picture of its own: both versions are listed (the newest under the artifact's id, the
        // older one under its version id), and each is found by its own prompt.
        #expect(Set(items.map(\.id)) == ["img", "att", "img-v1"] && items[0].id == "img")
        #expect(items[0].source == .artifact(versionID: "img-v2") && items[0].path.hasSuffix("b9.png"))
        #expect(try LibraryIndex(e.db).items(query: "dusk", showEvil: false).map(\.id) == ["img-v1"])
        #expect(try LibraryIndex(e.db).items(query: "fog", showEvil: false).map(\.id) == ["img"])
        // Deleting the older picture leaves the newer one.
        let old = try #require(items.first { $0.id == "img-v1" })
        _ = try LibraryIndex(e.db).delete(old)
        #expect(try LibraryIndex(e.db).items(filter: .images, showEvil: false).map(\.id).sorted() == ["att", "img"])
    }

    @Test func searchesNamesAndPrompts() throws {
        let e = try Self.seeded()
        let idx = LibraryIndex(e.db)
        #expect(try idx.items(query: "lighthouse", showEvil: false).map(\.id) == ["img"])
        #expect(try idx.items(query: "wave beach", showEvil: false).map(\.id) == ["vid"], "every word, prefix match")
        #expect(try idx.items(query: "quarterly", showEvil: false).map(\.id) == ["doc"], "names")
        #expect(try idx.items(filter: .images, query: "holiday", showEvil: false).map(\.id) == ["att"])
        #expect(try idx.items(filter: .videos, query: "holiday", showEvil: false).isEmpty)
        #expect(try idx.items(query: "dragon", showEvil: false).isEmpty, "Evil stays hidden in search")
        #expect(try idx.items(query: "dragon", showEvil: true).map(\.id) == ["evil"])
        #expect(try idx.items(query: "\"; DROP", showEvil: true).isEmpty, "quotes are escaped")
        #expect(try idx.items(query: "  ", showEvil: false).count == 4, "blank = no search")
        // The triggers keep the index in step: rename, delete.
        try e.db.write { db in try db.execute(sql: "UPDATE artifact SET title = 'Annual summary.pdf' WHERE id = 'doc'") }
        #expect(try idx.items(query: "quarterly", showEvil: false).isEmpty)
        #expect(try idx.items(query: "annual", showEvil: false).map(\.id) == ["doc"])
        try e.db.write { db in try db.execute(sql: "DELETE FROM message WHERE id = 'm-n1'") }  // cascades the attachment
        #expect(try idx.items(query: "holiday", showEvil: false).isEmpty)
        let docs = try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM library_doc WHERE ref_id = 'att'") }
        #expect(docs == 0)
    }

    @Test func incognitoIsNeverListed() throws {
        let mem = try AppDatabase.inMemory()
        try mem.write { db in
            try Self.chat(db, "i1")
            try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES ('bx', 'x', 1, '/tmp/x.png', 0, 'generated')")
            try Self.artifact(db, "ia", chat: "i1", kind: "image", title: "image.png", blob: "bx", prompt: "secret", at: 1)
        }
        let idx = LibraryIndex(mem)
        #expect(try idx.items(showEvil: true).isEmpty)
        #expect(try idx.item(path: "/tmp/x.png") == nil)
        #expect(try idx.delete(LibraryEntry(id: "ia", source: .artifact(versionID: "ia-v1"), kind: .image, name: "image.png", path: "/tmp/x.png",
                                           blobID: "bx", size: 1, chatID: "i1", createdAt: Date(), contentType: .png)).isEmpty)
        // And the on-disk store holds nothing of it.
        let e = try Self.env()
        #expect(try LibraryIndex(e.db).items(showEvil: true).isEmpty)
    }

    @Test func evilHiddenUnlessShownAndTheDefaultRule() throws {
        let e = try Self.seeded()
        let idx = LibraryIndex(e.db)
        #expect(!(try idx.items(showEvil: false).contains { $0.isEvil }))
        let shown = try idx.items(showEvil: true)
        #expect(shown.first?.id == "evil" && shown.first?.isEvil == true && shown.filter(\.isEvil).count == 1)
        #expect(try idx.item(path: e.dir.appendingPathComponent("Media/2026/b5.png").path)?.isEvil == true)
        // Default: on exactly when Evil Mode is enabled; the user's choice wins either way.
        #expect(LibraryIndex.showsEvil(setting: nil, evilEnabled: true))
        #expect(!LibraryIndex.showsEvil(setting: nil, evilEnabled: false))
        #expect(!LibraryIndex.showsEvil(setting: false, evilEnabled: true))
        #expect(LibraryIndex.showsEvil(setting: true, evilEnabled: false))
    }

    @Test func deleteRemovesRowsAndFile() throws {
        let e = try Self.seeded()
        let idx = LibraryIndex(e.db)
        let vid = try #require(try idx.items(filter: .videos, showEvil: false).first)
        let poster = (vid.path as NSString).deletingPathExtension + ".poster.jpg"
        try Data("jpg".utf8).write(to: URL(fileURLWithPath: poster))
        #expect(try idx.delete(vid) == [vid.path])
        #expect(!FileManager.default.fileExists(atPath: vid.path) && !FileManager.default.fileExists(atPath: poster))
        let (art, blob, doc) = try e.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_version WHERE artifact_id = 'vid'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_blob WHERE id = 'b2'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_doc WHERE ref_id = 'vid-v1'"))
        }
        #expect(art == 0 && blob == 0 && doc == 0)
        #expect(try idx.items(showEvil: false).map(\.id) == ["att", "doc", "img"])
        let att = try #require(try idx.items(query: "holiday", showEvil: false).first)
        #expect(try idx.delete(att) == [att.path] && !FileManager.default.fileExists(atPath: att.path))
    }

    @Test func sharedBlobStaysUntilItsLastReference() throws {
        let e = try Self.seeded()
        // The same picture attached in another message (one blob, two references).
        try e.db.write { db in
            try Self.chat(db, "n2")
            try Self.attachment(db, "att2", chat: "n2", name: "lighthouse copy.png", uti: "public.png", blob: "b1", at: 700)
        }
        let idx = LibraryIndex(e.db)
        let img = try #require(try idx.items(query: "lighthouse", showEvil: false).first { $0.id == "img" })
        #expect(try idx.delete(img).isEmpty, "the attachment still uses the file")
        #expect(FileManager.default.fileExists(atPath: img.path))
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_blob WHERE id = 'b1'") } == 1)
        let copy = try #require(try idx.items(showEvil: false).first { $0.id == "att2" })
        #expect(try idx.delete(copy) == [img.path], "last reference: the file goes")
        #expect(!FileManager.default.fileExists(atPath: img.path))
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_blob WHERE id = 'b1'") } == 0)
    }

    @Test func v33UpgradesAndBackfills() throws {
        var config = Configuration()
        config.prepareDatabase { try VecLoader.load($0) }
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { try ChunkTables.ensureVectorTable($0) }
        try Migrations.migrator().migrate(queue, upTo: "v32_video_run_history")
        try queue.write { db in
            try Self.chat(db, "old")
            try db.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES ('bo', 'o', 1, '/x/o.png', 0, 'generated')")
            try Self.artifact(db, "oa", chat: "old", kind: "image", title: "image.png", blob: "bo", prompt: "an old harbour", at: 1)
            try Self.attachment(db, "ot", chat: "old", name: "scan.pdf", uti: "com.adobe.pdf", blob: "bo", at: 2)
            try db.execute(sql: "INSERT INTO artifact_version (id, artifact_id, n, blob_id, spec_json, created_at) VALUES ('oa-v2', 'oa', 2, 'bo', 'not json', 3)")
        }
        try Migrations.migrator().migrate(queue)
        let hits = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT d.ref_id FROM library_fts JOIN library_doc d ON d.id = library_fts.rowid WHERE library_fts MATCH 'harbour OR scan' ORDER BY d.ref_id")
        }
        #expect(hits == ["oa-v1", "ot"])
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM library_doc") } == 3, "a spec that is not JSON is indexed by name")
        #expect(Migrations.head == "v33_library_fts")
    }
}
