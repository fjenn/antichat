// M6.T10 step 5 (R-273 AC4, cross-task contract 5): versions of produced files. A later turn that changes a file calls a
// create_* tool with `revises: <artifact_id>`; the result is `artifact_version` n + 1 of that artifact with
// `parent_version_id` = the previous version (ArtifactStore.save(revises:)). Earlier versions stay openable and
// downloadable (their blobs are never touched). The tool result lists the whole chain so the FileCard's ‹ v1 v2 ›
// switcher works from the persisted activity alone.
import Foundation
import GRDB
import AntiChatStorage

public struct VersionInfo: Codable, Sendable, Equatable {
    public var n: Int
    public var path: String
    public var size: Int64
}

public struct VersioningService: Sendable {
    public let store: ArtifactStore

    public init(store: ArtifactStore) { self.store = store }

    /// A problem with `revises` for a call in `chatID` (nil = fine): it must name an artifact of this chat.
    public func problem(revises: String?, chatID: String?) -> String? {
        guard let revises else { return nil }
        let artifact = try? store.database.read { try ArtifactRecord.fetchOne($0, key: revises) }
        guard let artifact else { return "$.revises: no file with artifact_id \"\(revises)\"" }
        if let chatID, artifact.chatID != chatID { return "$.revises: that file belongs to another chat" }
        return nil
    }

    /// Saves `data` as the next version of `artifactID` (from the reply `messageID`).
    public func newVersion(of artifactID: String, chatID: String, kind: String, filename: String, data: Data,
                           specJSON: String?, messageID: String?) throws -> SavedArtifact {
        try store.save(chatID: chatID, kind: kind, filename: filename, data: data, specJSON: specJSON, messageID: messageID,
                       revises: artifactID)
    }

    /// The chain oldest first (n, file path, size).
    public func versions(of artifactID: String) -> [VersionInfo] {
        (try? store.database.read { db in
            try ArtifactVersionRecord.filter(Column("artifact_id") == artifactID).order(Column("n")).fetchAll(db).compactMap { v in
                try FileBlobRecord.fetchOne(db, key: v.blobID).map { VersionInfo(n: v.n, path: $0.path, size: $0.size) }
            }
        }) ?? []
    }
}
