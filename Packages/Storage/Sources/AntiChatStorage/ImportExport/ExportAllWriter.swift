// M8.T07 steps 1–2 (R-093 AC1; P-platform-10): Export all data → one zip (format v1, FORMAT.md). Streams entry by
// entry with ZIPFoundation (one chat's JSON in memory at a time; media read from disk in chunks), reports bytes
// written against an estimate and stops between entries on Cancel (the partial file is deleted). Never exported:
// models, caches, logs, incognito (never on disk), network_activity, local_counter, import_record, memory
// suggestions and events, bookmarks (BLOB columns), Keychain items (settings come from the caller, already filtered).
import Foundation
import GRDB
import ZIPFoundation

public struct ExportOptions: Sendable {
    public var includeMedia: Bool
    /// `settings/defaults.json` (the caller filters secrets and bookmarks out); nil = not exported.
    public var settingsJSON: Data?
    public var appVersion: String
    public init(includeMedia: Bool = true, settingsJSON: Data? = nil, appVersion: String = "dev") {
        self.includeMedia = includeMedia; self.settingsJSON = settingsJSON; self.appVersion = appVersion
    }
}

public struct ExportProgress: Sendable, Equatable {
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public init(bytesDone: Int64, bytesTotal: Int64) { self.bytesDone = bytesDone; self.bytesTotal = bytesTotal }
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

public struct ExportResult: Sendable, Equatable {
    public var url: URL
    public var counts: AntiChatExportFormat.Counts
    /// Blobs whose file was not on disk (the row is exported, the bytes are not).
    public var missingMedia: Int
    public var cancelled: Bool
}

public struct ExportEstimate: Sendable, Equatable {
    public var mediaBytes: Int64
    public var dataBytes: Int64
}

public final class ExportAllWriter: @unchecked Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    /// The media size for the options sheet ("Include pictures, videos and files ({size})") and the progress total.
    public func estimate() throws -> ExportEstimate {
        try database.read { db in
            let media = try Int64.fetchOne(db, sql: """
                SELECT ifnull(sum(size), 0) FROM file_blob WHERE id IN (SELECT blob_id FROM attachment)
                  OR id IN (SELECT blob_id FROM project_file WHERE blob_id IS NOT NULL)
                """) ?? 0
            let text = try Int64.fetchOne(db, sql: "SELECT ifnull(sum(length(body)), 0) FROM message_part") ?? 0
            let rows = try Int64.fetchOne(db, sql: "SELECT (SELECT count(*) FROM message) + (SELECT count(*) FROM message_part)") ?? 0
            // JSON + Markdown copy of the text, ~300 bytes of columns per row.
            return ExportEstimate(mediaBytes: media, dataBytes: text * 2 + rows * 300)
        }
    }

    public func write(to url: URL, options: ExportOptions, progress: (ExportProgress) -> Void = { _ in },
                      isCancelled: () -> Bool = { false }) throws -> ExportResult {
        let fm = FileManager.default
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? fm.removeItem(at: partial)
        var done = false
        defer { if !done { try? fm.removeItem(at: partial) } }
        let archive = try Archive(url: partial, accessMode: .create)

        let est = try estimate()
        let total = est.dataBytes + (options.includeMedia ? est.mediaBytes : 0)
        var written: Int64 = 0
        var counts = AntiChatExportFormat.Counts()
        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.05 {
                lastReport = now
                progress(ExportProgress(bytesDone: written, bytesTotal: max(total, written)))
            }
        }
        func add(_ path: String, _ data: Data, compress: Bool = true) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: compress ? .deflate : .none) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
            written += Int64(data.count)
            report()
        }
        func cancelled() -> ExportResult? {
            guard isCancelled() else { return nil }
            return ExportResult(url: url, counts: counts, missingMedia: 0, cancelled: true)
        }

        // Projects (before chats in the importer; any order in the zip).
        let projectIDs = try database.read { try String.fetchAll($0, sql: "SELECT id FROM project ORDER BY created_at, id") }
        var projectFileEntry: [String: String] = [:]  // blob id → projects/<id>/files/<name>
        for pid in projectIDs {
            if let c = cancelled() { return c }
            let (project, instruction, files) = try database.read { db in
                (try AntiChatExportFormat.rows(db, "SELECT * FROM project WHERE id = ?", [pid]).first ?? [:],
                 try AntiChatExportFormat.rows(db, "SELECT * FROM project_instruction WHERE project_id = ?", [pid]).first,
                 try AntiChatExportFormat.rows(db, "SELECT * FROM project_file WHERE project_id = ? ORDER BY created_at, id", [pid]))
            }
            var used = Set<String>()
            for f in files where (f["origin"] as? String) == "copied" {
                guard let blob = f["blob_id"] as? String, projectFileEntry[blob] == nil else { continue }
                let base = ((f["display_name"] as? String) ?? "file").replacingOccurrences(of: "/", with: "-")
                var name = base, n = 1
                while used.contains(name.lowercased()) {  // review fix: a counter (UUIDv7 prefixes collide)
                    n += 1
                    name = "\(n)-\(base)"
                }
                used.insert(name.lowercased())
                projectFileEntry[blob] = "projects/\(pid)/files/\(name)"
            }
            var doc: [String: Any] = ["project": project, "files": files]
            doc["instruction"] = instruction ?? NSNull()
            try add(AntiChatExportFormat.projectPath(pid), AntiChatExportFormat.json(doc))
            if let text = instruction?["text"] as? String, !text.isEmpty {
                try add("projects/\(pid)/instructions.md", Data(text.utf8))
            }
            counts.projects += 1
        }

        // The media entries the zip will hold (sha256 → path), so the Markdown links only to files that are there.
        var mediaEntries: [String: String] = [:]
        if options.includeMedia {
            let planned = try database.read { db in
                try AntiChatExportFormat.rows(db, """
                    SELECT * FROM file_blob WHERE id IN (SELECT blob_id FROM attachment)
                      OR id IN (SELECT blob_id FROM project_file WHERE blob_id IS NOT NULL) ORDER BY created_at, id
                    """)
            }
            for b in planned {
                guard let id = b["id"] as? String, let path = b["path"] as? String, let sha = b["sha256"] as? String,
                      fm.fileExists(atPath: path), mediaEntries[sha] == nil else { continue }
                mediaEntries[sha] = projectFileEntry[id]
                    ?? AntiChatExportFormat.mediaPath(sha256: sha, ext: URL(fileURLWithPath: path).pathExtension.lowercased())
            }
        }

        // Chats: the full tree as rows (chats/) + the active path as Markdown (chats-md/).
        let chatIDs = try database.read { try String.fetchAll($0, sql: "SELECT id FROM chat ORDER BY created_at, id") }
        for id in chatIDs {
            if let c = cancelled() { return c }
            let (doc, messages, markdown, title) = try database.read { db -> ([String: Any], Int, String, String) in
                let chat = try AntiChatExportFormat.rows(db, "SELECT * FROM chat WHERE id = ?", [id]).first ?? [:]
                let messages = Self.preorder(try AntiChatExportFormat.rows(db, "SELECT * FROM message WHERE chat_id = ? ORDER BY position, created_at, id", [id]))
                let parts = try AntiChatExportFormat.rows(db, """
                    SELECT p.* FROM message_part p JOIN message m ON m.id = p.message_id WHERE m.chat_id = ? ORDER BY p.message_id, p.idx
                    """, [id]).map { var r = $0; r.removeValue(forKey: "id"); return r }
                let attachments = try AntiChatExportFormat.rows(db, """
                    SELECT a.* FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.chat_id = ? ORDER BY a.created_at, a.id
                    """, [id])
                let feedback = try AntiChatExportFormat.rows(db, """
                    SELECT f.* FROM feedback f JOIN message m ON m.id = f.message_id WHERE m.chat_id = ? ORDER BY f.message_id, f.kind
                    """, [id])
                let draft = try AntiChatExportFormat.rows(db, "SELECT * FROM draft WHERE chat_id = ?", [id]).first
                var doc: [String: Any] = ["chat": chat, "messages": messages, "parts": parts, "attachments": attachments, "feedback": feedback]
                doc["draft"] = draft ?? NSNull()
                let md = ChatMarkdownRenderer.render(try ChatDocument.load(id, db: db), pictures: .exportEntries(mediaEntries))
                return (doc, messages.count, md, chat["title"] as? String ?? "")
            }
            try add(AntiChatExportFormat.chatPath(id), AntiChatExportFormat.json(doc))
            try add("chats-md/\(AntiChatExportFormat.slug(title))-\(id).md", Data(markdown.utf8))  // the full id: unique
            counts.chats += 1
            counts.messages += messages
        }

        // Memory: topics + active items (no suggestions, no events) + one readable file per topic.
        let (topics, items) = try database.read { db in
            (try AntiChatExportFormat.rows(db, "SELECT * FROM memory_topic ORDER BY created_at, id"),
             try AntiChatExportFormat.rows(db, "SELECT * FROM memory_item WHERE state = 'active' ORDER BY created_at, id"))
        }
        try add(AntiChatExportFormat.memoryPath, AntiChatExportFormat.json(["topics": topics, "items": items]))
        var usedSlugs = Set<String>()
        for t in topics {
            let tid = t["id"] as? String ?? ""
            let mine = items.filter { $0["topic_id"] as? String == tid }
            guard !mine.isEmpty else { continue }
            let name = t["name"] as? String ?? "memory"
            let base = AntiChatExportFormat.slug(name)
            var slug = base, n = 1
            while usedSlugs.contains(slug) {
                n += 1
                slug = "\(base)-\(n)"
            }
            usedSlugs.insert(slug)
            let md = "# \(name)\n\n" + mine.map { "- \($0["text"] as? String ?? "")\n" }.joined()
            try add("memory/\(slug).md", Data(md.utf8))
        }
        counts.memories = items.count

        if let settings = options.settingsJSON { try add(AntiChatExportFormat.settingsPath, settings) }

        // Media: every blob an attachment or a copied project file points at.
        let blobs = try database.read { db in
            try AntiChatExportFormat.rows(db, """
                SELECT * FROM file_blob WHERE id IN (SELECT blob_id FROM attachment)
                  OR id IN (SELECT blob_id FROM project_file WHERE blob_id IS NOT NULL) ORDER BY created_at, id
                """)
        }
        var blobEntries: [[String: Any]] = []
        var missing = 0
        for b in blobs {
            if let c = cancelled() { return c }
            let id = b["id"] as? String ?? ""
            var entry: Any = NSNull()
            if options.includeMedia, let path = b["path"] as? String, let sha = b["sha256"] as? String {
                let file = URL(fileURLWithPath: path)
                if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, let fh = try? FileHandle(forReadingFrom: file) {
                    let name = projectFileEntry[id] ?? AntiChatExportFormat.mediaPath(sha256: sha, ext: file.pathExtension.lowercased())
                    defer { try? fh.close() }
                    try archive.addEntry(with: name, type: .file, uncompressedSize: size.int64Value, compressionMethod: .none) { pos, chunk in
                        try fh.seek(toOffset: UInt64(pos))
                        return try fh.read(upToCount: chunk) ?? Data()
                    }
                    written += size.int64Value
                    report()
                    entry = name
                    counts.media += 1
                } else {
                    missing += 1
                }
            }
            blobEntries.append(["row": b, "entry": entry])
        }
        try add(AntiChatExportFormat.blobsPath, AntiChatExportFormat.json(blobEntries))

        let schema = try database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").sorted { a, b in
                (Migrations.identifiers.firstIndex(of: a) ?? Int.max) < (Migrations.identifiers.firstIndex(of: b) ?? Int.max)
            }.last ?? ""
        }
        let manifest = AntiChatExportFormat.Manifest(appVersion: options.appVersion, schemaVersion: schema, createdAt: Date(),
                                                     counts: counts, includesMedia: options.includeMedia,
                                                     includesSettings: options.settingsJSON != nil)
        try add(AntiChatExportFormat.manifestPath, AntiChatExportFormat.Manifest.encoder.encode(manifest))
        if let c = cancelled() { return c }

        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: partial, to: url)
        done = true
        written = max(written, total)
        report(force: true)
        return ExportResult(url: url, counts: counts, missingMedia: missing, cancelled: false)
    }

    /// Parents before children (the importer inserts in this order; `parent_id` is an immediate foreign key).
    static func preorder(_ rows: [[String: Any]]) -> [[String: Any]] {
        var children: [String: [[String: Any]]] = [:]
        var roots: [[String: Any]] = []
        let ids = Set(rows.compactMap { $0["id"] as? String })
        for r in rows {
            if let p = r["parent_id"] as? String, ids.contains(p) { children[p, default: []].append(r) } else { roots.append(r) }
        }
        var out: [[String: Any]] = []
        out.reserveCapacity(rows.count)
        var stack = Array(roots.reversed())
        while let r = stack.popLast() {
            out.append(r)
            if let id = r["id"] as? String { stack.append(contentsOf: (children[id] ?? []).reversed()) }
        }
        return out
    }
}
