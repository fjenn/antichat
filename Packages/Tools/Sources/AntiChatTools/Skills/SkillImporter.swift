// M7.T12 step 2 (R-082 AC1, R-261 AC1; P-files-tools-16): Add skill from a folder, a `.zip`, a `.skill` (a zip by
// another name) or a single SKILL.md. Nothing is installed here: `inspect` stages a validated copy in a temp folder
// and returns what the review sheet shows (full SKILL.md text, file list, compatibility, scripts note, allowed-tools);
// `install` moves it into the store after the user's [Install].
// Limits (vendored Osaurus `SkillImportPolicy`, AntiChat values): archive ≤ 50 MB, ≤ 500 files, ≤ 10 MB per file,
// ≤ 16 path levels; `..`, absolute paths, empty components and symlinks are refused before anything is extracted
// (zip-slip), and the extracted tree is scanned again. A folder import has the same tree scan plus a 50 MB total.
// The archive listing is ZIPFoundation (no `unzip` child process, UP-OS-043; R-265). No network anywhere here.
import AntiChatStorage
import Foundation
import OsaurusVendored
import ZIPFoundation

public struct SkillImportCandidate: Sendable, Identifiable {
    public let id = UUID()
    /// What the user picked.
    public let source: URL
    /// The staged skill folder (temp; consumed by `install`, removed by `discard`).
    public let stagedRoot: URL
    /// The frontmatter `name` (the folder name it installs under), or the source's base name when missing.
    public let name: String
    /// The SKILL.md text, unedited (shown in full before install).
    public let markdown: String
    public let document: SkillDocument?
    public let files: [SkillFileEntry]
    public let issues: [SkillIssue]
    /// Notes such as "ignored additional SKILL.md files" (upstream `SkillImportResult.notes`).
    public let notes: [String]

    public var compatibility: String? { document?.compatibility }
    public var allowedTools: [String] { document?.allowedTools ?? [] }
    public var hasScripts: Bool { InstalledSkill.hasScripts(files) }
    public var blockingIssue: SkillIssue? { issues.first(where: \.blocking) }
    public var canInstall: Bool { document != nil && blockingIssue == nil }

    /// Removes the staged copy (Cancel).
    public func discard() { try? FileManager.default.removeItem(at: stagedRoot.deletingLastPathComponent()) }
}

public enum SkillImporter {
    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case unsupported(String), tooLarge(Int64), notUTF8
        public var description: String {
            switch self {
            case .unsupported(let ext): "Unsupported file type: \(ext)"
            case .tooLarge(let n): "The skill is larger than the \(n / (1024 * 1024)) MB limit"
            case .notUTF8: "SKILL.md is not readable UTF-8 text"
            }
        }
    }

    /// The M7.T12 step 1 limits on the vendored policy (upstream defaults: 512 entries).
    public static let policy = SkillImportPolicy(maxArchiveBytes: 50 * 1024 * 1024, maxEntryBytes: 10 * 1024 * 1024,
                                                 maxEntryCount: 500, maxPathDepth: 16)

    /// Folders, archives and markdown the Add skill panel accepts.
    public static let archiveExtensions: Set<String> = ["zip", "skill"]

    /// Stages and validates `url` (folder, .zip/.skill, or a markdown file). Throws on a limit, a path that escapes,
    /// a symlink or a missing SKILL.md; validation findings come back in `issues` (the sheet shows them).
    public static func inspect(_ url: URL, policy: SkillImportPolicy = policy) throws -> SkillImportCandidate {
        installArchiveReader()
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("antichat-skill-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw CocoaError(.fileNoSuchFile) }
            if isDir.boolValue {
                return try fromTree(url, folderName: nil, source: url, work: work, policy: policy, checkTotal: true)
            }
            let ext = url.pathExtension.lowercased()
            if archiveExtensions.contains(ext) {
                try policy.validateArchiveBeforeExtraction(url)
                let extracted = work.appendingPathComponent("extracted", isDirectory: true)
                try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: extracted)
                try? fm.removeItem(at: extracted.appendingPathComponent("__MACOSX"))  // Finder resource forks
                return try fromTree(extracted, folderName: url.deletingPathExtension().lastPathComponent, source: url,
                                    work: work, policy: policy, checkTotal: false)
            }
            if ext == "md" || ext == "markdown" {
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= policy.maxEntryBytes else { throw SkillFileError.archiveEntryTooLarge(path: url.lastPathComponent, limitBytes: policy.maxEntryBytes) }
                guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw ImportError.notUTF8 }
                let doc = try? SkillDocument(markdown: text)
                let name = doc?.name.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
                let stage = work.appendingPathComponent(safeFolderName(name), isDirectory: true)
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                try text.write(to: stage.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                return candidate(stage: stage, folderName: nil, source: url, notes: [])
            }
            throw ImportError.unsupported(ext.isEmpty ? url.lastPathComponent : ext)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Installs a reviewed candidate (the user pressed Install). Re-adding a name replaces that skill's folder.
    /// `source` = the catalogue entry it was downloaded from (kept with the skill, so it can be updated later).
    @discardableResult
    public static func install(_ c: SkillImportCandidate, into store: SkillStore, trust: SkillRecord.Trust = .user,
                               source: SkillsCatalog.Skill? = nil) throws -> InstalledSkill {
        guard c.canInstall else { throw SkillFileError.invalidSkillArchive }
        defer { c.discard() }
        return try store.install(from: c.stagedRoot, name: c.name, trust: trust, source: source)
    }

    /// Replaces the installed skill of the candidate's name with it: a newer version of `source` from the catalogue
    /// (`SkillStore.update`: the old copy comes back on any failure, the switches stay as they are).
    @discardableResult
    public static func update(_ c: SkillImportCandidate, into store: SkillStore, source: SkillsCatalog.Skill) throws -> InstalledSkill {
        defer { c.discard() }
        guard c.canInstall, c.name == source.name else { throw SkillFileError.invalidSkillArchive }
        return try store.update(c.name, from: c.stagedRoot, source: source)
    }

    // MARK: -

    /// A folder or an extracted archive: tree scan (limits, symlinks, containment), the shallowest SKILL.md is the
    /// skill, its folder is copied to the stage under the skill's name.
    static func fromTree(_ root: URL, folderName: String?, source: URL, work: URL, policy: SkillImportPolicy,
                         checkTotal: Bool) throws -> SkillImportCandidate {
        let plan = try policy.scanExtractedTree(at: root)
        if checkTotal {
            let total = SkillStore.files(in: plan.skillRootURL).reduce(Int64(0)) { $0 + $1.size }
            guard total <= policy.maxArchiveBytes else { throw SkillFileError.archiveTooLarge(limitBytes: policy.maxArchiveBytes) }
        }
        // The folder the skill sits in: SKILL.md at an archive's root → the archive's base name.
        let isRoot = plan.skillRootURL.standardizedFileURL.path == root.standardizedFileURL.path
        let dirName = isRoot ? (folderName ?? root.lastPathComponent) : plan.skillRootURL.lastPathComponent
        let text = (try? String(contentsOf: plan.skillMarkdownURL, encoding: .utf8)) ?? ""
        let name = (try? SkillDocument(markdown: text))?.name.flatMap { $0.isEmpty ? nil : $0 } ?? dirName
        let stage = work.appendingPathComponent("staged", isDirectory: true).appendingPathComponent(safeFolderName(name), isDirectory: true)
        try SkillStore.copyTree(from: plan.skillRootURL, to: stage)
        var notes: [String] = []
        if !plan.ignoredSkillMarkdownPaths.isEmpty {
            notes.append("Imported \(plan.selectedSkillMarkdownPath); ignored additional SKILL.md files: \(plan.ignoredSkillMarkdownPaths.joined(separator: ", "))")
        }
        return candidate(stage: stage, folderName: dirName, source: source, notes: notes)
    }

    static func candidate(stage: URL, folderName: String?, source: URL, notes: [String]) -> SkillImportCandidate {
        let files = SkillStore.files(in: stage)
        let md = SkillValidator.skillMarkdown(in: stage)
        let text = md.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var issues: [SkillIssue] = []
        var doc: SkillDocument?
        if md == nil {
            issues.append(SkillIssue(kind: .other, message: "Missing required file: SKILL.md"))
        } else {
            do {
                let d = try SkillDocument(markdown: text)
                doc = d
                // The folder-name rule checks the folder the user gave (a single SKILL.md has none: it gets one).
                issues = SkillValidator.validate(d, directoryName: folderName ?? d.name)
            } catch let e as SkillDocument.ParseError {
                issues.append(SkillIssue(kind: .other, message: e.description))
            } catch {
                issues.append(SkillIssue(kind: .other, message: "\(error)"))
            }
        }
        return SkillImportCandidate(source: source, stagedRoot: stage, name: stage.lastPathComponent, markdown: text,
                                    document: doc, files: files, issues: issues, notes: notes)
    }

    /// A folder name that cannot escape the Skills root (the validator reports the real problem with the name).
    static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "skill" : String(cleaned.prefix(128))
    }

    /// The vendored policy lists archives through this hook (UP-OS-043): ZIPFoundation's central directory, symlink
    /// entries refused here (they would extract as links).
    static func installArchiveReader() { _ = readerInstalled }

    private static let readerInstalled: Void = {
        SkillArchiveHooks.listEntries = { url in
            let archive: Archive
            do { archive = try Archive(url: url, accessMode: .read) } catch {
                throw SkillFileError.archiveListingFailed("not a zip archive")
            }
            return try archive.map { entry -> (name: String, uncompressedSize: Int64) in
                if entry.type == .symlink { throw SkillFileError.archiveEntryUnsupported(path: entry.path) }
                return (entry.path, Int64(entry.uncompressedSize))
            }
        }
    }()
}
