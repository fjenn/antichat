// M5.T13 (R-022, R-045 AC2, G-026; P-files-tools-08): the Library's one list of pictures, videos and files — every
// artifact (its newest version; a picture's every version, each edit being a picture of its own) and every sent attachment, from `artifact_version` + `file_blob` + `attachment` with
// the chat's mode, newest first. Filters All / Images / Videos / Files; search over names and prompts through
// `library_fts` (v32, FTS5 external content over `library_doc`, kept in step by triggers on artifact_version /
// artifact / attachment). Evil items carry `isEvil` and are left out unless "Show Evil items in Library" is on — its
// default follows the Evil enable state until the user sets it (settings-map §4). Incognito never reaches the
// Library: an in-memory database lists nothing (R-022 AC3). Delete removes the rows and the file on disk, unless the
// blob is still referenced elsewhere (then only this reference goes; the file stays until its last reference).
import Foundation
import GRDB
import UniformTypeIdentifiers

public struct LibraryEntry: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case image, video, file }
    public enum Source: Sendable, Equatable, Hashable {
        /// An artifact (newest version `versionID`).
        case artifact(versionID: String)
        case attachment
    }

    /// The artifact id or the attachment id.
    public var id: String
    public var source: Source
    public var kind: Kind
    public var name: String
    public var prompt: String?
    public var path: String
    public var blobID: String
    public var size: Int64
    public var chatID: String
    /// The source message: the producing turn (or, for a version saved without one, the chat's last message at that
    /// moment) or the message the file was attached to.
    public var messageID: String?
    public var isEvil: Bool
    public var createdAt: Date
    public var contentType: UTType
    /// Clip length in seconds (videos with a stored spec; nil = read it from the file).
    public var duration: Double?
    /// The clip has a sound track (videos with a stored spec; nil = read it from the file).
    public var hasSound: Bool?

    public init(id: String, source: Source, kind: Kind, name: String, prompt: String? = nil, path: String, blobID: String,
                size: Int64, chatID: String, messageID: String? = nil, isEvil: Bool = false, createdAt: Date,
                contentType: UTType, duration: Double? = nil, hasSound: Bool? = nil) {
        self.id = id; self.source = source; self.kind = kind; self.name = name; self.prompt = prompt; self.path = path
        self.blobID = blobID; self.size = size; self.chatID = chatID; self.messageID = messageID; self.isEvil = isEvil
        self.createdAt = createdAt; self.contentType = contentType; self.duration = duration; self.hasSound = hasSound
    }
}

public enum LibraryFilter: String, Sendable, CaseIterable {
    case all, images, videos, files

    public func admits(_ k: LibraryEntry.Kind) -> Bool {
        switch self {
        case .all: true
        case .images: k == .image
        case .videos: k == .video
        case .files: k == .file
        }
    }
}

public struct LibraryIndex: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// "Show Evil items in Library": the user's choice, else on exactly when Evil Mode is enabled (settings-map §4).
    public static func showsEvil(setting: Bool?, evilEnabled: Bool) -> Bool { setting ?? evilEnabled }

    /// The kind of a stored file: an artifact's own kind first, else its type.
    public static func kind(artifactKind: String?, type: UTType) -> LibraryEntry.Kind {
        switch artifactKind {
        case "image"?: return .image
        case "video"?: return .video
        case .some: return .file
        case nil: break
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }

    /// Items newest first. `query` searches names and prompts (prefix match per word, all words); `showEvil` false
    /// leaves Evil chats' items out. Incognito (in-memory) databases list nothing.
    public func items(filter: LibraryFilter = .all, query: String = "", showEvil: Bool, limit: Int = 5_000) throws -> [LibraryEntry] {
        guard !database.isInMemory else { return [] }
        let match = Self.ftsQuery(query)
        return try database.read { db in
            var hits: Set<String>?, versionHits = Set<String>()
            if let match {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.ref_kind, d.ref_id, v.artifact_id FROM library_fts f
                    JOIN library_doc d ON d.id = f.rowid
                    LEFT JOIN artifact_version v ON d.ref_kind = 'version' AND v.id = d.ref_id
                    WHERE library_fts MATCH ?
                    """, arguments: [match])
                hits = Set(rows.compactMap { r in (r["ref_kind"] as String) == "version" ? r["artifact_id"] : r["ref_id"] })
                versionHits = Set(rows.compactMap { r in (r["ref_kind"] as String) == "version" ? r["ref_id"] : nil })
            }
            var out: [LibraryEntry] = []
            for row in try Row.fetchAll(db, sql: Self.listSQL(showEvil: showEvil)) {
                guard let item = Self.item(row) else { continue }
                // A picture is found by its own name and prompt (each version is listed by itself); a document by any
                // of its versions (only its newest is listed).
                if let hits {
                    if item.kind == .image, case .artifact(let version) = item.source {
                        guard versionHits.contains(version) else { continue }
                    } else if !hits.contains(row["artifact_id"] ?? item.id) { continue }
                }
                guard filter.admits(item.kind) else { continue }
                out.append(item)
                if out.count >= limit { break }
            }
            return out
        }
    }

    /// The item whose stored file is `path` (FileCard "Show in Library"), Evil included.
    public func item(path: String) throws -> LibraryEntry? {
        guard !database.isInMemory else { return nil }
        return try database.read { db in
            try Row.fetchAll(db, sql: Self.listSQL(showEvil: true, path: true), arguments: [path, path]).lazy.compactMap(Self.item).first
        }
    }

    static func listSQL(showEvil: Bool, path: Bool = false) -> String {
        let evil = showEvil ? "" : "AND c.mode <> 'evil'"
        return """
            SELECT 'artifact' AS src,
                   CASE WHEN v.n = (SELECT MAX(n) FROM artifact_version x WHERE x.artifact_id = a.id) THEN a.id ELSE v.id END AS id,
                   a.id AS artifact_id, v.id AS version_id, a.kind AS artifact_kind, a.title AS name,
                   v.spec_json AS spec_json, b.id AS blob_id, b.path AS path, b.size AS size, a.chat_id AS chat_id,
                   c.mode AS mode,
                   COALESCE(v.created_by_message_id, (SELECT m2.id FROM message m2 WHERE m2.chat_id = a.chat_id
                     AND m2.created_at <= v.created_at ORDER BY m2.created_at DESC LIMIT 1)) AS message_id,
                   v.created_at AS created_at, NULL AS uti
            FROM artifact a
            JOIN artifact_version v ON v.artifact_id = a.id
              AND (a.kind = 'image' OR v.n = (SELECT MAX(n) FROM artifact_version x WHERE x.artifact_id = a.id))
            JOIN file_blob b ON b.id = v.blob_id
            JOIN chat c ON c.id = a.chat_id
            WHERE 1 \(evil) \(path ? "AND b.path = ?" : "")
            UNION ALL
            SELECT 'attachment', t.id, NULL, NULL, NULL, t.display_name, NULL, b.id, b.path, b.size, m.chat_id, c.mode, t.message_id,
                   t.created_at, t.uti
            FROM attachment t
            JOIN message m ON m.id = t.message_id
            JOIN chat c ON c.id = m.chat_id
            JOIN file_blob b ON b.id = t.blob_id
            WHERE 1 \(evil) \(path ? "AND b.path = ?" : "")
            ORDER BY created_at DESC, id DESC
            """
    }

    static func item(_ r: Row) -> LibraryEntry? {
        let name = StoredFileNames.name(title: r["name"], specJSON: r["spec_json"])
        let path: String = r["path"]
        let uti: String? = r["uti"]
        let ext = (name as NSString).pathExtension.isEmpty ? (path as NSString).pathExtension : (name as NSString).pathExtension
        let type = uti.flatMap(UTType.init) ?? UTType(filenameExtension: ext) ?? .data
        let artifactKind: String? = r["artifact_kind"]
        let kind = kind(artifactKind: artifactKind, type: type)
        var prompt: String?, duration: Double?, sound: Bool?
        if let s: String = r["spec_json"], let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
            prompt = o["prompt"] as? String
            if kind == .video, let f = (o["frames"] as? NSNumber)?.doubleValue, let fps = (o["fps"] as? NSNumber)?.doubleValue, fps > 0 {
                duration = f / fps
            }
            if kind == .video, let snd = o["sound"] as? Bool { sound = snd }
        }
        let src: String = r["src"]
        let source: LibraryEntry.Source
        if src == "artifact" {
            guard let v: String = r["version_id"] else { return nil }
            source = .artifact(versionID: v)
        } else {
            source = .attachment
        }
        return LibraryEntry(id: r["id"], source: source, kind: kind, name: name, prompt: prompt, path: path, blobID: r["blob_id"],
                           size: r["size"] ?? 0, chatID: r["chat_id"], messageID: r["message_id"],
                           isEvil: (r["mode"] as String?) == "evil",
                           createdAt: Date(timeIntervalSince1970: r["created_at"] ?? 0), contentType: type, duration: duration,
                           hasSound: sound)
    }

    /// "sunset beach" → `"sunset"* "beach"*` (every word, as a prefix); nil for an empty query.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    // MARK: Delete

    /// Removes the item: an artifact with all its versions, or one attachment. Each blob it used goes too — row and
    /// file (plus a clip's poster sidecar) — unless another artifact version, attachment, project file or recording
    /// still references it. Returns the files removed from disk.
    @discardableResult
    public func delete(_ item: LibraryEntry) throws -> [String] {
        guard !database.isInMemory else { return [] }
        let orphaned: [String] = try database.write { db in
            var blobs: [String]
            switch item.source {
            case .artifact(let versionID) where item.kind == .image:
                // A picture and each of its edits are listed one by one, and each is deleted by itself; the artifact
                // goes with its last picture.
                guard let artifact = try String.fetchOne(db, sql: "SELECT artifact_id FROM artifact_version WHERE id = ?", arguments: [versionID]) else {
                    blobs = []
                    break
                }
                blobs = try String.fetchAll(db, sql: "SELECT blob_id FROM artifact_version WHERE id = ?", arguments: [versionID])
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact_version WHERE artifact_id = ?", arguments: [artifact]) ?? 0 > 1 {
                    try db.execute(sql: "DELETE FROM artifact_version WHERE id = ?", arguments: [versionID])
                } else {
                    try db.execute(sql: "DELETE FROM artifact WHERE id = ?", arguments: [artifact])
                }
            case .artifact:
                blobs = try String.fetchAll(db, sql: "SELECT DISTINCT blob_id FROM artifact_version WHERE artifact_id = ?", arguments: [item.id])
                try db.execute(sql: "DELETE FROM artifact WHERE id = ?", arguments: [item.id])
            case .attachment:
                blobs = try String.fetchAll(db, sql: "SELECT blob_id FROM attachment WHERE id = ?", arguments: [item.id])
                try db.execute(sql: "DELETE FROM attachment WHERE id = ?", arguments: [item.id])
            }
            blobs = Array(Set(blobs))
            var paths: [String] = []
            for blob in blobs where try !Self.isReferenced(blob, db) {
                if let p = try String.fetchOne(db, sql: "SELECT path FROM file_blob WHERE id = ?", arguments: [blob]) { paths.append(p) }
                try db.execute(sql: "DELETE FROM file_blob WHERE id = ?", arguments: [blob])
            }
            return paths
        }
        var removed: [String] = []
        let fm = FileManager.default
        for p in orphaned {
            if (try? fm.removeItem(atPath: p)) != nil { removed.append(p) }
            try? fm.removeItem(atPath: (p as NSString).deletingPathExtension + ".poster.jpg")
        }
        return removed
    }

    /// True while any table that points at `file_blob` still uses `blob`. The single list every "may I drop this blob"
    /// check uses (RecordingStore, ProjectStore, the library), so a new referencing table is added in one place.
    public static func isReferenced(_ blob: String, _ db: Database) throws -> Bool {
        let refs = [("artifact_version", "blob_id"), ("attachment", "blob_id"), ("project_file", "blob_id"), ("recording", "file_blob_id")]
        for (table, column) in refs where try db.tableExists(table) {
            if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE \(column) = ?)", arguments: [blob]) == true { return true }
        }
        return false
    }
}
