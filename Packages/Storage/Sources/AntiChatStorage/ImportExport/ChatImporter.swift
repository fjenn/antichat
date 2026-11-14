// M8.T06 steps 3–9, 11, 12 (R-092; G-058): a ChatGPT or Claude export (zip or conversations.json) onto the message
// tree, streamed. Detection peeks at the first conversation; the zip's `conversations.json` is extracted to a temp
// file and read one conversation at a time (JSONArrayStreamer); each conversation is parsed (ChatGPT/Claude
// importers, ported from osaurus@2922745, P-platform-10), repaired (TreeImporter.buildTree), deduped against
// `import_record` and written in its own transaction, so Cancel (checked between conversations) keeps every chat
// already imported and never a partial one. Images (ChatGPT `file-…` asset pointers, `dalle-generations/`) are
// resolved to zip entries and stored as `file_blob(origin='import')` + attachment rows. Unsupported parts are kept as
// `[Imported {type}]` text and counted. Message FTS rows are deferred to MessageSearchBacklog (a background pass after
// the import, AT-092); embedding is the background indexer's job. No network: AntiChatStorage links no networking.
import CryptoKit
import Foundation
import GRDB
import ZIPFoundation

public struct ImportSummary: Sendable, Equatable {
    public var format: ImportFormat?
    public var chats = 0
    public var messages = 0
    public var images = 0
    /// Already here (same external key, not newer).
    public var skipped = 0
    /// Re-imported because the export is newer (same chat id).
    public var replaced = 0
    /// Unsupported part type → count (kept as text).
    public var kept: [String: Int] = [:]
    public var cancelled = false
    public var chatIDs: [String] = []
    /// M8.T07 (AntiChat exports): projects and memories restored, blobs whose bytes were not in the zip, and the
    /// export's settings (restored only after the user confirms, `import.settings.ask`).
    public var projects = 0
    public var memories = 0
    public var missingMedia = 0
    public var settingsJSON: Data?
    public init() {}
}

public struct ImportProgress: Sendable, Equatable {
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var chatsDone: Int
    public init(bytesDone: Int64, bytesTotal: Int64, chatsDone: Int) {
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.chatsDone = chatsDone
    }
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

public enum ImportDetection: Equatable, Sendable {
    case chatGPT, claude, antichat, unsupported
}

public final class ChatImporter: @unchecked Sendable {
    public let database: AppDatabase
    public let mediaRoot: URL

    public init(database: AppDatabase, mediaRoot: URL) {
        self.database = database
        self.mediaRoot = mediaRoot
    }

    // MARK: Detection (step 3)

    public static func detect(_ url: URL) -> ImportDetection {
        if isZip(url) {
            guard let archive = try? Archive(url: url, accessMode: .read) else { return .unsupported }
            if let manifest = entry(archive, named: "manifest.json"), let data = try? read(archive, manifest),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["format"] as? String == "antichat-export" {
                return .antichat
            }
            guard let conv = entry(archive, named: "conversations.json"),
                  let head = try? read(archive, conv, limit: 1 << 20) else { return .unsupported }
            return sniff(head)
        }
        guard let fh = try? FileHandle(forReadingFrom: url), let head = try? fh.read(upToCount: 1 << 20) else { return .unsupported }
        try? fh.close()
        return sniff(head)
    }

    /// The format from the first conversation's keys (ChatGPT: `mapping`; Claude: `chat_messages`), tolerant of a
    /// cut-off head (G-058: the detector looks for the keys, not a full parse).
    static func sniff(_ head: Data) -> ImportDetection {
        let s = String(decoding: head.prefix(1 << 20), as: UTF8.self)
        if let o = try? JSONSerialization.jsonObject(with: head) as? [String: Any], o["format"] as? String == "antichat-export" {
            return .antichat
        }
        if s.range(of: #""mapping"\s*:"#, options: .regularExpression) != nil, s.contains("\"current_node\"") || s.contains("\"mapping\"") {
            return .chatGPT
        }
        if s.range(of: #""chat_messages"\s*:"#, options: .regularExpression) != nil { return .claude }
        return .unsupported
    }

    static func isZip(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url), let magic = try? fh.read(upToCount: 4) else { return false }
        try? fh.close()
        return magic.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    static func entry(_ archive: Archive, named name: String) -> Entry? {
        archive.filter { e in
            let p = e.path.lowercased()
            return e.type == .file && !p.hasPrefix("__macosx/") && (p as NSString).lastPathComponent == name
        }.min { $0.path.count < $1.path.count }
    }

    /// The shared bounded reader with the import caps (M6 review #2: ratio-capped per part, total-capped).
    static func bounded(_ archive: Archive) -> BoundedZip {
        BoundedZip(archive: archive, partCap: BoundedZip.importPartCap, totalCap: BoundedZip.importTotalCap,
                   maxRatio: BoundedZip.importRatio)
    }

    static func read(_ archive: Archive, _ entry: Entry, limit: Int = .max) throws -> Data {
        var out = Data()
        do {
            try bounded(archive).stream(entry) { chunk in
                out.append(chunk)
                if out.count >= limit { throw StopReading() }
            }
        } catch is StopReading {}
        return out
    }

    struct StopReading: Error {}

    // MARK: Run

    /// Imports `url`. `progress` is called after each conversation; `isCancelled` is checked between conversations.
    public func run(_ url: URL, progress: (ImportProgress) -> Void = { _ in },
                    isCancelled: () -> Bool = { false }) throws -> ImportSummary {
        var summary = ImportSummary()
        var archive: Archive?
        var json = url
        var temp: URL?
        defer { if let temp { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) } }
        if Self.isZip(url) {
            let a = try Archive(url: url, accessMode: .read)
            guard let conv = Self.entry(a, named: "conversations.json") else { throw ImportError.noConversations }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("conversations.json")
            try Self.bounded(a).extract(conv, to: out)
            temp = out
            json = out
            archive = a
        }
        let images = archive.map { ImageIndex(archive: $0) }
        // AT-092: the chats' full-text rows are written by MessageSearchBacklog after the import (the FTS triggers
        // were ≈ 40 % of the import's time); the window closes however the run ends.
        if !database.isInMemory {
            try MessageSearchBacklog(database: database).begin()
        }
        defer { if !database.isInMemory { try? MessageSearchBacklog(database: database).end() } }
        let streamer = JSONArrayStreamer(url: json)
        let total = streamer.totalBytes
        var format: ImportFormat?
        let fileSHA = nil as String?
        try streamer.forEach { bytes, consumed in
            if isCancelled() { summary.cancelled = true; return false }
            // One autorelease pool per conversation: JSONSerialization's Foundation objects are autoreleased and a
            // 1 GB export otherwise keeps every conversation's tree alive until the import ends (+2.3 GB RSS).
            let parsed: RawConversation? = autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
                if ChatGPTTreeImporter.matches(object) { return ChatGPTTreeImporter.parse(object) }
                if ClaudeTreeImporter.matches(object) { return ClaudeTreeImporter.parse(object) }
                return nil
            }
            guard let raw = parsed else { return true }
            format = format ?? raw.format
            let tree = TreeImporter.buildTree(raw)
            try write(tree, images: images, fileSHA: fileSHA, summary: &summary)
            progress(ImportProgress(bytesDone: consumed, bytesTotal: total, chatsDone: summary.chats + summary.skipped + summary.replaced))
            return true
        }
        summary.format = format
        if format == nil, !summary.cancelled { throw ImportError.noConversations }
        progress(ImportProgress(bytesDone: summary.cancelled ? 0 : total, bytesTotal: total,
                                chatsDone: summary.chats + summary.skipped + summary.replaced))
        return summary
    }

    /// RC review P2-5: the dedup key of a conversation without a source id. `title|createdAt` collided for two such
    /// conversations with the same title and no `created_at` (the second was skipped as a re-import of the first), so
    /// the key also hashes every message: the same conversation re-imported still matches, a different one never does.
    static func contentKey(_ tree: ImportedTree) -> String {
        var h = SHA256()
        func add(_ s: String) { h.update(data: Data(s.utf8)); h.update(data: Data([0x1F])) }
        add(tree.title)
        add(tree.createdAt.map { String($0.timeIntervalSince1970) } ?? "-")
        for n in tree.nodes {
            add(n.sourceId)
            add(n.parentSourceId ?? "-")
            add(n.role.rawValue)
            for p in n.parts { add(p.kind.rawValue); add(p.body) }
            add(n.images.joined(separator: "\u{1E}"))
            h.update(data: Data([0x1D]))
        }
        return "content:" + h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Step 7: dedup by (source, external key); one transaction per conversation.
    private func write(_ tree: ImportedTree, images: ImageIndex?, fileSHA: String?, summary: inout ImportSummary) throws {
        let source = tree.format.rawValue
        let key = tree.sourceId ?? Self.contentKey(tree)
        let updated = tree.updatedAt?.timeIntervalSince1970
        // Image bytes are hashed and stored before the transaction (file writes outside the write lock).
        var blobs: [String: FileBlobRecord] = [:]
        if let images {
            for ref in Set(tree.nodes.flatMap(\.images)) {
                if let b = try? images.store(ref, mediaRoot: mediaRoot, database: database) { blobs[ref] = b }
            }
        }
        enum Outcome { case new(String), replaced(String), skipped }
        let outcome: Outcome = try database.write { db in
            let existing = try Row.fetchOne(db, sql: """
                SELECT r.id, r.chat_id, r.external_updated_at FROM import_record r JOIN chat c ON c.id = r.chat_id
                WHERE r.source = ? AND r.external_key = ?
                """, arguments: [source, key])
            if let existing {
                let had: Double? = existing["external_updated_at"]
                guard let updated, updated > (had ?? -Double.infinity) else { return .skipped }
                let chatID: String = existing["chat_id"]
                // RC review P1-1: a chat the user went on with here (a message with no source id: a local turn, edit or
                // regeneration) is never replaced, since that would delete what they wrote. The newer export lands as
                // a new chat, and the import record follows it, so the next re-import replaces only imported content.
                let hasLocal = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE chat_id = ? AND source_id IS NULL)",
                                                 arguments: [chatID]) ?? false
                if hasLocal {
                    let newID = try TreeImporter.write(tree, db, image: { blobs[$0] })
                    try db.execute(sql: "UPDATE import_record SET chat_id = ?, external_updated_at = ?, imported_at = ?, file_sha256 = ? WHERE id = ?",
                                   arguments: [newID, updated, Date().timeIntervalSince1970, fileSHA, existing["id"] as String])
                    return .new(newID)
                }
                _ = try TreeImporter.write(tree, db, replacing: chatID, image: { blobs[$0] })
                try db.execute(sql: "UPDATE import_record SET external_updated_at = ?, imported_at = ?, file_sha256 = ? WHERE id = ?",
                               arguments: [updated, Date().timeIntervalSince1970, fileSHA, existing["id"] as String])
                return .replaced(chatID)
            }
            try db.execute(sql: "DELETE FROM import_record WHERE source = ? AND external_key = ?", arguments: [source, key])
            let chatID = try TreeImporter.write(tree, db, image: { blobs[$0] })
            try db.execute(sql: """
                INSERT INTO import_record(id, source, external_key, chat_id, external_updated_at, file_sha256, imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [StorageID.make(), source, key, chatID, updated, fileSHA, Date().timeIntervalSince1970])
            return .new(chatID)
        }
        switch outcome {
        case .skipped:
            summary.skipped += 1
            return
        case .new(let id):
            summary.chats += 1
            summary.chatIDs.append(id)
        case .replaced(let id):
            summary.replaced += 1
            summary.chatIDs.append(id)
        }
        summary.messages += tree.nodes.count
        summary.images += tree.nodes.reduce(0) { $0 + $1.images.filter { blobs[$0] != nil }.count }
        for t in tree.nodes.flatMap(\.kept) { summary.kept[t, default: 0] += 1 }
    }
}

/// The zip's image entries by asset id (ChatGPT `file-…` / `file_…` pointers; `dalle-generations/`).
final class ImageIndex {
    let archive: Archive
    private var byName: [String: Entry] = [:]
    static let exts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]

    init(archive: Archive) {
        self.archive = archive
        for e in archive where e.type == .file {
            let name = (e.path as NSString).lastPathComponent
            guard Self.exts.contains((name as NSString).pathExtension.lowercased()), !name.hasPrefix("._") else { continue }
            byName[name] = e
        }
    }

    func entry(_ ref: String) -> Entry? {
        guard !ref.isEmpty else { return nil }  // RC review P2-2: "" prefixes every name (a random image)
        if let e = byName[ref] { return e }
        let alt = ref.replacingOccurrences(of: "file_", with: "file-")
        return byName.first { $0.key.hasPrefix(ref) || $0.key.hasPrefix(alt) }?.value
    }

    /// Stores the image once per sha256 under `<media>/<yyyy>/<sha256>.<ext>` (M6 media-store layout).
    func store(_ ref: String, mediaRoot: URL, database: AppDatabase) throws -> FileBlobRecord? {
        guard let e = entry(ref) else { return nil }
        let data = try ChatImporter.read(archive, e)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let b = try database.read({ try FileBlobRecord.filter(Column("sha256") == sha).fetchOne($0) }) { return b }
        let ext = ((e.path as NSString).pathExtension.lowercased()).replacingOccurrences(of: "jpeg", with: "jpg")
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let dir = mediaRoot.appendingPathComponent("\(year)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(sha).\(ext)")
        if !FileManager.default.fileExists(atPath: path.path) { try data.write(to: path, options: .atomic) }
        let blob = FileBlobRecord(sha256: sha, size: Int64(data.count), path: path.path, origin: .import)
        try database.write { db in
            if try FileBlobRecord.filter(Column("sha256") == sha).fetchOne(db) == nil { try blob.insert(db) }
        }
        return try database.read { try FileBlobRecord.filter(Column("sha256") == sha).fetchOne($0) }
    }
}
