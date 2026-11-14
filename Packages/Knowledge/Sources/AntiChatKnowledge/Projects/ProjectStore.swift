// Ported from osaurus-ai/osaurus@66c3dde:Models/Project/ProjectStore.swift + Managers/ProjectManager.swift (P-media-01;
// one GRDB store instead of JSON files plus a manager, A-M8-T04a). M8.T04 steps 2–8 (R-064): create / rename / icon,
// instructions (≤ 8,000 chars) frozen per chat at its first send, files with the limits checked before any copy
// (≤ 100 copied files and ≤ 2 GB in total; a linked folder has no limit), move a chat in or out, project-only memory
// (default global) and delete with keep-or-delete chats. Copied files' blobs are refcounted: a blob goes only when no
// attachment, artifact version or other project file still points at it.
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB

public enum ProjectError: Error, Equatable, Sendable {
    case notFound
    case invalidName
    /// `project.files.limit`: adding these would pass 100 files or 2 GB (nothing beyond the limit is copied).
    case filesLimit(accepted: Int)
}

public struct ProjectStore: Sendable {
    public static let maxFiles = 100
    public static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    public let database: AppDatabase
    public let now: @Sendable () -> Date

    /// Where the indexer keeps each file's extracted text (`<mediaRoot>/projects/<file id>.md`, ProjectFileIndexer).
    public var mediaRoot: URL = AttachmentIntake.defaultMediaRoot()

    /// Review fix (M8.T16): removing a file or a project also removes its extracted text.
    func removeTexts(_ fileIDs: [String]) {
        guard !database.isInMemory else { return }
        for id in fileIDs {
            try? FileManager.default.removeItem(at: mediaRoot.appendingPathComponent("projects", isDirectory: true).appendingPathComponent("\(id).md"))
        }
    }

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    // MARK: Projects

    @discardableResult
    public func create(name: String, icon: String = "folder") throws -> Project {
        let name = try Self.validName(name)
        let t = now()
        let p = Project(id: StorageID.make(now: t), name: name, icon: Project.icons.contains(icon) ? icon : "folder",
                        memoryMode: .global, createdAt: t, updatedAt: t)
        try database.write { db in
            try p.insert(db)
            try db.execute(sql: "INSERT INTO project_instruction (project_id, text, updated_at) VALUES (?, '', ?)",
                           arguments: [p.id, t.timeIntervalSince1970])
        }
        return p
    }

    static func validName(_ raw: String) throws -> String {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= Project.maxName else { throw ProjectError.invalidName }
        return n
    }

    public func project(_ id: String) throws -> Project? {
        try database.read { try Project.filter(Column("deleted_at") == nil).filter(key: id).fetchOne($0) }
    }

    /// Every project, most recently updated first, with its (unarchived) chat count.
    public func summaries() throws -> [ProjectSummary] {
        try database.read { try Self.summaries($0) }
    }

    public static func summaries(_ db: Database) throws -> [ProjectSummary] {
        try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, p.icon, p.updated_at,
                   (SELECT COUNT(*) FROM chat c WHERE c.project_id = p.id AND c.archived_at IS NULL) AS n
            FROM project p WHERE p.deleted_at IS NULL ORDER BY p.updated_at DESC, p.name
            """).map {
            ProjectSummary(id: $0["id"], name: $0["name"], icon: $0["icon"], chatCount: $0["n"],
                           updatedAt: Date(timeIntervalSince1970: $0["updated_at"]))
        }
    }

    public func rename(_ id: String, to name: String) throws {
        let name = try Self.validName(name)
        try touch(id) { $0.name = name }
    }

    public func setIcon(_ id: String, _ icon: String) throws {
        guard Project.icons.contains(icon) else { return }
        try touch(id) { $0.icon = icon }
    }

    /// Step 7: `project` = chats here read and write only this project's memory; `global` (default) = global memory.
    public func setMemoryMode(_ id: String, _ mode: ProjectMemoryMode) throws {
        try touch(id) { $0.memoryMode = mode }
    }

    private func touch(_ id: String, _ change: (inout Project) -> Void) throws {
        try database.write { db in
            guard var p = try Project.fetchOne(db, key: id) else { throw ProjectError.notFound }
            change(&p)
            p.updatedAt = now()
            try p.update(db)
        }
    }

    // MARK: Instructions (step 4)

    public func instructions(_ id: String) throws -> String {
        try database.read { try String.fetchOne($0, sql: "SELECT text FROM project_instruction WHERE project_id = ?", arguments: [id]) } ?? ""
    }

    public func setInstructions(_ id: String, _ text: String) throws {
        let t = String(text.prefix(Project.maxInstructions))
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO project_instruction (project_id, text, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(project_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
                """, arguments: [id, t, now().timeIntervalSince1970])
        }
    }

    /// The instructions a chat's prompt carries: captured at its first send (the chat's project's text then, "" for a
    /// chat outside a project) and never changed afterwards — editing applies to new chats, moving a chat keeps it.
    public func frozenInstructions(chatID: String) throws -> String {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT project_id, project_instruction_text FROM chat WHERE id = ?",
                                             arguments: [chatID]) else { return "" }
            if let frozen: String = row["project_instruction_text"] { return frozen }
            var text = ""
            if let pid: String = row["project_id"] {
                text = try String.fetchOne(db, sql: """
                    SELECT i.text FROM project_instruction i JOIN project p ON p.id = i.project_id
                    WHERE i.project_id = ? AND p.deleted_at IS NULL
                    """, arguments: [pid]) ?? ""
            }
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: "UPDATE chat SET project_instruction_text = ?, project_instruction_hash = ? WHERE id = ?",
                           arguments: [text, hash, chatID])
            return text
        }
    }

    /// The chat's project and its memory mode (nil outside a project).
    public func memoryScope(chatID: String) throws -> (projectID: String, mode: ProjectMemoryMode)? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.id, p.memory_mode FROM chat c JOIN project p ON p.id = c.project_id
                WHERE c.id = ? AND p.deleted_at IS NULL
                """, arguments: [chatID]) else { return nil }
            return (row["id"], ProjectMemoryMode(rawValue: row["memory_mode"]) ?? .global)
        }
    }

    // MARK: Chats (step 6)

    public func chatIDs(_ projectID: String) throws -> [String] {
        try database.read {
            try String.fetchAll($0, sql: "SELECT id FROM chat WHERE project_id = ? AND archived_at IS NULL ORDER BY updated_at DESC",
                                arguments: [projectID])
        }
    }

    /// Moves a chat into a project (nil = back to Recents). Its frozen prefix is untouched.
    public func move(chatID: String, to projectID: String?) throws {
        try database.write { db in
            if let projectID, try Project.fetchOne(db, key: projectID) == nil { throw ProjectError.notFound }
            try db.execute(sql: "UPDATE chat SET project_id = ? WHERE id = ?", arguments: [projectID, chatID])
            if let projectID {
                try db.execute(sql: "UPDATE project SET updated_at = ? WHERE id = ?", arguments: [now().timeIntervalSince1970, projectID])
            }
        }
    }

    // MARK: Files (step 5)

    public func files(_ projectID: String) throws -> [ProjectFile] {
        try database.read {
            try ProjectFile.filter(Column("project_id") == projectID).order(Column("origin"), Column("display_name")).fetchAll($0)
        }
    }

    /// How many of `sizes` (in order) fit beside the project's copied files: ≤ 100 files and ≤ 2 GB in total.
    public func admit(_ projectID: String, sizes: [Int64]) throws -> Int {
        try database.read { db in try Self.admit(db, projectID, sizes: sizes) }
    }

    /// The same check inside a caller's transaction (the indexer admits and inserts in one write: two quick drops
    /// can no longer both pass the limit; review fix).
    static func admit(_ db: Database, _ projectID: String, sizes: [Int64]) throws -> Int {
        let r = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM project_file WHERE project_id = ? AND origin = 'copied'
            """, arguments: [projectID])
        let count: Int = r?["n"] ?? 0, bytes: Int64 = r?["b"] ?? 0
        var n = count, b = bytes, accepted = 0
        for s in sizes {
            guard n + 1 <= Self.maxFiles, b + s <= Self.maxBytes else { break }
            n += 1
            b += s
            accepted += 1
        }
        return accepted
    }

    /// Removes a file: its chunks, its row and (copied) its blob when nothing else references it.
    public func removeFile(_ id: String) throws {
        let orphan = try database.write { db -> FileBlobRecord? in
            guard let f = try ProjectFile.fetchOne(db, key: id) else { return nil }
            try Self.deleteChunks(db, fileIDs: [f.id])
            try f.delete(db)
            return try f.blobID.flatMap { try Self.deleteBlobIfUnreferenced(db, blobID: $0) }
        }
        if let orphan { Self.removeBlobFiles([orphan]) }
        removeTexts([id])
    }

    static func deleteChunks(_ db: Database, fileIDs: [String]) throws {
        guard !fileIDs.isEmpty else { return }
        let marks = fileIDs.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments([ProjectFile.chunkSource] + fileIDs)
        if try db.tableExists("chunk_vec") {
            try db.execute(sql: "DELETE FROM chunk_vec WHERE rowid IN (SELECT id FROM chunk WHERE source = ? AND source_id IN (\(marks)))",
                           arguments: args)
        }
        try db.execute(sql: "DELETE FROM chunk WHERE source = ? AND source_id IN (\(marks))", arguments: args)
    }

    /// Deletes the blob row when nothing points at it (`LibraryIndex.isReferenced`: attachment, artifact version,
    /// project file, recording); returns it for the file removal after the transaction.
    static func deleteBlobIfUnreferenced(_ db: Database, blobID: String) throws -> FileBlobRecord? {
        guard try !LibraryIndex.isReferenced(blobID, db), let blob = try FileBlobRecord.fetchOne(db, key: blobID) else { return nil }
        try blob.delete(db)
        return blob
    }

    static func removeBlobFiles(_ blobs: [FileBlobRecord]) {
        for b in blobs {
            let url = URL(fileURLWithPath: b.path)
            try? FileManager.default.removeItem(at: url)
            let extracted = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("extracted", isDirectory: true).appendingPathComponent("\(b.sha256).md")
            try? FileManager.default.removeItem(at: extracted)
        }
    }

    // MARK: Delete (step 8)

    /// Deletes the project. `keepChats` moves its chats to Recents (`project_id = NULL`), else they are deleted with
    /// their messages (and FTS rows, by trigger). Copied files go with their blobs unless referenced elsewhere;
    /// project-scope memory goes by cascade (memory_topic → memory_item → memory_event).
    public func delete(_ id: String, keepChats: Bool) throws {
        let orphans = try database.write { db -> ([FileBlobRecord], [String]) in
            guard try Project.fetchOne(db, key: id) != nil else { throw ProjectError.notFound }
            if keepChats {
                try db.execute(sql: "UPDATE chat SET project_id = NULL WHERE project_id = ?", arguments: [id])
            } else {
                try db.execute(sql: "DELETE FROM chat WHERE project_id = ?", arguments: [id])
            }
            let files = try ProjectFile.filter(Column("project_id") == id).fetchAll(db)
            try Self.deleteChunks(db, fileIDs: files.map(\.id))
            try db.execute(sql: "DELETE FROM chunk WHERE source = 'memory' AND source_id IN (SELECT id FROM memory_item WHERE project_id = ?)",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [id])
            let blobs = try Set(files.compactMap(\.blobID)).compactMap { try Self.deleteBlobIfUnreferenced(db, blobID: $0) }
            return (blobs, files.map(\.id))
        }
        Self.removeBlobFiles(orphans.0)
        removeTexts(orphans.1)
    }
}
