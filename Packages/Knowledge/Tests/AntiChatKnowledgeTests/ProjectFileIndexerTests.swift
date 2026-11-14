// M8.T04 AT-064 unit leg (R-064 AC2): copied files (media store, file_blob dedup, chunks with page_ref, real
// progress 1.0, text tokens) and a linked folder (no copy; skips hidden files and `.git`; an edit re-indexes by mtime +
// size; a deletion removes the chunks), the FSEvents watcher firing a rescan within 5 s, and the limit (files beyond
// 100 are not copied). No network: AntiChatKnowledge does not link AntiChatNetwork, so indexing cannot open a
// connection (the NetworkGate counter of the app stays 0 by construction).
//   make test-unit FILTER=ProjectFileIndexerTests
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatKnowledge

@Suite(.serialized) struct ProjectFileIndexerTests {
    struct Rig {
        let dir: URL
        let db: AppDatabase
        let indexer: ProjectFileIndexer
        let project: Project
    }

    func rig() throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pfi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let p = try ProjectStore(database: db).create(name: "Small")
        return Rig(dir: dir, db: db, indexer: ProjectFileIndexer(database: db, mediaRoot: dir.appendingPathComponent("Media"), embedder: nil), project: p)
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func chunks(_ db: AppDatabase, _ fileID: String) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT text FROM chunk WHERE source = 'project_file' AND source_id = ? ORDER BY ord", arguments: [fileID]) }
    }

    @Test func copiedFilesAreStoredDedupedAndChunked() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let a = r.dir.appendingPathComponent("src/notes.md"), b = r.dir.appendingPathComponent("src/copy-of-notes.md")
        try write("# Notes\n\nThe kiln fires at 1240 degrees.", a)
        try write("# Notes\n\nThe kiln fires at 1240 degrees.", b)
        let res = try await r.indexer.add([a, b], to: r.project.id)
        #expect(res.added.count == 2 && res.rejected == 0)
        let files = try ProjectStore(database: r.db).files(r.project.id)
        #expect(files.allSatisfy { $0.indexState == .ready && $0.progress == 1 && ($0.textTokens ?? 0) > 0 && $0.origin == .copied })
        #expect(Set(files.compactMap(\.blobID)).count == 1)  // same bytes → one blob
        #expect(try chunks(r.db, files[0].id).joined().contains("1240 degrees"))
        #expect(r.indexer.text(fileID: files[0].id)?.contains("kiln") == true)
        try ProjectStore(database: r.db).removeFile(files[0].id)
        #expect(try chunks(r.db, files[0].id).isEmpty)
        #expect(try r.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_blob") } == 1)  // still used by the other
    }

    @Test func linkedFolderIndexesInPlaceAndFollowsChanges() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let folder = r.dir.appendingPathComponent("linked")
        try write("Alpha report: revenue grew 12 percent.", folder.appendingPathComponent("a.md"))
        try write("Beta: the launch is in March.", folder.appendingPathComponent("sub/b.txt"))
        try write("hidden", folder.appendingPathComponent(".secret.md"))
        try write("git internals", folder.appendingPathComponent(".git/HEAD.md"))
        try write("dependency", folder.appendingPathComponent("node_modules/x/readme.md"))
        let first = try await r.indexer.link(folder, to: r.project.id)
        #expect(first.indexed == 2 && !first.capped && !first.missing)
        var files = try ProjectStore(database: r.db).files(r.project.id)
        #expect(Set(files.compactMap(\.relPath)) == ["a.md", "sub/b.txt"] && files.allSatisfy { $0.origin == .linked && $0.blobID == nil })
        #expect(!FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("Media/\(Calendar.current.component(.year, from: Date()))").path))
        let unchanged = try await r.indexer.rescan(r.project.id)
        #expect(unchanged.unchanged == 2 && unchanged.indexed == 0)
        try write("Alpha report: revenue grew 15 percent after the audit.", folder.appendingPathComponent("a.md"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: folder.appendingPathComponent("a.md").path)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("sub/b.txt"))
        let second = try await r.indexer.rescan(r.project.id)
        #expect(second.indexed == 1 && second.removed == 1)
        files = try ProjectStore(database: r.db).files(r.project.id)
        let text = try chunks(r.db, files[0].id).joined()
        #expect(files.count == 1 && text.contains("15 percent"))
        try FileManager.default.removeItem(at: folder)
        let missing = try await r.indexer.rescan(r.project.id)
        #expect(missing.missing)
        #expect(try ProjectStore(database: r.db).files(r.project.id).count == 1)  // the last index stays
    }

    @Test func watcherRescansWithinFiveSeconds() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let folder = r.dir.appendingPathComponent("watched")
        try write("one", folder.appendingPathComponent("one.md"))
        try await r.indexer.link(folder, to: r.project.id)
        let indexer = r.indexer, pid = r.project.id
        let fired = Mutex(0)
        let watcher = LinkedFolderWatcher(folder: folder, latency: 0.5) {
            _ = try? await indexer.rescan(pid)
            fired.withLock { $0 += 1 }
        }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))  // the stream starts after its first latency window
        let start = ContinuousClock.now
        try write("two: the second document", folder.appendingPathComponent("two.md"))
        var names: Set<String> = []
        while ContinuousClock.now - start < .seconds(5) {
            names = Set(try ProjectStore(database: r.db).files(pid).filter { $0.indexState == .ready }.compactMap(\.relPath))
            if names.contains("two.md") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(names.contains("two.md"), "FSEvents change not re-indexed within 5 s")
    }

    @Test func filesBeyondTheLimitAreNotCopied() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        try r.db.write { db in
            for i in 0..<99 {
                try ProjectFile(id: "x\(i)", projectID: r.project.id, displayName: "x\(i).md", size: 1, origin: .copied,
                                indexState: .ready, progress: 1, createdAt: Date()).insert(db)
            }
        }
        let a = r.dir.appendingPathComponent("src/100.md"), b = r.dir.appendingPathComponent("src/101.md")
        try write("hundredth", a)
        try write("one too many", b)
        let res = try await r.indexer.add([a, b], to: r.project.id)
        #expect(res.added.count == 1 && res.rejected == 1)
        #expect(try ProjectStore(database: r.db).files(r.project.id).count == 100)
    }
}
