// "@" path completion for the composer (M1.T17 step 2; G-006, P-shell-06 RL-005 IMPROVE).
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Models/Chat/AtFileMenu.swift (MIT); logic unchanged,
// comments shortened. In AntiChat "@" opens the same tool list as "+" (IS-6, ChatGPT F-027); only when the text after "@" is
// a path (`@/…`, `@~/…`) does the menu browse the file system with this resolver, and a picked file joins the composer
// tray as a file tile (M1: not read; file intake is M6, C-018). `rootPath` is the project folder once projects land
// (M8); until then relative queries resolve against the home directory.
// Synchronous file-system I/O: call it off the main actor (ComposerMenus lists on a detached task).
import Foundation

/// Outcome of enumerating a directory for the "@" menu: an empty folder, a folder macOS (TCC) blocked, or a path
/// that does not exist.
public enum AtFileMenuStatus: Sendable, Equatable {
    /// The directory was read (it may still contain zero matching entries).
    case ok
    /// The OS denied access (typically a TCC-protected folder whose prompt was declined).
    case denied
    /// The directory doesn't exist or isn't a directory.
    case notFound
}

/// Result of one "@" listing: the rows, the outcome, and the resolved directory.
public struct AtFileMenuResult: Sendable, Equatable {
    public let items: [AtFileItem]
    public let status: AtFileMenuStatus
    public let directory: String

    public init(items: [AtFileItem], status: AtFileMenuStatus, directory: String) {
        self.items = items
        self.status = status
        self.directory = directory
    }
}

/// A single row in the "@" file menu.
public struct AtFileItem: Identifiable, Equatable, Sendable {
    public let name: String
    /// Absolute path on disk.
    public let path: String
    public let isDirectory: Bool

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// Pure resolver + directory lister. Stateless static methods, not actor-isolated.
public enum AtFileMenu {
    /// Upper bound on rows handed to the popup.
    public static let maxResults = 50

    /// Whether the text typed after "@" is a path (AntiChat addition: otherwise "@" filters the tool list).
    public static func isPathQuery(_ query: String) -> Bool { query.hasPrefix("/") || query.hasPrefix("~") }

    /// Splits a raw `@` query into the directory to enumerate and the partial leaf name to filter by.
    /// - Parameters:
    ///   - query: text typed after `@`, e.g. "", "~/Doc", "src/", "/etc/ho".
    ///   - rootPath: relative queries resolve against it, falling back to the home directory when nil.
    public static func resolve(query: String, rootPath: URL?) -> (dir: URL, filter: String) {
        let expanded: String
        if query.hasPrefix("/") {
            expanded = query
        } else if query.hasPrefix("~") {
            expanded = (query as NSString).expandingTildeInPath
        } else {
            let root = rootPath ?? URL(fileURLWithPath: NSHomeDirectory())
            expanded = query.isEmpty ? root.path : root.appendingPathComponent(query).path
        }

        // A trailing slash (or an empty query) means "list this directory"; otherwise the final path component is a
        // partial name to filter by.
        if query.isEmpty || query.hasSuffix("/") {
            return (URL(fileURLWithPath: expanded, isDirectory: true), "")
        }
        let url = URL(fileURLWithPath: expanded)
        return (url.deletingLastPathComponent(), url.lastPathComponent)
    }

    /// Enumerates the directory implied by `query`, filtered by its partial leaf name. Directories sort before
    /// files, then case-insensitive alphabetical. Blocking file-system I/O: call off the main actor.
    public static func list(query: String, rootPath: URL?) -> AtFileMenuResult {
        let (dir, filter) = resolve(query: query, rootPath: rootPath)
        let lowerFilter = filter.lowercased()

        // Show dotfiles only once the user starts typing a leading dot.
        let options: FileManager.DirectoryEnumerationOptions = filter.hasPrefix(".") ? [] : [.skipsHiddenFiles]

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: options)
        } catch {
            return AtFileMenuResult(items: [], status: classify(error), directory: dir.path)
        }

        var items: [AtFileItem] = []
        items.reserveCapacity(entries.count)
        for url in entries {
            let name = url.lastPathComponent
            if !lowerFilter.isEmpty && !name.lowercased().hasPrefix(lowerFilter) { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            items.append(AtFileItem(name: name, path: url.path, isDirectory: isDir))
        }

        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        let capped = items.count > maxResults ? Array(items.prefix(maxResults)) : items
        return AtFileMenuResult(items: capped, status: .ok, directory: dir.path)
    }

    /// Maps a `contentsOfDirectory` failure onto a menu status: a permission denial (TCC or POSIX) is told apart
    /// from a missing path.
    private static func classify(_ error: Error) -> AtFileMenuStatus {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError { return .denied }
            if nsError.code == NSFileReadNoSuchFileError { return .notFound }
        }
        // Cocoa often wraps the raw POSIX error; check it too (EPERM/EACCES).
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return .denied
        }
        return .notFound
    }
}
