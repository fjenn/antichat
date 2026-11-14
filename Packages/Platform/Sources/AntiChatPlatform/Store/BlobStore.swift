// Ported from ollama/ollama@4d22e65:manifest/layer.go (MIT) — temp file → streaming sha256 → rename into the
// blob directory — and manifest/paths.go (digest validation). M2.T08/T10 (R-293 AC1, NFR-D5; blueprint E §E.2.6).
// Layout under `<Models>`:
//   store/sha256/<aa>/<hash>   one read-only file per unique sha256 (Normal/Evil/packs share it)
//   partial/<hash>.part|.bitmap downloads in flight (same volume, so commit is a rename(2))
//   installs/<model-id>/        install views (InstallView, T10)
import Darwin
import Foundation

/// The Models folder and its fixed sub-directories.
public struct ModelsDirectory: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    public var store: URL { root.appending(path: "store/sha256", directoryHint: .isDirectory) }
    public var partial: URL { root.appending(path: "partial", directoryHint: .isDirectory) }
    public var installs: URL { root.appending(path: "installs", directoryHint: .isDirectory) }

    public func part(_ sha: String) -> URL { partial.appending(path: "\(sha).part") }
    public func bitmap(_ sha: String) -> URL { partial.appending(path: "\(sha).bitmap") }

    /// `~/Library/Application Support/AntiChat/Models` (`…/AntiChat-Dev/Models` in Debug, or `<dev container>/Models`).
    /// M8.T10: a moved Models folder (Settings › Storage › Move…) is followed through its bookmark; while its drive
    /// is not connected the starter kept in `Models-internal` serves (`ModelsFolderLocation.State.missing`).
    public static func `default`(container: URL, location: ModelsFolderLocation = ModelsFolderLocation()) -> ModelsDirectory {
        switch location.resolve() {
        case .standard: ModelsDirectory(root: container.appending(path: "Models", directoryHint: .isDirectory))
        case .moved(let url): ModelsDirectory(root: url)
        case .missing: ModelsDirectory(root: container.appending(path: "Models-internal", directoryHint: .isDirectory))
        }
    }

    /// Creates the folders and excludes the Models folder from Time Machine (NFR-D9; chats and settings stay included).
    public func create() throws {
        for d in [store, partial, installs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try excludeFromBackup()
    }

    /// `isExcludedFromBackup = true` on the Models folder — at creation and on every launch (NFR-D9).
    public func excludeFromBackup() throws {
        var u = root
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try u.setResourceValues(v)
    }

    /// Read from the file system, not from `root`'s resource-value cache: URL copies share one cache that never sees a
    /// change made through another URL object (another process, Finder, `tmutil`), so a long-lived `ModelsDirectory`
    /// would keep reporting the value it read first. The flag itself is eventually consistent on macOS 26: a read right
    /// after `setResourceValues` can still return the previous value for a few ms (measured ≤ 35 ms at load ~30).
    public var isExcludedFromBackup: Bool {
        var u = root
        u.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        return (try? u.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}

public enum BlobStoreError: Error, Equatable, Sendable {
    case badDigest(String)
    case missingPartial(String)
    case digestMismatch(expected: String, actual: String)
}

public struct BlobStore: Sendable {
    public let models: ModelsDirectory
    public init(models: ModelsDirectory) { self.models = models }

    public func url(_ sha: String) -> URL {
        models.store.appending(path: String(sha.prefix(2)), directoryHint: .isDirectory).appending(path: sha)
    }

    public func contains(_ sha: String) -> Bool { Verify.isSHA256Hex(sha) && FileManager.default.fileExists(atPath: url(sha).path) }

    /// Moves a verified part into the store: digest format check, `rename(2)` (same volume), read-only (0444).
    /// Idempotent: when the blob already exists the part is deleted and the existing blob kept. `verify` re-hashes
    /// the part first (callers that just hashed it pass false).
    @discardableResult
    public func commit(partial: URL, sha256: String, verify: Bool = false) throws -> URL {
        guard Verify.isSHA256Hex(sha256) else { throw BlobStoreError.badDigest(sha256) }
        let fm = FileManager.default
        let dest = url(sha256)
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: partial)
            return dest
        }
        guard fm.fileExists(atPath: partial.path) else { throw BlobStoreError.missingPartial(partial.path) }
        if verify {
            let actual = try Verify.sha256(partial)
            guard actual == sha256 else { throw BlobStoreError.digestMismatch(expected: sha256, actual: actual) }
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(partial.path, 0o444)
        if rename(partial.path, dest.path) != 0 {
            let e = errno
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: partial); return dest }  // lost a race: same bytes
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        return dest
    }

    /// Every blob digest in the store.
    public func all() -> [String] {
        guard let e = FileManager.default.enumerator(at: models.store, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.lastPathComponent }.filter(Verify.isSHA256Hex)
    }

    public func remove(_ sha: String) throws {
        guard Verify.isSHA256Hex(sha) else { throw BlobStoreError.badDigest(sha) }
        let u = url(sha)
        chmod(u.path, 0o644)
        try FileManager.default.removeItem(at: u)
    }
}
