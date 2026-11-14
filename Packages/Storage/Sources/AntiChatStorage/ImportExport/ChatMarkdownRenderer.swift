// M8.T07 steps 1, 5 (R-093 AC1, R-019 AC1/AC3): one chat's active path as readable Markdown. `ChatDocument` is the
// shared input of every single-chat exporter (Markdown here; HTML / PDF / image in AntiChatUI/Share): title, mode,
// dates and the user/assistant turns of the active path with their text parts and picture attachments. Evil chats
// begin with the line `> Evil mode` (the watermark is text, never colour only).
import Foundation
import GRDB

public struct ChatDocument: Sendable, Equatable {
    public struct Picture: Sendable, Equatable {
        public var name: String
        public var uti: String
        public var sha256: String
        /// The blob file on disk (may be missing after an export without media).
        public var path: String
        public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
        public var mimeType: String {
            switch fileExtension {
            case "jpg", "jpeg": "image/jpeg"
            case "gif": "image/gif"
            case "webp": "image/webp"
            case "heic": "image/heic"
            case "tif", "tiff": "image/tiff"
            default: "image/png"
            }
        }
        public func data() -> Data? { FileManager.default.contents(atPath: path) }
        public init(name: String, uti: String, sha256: String, path: String) {
            self.name = name; self.uti = uti; self.sha256 = sha256; self.path = path
        }
    }

    public struct Turn: Sendable, Equatable {
        public var role: MessageRole
        public var text: String
        public var pictures: [Picture]
        public var createdAt: Date
        public init(role: MessageRole, text: String, pictures: [Picture], createdAt: Date) {
            self.role = role; self.text = text; self.pictures = pictures; self.createdAt = createdAt
        }
    }

    public var id: String
    public var title: String
    public var isEvil: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [Turn]

    public init(id: String, title: String, isEvil: Bool, createdAt: Date, updatedAt: Date, turns: [Turn]) {
        self.id = id; self.title = title; self.isEvil = isEvil; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.turns = turns
    }

    public var displayTitle: String { title.isEmpty ? "Chat" : title }

    static let pictureUTIs: Set<String> = ["public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp",
                                           "public.tiff", "public.image"]

    public static func load(_ chatID: String, from database: AppDatabase) throws -> ChatDocument {
        try database.read { try load(chatID, db: $0) }
    }

    public static func load(_ chatID: String, db: Database) throws -> ChatDocument {
        guard let chat = try ChatRecord.fetchOne(db, key: chatID) else { throw StorageError.notFound("chat \(chatID)") }
        var turns: [Turn] = []
        for m in try MessageTree.visiblePath(chatID, db: db) where m.role == .user || m.role == .assistant {
            let text = try MessageRepository.parts(of: m.id, db: db).filter { $0.kind == .text }.map(\.body)
                .joined(separator: "\n\n")
            let pictures = try Row.fetchAll(db, sql: """
                SELECT a.display_name, a.uti, b.sha256, b.path FROM attachment a JOIN file_blob b ON b.id = a.blob_id
                WHERE a.message_id = ? ORDER BY a.created_at, a.id
                """, arguments: [m.id]).compactMap { r -> Picture? in
                let p = Picture(name: r[0], uti: r[1], sha256: r[2], path: r[3])
                let isPicture = pictureUTIs.contains(p.uti) || p.uti.hasPrefix("public.") && ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(p.fileExtension)
                return isPicture ? p : nil
            }
            if text.isEmpty, pictures.isEmpty { continue }
            turns.append(Turn(role: m.role, text: text, pictures: pictures, createdAt: m.createdAt))
        }
        return ChatDocument(id: chat.id, title: chat.title, isEvil: chat.mode == .evil, createdAt: chat.createdAt,
                            updatedAt: chat.updatedAt, turns: turns)
    }
}

public enum ChatMarkdownRenderer {
    /// The first line of every Evil export (copy key `export.evilHeader`).
    public static let evilHeader = "Evil mode"

    public enum PictureStyle: Sendable, Equatable {
        /// `data:` URIs inline (single-chat Markdown and Copy as Markdown; R-019 AC3).
        case inline
        /// A relative link into the export's `media/` folder (export-all `chats-md/`), or the name when not included.
        case exportLink(included: Bool)
        /// Review fix (M8.T16): a link only to a file the export really holds (sha256 → zip entry path); a picture
        /// that is not in the zip (missing on disk, media not included) shows its name.
        case exportEntries([String: String])
    }

    public static func roleHeading(_ role: MessageRole) -> String { role == .user ? "You" : "AntiChat" }

    public static func render(_ doc: ChatDocument, pictures: PictureStyle = .inline) -> String {
        var out = ""
        if doc.isEvil { out += "> \(evilHeader)\n\n" }
        out += "---\n"
        out += "title: \(yamlQuoted(doc.displayTitle))\n"
        out += "date: \(iso(doc.createdAt))\n"
        out += "updated: \(iso(doc.updatedAt))\n"
        out += "mode: \(doc.isEvil ? "evil" : "normal")\n"
        out += "---\n\n"
        out += "# \(doc.displayTitle)\n"
        for turn in doc.turns {
            out += "\n## \(roleHeading(turn.role))\n\n"
            if !turn.text.isEmpty { out += turn.text + "\n" }
            for p in turn.pictures {
                let alt = p.name.replacingOccurrences(of: "]", with: ")")
                switch pictures {
                case .inline:
                    if let data = p.data() {
                        out += "\n![\(alt)](data:\(p.mimeType);base64,\(data.base64EncodedString()))\n"
                    } else {
                        out += "\n*[\(alt)]*\n"
                    }
                case .exportLink(let included):
                    out += included ? "\n![\(alt)](../\(AntiChatExportFormat.mediaPath(sha256: p.sha256, ext: p.fileExtension)))\n"
                                    : "\n*[\(alt)]*\n"
                case .exportEntries(let entries):
                    out += entries[p.sha256].map { "\n![\(alt)](../\($0))\n" } ?? "\n*[\(alt)]*\n"
                }
            }
        }
        return out
    }

    static func iso(_ d: Date) -> String { d.formatted(.iso8601) }

    static func yamlQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }
}
