// M6.T13 step 1 (R-016 AC1, cross-task contract 5): when a reply is done, every promoted block (OutputPromotion) is
// saved as an artifact of the chat — the source as the version's file in the media store (ArtifactStore: one blob per
// sha256, incognito → temp dir), `spec_json` = {source_sha256, language, kind, react, lines}, created_by_message_id =
// the reply. A reply made by "Edit selection" / "Fix" (ArtifactEditService) revises that artifact: its first promoted
// block becomes version n + 1 (the old versions stay). A block whose source this chat already holds (a regenerated
// reply repeating it) is not saved twice.
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

/// A promoted block found in the chat's store (the renderer's card → side panel).
public struct PromotedArtifactRef: Sendable, Equatable {
    public var artifactID: String
    public var title: String
    public var kind: ArtifactKind
    public var react: Bool
    public var language: String
    /// The version this block is (its sha256's version).
    public var version: Int
    /// The chain oldest first: (n, file path).
    public var versions: [(n: Int, path: String)]
    public var createdAt: Date
    /// When this block's version was saved (fresh cards open the panel by themselves).
    public var versionCreatedAt: Date

    public init(artifactID: String, title: String, kind: ArtifactKind, react: Bool, language: String, version: Int,
                versions: [(n: Int, path: String)], createdAt: Date, versionCreatedAt: Date) {
        self.artifactID = artifactID; self.title = title; self.kind = kind; self.react = react; self.language = language
        self.version = version; self.versions = versions; self.createdAt = createdAt; self.versionCreatedAt = versionCreatedAt
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.artifactID == b.artifactID && a.version == b.version && a.versions.map(\.n) == b.versions.map(\.n)
            && a.versions.map(\.path) == b.versions.map(\.path) && a.title == b.title
    }
}

public struct ArtifactPromotionService: Sendable {
    public let store: ArtifactStore

    public init(store: ArtifactStore) { self.store = store }

    /// Saves the promoted blocks of `text` (reply `messageID` of `chatID`). `revises` = the artifact an edit / fix turn
    /// changes: the first block becomes its next version. Returns the saved versions.
    @discardableResult
    public func promote(text: String, chatID: String, messageID: String?, revises: String? = nil,
                        revisesVersion: Int? = nil) -> [SavedArtifact] {
        var revising = revises
        var out: [SavedArtifact] = []
        for block in OutputPromotion.promotions(in: text) {
            if revising == nil, let existing = lookup(sha256: block.sha256, chatID: chatID), existing.version >= 1 { continue }
            do {
                let saved = try store.save(chatID: chatID, kind: block.kind.rawValue, filename: block.filename,
                                           data: Data(block.source.utf8), specJSON: block.specJSON, messageID: messageID,
                                           revises: revising, revisesVersion: revising == nil ? nil : revisesVersion)
                out.append(saved)
            } catch {
                continue
            }
            revising = nil
        }
        return out
    }

    /// The artifact (and version) holding a block with this source in `chatID`, newest first.
    public func lookup(sha256: String, chatID: String) -> PromotedArtifactRef? {
        Self.lookup(sha256: sha256, chatID: chatID, database: store.database)
    }

    public static func lookup(sha256: String, chatID: String, database: AppDatabase) -> PromotedArtifactRef? {
        try? database.reader.read { db -> PromotedArtifactRef? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT v.artifact_id, v.n, v.spec_json, v.created_at FROM artifact_version v JOIN artifact a ON a.id = v.artifact_id
                WHERE a.chat_id = ? AND v.spec_json LIKE ? ORDER BY v.created_at DESC LIMIT 1
                """, arguments: [chatID, "%\"source_sha256\":\"\(sha256)\"%"]),
                  let artifact = try ArtifactRecord.fetchOne(db, key: row["artifact_id"] as String)
            else { return nil }
            let spec = (row["spec_json"] as String?).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            let chain = try ArtifactVersionRecord.filter(Column("artifact_id") == artifact.id).order(Column("n")).fetchAll(db)
                .compactMap { v -> (Int, String)? in try FileBlobRecord.fetchOne(db, key: v.blobID).map { (v.n, $0.path) } }
            return PromotedArtifactRef(
                artifactID: artifact.id, title: artifact.title, kind: ArtifactKind(rawValue: artifact.kind) ?? .code,
                react: spec?["react"] as? Bool ?? false, language: spec?["language"] as? String ?? "",
                version: row["n"], versions: chain.map { (n: $0.0, path: $0.1) }, createdAt: artifact.createdAt,
                versionCreatedAt: Date(timeIntervalSince1970: row["created_at"] as Double? ?? 0))
        }
    }

    /// The `spec_json` of an artifact version (kind, language, react) — the panel's preview mode for any version.
    public static func spec(artifactID: String, database: AppDatabase) -> (language: String, react: Bool)? {
        try? database.reader.read { db in
            guard let v = try ArtifactVersionRecord.filter(Column("artifact_id") == artifactID).order(Column("n").desc).fetchOne(db),
                  let json = v.specJSON,
                  let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
            return (o["language"] as? String ?? "", o["react"] as? Bool ?? false)
        }
    }
}
