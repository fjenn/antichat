// M4.T09 (R-287 AC4): every `artifact_version` row records how it was made. `parent_version_id` exists since
// v14_files_m6; this adds `operation` (`ArtifactOperation`; NULL for files that are not media, e.g. documents).
import GRDB

extension Migrations {
    static func v30PhotoLineage(_ db: Database) throws {
        let ops = ArtifactOperation.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        try db.execute(sql: "ALTER TABLE artifact_version ADD COLUMN operation TEXT CHECK (operation IS NULL OR operation IN (\(ops)))")
    }
}

/// How a media version was made (R-287 AC4); the same value goes into the file's metadata (MediaProvenanceWriter).
public enum ArtifactOperation: String, Sendable, Codable, CaseIterable {
    case generate, edit, inpaint, outpaint, variation, upscale, removeBackground, erase, markup, animate
}
