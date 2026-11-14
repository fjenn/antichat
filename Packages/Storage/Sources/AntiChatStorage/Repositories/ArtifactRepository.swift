// Artifacts and their versions (architecture §5.1 `artifact` / `artifact_version`; M4.T10, G-025). Every produced
// file (M6.T09–T13, image results in M4) is one artifact with a version chain n = 1, 2, …; FileCard shows
// "Version {n}" and the SidePanel version picker lists the chain.
import Foundation
import GRDB

public struct ArtifactRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artifact"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var chatID: String
    /// pdf, docx, xlsx, pptx, csv, md, chart, image, video, html, svg, … (free text; M6.T01 documents the set).
    public var kind: String
    public var title: String
    public var createdAt: Date
    enum CodingKeys: String, CodingKey { case id, kind, title, chatID = "chat_id", createdAt = "created_at" }

    public init(id: String = StorageID.make(), chatID: String, kind: String, title: String, createdAt: Date = Date()) {
        self.id = id; self.chatID = chatID; self.kind = kind; self.title = title; self.createdAt = createdAt
    }
}

public struct ArtifactVersionRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artifact_version"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var artifactID: String
    public var n: Int
    public var blobID: String
    public var specJSON: String?
    public var createdByMessageID: String?
    public var createdAt: Date
    /// v14 (M6.T01): the version this one was made from (the previous one in the chain; nil for version 1).
    public var parentVersionID: String?
    /// v30 (M4.T09, R-287 AC4): how a media version was made (`ArtifactOperation` raw value); nil for documents.
    public var operation: String?
    enum CodingKeys: String, CodingKey {
        case id, n, operation
        case artifactID = "artifact_id", blobID = "blob_id", specJSON = "spec_json"
        case createdByMessageID = "created_by_message_id", createdAt = "created_at"
        case parentVersionID = "parent_version_id"
    }

    public init(id: String = StorageID.make(), artifactID: String, n: Int, blobID: String, specJSON: String? = nil,
                createdByMessageID: String? = nil, createdAt: Date = Date(), parentVersionID: String? = nil,
                operation: ArtifactOperation? = nil) {
        self.id = id; self.artifactID = artifactID; self.n = n; self.blobID = blobID; self.specJSON = specJSON
        self.createdByMessageID = createdByMessageID; self.createdAt = createdAt; self.parentVersionID = parentVersionID
        self.operation = operation?.rawValue
    }
}

public struct ArtifactRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    public func create(chatID: String, kind: String, title: String, now: Date = Date()) throws -> ArtifactRecord {
        try database.write { db in
            let record = ArtifactRecord(chatID: chatID, kind: kind, title: title, createdAt: now)
            try record.insert(db)
            return record
        }
    }

    /// Appends version n = max + 1 in one transaction.
    @discardableResult
    public func addVersion(artifactID: String, blobID: String, specJSON: String? = nil, messageID: String? = nil,
                           operation: ArtifactOperation? = nil, now: Date = Date()) throws -> ArtifactVersionRecord {
        try database.write { db in
            let previous = try ArtifactVersionRecord.filter(Column("artifact_id") == artifactID)
                .order(Column("n").desc).fetchOne(db)
            let version = ArtifactVersionRecord(artifactID: artifactID, n: (previous?.n ?? 0) + 1, blobID: blobID,
                                                specJSON: specJSON, createdByMessageID: messageID, createdAt: now,
                                                parentVersionID: previous?.id, operation: operation)
            try version.insert(db)
            return version
        }
    }

    public func artifact(id: String) throws -> ArtifactRecord? {
        try database.read { db in try ArtifactRecord.fetchOne(db, key: id) }
    }

    /// Versions oldest first (n ascending).
    public func versions(artifactID: String) throws -> [ArtifactVersionRecord] {
        try database.read { db in
            try ArtifactVersionRecord.filter(Column("artifact_id") == artifactID).order(Column("n")).fetchAll(db)
        }
    }
}
