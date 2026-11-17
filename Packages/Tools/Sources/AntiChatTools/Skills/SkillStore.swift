// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Managers/SkillManager.swift (MIT; P-files-tools-16,
// M7.T12): the installed-skill store without its agent, plugin, SwiftUI and search-index coupling. Kept from upstream:
// one folder per skill under the Skills root, installs staged next to the destination and swapped in with a backup
// (`installStagedSkillDirectory`), containment checks on every copied path. Changed: the folder is installed exactly
// as imported (every file, SKILL.md unedited; upstream rewrites SKILL.md and keeps only references/ and assets/), so a
// skill exports byte-identical (R-261); state lives in the `skill` table (v29_skill_flags), not in the SKILL.md.
//   Root: `<Application Support>/AntiChat[-Dev]/Skills/<name>/` (`AppDatabase.containerURL`).
import AntiChatStorage
import CryptoKit
import Foundation
import OsaurusVendored

/// One file of a skill folder (review sheet, export).
public struct SkillFileEntry: Sendable, Hashable, Identifiable {
    public let relativePath: String
    public let size: Int64
    public var id: String { relativePath }
}

/// An installed skill: its row plus what its folder holds now.
public struct InstalledSkill: Sendable, Hashable, Identifiable {
    public var record: SkillRecord
    /// nil when SKILL.md is missing or unreadable (the row shows `skills.invalid`).
    public var document: SkillDocument?
    public var issues: [SkillIssue]
    public var files: [SkillFileEntry]

    public var id: String { record.name }
    public var name: String { record.name }
    public var description: String { document?.description ?? "" }
    /// No blocking validation error (invalid skills stay listed, switched off for use).
    public var isValid: Bool { document != nil && !issues.contains(where: \.blocking) }
    /// The folder has a `scripts/` directory (R-265: never run unless Run code is on; M7.T13).
    public var hasScripts: Bool { Self.hasScripts(files) }
    /// The first blocking reason (`skills.invalid` {reason}).
    public var invalidReason: String? { isValid ? nil : (issues.first(where: \.blocking)?.message ?? "SKILL.md is missing") }

    static func hasScripts(_ files: [SkillFileEntry]) -> Bool { files.contains { $0.relativePath.hasPrefix("scripts/") } }
}

public struct SkillStore: Sendable {
    public let root: URL
    let repository: SkillRepository

    public init(root: URL, database: AppDatabase) {
        self.root = root
        self.repository = SkillRepository(database)
    }

    /// The Skills folder next to `database`'s file (the container); the default container for an in-memory one.
    public static func root(for database: AppDatabase) -> URL {
        (database.fileURL?.deletingLastPathComponent() ?? AppDatabase.containerURL()).appendingPathComponent("Skills", isDirectory: true)
    }

    public func directory(for name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    // MARK: Read

    /// Every installed skill, by name.
    public func list() -> [InstalledSkill] {
        ((try? repository.all()) ?? []).map(load)
    }

    public func skill(named name: String) -> InstalledSkill? {
        (try? repository.skill(named: name)).flatMap { $0 }.map(load)
    }

    func load(_ record: SkillRecord) -> InstalledSkill {
        let dir = directory(for: record.path)
        let files = Self.files(in: dir)
        guard let md = SkillValidator.skillMarkdown(in: dir), let text = try? String(contentsOf: md, encoding: .utf8) else {
            return InstalledSkill(record: record, document: nil, issues: [SkillIssue(kind: .other, message: "Missing required file: SKILL.md")],
                                  files: files)
        }
        do {
            let doc = try SkillDocument(markdown: text)
            return InstalledSkill(record: record, document: doc, issues: SkillValidator.validate(doc, directoryName: record.path),
                                  files: files)
        } catch let e as SkillDocument.ParseError {
            return InstalledSkill(record: record, document: nil, issues: [SkillIssue(kind: .other, message: e.description)], files: files)
        } catch {
            return InstalledSkill(record: record, document: nil, issues: [SkillIssue(kind: .other, message: "\(error)")], files: files)
        }
    }

    /// The instructions of `name` (SKILL.md body), or nil.
    public func body(of name: String) -> String? { skill(named: name)?.document?.body }

    // MARK: Write

    /// Installs the folder `staged` (a validated copy; consumed) as skill `name`, replacing an existing folder of that
    /// name when `replacing`. A re-install keeps the row id and the user's switches. `source` = the catalogue entry
    /// the files were downloaded from (recorded for Update, SkillProvenance.swift); nil = not from the catalogue.
    @discardableResult
    public func install(from staged: URL, name: String, trust: SkillRecord.Trust, enabled: Bool = true,
                        replacing: Bool = true, source: SkillsCatalog.Skill? = nil) throws -> InstalledSkill {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = directory(for: name)
        try Self.ensureContained(destination, in: root)
        let stage = root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try Self.copyTree(from: staged, to: stage)
        try Self.installStaged(stage, to: destination, skillName: name, overwriteExisting: replacing)
        let doc = SkillValidator.skillMarkdown(in: destination).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { try? SkillDocument(markdown: $0) }
        let record = try repository.upsert(SkillRecord(
            name: name, path: name, enabled: enabled, manifestJSON: doc?.manifestJSON ?? "{}", trust: trust,
            contentHash: Self.contentHash(of: destination)))
        // Without a record the skill is simply the user's own: never offered an update.
        try? setProvenance(source.map { SkillProvenance(id: $0.id, commit: $0.commit, digest: SkillProvenance.digest(of: destination)) },
                           for: name)
        return load(record)
    }

    /// Removes the folder and the row.
    public func delete(_ name: String) throws {
        let dir = directory(for: name)
        try Self.ensureContained(dir, in: root)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        try repository.delete(name)
        try? setProvenance(nil, for: name)
    }

    public func setEnabled(_ name: String, _ on: Bool) throws { try repository.update(name) { $0.enabled = on } }

    /// "Apply to every chat" (R-082 AC3).
    public func setApplyAll(_ name: String, _ on: Bool) throws { try repository.update(name) { $0.applyAll = on } }

    /// Brings the rows in line with the folders: a folder without a row is added (user, on), a row without a folder is
    /// removed, a changed folder gets a new manifest + hash (an edit in Finder or a text editor; R-082 AC5 "editable").
    public func reconcile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rows = try repository.all()
        let folders = Set(((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent))
        for r in rows where !folders.contains(r.path) { try repository.delete(r.name) }
        for f in folders {
            let dir = directory(for: f)
            let hash = Self.contentHash(of: dir)
            let row = rows.first { $0.path == f }
            if let row, row.contentHash == hash { continue }
            let doc = SkillValidator.skillMarkdown(in: dir).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .flatMap { try? SkillDocument(markdown: $0) }
            if var row {
                row.manifestJSON = doc?.manifestJSON ?? "{}"
                row.contentHash = hash
                row.updatedAt = Date()
                try repository.upsert(row)
            } else {
                try repository.upsert(SkillRecord(name: f, path: f, manifestJSON: doc?.manifestJSON ?? "{}", trust: .user,
                                                  contentHash: hash))
            }
        }
    }

    // MARK: Files

    /// Regular files of `dir`, relative paths, sorted (hidden `.DS_Store`-style files included as they are).
    public static func files(in dir: URL) -> [SkillFileEntry] {
        let base = dir.standardizedFileURL.pathComponents
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return [] }
        var out: [SkillFileEntry] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            let rel = u.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
            out.append(SkillFileEntry(relativePath: rel, size: Int64(v.fileSize ?? 0)))
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    /// SHA-256 over every file's relative path and bytes, in path order.
    public static func contentHash(of dir: URL) -> String {
        var h = SHA256()
        for f in files(in: dir) {
            h.update(data: Data(f.relativePath.utf8))
            h.update(data: Data([0]))
            if let d = try? Data(contentsOf: dir.appendingPathComponent(f.relativePath)) { h.update(data: d) }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a skill tree (regular files and folders only; a symlink fails, upstream `copyImportedSubdirectory`).
    static func copyTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let src = source.standardizedFileURL
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        else { throw SkillFileError.skillImportCopyFailed(path: src.lastPathComponent, reason: "Could not inspect directory") }
        let base = src.pathComponents
        for case let entry as URL in e {
            let rel = entry.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
            let v = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { throw SkillFileError.archiveEntryUnsupported(path: rel) }
            let target = destination.appendingPathComponent(rel)
            try ensureContained(target, in: destination)
            if v.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if v.isRegularFile == true {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: entry, to: target)
            } else {
                throw SkillFileError.archiveEntryUnsupported(path: rel)
            }
        }
    }

    /// Upstream `installStagedSkillDirectory`: move in place, or swap with a backup that is restored on failure.
    static func installStaged(_ stage: URL, to destination: URL, skillName: String, overwriteExisting: Bool) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw SkillFileError.skillImportCopyFailed(path: destination.lastPathComponent, reason: "Destination exists and is not a directory")
            }
            guard overwriteExisting else { throw SkillFileError.skillAlreadyExists(name: skillName) }
        }
        if !exists {
            try fm.moveItem(at: stage, to: destination)
            return
        }
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).import-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: stage, to: destination)
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: backup, to: destination)
            throw SkillFileError.skillImportCopyFailed(path: destination.lastPathComponent, reason: error.localizedDescription)
        }
    }

    /// Upstream `ensureContained`.
    static func ensureContained(_ fileURL: URL, in baseDirectory: URL) throws {
        // Resolved from the deepest folder that exists: a path that does not exist yet keeps `/private` where its
        // existing base loses it (/private/tmp, /private/var/tmp), and a new skill folder then looked like an escape.
        var existing = fileURL.standardized, tail: [String] = []
        while existing.pathComponents.count > 1, !FileManager.default.fileExists(atPath: existing.path) {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let f = tail.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.pathComponents
        let b = baseDirectory.standardized.resolvingSymlinksInPath().pathComponents
        guard f.count >= b.count, Array(f.prefix(b.count)) == b else { throw SkillFileError.archiveEntryEscapes(path: fileURL.path) }
    }
}
