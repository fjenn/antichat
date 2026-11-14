// M6.T16 step 3–4 (R-018 AC1; architecture §5.3, §9.1; A-M6-11): the generic installer of downloadable runtime
// components — File tools now, the video runtime in M5.T01 (D-026: adopt, never fork; nothing here knows what runs
// inside a runtime). Flow: NFR-D2 disk preflight (download + 10 GB) → C-007 download with resume (TransferEngine:
// sha256 verify, one re-fetch on a mismatch) → unzip into a staging folder next to the target → refuse any entry
// that escapes the folder → every Mach-O and framework bundle must pass SecStaticCodeCheckValidity (strict, all
// architectures) → atomic rename to `Runtimes/<name>@<version>/` → `runtime_install` row → older versions removed.
//
// The Runtimes root is `~/Library/Application Support/AntiChat/Runtimes` (Debug: `AntiChat-Dev/Runtimes`) and never
// follows `-ANTICHAT_DEV_CONTAINER`: the sandboxed FileTools XPC can read exactly these two paths through its
// home-relative read-only exception (A-M6-11). The app never writes into the service's container.
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Security

public enum RuntimeInstallError: Error, Equatable, Sendable {
    /// The catalog lists no runtime of that name (or none for this app version / tier).
    case notInCatalog(String)
    /// NFR-D2: free space < download + 10 GB. `download.diskFull` "Needs {gb} GB more free space."
    case diskFull(gbNeeded: Int, neededBytes: Int64, availableBytes: Int64)
    /// The zip did not match the catalog sha256 after the one re-fetch (`download.failed`).
    case verifyFailed(expected: String, actual: String)
    /// Every source answered 404/410 (`download.unavailable`).
    case unavailable
    /// The Network gate refused the request (Offline only).
    case blocked
    case http(Int)
    /// The archive could not be unpacked, or an entry points outside the runtime folder.
    case badArchive(String)
    /// A Mach-O or bundle in the runtime failed strict signature validation (`status` = OSStatus).
    case badSignature(path: String, status: Int32)

    /// The copy-deck key shown for the failure.
    public var copyKey: String {
        switch self {
        case .diskFull: "download.diskFull"
        case .unavailable, .notInCatalog: "download.unavailable"
        case .blocked: "add.disabled.offline"
        default: "download.failed"
        }
    }
}

/// Where runtime components live (architecture §5.3).
public struct RuntimePaths: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    /// `~/Library/Application Support/AntiChat[-Dev]/Runtimes` — fixed, see the file header (A-M6-11).
    public static func `default`(debug: Bool = AppDatabase.isDebugBuild) -> RuntimePaths {
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return RuntimePaths(root: support.appending(path: "\(AppDatabase.defaultContainerName(debug: debug))/Runtimes", directoryHint: .isDirectory))
    }

    public func folder(name: String, version: String) -> URL { root.appending(path: "\(name)@\(version)", directoryHint: .isDirectory) }
    public func folder(_ r: CatalogRuntime) -> URL { folder(name: r.name, version: r.version) }
    /// Resumable download parts (`partial/<sha>.part`, TransferEngine's layout).
    var downloads: ModelsDirectory { ModelsDirectory(root: root.appending(path: ".download", directoryHint: .isDirectory)) }
    var staging: URL { root.appending(path: ".staging", directoryHint: .isDirectory) }
}

/// An installed runtime: its folder and the catalog facts it was verified against.
public struct InstalledRuntime: Sendable, Equatable {
    public var name: String
    public var version: String
    public var url: URL
    public var sha256: String
    public var installedAt: Date
}

public final class RuntimeInstaller: Sendable {
    /// Fetches a verified file and returns its local URL (default: `TransferEngine.download`).
    public typealias Fetch = @Sendable (DownloadRequest, @escaping @Sendable (Int64) -> Void) async throws -> URL
    /// Strict code-signature check of one Mach-O file or bundle; `errSecSuccess` = valid.
    public typealias Validator = @Sendable (URL) -> OSStatus

    public let paths: RuntimePaths
    public let registry: RuntimeRegistry
    let fetch: Fetch
    let freeBytes: @Sendable () -> Int64
    let validate: Validator

    public init(paths: RuntimePaths = .default(), registry: RuntimeRegistry, fetch: Fetch? = nil,
                freeBytes: (@Sendable () -> Int64)? = nil, validate: @escaping Validator = RuntimeInstaller.checkSignature) {
        self.paths = paths
        self.registry = registry
        let downloads = paths.downloads
        self.fetch = fetch ?? { request, progress in
            #if ANTICHAT_TRYOUT_PREVIEW
            if let local = try TryoutPreview.stageBundledRuntime(request, into: downloads.partial) { progress(request.size); return local }
            #endif
            return try await TransferEngine(models: downloads).download(request, progress: progress)
        }
        let root = paths.root
        self.freeBytes = freeBytes ?? { DiskPreflight.freeBytes(volume: root.deletingLastPathComponent()) }
        self.validate = validate
    }

    // MARK: Query

    /// The installed version of `name`, if its row exists and its folder is still on disk.
    public func installed(_ name: String) -> InstalledRuntime? {
        guard let r = registry.record(name), FileManager.default.fileExists(atPath: r.path) else { return nil }
        return InstalledRuntime(name: r.id, version: r.version, url: URL(fileURLWithPath: r.path, isDirectory: true), sha256: r.sha256,
                                installedAt: r.installedAt)
    }

    /// True when `runtime` (that exact version and sha256) is installed.
    public func isCurrent(_ runtime: CatalogRuntime) -> Bool {
        guard let i = installed(runtime.name) else { return false }
        return i.version == runtime.version && i.sha256 == runtime.sha256
    }

    // MARK: Install

    /// Installs `runtime` (no-op when that version is already installed). `progress` gets the bytes on disk.
    @discardableResult
    public func install(_ runtime: CatalogRuntime, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> InstalledRuntime {
        if isCurrent(runtime), let i = installed(runtime.name) { return i }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)

        // NFR-D2 preflight: free ≥ download + 10 GB (the headroom covers the unpacked tree, ~3× the zip).
        let free = freeBytes()
        if case .short(let gb) = DiskPreflight.check(total: runtime.sizeBytes, free: free) {
            throw RuntimeInstallError.diskFull(gbNeeded: gb, neededBytes: runtime.sizeBytes + DiskPreflight.headroomBytes, availableBytes: free)
        }

        guard let source = URL(string: runtime.url) else { throw RuntimeInstallError.notInCatalog(runtime.name) }
        let request = DownloadRequest(sha256: runtime.sha256, size: runtime.sizeBytes, sources: [source], pack: runtime.name)
        let zip: URL
        do {
            zip = try await fetch(request, progress)
        } catch let e as TransferError {
            switch e {
            case .checksum(let expected, let actual): throw RuntimeInstallError.verifyFailed(expected: expected, actual: actual)
            case .unavailable: throw RuntimeInstallError.unavailable
            case .blocked: throw RuntimeInstallError.blocked
            case .http(let code): throw RuntimeInstallError.http(code)
            case .paused: throw CancellationError()
            }
        }
        // Defence in depth: the fetcher verified it; a custom fetcher must not be able to skip it.
        let actual = try Verify.sha256(zip)
        guard actual == runtime.sha256 else {
            try? fm.removeItem(at: zip)
            throw RuntimeInstallError.verifyFailed(expected: runtime.sha256, actual: actual)
        }

        try fm.createDirectory(at: paths.staging, withIntermediateDirectories: true)
        let stage = paths.staging.appending(path: "\(runtime.folderName)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: stage) }
        try Self.preflight(zip)
        try Self.unzip(zip, into: stage)
        try Self.checkContained(stage)
        try verifySignatures(stage)

        let target = paths.folder(runtime)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: stage, to: target)
        try? fm.removeItem(at: zip)

        let record = RuntimeInstallRecord(id: runtime.name, version: runtime.version, path: target.path, sha256: runtime.sha256,
                                          sizeBytes: SpaceAccountant.treeAllocated(target))
        try registry.save(record)
        for old in otherVersions(of: runtime.name, keeping: target) { try? fm.removeItem(at: old) }
        AppLog.log(.download, .info, "runtime: installed \(runtime.folderName) (\(record.sizeBytes) B on disk)")
        await Self.postChange(runtime.name)
        return InstalledRuntime(name: runtime.name, version: runtime.version, url: target, sha256: runtime.sha256, installedAt: record.installedAt)
    }

    // MARK: Remove

    /// Deletes every installed version of `name` and its row (Settings "Remove", M8 "Remove everything").
    public func remove(_ name: String) throws {
        let fm = FileManager.default
        for dir in otherVersions(of: name, keeping: nil) { try fm.removeItem(at: dir) }
        try registry.delete(name)
        Self.postChangeSoon(name)
    }

    // MARK: Change notification

    /// fix/review P2: `runtimeDidChangeNotification` is delivered on the main thread. Its observers are main-actor
    /// code (Settings › Tools' `.onReceive` refreshes a `@MainActor` model; FileToolsTools re-registers tools from a
    /// `queue: nil` observer, i.e. on the posting thread), and `install` runs off the main thread: posted from there,
    /// they mutated @Observable state off-main. `install` posts on the main actor before it returns.
    static func postChange(_ name: String) async {
        await MainActor.run { post(name) }
    }

    /// `remove` is synchronous: on the main thread it posts at once, elsewhere it hands the post to the main queue.
    static func postChangeSoon(_ name: String) {
        if pthread_main_np() != 0 {
            MainActor.assumeIsolated { post(name) }
        } else {
            DispatchQueue.main.async { post(name) }
        }
    }

    @MainActor private static func post(_ name: String) {
        NotificationCenter.default.post(name: .init(ToolDefaults.runtimeDidChangeNotification), object: name)
    }

    func otherVersions(of name: String, keeping: URL?) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: paths.root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(name + "@") && $0.standardizedFileURL != keeping?.standardizedFileURL }
    }

    // MARK: Verification steps

    /// Before extraction (review #9; checkContained runs after it, too late for a write): no absolute or `..` path, and
    /// no entry below a symlink entry (a link followed by a file written through it).
    static func preflight(_ zip: URL) throws {
        let entries: [(path: String, isSymlink: Bool)]
        do { entries = try BoundedZip.entries(of: zip) } catch { throw RuntimeInstallError.badArchive("not a zip archive") }
        let links = Set(entries.filter(\.isSymlink).map { $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path })
        for e in entries {
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            if e.path.hasPrefix("/") || e.path.hasPrefix("~") || parts.contains("..") || e.path.contains("\\") {
                throw RuntimeInstallError.badArchive("entry outside the runtime folder: \(e.path.prefix(120))")
            }
            var prefix = ""
            for part in parts.dropLast() {
                prefix += prefix.isEmpty ? String(part) : "/" + part
                if links.contains(prefix) { throw RuntimeInstallError.badArchive("entry below a symlink: \(e.path.prefix(120))") }
            }
        }
    }

    /// `ditto -x -k` keeps symlinks and modes (the runtime's framework has `Versions/Current` links).
    static func unzip(_ zip: URL, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RuntimeInstallError.badArchive("ditto exit \(p.terminationStatus): \(msg.prefix(200))")
        }
    }

    /// Every entry, symlink targets resolved, stays inside `dir` (no `../` or absolute links out of the runtime).
    static func checkContained(_ dir: URL) throws {
        let root = dir.resolvingSymlinksInPath().path + "/"
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let u as URL in e {
            let resolved = u.resolvingSymlinksInPath().path
            if !(resolved + "/").hasPrefix(root) { throw RuntimeInstallError.badArchive("\(u.path.dropFirst(root.count - 1)) points outside the runtime") }
        }
    }

    /// Every Mach-O file and every framework version bundle must validate strictly; unsigned = refused.
    func verifySignatures(_ dir: URL) throws {
        let items = Self.codeItems(dir)
        guard !items.isEmpty else { throw RuntimeInstallError.badSignature(path: "(no signed code in the runtime)", status: Int32(errSecCSUnsigned)) }
        let base = dir.resolvingSymlinksInPath().path
        for u in items {
            let status = validate(u)
            if status != errSecSuccess {
                let rel = String(u.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
                AppLog.log(.download, .error, "runtime: signature check failed for \(rel) (\(status))")
                throw RuntimeInstallError.badSignature(path: rel, status: status)
            }
        }
    }

    /// Mach-O files (thin or FAT magic) and `*.framework/Versions/<v>` folders, sorted.
    static func codeItems(_ dir: URL) -> [URL] {
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                if u.deletingLastPathComponent().lastPathComponent == "Versions", u.pathComponents.dropLast(2).last?.hasSuffix(".framework") == true {
                    out.append(u)
                }
            } else if v.isRegularFile == true, isMachO(u) {
                out.append(u)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func isMachO(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 8), d.count == 8 else { return false }
        let m = [UInt8](d)
        let thin: [[UInt8]] = [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xfe, 0xed, 0xfa, 0xce]]
        if thin.contains(Array(m[0..<4])) { return true }
        if m[0] == 0xca, m[1] == 0xfe, m[2] == 0xba, m[3] == 0xbe || m[3] == 0xbf {
            let n = UInt32(m[4]) << 24 | UInt32(m[5]) << 16 | UInt32(m[6]) << 8 | UInt32(m[7])
            return n > 0 && n < 8  // Java class files share the FAT magic
        }
        return false
    }

    /// `SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` (strict, all architectures, nested code).
    public static let checkSignature: Validator = { url in
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return status }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(code, flags, nil)
        return status
    }
}
