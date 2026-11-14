// Incognito temp directories (`$TMPDIR/AntiChat-incognito-*`: the session's dir, intake copies, image-input and
// media-job xfer files, in-memory artifact outputs). Every one records the pid that owns it in `.owner`, so the
// launch sweep (`IncognitoSession.sweepStaleTempDirectories`) of another AntiChat process — a second app instance, a
// test host, a test run in another checkout, all sharing the user's $TMPDIR — leaves a live one alone and removes only
// what a crashed or killed process left behind. A directory without an owner file counts as abandoned.
// fix/review P7: the owner is the pid *and* that process's start time (`.owner` = "<pid> <start µs>"). A pid alone
// was reused: after a crash, any later process given the same pid (root's gave EPERM, which also counted) kept the
// dead session's directory "live", and its incognito files stayed on disk. An owner file of an older build (pid only)
// is live only while that pid's process started before the file was written.
import Darwin
import Foundation

public enum IncognitoTemp {
    public static let prefix = "AntiChat-incognito-"
    public static let ownerFile = ".owner"
    public static var defaultRoot: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// Creates `<root>/AntiChat-incognito-<suffix>/` (0700) owned by this process and returns it.
    @discardableResult
    public static func make(_ suffix: String = UUID().uuidString, in root: URL = defaultRoot) -> URL {
        let dir = root.appendingPathComponent(prefix + suffix, isDirectory: true)
        claim(dir)
        return dir
    }

    /// Creates `dir` if needed and records this process as its owner (idempotent).
    public static func claim(_ dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let owner = dir.appendingPathComponent(ownerFile)
        let me = Data(ownerStamp.utf8)
        if fm.contents(atPath: owner.path) != me { fm.createFile(atPath: owner.path, contents: me) }
    }

    /// This process's owner identity: "<pid> <start time µs>".
    public static let ownerStamp: String = {
        let pid = getpid()
        return "\(pid) \(startTime(of: pid) ?? 0)"
    }()

    /// The start time (µs since 1970) of the running process `pid`, nil when there is none. `sysctl(KERN_PROC_PID)`
    /// answers for any user's process (no EPERM).
    public static func startTime(of pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return UInt64(t.tv_sec) * 1_000_000 + UInt64(t.tv_usec)
    }

    /// `dir`'s owner file names this very process (pid and start time).
    public static func isOwnedByThisProcess(_ dir: URL) -> Bool {
        FileManager.default.contents(atPath: dir.appendingPathComponent(ownerFile).path) == Data(ownerStamp.utf8)
    }

    /// Names in `root` that start with `prefix`, read straight from the directory stream (`readdir`: a name per entry,
    /// no URL, no attribute fetch, nothing built for an entry that is not ours). fix/selection-hang: the launch sweep used
    /// `FileManager.contentsOfDirectory`, which fetched every entry's attributes — with 359k unrelated entries in a
    /// shared $TMPDIR (other test suites' leftovers) the app's `init` blocked the main thread 25–40 s. At most `limit`
    /// names are returned; `scanned` gets the number of directory entries read.
    public static func matchingNames(in root: URL, prefix: String = prefix, limit: Int = .max,
                                     scanned: UnsafeMutablePointer<Int>? = nil) -> [String] {
        guard let dir = opendir(root.path) else { return [] }
        defer { closedir(dir) }
        let wanted = Array(prefix.utf8)
        var out: [String] = []
        var n = 0
        while out.count < limit, let entry = readdir(dir) {
            n += 1
            let matches: Bool = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                let len = Int(entry.pointee.d_namlen)
                guard len >= wanted.count else { return false }
                for i in 0..<wanted.count where raw[i] != wanted[i] { return false }
                return true
            }
            guard matches else { continue }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            out.append(name)
        }
        scanned?.pointee = n
        return out
    }

    /// A real directory (not a symlink) owned by this user: the only kind a sweep may remove.
    public static func isOurs(_ dir: URL) -> Bool {
        var st = stat()
        guard lstat(dir.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
    }

    /// The owning process is alive (this one included): the directory is in use. The process now running under the
    /// owner's pid must be the owner itself (same start time), not a later process that reused the pid.
    public static func isLive(_ dir: URL) -> Bool {
        let owner = dir.appendingPathComponent(ownerFile)
        guard let text = try? String(contentsOf: owner, encoding: .utf8) else { return false }
        let parts = text.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard let first = parts.first, let pid = pid_t(first), pid > 0, let started = startTime(of: pid) else { return false }
        if parts.count >= 2 {
            guard let recorded = UInt64(parts[1]) else { return false }
            return recorded == started
        }
        // An older build's owner file (pid only): its owner wrote it after it started, so a process that started after
        // the file was last written reused the pid (1 s of slack for file-system timestamps).
        guard let written = (try? FileManager.default.attributesOfItem(atPath: owner.path))?[.modificationDate] as? Date
        else { return false }
        return Double(started) / 1_000_000 <= written.timeIntervalSince1970 + 1
    }
}
