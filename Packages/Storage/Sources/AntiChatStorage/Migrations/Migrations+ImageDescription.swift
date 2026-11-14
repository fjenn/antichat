// M9.T02 step 5 (NFR-A5, A-M9-T02a): the description of a picture for people who can't see it — written by the vision
// model after the picture is shown, editable in the viewer. Keyed by the picture's content hash (`file_blob.sha256`),
// so a variant, a saved copy and a version that is the same file share one description. No FK: a description outlives
// nothing (the blob GC removes orphans through `ImageDescriptionStore.sweep`). `source`: `auto` (the model) or `user`
// (an edit; the model never overwrites it).
import Foundation
import GRDB

extension Migrations {
    static func v31ImageDescription(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE image_description (
              sha256 TEXT PRIMARY KEY NOT NULL,
              text TEXT NOT NULL,
              source TEXT NOT NULL CHECK (source IN ('auto', 'user')),
              language TEXT NOT NULL,
              updated_at DOUBLE NOT NULL
            );
            """)
    }
}

/// One stored description.
public struct ImageDescription: Sendable, Equatable {
    public enum Source: String, Sendable { case auto, user }
    public var text: String
    public var source: Source
    public var language: String

    public init(text: String, source: Source, language: String) {
        self.text = text
        self.source = source
        self.language = language
    }
}

/// Reads and writes `image_description` (M9.T02).
public struct ImageDescriptionStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public func get(sha256: String) throws -> ImageDescription? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT text, source, language FROM image_description WHERE sha256 = ?", arguments: [sha256])
                .map { ImageDescription(text: $0["text"], source: ImageDescription.Source(rawValue: $0["source"]) ?? .auto,
                                        language: $0["language"]) }
        }
    }

    /// Stores `d`; an `auto` description never replaces a `user` one.
    @discardableResult
    public func set(sha256: String, _ d: ImageDescription, at date: Date = Date()) throws -> Bool {
        try database.write { db in
            if d.source == .auto,
               try String.fetchOne(db, sql: "SELECT source FROM image_description WHERE sha256 = ?", arguments: [sha256]) == "user" {
                return false
            }
            try db.execute(sql: """
                INSERT INTO image_description (sha256, text, source, language, updated_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(sha256) DO UPDATE SET text = excluded.text, source = excluded.source,
                  language = excluded.language, updated_at = excluded.updated_at
                """, arguments: [sha256, d.text, d.source.rawValue, d.language, date.timeIntervalSince1970])
            return true
        }
    }

    /// Removes descriptions whose picture is gone (no `file_blob` with that hash).
    @discardableResult
    public func sweep() throws -> Int {
        try database.write { db in
            try db.execute(sql: "DELETE FROM image_description WHERE sha256 NOT IN (SELECT sha256 FROM file_blob)")
            return db.changesCount
        }
    }
}
