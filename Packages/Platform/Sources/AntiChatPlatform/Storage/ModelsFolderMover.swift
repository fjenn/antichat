// M8.T10 step 4 (R-205 AC3/AC7, NFR-D2 rule, NFR-D9): Settings › Storage › Models folder › Move…. Preflight (free space
// ≥ folder + 10 GB) → copy the store, manifests and install views with progress, sha256-verify every blob at the
// destination against its name → persist the bookmark (`ModelsFolderLocation`) → exclude the new folder from Time
// Machine → keep the starter chat model (+ its tokenizer files: the whole install) on the internal disk in
// `<container>/Models-internal` → delete the old copies. Any failure before the bookmark is written deletes the partial
// copy and leaves the old folder as it was (`storage.move.failed`). The caller evicts every model first and blocks
// loads until the move returns (the helper holds mmaps of the old files).
import AntiChatStorage
import CryptoKit
import Foundation

public enum ModelsFolderMoveError: Error, Equatable, Sendable {
    case notEnoughSpace(need: Int64, free: Int64)
    case destinationNotEmpty
    case verifyFailed(String)
    case copyFailed(String)
}

public struct ModelsFolderMover: Sendable {
    public let source: ModelsDirectory
    /// `<container>/Models-internal` (the starter stays here).
    public let internalRoot: URL
    /// Install ids kept internal (the starter chat model `chat-0.8b` by default).
    public let keepInternal: Set<String>
    public var reserveBytes: Int64 = 10_000_000_000
    /// Test hook: throw after this many files were copied (failure injection).
    public var failAfterFiles: Int?

    public init(source: ModelsDirectory, internalRoot: URL, keepInternal: Set<String> = ["chat-0.8b"]) {
        self.source = source; self.internalRoot = internalRoot; self.keepInternal = keepInternal
    }

    public struct Result: Sendable, Equatable {
        public var destination: URL
        public var copiedFiles: Int
        public var verifiedBlobs: Int
        public var keptInternal: [String]
    }

    /// Moves the Models folder into `parent/Models` (or into `parent` itself when it is an empty folder named Models).
    public func move(to parent: URL, location: ModelsFolderLocation, progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        let dest = parent.lastPathComponent == "Models" ? parent : parent.appendingPathComponent("Models", isDirectory: true)
        // RC review P2-5: a destination inside the current folder would be deleted with "the old copies" after the
        // commit (and copied into itself on the way). It is not an empty place to move to.
        let srcPath = source.root.resolvingSymlinksInPath().standardizedFileURL.path
        let destPath = dest.resolvingSymlinksInPath().standardizedFileURL.path
        if destPath == srcPath || destPath.hasPrefix(srcPath + "/") { throw ModelsFolderMoveError.destinationNotEmpty }
        if let items = try? fm.contentsOfDirectory(atPath: dest.path), !items.filter({ !$0.hasPrefix(".") }).isEmpty {
            throw ModelsFolderMoveError.destinationNotEmpty
        }
        let files = Self.files(source.root)
        let total = files.reduce(Int64(0)) { $0 + Self.size($1) }
        let free = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard free >= total + reserveBytes else { throw ModelsFolderMoveError.notEnoughSpace(need: total + reserveBytes, free: free) }
        let createdDest = !fm.fileExists(atPath: dest.path)
        var copied = 0, verified = 0
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            var done: Int64 = 0
            for f in files {
                let rel = String(f.path.dropFirst(source.root.path.count + 1))
                let to = dest.appendingPathComponent(rel)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let fail = failAfterFiles, copied >= fail { throw ModelsFolderMoveError.copyFailed("injected after \(copied)") }
                do { try fm.copyItem(at: f, to: to) } catch { throw ModelsFolderMoveError.copyFailed("\(rel): \(error.localizedDescription)") }
                copied += 1
                if rel.hasPrefix("store/sha256/") {
                    guard try Self.sha256(to) == f.lastPathComponent else { throw ModelsFolderMoveError.verifyFailed(rel) }
                    verified += 1
                }
                done += Self.size(f)
                progress(total > 0 ? Double(done) / Double(total) : 1)
            }
            try ModelsDirectory(root: dest).excludeFromBackup()
            // The starter stays internal: its install view + blobs + manifest in Models-internal.
            try keepStarter()
            try location.persist(dest)
        } catch {
            if createdDest { try? fm.removeItem(at: dest) } else { for f in Self.files(dest) { try? fm.removeItem(at: f) } }
            throw error
        }
        // Committed: the old copies go (the source folder itself stays empty only when it is not the container's).
        for name in (try? fm.contentsOfDirectory(atPath: source.root.path)) ?? [] {
            try? fm.removeItem(at: source.root.appendingPathComponent(name))
        }
        try? fm.removeItem(at: source.root)
        progress(1)
        return Result(destination: dest, copiedFiles: copied, verifiedBlobs: verified, keptInternal: keepInternal.sorted())
    }

    /// Copies the starter's install view, manifest and blobs into `Models-internal` (replacing an older copy).
    func keepStarter() throws {
        let fm = FileManager.default
        let internalDir = ModelsDirectory(root: internalRoot)
        for id in keepInternal {
            let view = source.install(id)
            guard let m = InstallManifest.load(view.appending(path: "manifest.json")) else { continue }
            try fm.createDirectory(at: internalDir.installs, withIntermediateDirectories: true)
            try fm.createDirectory(at: internalDir.manifests, withIntermediateDirectories: true)
            for sha in m.blobs {
                let from = BlobStore(models: source).url(sha), to = BlobStore(models: internalDir).url(sha)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: to)
            }
            let dst = internalDir.install(id)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: view, to: dst)  // relative symlinks into store/ resolve inside Models-internal too
            let mf = internalDir.manifest(m.sha256)
            if !fm.fileExists(atPath: mf.path) { try m.encoded().write(to: mf) }
        }
    }

    /// Regular files and symlinks under `root`, sorted (directories are recreated on the way).
    static func files(_ root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { u in
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return v?.isRegularFile == true || v?.isSymbolicLink == true
        }.map(\.standardizedFileURL).sorted { $0.path < $1.path }
    }

    static func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return Verify.hex(hasher.finalize())
    }
}
