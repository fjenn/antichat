// The per-chat jail inside the FileTools service's own container (M6.T17 step 2; A-M6-11):
// `<container>/Data/scratch/<instance>/<chatID>/{in,out,tmp}`, created by the service (0700). Inputs arrive as file
// descriptors the app opened read-only on its own files and are copied into `in/`; outputs leave the same way
// (the service opens `out/*` read-only and hands the descriptors over). Paths never cross the XPC boundary, so the
// app never writes into this container and the service never names a path outside it.
//
// Names are untrusted (the model chose them; the code chose the output names): only a single path component,
// no leading dot, no NUL/slash, ≤ 255 bytes. Outputs are opened O_NOFOLLOW and must be regular files whose real
// path lies inside `out/`.
//
// One folder per service PROCESS (`<instance>`, held by an exclusive lock file next to it): a container belongs to a
// bundle id, not to a process, and every host app process (a second app copy, a Debug build next to the Release one,
// test hosts of parallel test runs) gets its own instance of each slot service in the SAME container. Each instance
// cleans only its own folder and what no live instance owns (a dead instance's folder, anything code planted next to
// the instance folders); another live instance's jails are never touched. Before this, an instance's launch or run
// deleted the other instance's live jail, and that chat's outputs vanished between the code writing them and their
// hand-out (RunPythonServiceTests: no chart, no xlsx).
import Darwin
import Foundation

public enum JailError: Error, Equatable, Sendable {
    case badChatID(String)
    case badName(String)
    case io(String, Int32)
}

public struct Jail: Sendable {
    public let root: URL
    /// The folder every instance of this service shares (`<container>/Data/scratch`), `root`'s parent; nil when `root`
    /// is private (unit tests).
    public let shared: URL?
    /// `root`'s name in `shared` and the stem of its lock file (`<instance>.lock`), nil when `root` is private.
    let instance: String?
    /// The descriptor holding this instance's lock (open for the life of the process; tests release it).
    let lockFD: Int32?
    /// Largest input copied in (the intake limit, R-020: 512 MB).
    public static let maxInputBytes: Int64 = 512 * 1024 * 1024
    /// At most this many output files are handed back per run.
    public static let maxOutputs = 32

    public init(root: URL) { self.root = root.standardizedFileURL; shared = nil; instance = nil; lockFD = nil }

    init(shared: URL, instance: String, lockFD: Int32?) {
        let base = shared.standardizedFileURL
        self.shared = base; self.instance = instance; self.lockFD = lockFD
        root = base.appending(path: instance, directoryHint: .isDirectory)
    }

    /// `<service home>/scratch` — the service's home is its container's `Data/` (App Sandbox).
    public static var sharedScratch: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: "scratch", directoryHint: .isDirectory) }

    /// This process's jail root in `sharedScratch` (see the header). If the lock file cannot be created the folder is
    /// still private to this process by name, but another instance would take it for a dead one's.
    public static func `default`() -> Jail {
        (try? claimInstance(in: sharedScratch)) ?? Jail(shared: sharedScratch, instance: "i-" + UUID().uuidString, lockFD: nil)
    }

    /// Creates `<shared>/i-<uuid>.lock` already locked (O_EXLOCK: no window in which another instance could take it
    /// for a dead one's) and returns the jail rooted at `<shared>/i-<uuid>`. The lock is held until the process ends.
    public static func claimInstance(in shared: URL) throws -> Jail {
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "i-" + UUID().uuidString
        let fd = open(shared.appending(path: name + lockSuffix).path,
                      O_RDONLY | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JailError.io("instance lock", errno) }
        return Jail(shared: shared, instance: name, lockFD: fd)
    }

    static let lockSuffix = ".lock"

    /// Tests: ends this instance as a process exit would (the lock goes; its folder is now a dead instance's).
    func releaseInstanceLock() { if let lockFD { close(lockFD) } }

    public static func validChatID(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy { c in
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 95
        }
    }

    /// A safe single-component file name, or nil.
    public static func safeName(_ name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0"),
              !name.contains(":"), name != "..", name.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return nil }
        return name
    }

    public func folder(_ chatID: String) -> URL { root.appending(path: chatID, directoryHint: .isDirectory) }
    public func inDir(_ chatID: String) -> URL { folder(chatID).appending(path: "in", directoryHint: .isDirectory) }
    public func outDir(_ chatID: String) -> URL { folder(chatID).appending(path: "out", directoryHint: .isDirectory) }
    public func tmpDir(_ chatID: String) -> URL { folder(chatID).appending(path: "tmp", directoryHint: .isDirectory) }

    /// Creates `<chat>/{in,out,tmp}` (0700). Idempotent.
    @discardableResult
    public func prepare(_ chatID: String) throws -> URL {
        guard Self.validChatID(chatID) else { throw JailError.badChatID(chatID) }
        let fm = FileManager.default
        for d in [root, folder(chatID), inDir(chatID), outDir(chatID), tmpDir(chatID)] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return folder(chatID)
    }

    /// Copies the readable descriptor `fd` (not closed here) into `in/<name>`, replacing an older copy.
    public func copyIn(_ chatID: String, name: String, from fd: Int32) throws {
        guard Self.validChatID(chatID) else { throw JailError.badChatID(chatID) }
        guard let safe = Self.safeName(name) else { throw JailError.badName(name) }
        let dst = inDir(chatID).appending(path: safe).path
        unlink(dst)  // a symlink planted by earlier code is removed, never followed
        let out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw JailError.io("open \(safe)", errno) }
        defer { close(out) }
        if lseek(fd, 0, SEEK_SET) < 0 && errno != ESPIPE { throw JailError.io("seek \(safe)", errno) }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw JailError.io("read \(safe)", errno) }
            if n == 0 { break }
            total += Int64(n)
            if total > Self.maxInputBytes { unlink(dst); throw JailError.io("\(safe) exceeds \(Self.maxInputBytes) bytes", EFBIG) }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(out, $0.baseAddress! + off, n - off) }
                if w < 0 { if errno == EINTR { continue }; throw JailError.io("write \(safe)", errno) }
                off += w
            }
        }
    }

    /// Opens the named outputs (relative to `out/`) read-only for hand-over. Names that are not a regular file
    /// inside `out/` (symlinks, `..`, devices, directories) are skipped. The caller closes the descriptors.
    public func openOutputs(_ chatID: String, names: [String]) -> [(name: String, size: Int64, fd: Int32)] {
        guard Self.validChatID(chatID) else { return [] }
        let base = outDir(chatID).resolvingSymlinksInPath().path + "/"
        var out: [(String, Int64, Int32)] = []
        for name in names.prefix(Self.maxOutputs) {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ Self.safeName($0) != nil }) else { continue }
            let url = outDir(chatID).appending(path: name)
            guard (url.deletingLastPathComponent().resolvingSymlinksInPath().path + "/").hasPrefix(base) else { continue }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); continue }
            out.append((name, Int64(st.st_size), fd))
        }
        return out
    }

    /// Deletes every jail except `chatID`'s (service launch, a run of another chat, idle exit), and everything in the
    /// shared folder no live instance owns. One live jail per service (M6.T21 review #5): code in one chat cannot list
    /// or read another chat's inputs and outputs. Another live instance's folder is left alone (see the header).
    public func removeAll(except chatID: String? = nil) {
        let fm = FileManager.default
        removeUnowned()
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name != chatID { try? fm.removeItem(at: root.appending(path: name)) }
    }

    /// Deletes the shared folder's entries no live instance owns (a dead instance's folder, the old layout, planted
    /// files); every live instance's folder stays.
    public func removeUnowned() {
        let (orphans, held) = unowned()
        for name in orphans { if let shared { try? FileManager.default.removeItem(at: shared.appending(path: name)) } }
        for fd in held { close(fd) }
    }

    /// The shared folder's entries no live instance owns, and the dead instances' lock descriptors this call took (the
    /// caller deletes, then closes them: no other instance treats a folder as dead while it is being deleted). An
    /// instance is live while some process holds its lock; its folder and lock file are owned, nothing else is.
    func unowned() -> (names: [String], held: [Int32]) {
        guard let shared, let instance, let names = try? FileManager.default.contentsOfDirectory(atPath: shared.path) else { return ([], []) }
        var live: Set<String> = [instance], held: [Int32] = []
        for name in names where name.hasSuffix(Self.lockSuffix) {
            let owner = String(name.dropLast(Self.lockSuffix.count))
            guard owner != instance else { continue }
            let fd = open(shared.appending(path: name).path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { held.append(fd) } else if errno == EWOULDBLOCK { live.insert(owner) }
        }
        let orphans = names.filter { name in
            let owner = name.hasSuffix(Self.lockSuffix) ? String(name.dropLast(Self.lockSuffix.count)) : name
            return !live.contains(owner)
        }
        return (orphans, held)
    }

    /// True when this instance's scratch holds nothing and the shared folder nothing no live instance owns: the check
    /// behind `ResetAck.scratchEmpty` (another app process's live jails are not this slot's earlier chats).
    public var isEmpty: Bool {
        let (orphans, held) = unowned()
        for fd in held { close(fd) }
        guard orphans.isEmpty else { return false }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return !FileManager.default.fileExists(atPath: root.path)
        }
        return names.isEmpty
    }

    /// Deletes the chat's jail (reset, chat deleted, idle-out).
    public func remove(_ chatID: String) {
        guard Self.validChatID(chatID) else { return }
        try? FileManager.default.removeItem(at: folder(chatID))
    }
}
