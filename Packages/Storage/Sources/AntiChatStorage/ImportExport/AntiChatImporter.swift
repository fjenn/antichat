// M8.T07 step 3 (R-093 AC2): re-import of an AntiChat export (format v1, FORMAT.md), wired into the M8.T06
// detection (`ChatImporter.detect` → `.antichat`). Rows come back verbatim with the same ids: blobs first (deduped by
// sha256; bytes extracted to `<media>/<yyyy>/<sha256>.<ext>`, or a row without a file when the export had no media,
// counted as missing), then projects, memory (topics matched by name, active items), then one transaction per chat.
// A chat whose id is already here is skipped (dedup through `import_record(source='antichat', external_key=<id>)`).
// Settings are only handed back (`ImportSummary.settingsJSON`): the caller asks before restoring them. A newer format
// version is refused (`ImportError.newerExport`). No network; message FTS is deferred like the M8.T06 import.
import CryptoKit
import Foundation
import GRDB
import ZIPFoundation

public final class AntiChatImporter: @unchecked Sendable {
    public let database: AppDatabase
    public let mediaRoot: URL

    public init(database: AppDatabase, mediaRoot: URL) {
        self.database = database
        self.mediaRoot = mediaRoot
    }

    public static func manifest(_ archive: Archive) throws -> AntiChatExportFormat.Manifest {
        guard let e = archive[AntiChatExportFormat.manifestPath] else { throw ImportError.unrecognizedFormat }
        let m = try AntiChatExportFormat.Manifest.decoder.decode(AntiChatExportFormat.Manifest.self, from: ChatImporter.read(archive, e))
        guard m.format == AntiChatExportFormat.formatID else { throw ImportError.unrecognizedFormat }
        guard m.version <= AntiChatExportFormat.version else { throw ImportError.newerExport }
        return m
    }

    public func run(_ url: URL, progress: (ImportProgress) -> Void = { _ in },
                    isCancelled: () -> Bool = { false }) throws -> ImportSummary {
        let archive = try Archive(url: url, accessMode: .read)
        _ = try Self.manifest(archive)
        var summary = ImportSummary()
        let columns = try database.read { db in
            var out: [String: Set<String>] = [:]
            for t in ["chat", "message", "message_part", "attachment", "feedback", "draft", "file_blob", "project",
                      "project_instruction", "project_file", "memory_topic", "memory_item"] {
                out[t] = Set(try db.columns(in: t).map(\.name))
            }
            return out
        }
        func object(_ path: String) throws -> Any? {
            guard let e = archive[path] else { return nil }
            return try JSONSerialization.jsonObject(with: ChatImporter.read(archive, e))
        }

        // Blobs: old id → id here.
        var blobID: [String: String] = [:]
        for item in (try object(AntiChatExportFormat.blobsPath) as? [[String: Any]]) ?? [] {
            guard let row = item["row"] as? [String: Any], let id = row["id"] as? String, let sha = row["sha256"] as? String else { continue }
            if let existing = try database.read({ try String.fetchOne($0, sql: "SELECT id FROM file_blob WHERE sha256 = ?", arguments: [sha]) }) {
                blobID[id] = existing
                continue
            }
            // Review fix (M8.T16): an export zip is shared content; its names never choose where a file lands.
            guard Self.isSHA256(sha) else { summary.missingMedia += 1; continue }
            var ext = ((row["path"] as? String ?? "") as NSString).pathExtension.lowercased()
            if ext.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) == nil { ext = "" }
            let created = (row["created_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            let year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: created))
            let dir = mediaRoot.appendingPathComponent("\(year)", isDirectory: true)
            let dest = dir.appendingPathComponent(ext.isEmpty ? sha : "\(sha).\(ext)")
            guard dest.standardizedFileURL.path.hasPrefix(mediaRoot.standardizedFileURL.path + "/") else { summary.missingMedia += 1; continue }
            if let entryPath = item["entry"] as? String, let entry = archive[entryPath] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    // Extract beside the destination, keep it only when the bytes hash to the recorded sha256.
                    let tmp = dir.appendingPathComponent(".import-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try ChatImporter.bounded(archive).extract(entry, to: tmp)
                    guard try Self.sha256(of: tmp) == sha else { summary.missingMedia += 1; continue }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                }
                summary.images += 1
            } else {
                summary.missingMedia += 1
            }
            let newID = try database.write { db -> String in
                let taken = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file_blob WHERE id = ?)", arguments: [id]) ?? false
                let use = taken ? StorageID.make() : id
                try AntiChatExportFormat.insert(row, into: "file_blob", columns: columns["file_blob"]!, db: db,
                                                override: ["id": use, "path": dest.path], orIgnore: false)
                return use
            }
            blobID[id] = newID
        }

        // Projects (same id; skipped when already here).
        let projectEntries = archive.filter { $0.type == .file && $0.path.hasPrefix("projects/") && $0.path.hasSuffix("/project.json") }
            .map(\.path).sorted()
        for path in projectEntries {
            guard let doc = try object(path) as? [String: Any], let project = doc["project"] as? [String: Any],
                  let pid = project["id"] as? String else { continue }
            let added = try database.write { db -> Bool in
                guard try AntiChatExportFormat.insert(project, into: "project", columns: columns["project"]!, db: db,
                                                      override: ["linked_folder_bookmark": nil]) else { return false }
                if let ins = doc["instruction"] as? [String: Any] {
                    try AntiChatExportFormat.insert(ins, into: "project_instruction", columns: columns["project_instruction"]!, db: db)
                }
                for f in doc["files"] as? [[String: Any]] ?? [] {
                    let blob = (f["blob_id"] as? String).flatMap { blobID[$0] }
                    // Review fix (M8.T16): the export carries no chunks or extracted text, so every file is indexed
                    // again here (copied: from its blob, after the import; linked: at the next rescan).
                    try AntiChatExportFormat.insert(f, into: "project_file", columns: columns["project_file"]!, db: db,
                                                    override: ["blob_id": blob, "index_state": "pending", "text_tokens": nil,
                                                               "progress": 0, "mtime": nil])
                }
                return true
            }
            if added { summary.projects += 1 }
            _ = pid
        }

        // Memory: topics (matched by id, else by scope + project + name), then active items with their chunk mirror.
        if let memory = try object(AntiChatExportFormat.memoryPath) as? [String: Any] {
            summary.memories = try database.write { db -> Int in
                var topicID: [String: String] = [:]
                for t in memory["topics"] as? [[String: Any]] ?? [] {
                    guard let id = t["id"] as? String, let name = t["name"] as? String else { continue }
                    let project = t["project_id"] as? String
                    if let project, try !(Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project WHERE id = ?)", arguments: [project]) ?? false) {
                        continue
                    }
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memory_topic WHERE id = ?)", arguments: [id]) == true {
                        topicID[id] = id
                    } else if let same = try String.fetchOne(db, sql: """
                        SELECT id FROM memory_topic WHERE scope = ? AND ifnull(project_id, '') = ifnull(?, '') AND name = ? COLLATE NOCASE
                        """, arguments: [t["scope"] as? String ?? "global", project, name]) {
                        topicID[id] = same
                    } else {
                        try AntiChatExportFormat.insert(t, into: "memory_topic", columns: columns["memory_topic"]!, db: db, orIgnore: false)
                        topicID[id] = id
                    }
                }
                var added = 0
                for item in memory["items"] as? [[String: Any]] ?? [] {
                    guard let id = item["id"] as? String, let topic = (item["topic_id"] as? String).flatMap({ topicID[$0] }) else { continue }
                    guard try AntiChatExportFormat.insert(item, into: "memory_item", columns: columns["memory_item"]!, db: db,
                                                          override: ["topic_id": topic]) else { continue }
                    let topicName = try String.fetchOne(db, sql: "SELECT name FROM memory_topic WHERE id = ?", arguments: [topic]) ?? ""
                    try db.execute(sql: """
                        INSERT INTO chunk (source, source_id, chat_id, ord, text, created_at) VALUES ('memory', ?, NULL, 0, ?, ?)
                        """, arguments: [id, "\(topicName): \(item["key"] as? String ?? ""): \(item["text"] as? String ?? "")",
                                         Date().timeIntervalSince1970])
                    added += 1
                }
                return added
            }
        }

        // Chats.
        let chatEntries = archive.filter { $0.type == .file && $0.path.hasPrefix("chats/") && $0.path.hasSuffix(".json") }
            .sorted { $0.path < $1.path }
        let total = chatEntries.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        var doneBytes: Int64 = 0
        if !database.isInMemory { try MessageSearchBacklog(database: database).begin() }
        defer { if !database.isInMemory { try? MessageSearchBacklog(database: database).end() } }
        for entry in chatEntries {
            if isCancelled() { summary.cancelled = true; break }
            try autoreleasepool {
                guard let doc = try JSONSerialization.jsonObject(with: ChatImporter.read(archive, entry)) as? [String: Any] else { return }
                try write(doc, columns: columns, blobID: blobID, summary: &summary)
            }
            doneBytes += Int64(entry.uncompressedSize)
            progress(ImportProgress(bytesDone: doneBytes, bytesTotal: total, chatsDone: summary.chats + summary.skipped))
        }

        if let e = archive[AntiChatExportFormat.settingsPath] { summary.settingsJSON = try ChatImporter.read(archive, e) }
        progress(ImportProgress(bytesDone: total, bytesTotal: total, chatsDone: summary.chats + summary.skipped))
        return summary
    }

    /// One chat in one transaction: the chat row (leaf set last), messages parents-first (`active_child_id` set after
    /// the rows exist: a pending deferred violation makes SQLite re-check every insert, M8.T06), parts, attachments,
    /// feedback, the draft and its `import_record`.
    private func write(_ doc: [String: Any], columns: [String: Set<String>], blobID: [String: String],
                       summary: inout ImportSummary) throws {
        guard let chat = doc["chat"] as? [String: Any], let id = chat["id"] as? String else { return }
        let messages = doc["messages"] as? [[String: Any]] ?? []
        let inserted = try database.write { db -> Bool in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat WHERE id = ?)", arguments: [id]) == true { return false }
            var project = chat["project_id"] as? String
            if let p = project, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project WHERE id = ?)", arguments: [p]) != true {
                project = nil
            }
            try AntiChatExportFormat.insert(chat, into: "chat", columns: columns["chat"]!, db: db,
                                            override: ["leaf_message_id": nil, "project_id": project], orIgnore: false)
            // RC review P2-3: every row lands in THIS chat only (a crafted file cannot add rows to a chat already here).
            let ownMessages = Set(messages.compactMap { $0["id"] as? String })
            func own(_ row: [String: Any]) -> Bool { (row["message_id"] as? String).map(ownMessages.contains) ?? false }
            for m in messages {
                try AntiChatExportFormat.insert(m, into: "message", columns: columns["message"]!, db: db,
                                                override: ["active_child_id": nil, "chat_id": id], orIgnore: false)
            }
            for p in doc["parts"] as? [[String: Any]] ?? [] where own(p) {
                try AntiChatExportFormat.insert(p, into: "message_part", columns: columns["message_part"]!, db: db, orIgnore: false)
            }
            for a in doc["attachments"] as? [[String: Any]] ?? [] where own(a) {
                guard let blob = (a["blob_id"] as? String).flatMap({ blobID[$0] }) else { continue }
                try AntiChatExportFormat.insert(a, into: "attachment", columns: columns["attachment"]!, db: db, override: ["blob_id": blob])
            }
            for f in doc["feedback"] as? [[String: Any]] ?? [] where own(f) {
                try AntiChatExportFormat.insert(f, into: "feedback", columns: columns["feedback"]!, db: db)
            }
            if let d = doc["draft"] as? [String: Any] {
                try AntiChatExportFormat.insert(d, into: "draft", columns: columns["draft"]!, db: db, override: ["chat_id": id])
            }
            for m in messages {
                if let child = m["active_child_id"] as? String, let mid = m["id"] as? String {
                    try db.execute(sql: "UPDATE message SET active_child_id = ? WHERE id = ?", arguments: [child, mid])
                }
            }
            if let leaf = chat["leaf_message_id"] as? String {
                try db.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?", arguments: [leaf, id])
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO import_record(id, source, external_key, chat_id, external_updated_at, file_sha256, imported_at)
                VALUES (?, 'antichat', ?, ?, ?, NULL, ?)
                """, arguments: [StorageID.make(), id, id, (chat["updated_at"] as? NSNumber)?.doubleValue, Date().timeIntervalSince1970])
            return true
        }
        if inserted {
            summary.chats += 1
            summary.messages += messages.count
            summary.chatIDs.append(id)
        } else {
            summary.skipped += 1
        }
    }
}


extension AntiChatImporter {
    static func isSHA256(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
