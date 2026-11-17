// M6.T13 steps 5 and 7 (R-016 AC5, R-017 AC2): every file of a chat — attached (attachment rows of its messages,
// file_blob.origin upload) and produced (artifact + its latest version's blob, origin generated) — with name, kind,
// size and date, newest first. The Outputs list shows the produced ones, "Files in this chat" both.
import Foundation
import GRDB

public struct ChatFile: Sendable, Equatable, Identifiable {
    public enum Origin: String, Sendable { case attached, produced }
    /// attachment id, or artifact id for a produced file.
    public var id: String
    public var origin: Origin
    public var name: String
    /// Artifact kind (pdf, docx, xlsx, csv, pptx, chart, md …) or the attachment's UTI.
    public var kind: String
    public var size: Int64
    public var date: Date
    public var path: String
    /// Latest version number (produced files).
    public var version: Int?

    public init(id: String, origin: Origin, name: String, kind: String, size: Int64, date: Date, path: String, version: Int?) {
        self.id = id; self.origin = origin; self.name = name; self.kind = kind; self.size = size; self.date = date
        self.path = path; self.version = version
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

public struct ChatFilesQuery: Sendable {
    let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    public func files(chatID: String) throws -> [ChatFile] {
        try database.reader.read { db in
            var out: [ChatFile] = []
            let attached = try Row.fetchAll(db, sql: """
                SELECT a.id, a.display_name, a.uti, b.size, a.created_at, b.path
                FROM attachment a JOIN file_blob b ON b.id = a.blob_id JOIN message m ON m.id = a.message_id
                WHERE m.chat_id = ?
                """, arguments: [chatID])
            for r in attached {
                out.append(ChatFile(id: r["id"], origin: .attached, name: r["display_name"], kind: r["uti"], size: r["size"],
                                    date: r["created_at"] as Date, path: r["path"], version: nil))
            }
            // A picture's edits are versions of one artifact, and each one is a picture the chat made: all are listed
            // (a document's revisions are one file: its latest version).
            let produced = try Row.fetchAll(db, sql: """
                SELECT a.id, a.kind, a.title, v.n, v.created_at, v.spec_json, b.size, b.path,
                       (SELECT max(n) FROM artifact_version WHERE artifact_id = a.id) AS newest
                FROM artifact a
                JOIN artifact_version v ON v.artifact_id = a.id
                JOIN file_blob b ON b.id = v.blob_id
                WHERE a.chat_id = ?
                """, arguments: [chatID])
            for r in produced {
                let created: Date = r["created_at"]
                let n: Int = r["n"], newest: Int = r["newest"], kind: String = r["kind"], id: String = r["id"]
                guard n == newest || kind == "image" else { continue }
                out.append(ChatFile(id: n == newest ? id : "\(id)#\(n)", origin: .produced,
                                    name: StoredFileNames.name(title: r["title"], specJSON: r["spec_json"]), kind: kind,
                                    size: r["size"], date: created, path: r["path"], version: n))
            }
            return out.sorted { ($0.date, $0.name) > ($1.date, $1.name) }
        }
    }
}
