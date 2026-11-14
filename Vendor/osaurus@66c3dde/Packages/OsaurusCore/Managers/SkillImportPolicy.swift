//
//  SkillImportPolicy.swift
//  osaurus
//
//  Guardrails for importing third-party skill archives before they enter the
//  persisted skill store.
//

import Darwin
import Foundation

/// Import limits for a third-party skill bundle. The defaults are intentionally
/// generous for normal skill packs while still bounding the user-clicked ZIP
/// path before extraction and again before persistence.
public struct SkillImportPolicy: Sendable, Equatable {
    public static let `default` = SkillImportPolicy()

    public let maxArchiveBytes: Int64
    public let maxEntryBytes: Int64
    public let maxEntryCount: Int
    public let maxPathDepth: Int

    public init(
        maxArchiveBytes: Int64 = 50 * 1024 * 1024,
        maxEntryBytes: Int64 = 10 * 1024 * 1024,
        maxEntryCount: Int = 512,
        maxPathDepth: Int = 16
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntryBytes = maxEntryBytes
        self.maxEntryCount = maxEntryCount
        self.maxPathDepth = maxPathDepth
    }

    public func validateArchiveBeforeExtraction(_ zipURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard archiveBytes <= maxArchiveBytes else {
            throw SkillFileError.archiveTooLarge(limitBytes: maxArchiveBytes)
        }

        let entries = try Self.listArchiveEntries(in: zipURL)
        try validateArchiveEntries(entries)
    }

    func validateArchiveEntries(_ entries: [SkillArchiveEntry]) throws {
        guard entries.count <= maxEntryCount else {
            throw SkillFileError.archiveEntryLimitExceeded(limit: maxEntryCount)
        }

        for entry in entries {
            try validateArchivePath(entry.name)
            if !entry.isDirectory, entry.uncompressedSize > maxEntryBytes {
                throw SkillFileError.archiveEntryTooLarge(path: entry.name, limitBytes: maxEntryBytes)
            }
        }
    }

    func validateArchiveEntryNames(_ names: [String]) throws {
        try validateArchiveEntries(names.map { SkillArchiveEntry(name: $0, uncompressedSize: 0) })
    }

    public func scanExtractedTree(at rootURL: URL) throws -> SkillImportPlan {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var fileCount = 0
        var skillMarkdowns: [String] = []

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw SkillFileError.invalidSkillArchive
        }

        for case let entry as URL in enumerator {
            let relativePath = try relativePath(for: entry, in: root)
            try validateArchivePath(relativePath)

            let values = try entry.resourceValues(
                forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw SkillFileError.archiveEntryUnsupported(path: relativePath)
            }

            let resolvedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolvedEntry, in: resolvedRoot) else {
                throw SkillFileError.archiveEntryEscapes(path: relativePath)
            }

            if values.isDirectory == true {
                continue
            }

            guard values.isRegularFile == true else {
                throw SkillFileError.archiveEntryUnsupported(path: relativePath)
            }

            fileCount += 1
            guard fileCount <= maxEntryCount else {
                throw SkillFileError.archiveEntryLimitExceeded(limit: maxEntryCount)
            }

            let fileSize = Int64(values.fileSize ?? 0)
            guard fileSize <= maxEntryBytes else {
                throw SkillFileError.archiveEntryTooLarge(path: relativePath, limitBytes: maxEntryBytes)
            }

            if entry.lastPathComponent == "SKILL.md" {
                skillMarkdowns.append(relativePath)
            }
        }

        guard let selected = Self.selectedSkillMarkdown(from: skillMarkdowns) else {
            throw SkillFileError.invalidSkillArchive
        }

        let ignored = skillMarkdowns.filter { $0 != selected }.sorted()
        let skillMarkdownURL = root.appendingPathComponent(selected)
        return SkillImportPlan(
            skillMarkdownURL: skillMarkdownURL,
            skillRootURL: skillMarkdownURL.deletingLastPathComponent(),
            selectedSkillMarkdownPath: selected,
            ignoredSkillMarkdownPaths: ignored
        )
    }

    private func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }
        guard components.count <= maxPathDepth else {
            throw SkillFileError.archiveEntryTooDeep(path: path, limit: maxPathDepth)
        }
    }

    private func relativePath(for fileURL: URL, in baseDirectory: URL) throws -> String {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func selectedSkillMarkdown(from paths: [String]) -> String? {
        paths.min { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs < rhs
        }
    }

    private static func isContained(_ fileURL: URL, in baseDirectory: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        return fileComponents.count >= baseComponents.count
            && Array(fileComponents.prefix(baseComponents.count)) == baseComponents
    }

    // ANTICHAT-PATCH: UP-OS-043 no `/usr/bin/unzip -l` child process (R-265: AntiChat spawns no process for skills);
    // the archive listing comes from `SkillArchiveHooks.listEntries` (AntiChatTools installs a ZIPFoundation reader).
    private static func listArchiveEntries(in zipURL: URL) throws -> [SkillArchiveEntry] {
        guard let list = SkillArchiveHooks.listEntries else {
            throw SkillFileError.archiveListingFailed("no archive reader installed")
        }
        do {
            return try list(zipURL).map { SkillArchiveEntry(name: $0.name, uncompressedSize: $0.uncompressedSize) }
        } catch let error as SkillFileError {
            throw error
        } catch {
            throw SkillFileError.archiveListingFailed(error.localizedDescription)
        }
    }
    // ANTICHAT-PATCH-END
}

struct SkillArchiveEntry: Sendable, Equatable {
    let name: String
    let uncompressedSize: Int64

    var isDirectory: Bool {
        name.hasSuffix("/")
    }
}

public struct SkillImportPlan: Sendable, Equatable {
    public let skillMarkdownURL: URL
    public let skillRootURL: URL
    public let selectedSkillMarkdownPath: String
    public let ignoredSkillMarkdownPaths: [String]
}

public struct SkillImportResult: Sendable, Equatable {
    public let skill: Skill
    public let notes: [String]
}

// ANTICHAT-PATCH: UP-OS-043 the archive listing hook (replaces SkillArchiveProcessRunner and its output readers)
/// How a skill archive's entries are listed (name as stored, uncompressed size; directories end in "/").
/// Set once by the host before an import; nil = archive imports fail with `archiveListingFailed`.
package enum SkillArchiveHooks {
    nonisolated(unsafe) package static var listEntries: (@Sendable (URL) throws -> [(name: String, uncompressedSize: Int64)])?
}
// ANTICHAT-PATCH-END

// ANTICHAT-PATCH: UP-OS-044 `SkillFileError` copied from Managers/SkillManager.swift:12-62 (SkillManager is not vendored)
public enum SkillFileError: Error, LocalizedError, Sendable {
    case cannotModifyBuiltIn
    case cannotModifyPluginSkill
    case skillNotFound
    case exportFailed
    case invalidSkillArchive
    case archiveTooLarge(limitBytes: Int64)
    case archiveEntryTooLarge(path: String, limitBytes: Int64)
    case archiveEntryLimitExceeded(limit: Int)
    case archiveEntryTooDeep(path: String, limit: Int)
    case archiveEntryEscapes(path: String)
    case archiveEntryUnsupported(path: String)
    case archiveListingFailed(String)
    case skillAlreadyExists(name: String)
    case skillImportCopyFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotModifyBuiltIn: return L("Cannot modify built-in skills")
        case .cannotModifyPluginSkill: return L("Cannot modify plugin-provided skills")
        case .skillNotFound: return L("Skill not found")
        case .exportFailed: return L("Failed to export skill")
        case .invalidSkillArchive: return L("Invalid skill archive - SKILL.md not found")
        case .archiveTooLarge(let limitBytes):
            return L("Skill archive is larger than the \(Self.formatBytes(limitBytes)) limit")
        case .archiveEntryTooLarge(let path, let limitBytes):
            return L("Skill archive entry \"\(path)\" is larger than the \(Self.formatBytes(limitBytes)) limit")
        case .archiveEntryLimitExceeded(let limit):
            return L("Skill archive contains more than \(limit) entries")
        case .archiveEntryTooDeep(let path, let limit):
            return L("Skill archive entry \"\(path)\" is deeper than the \(limit)-level limit")
        case .archiveEntryEscapes(let path):
            return L("Skill archive entry \"\(path)\" escapes the archive root")
        case .archiveEntryUnsupported(let path):
            return L("Skill archive entry \"\(path)\" is not a regular file or directory")
        case .archiveListingFailed(let details):
            let suffix = details.isEmpty ? "" : ": \(details)"
            return L("Could not inspect skill archive\(suffix)")
        case .skillAlreadyExists(let name):
            return L("A skill named \"\(name)\" already exists")
        case .skillImportCopyFailed(let path, let reason):
            return L("Could not import skill file \"\(path)\": \(reason)")
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}
// ANTICHAT-PATCH-END
