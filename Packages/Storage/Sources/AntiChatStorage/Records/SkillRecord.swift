// M7.T12: `skill` rows (migration `v29_skill_flags`, Migrations+Skills.swift) and their repository.
import Foundation
import GRDB

public struct SkillRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "skill"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    /// Where the skill came from (architecture §5.1): shipped starter, added by the user, or (later) a GitHub URL.
    public enum Trust: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case bundled, user, github }
    /// R-265: scripts never run (`never`) unless Run code is on; M7.T13 adds the approval states.
    public enum ScriptPolicy: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case never, ask, allow }

    public var id: String
    /// The Agent Skills `name` (equals the folder name).
    public var name: String
    /// Folder name under the Skills root.
    public var path: String
    public var enabled: Bool
    /// The parsed frontmatter as sorted-key JSON (description, license, compatibility, allowed-tools, metadata).
    public var manifestJSON: String
    public var trust: Trust
    public var scriptPolicy: ScriptPolicy
    /// "Apply to every chat" (R-082 AC3; off by default).
    public var applyAll: Bool
    public var contentHash: String
    public var embedding: Data?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, path, enabled, trust, embedding
        case manifestJSON = "manifest_json", scriptPolicy = "script_policy", applyAll = "apply_all"
        case contentHash = "content_hash", createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(id: String = UUID().uuidString, name: String, path: String? = nil, enabled: Bool = true,
                manifestJSON: String = "{}", trust: Trust = .user, scriptPolicy: ScriptPolicy = .never,
                applyAll: Bool = false, contentHash: String = "", embedding: Data? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.path = path ?? name; self.enabled = enabled; self.manifestJSON = manifestJSON
        self.trust = trust; self.scriptPolicy = scriptPolicy; self.applyAll = applyAll; self.contentHash = contentHash
        self.embedding = embedding; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SkillRepository: Sendable {
    let database: AppDatabase
    public init(_ database: AppDatabase) { self.database = database }

    /// Every installed skill, by name.
    public func all() throws -> [SkillRecord] {
        try database.read { try SkillRecord.order(Column("name")).fetchAll($0) }
    }

    public func skill(named name: String) throws -> SkillRecord? {
        try database.read { try SkillRecord.filter(Column("name") == name).fetchOne($0) }
    }

    /// Insert or replace by name (a re-import of the same name keeps the row id and the user's switches).
    @discardableResult
    public func upsert(_ record: SkillRecord) throws -> SkillRecord {
        try database.write { db in
            var r = record
            if let existing = try SkillRecord.filter(Column("name") == record.name).fetchOne(db) {
                r.id = existing.id
                r.createdAt = existing.createdAt
                r.enabled = existing.enabled
                r.applyAll = existing.applyAll
                r.scriptPolicy = existing.scriptPolicy
            }
            try r.save(db)
            return r
        }
    }

    public func update(_ name: String, _ change: (inout SkillRecord) -> Void) throws {
        try database.write { db in
            guard var r = try SkillRecord.filter(Column("name") == name).fetchOne(db) else { return }
            change(&r)
            r.updatedAt = Date()
            try r.update(db)
        }
    }

    public func delete(_ name: String) throws {
        _ = try database.write { try SkillRecord.filter(Column("name") == name).deleteAll($0) }
    }
}
