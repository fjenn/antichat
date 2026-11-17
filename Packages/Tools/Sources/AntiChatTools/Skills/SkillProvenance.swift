// Updates for skills installed from the catalogue (Settings › Skills, "Update").
//   * Where a skill came from is kept beside the skills, not inside them: `<Skills>/.catalog/<name>.json` (catalogue
//     id, pinned commit, the digest of the file set that was installed). A skill's own folder stays exactly what was
//     imported (byte-identical export, R-261; the validator and `contentHash` never see the record), the dot folder is
//     no skill to `reconcile`, and it lives in Application Support like the skills, so it survives app updates.
//     Any other install of that name (the user's own file, Create skill, a starter) and Delete remove the record.
//   * Skills installed before there was a record: `adoptCatalogSkills`, once per store. A skill whose name is in the
//     index and whose files are exactly the listed ones is that catalogue version; any other skill is the user's own
//     and is never offered an update.
//   * `availableUpdates`: the index lists the record's id with another file set (digests, not commit ids: a new
//     commit that left this skill alone is no update) AND the installed files are still the recorded ones. A copy
//     the user edited is left alone, silently.
//   * `update` swaps the folder in with the old one kept aside until the new files, the row and the record are all
//     in place; any failure puts the old folder, row and record back. The row keeps its switches (on / off, every
//     chat) and where the skill came from.
//   * `SkillUpdateChange.between`: whether an update has to be reviewed first (a new or changed file under
//     `scripts/`, or another `allowed-tools`); anything else is text and is applied directly.
// The digest ignores `.DS_Store` (Show in Finder is in the row's menu; looking at a folder is not editing it).
import AntiChatStorage
import CryptoKit
import Foundation
import OsaurusVendored

/// Where an installed skill came from: one entry of the skills catalogue.
public struct SkillProvenance: Codable, Sendable, Equatable {
    /// The catalogue id (`<source>/<name>`).
    public var id: String
    /// The commit the installed files were pinned to.
    public var commit: String
    /// `SkillProvenance.digest` of the files as they were installed.
    public var digest: String

    public init(id: String, commit: String, digest: String) { self.id = id; self.commit = commit; self.digest = digest }

    /// The folder under the Skills root that holds the records (and `adopted`, the once-only marker).
    static let folder = ".catalog"
    static let ignored: Set<String> = [".DS_Store"]

    /// One digest for a set of files: SHA-256 over every path and its SHA-256, in path order.
    public static func digest(_ files: [(path: String, sha256: String)]) -> String {
        var h = SHA256()
        for f in files.sorted(by: { $0.path < $1.path }) {
            h.update(data: Data("\(f.path)\u{0}\(f.sha256.lowercased())\n".utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of what the catalogue lists for `skill`.
    public static func digest(of skill: SkillsCatalog.Skill) -> String { digest(skill.files.map { ($0.path, $0.sha256) }) }

    /// The digest of the files in `dir` now.
    public static func digest(of dir: URL) -> String { digest(hashes(in: dir).map { ($0.key, $0.value) }) }

    /// Relative path → SHA-256 of every file in `dir` (`.DS_Store` left out).
    static func hashes(in dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        for f in SkillStore.files(in: dir) where !ignored.contains((f.relativePath as NSString).lastPathComponent) {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(f.relativePath)) else { continue }
            out[f.relativePath] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }
}

/// What an update changes that the user has to see first.
public enum SkillUpdateChange: String, Sendable, Equatable {
    case scripts, tools, both

    /// nil = the update touches neither scripts nor `allowed-tools`: no review.
    public static func between(installed: InstalledSkill, in directory: URL, candidate: SkillImportCandidate) -> SkillUpdateChange? {
        let old = SkillProvenance.hashes(in: directory), new = SkillProvenance.hashes(in: candidate.stagedRoot)
        let scripts = new.contains { $0.key.hasPrefix("scripts/") && old[$0.key] != $0.value }
        let tools = Set(installed.document?.allowedTools ?? []) != Set(candidate.allowedTools)
        return scripts ? (tools ? .both : .scripts) : (tools ? .tools : nil)
    }
}

extension SkillStore {
    public enum UpdateError: Error, Equatable { case notInstalled(String), invalid(String) }

    private var provenanceFolder: URL { root.appendingPathComponent(SkillProvenance.folder, isDirectory: true) }
    private func provenanceURL(_ name: String) -> URL { provenanceFolder.appendingPathComponent("\(name).json") }

    /// Where `name` came from; nil = the user's own skill (or a starter).
    public func provenance(of name: String) -> SkillProvenance? {
        guard let data = try? Data(contentsOf: provenanceURL(name)) else { return nil }
        return try? JSONDecoder().decode(SkillProvenance.self, from: data)
    }

    /// Writes the record of `name`; nil removes it.
    func setProvenance(_ provenance: SkillProvenance?, for name: String) throws {
        let fm = FileManager.default, url = provenanceURL(name)
        try Self.ensureContained(url, in: provenanceFolder)
        guard let provenance else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: provenanceFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(provenance).write(to: url, options: .atomic)
    }

    /// Once per store: gives the skills that were installed from the catalogue before records were kept their record
    /// (same name, exactly the listed files, in the first of `catalogs` that has them so). Nothing happens without
    /// an index to compare with; the next call tries again then.
    public func adoptCatalogSkills(from catalogs: [SkillsCatalog]) {
        let fm = FileManager.default
        let marker = provenanceFolder.appendingPathComponent("adopted")
        let catalogs = catalogs.filter { !$0.isEmpty }
        guard !catalogs.isEmpty, !fm.fileExists(atPath: marker.path), let rows = try? repository.all() else { return }
        for row in rows where row.trust != .bundled && provenance(of: row.name) == nil {
            let entries = catalogs.compactMap { c in c.skills.first { $0.name == row.name } }
            guard !entries.isEmpty else { continue }
            let digest = SkillProvenance.digest(of: directory(for: row.path))
            if let entry = entries.first(where: { SkillProvenance.digest(of: $0) == digest }) {
                try? setProvenance(SkillProvenance(id: entry.id, commit: entry.commit, digest: digest), for: row.name)
            }
        }
        try? fm.createDirectory(at: provenanceFolder, withIntermediateDirectories: true)
        try? Data().write(to: marker)
    }

    /// The installed skills `catalog` has a newer file set for, by installed name. No network: this only compares.
    public func availableUpdates(in catalog: SkillsCatalog) -> [String: SkillsCatalog.Skill] {
        guard !catalog.isEmpty, let rows = try? repository.all() else { return [:] }
        let known = rows.compactMap { row in provenance(of: row.name).map { (row, $0) } }
        guard !known.isEmpty else { return [:] }
        let ids = Set(known.map(\.1.id))
        let entries = Dictionary(catalog.skills.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: SkillsCatalog.Skill] = [:]
        for (row, from) in known {
            guard let entry = entries[from.id], entry.name == row.name, SkillProvenance.digest(of: entry) != from.digest,
                  SkillProvenance.digest(of: directory(for: row.path)) == from.digest else { continue }
            out[row.name] = entry
        }
        return out
    }

    /// Replaces the installed skill `name` with the folder `staged` (a verified download of `source`; not consumed).
    /// The new files are validated before anything moves, and the old folder is kept until the new folder, the row
    /// and the record are in place: on any failure all three are as they were. The row keeps its switches.
    @discardableResult
    public func update(_ name: String, from staged: URL, source: SkillsCatalog.Skill) throws -> InstalledSkill {
        let fm = FileManager.default
        guard let old = try repository.skill(named: name) else { throw UpdateError.notInstalled(name) }
        let destination = directory(for: old.path)
        try Self.ensureContained(destination, in: root)
        let stage = root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try Self.copyTree(from: staged, to: stage)
        guard let md = SkillValidator.skillMarkdown(in: stage), let text = try? String(contentsOf: md, encoding: .utf8),
              let doc = try? SkillDocument(markdown: text) else { throw UpdateError.invalid("Missing required file: SKILL.md") }
        if let issue = SkillValidator.validate(doc, directoryName: old.path).first(where: \.blocking) { throw UpdateError.invalid(issue.message) }
        let before = provenance(of: name)
        let backup = root.appendingPathComponent(".\(old.path).update-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: stage, to: destination)
            var row = old
            row.manifestJSON = doc.manifestJSON
            row.contentHash = Self.contentHash(of: destination)
            row.updatedAt = Date()
            try repository.upsert(row)
            try setProvenance(SkillProvenance(id: source.id, commit: source.commit, digest: SkillProvenance.digest(of: destination)),
                              for: name)
        } catch {
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: backup, to: destination)
            _ = try? repository.upsert(old)
            try? setProvenance(before, for: name)
            throw error
        }
        try? fm.removeItem(at: backup)
        return load(try repository.skill(named: name) ?? old)
    }
}
