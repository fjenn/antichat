// M8.T08 step 8 (NFR-PR4; AT-NFR-PR4): data at rest is protected by OS permissions. On every launch the app's own
// directories get POSIX 0700 (`~/Library/Application Support/AntiChat`, `~/Library/Caches/AntiChat`,
// `~/Library/Logs/AntiChat`; Debug: the `AntiChat-Dev` names) and the database triple, backups and the app's
// own exports get 0600. Only the owner (the user running AntiChat, which is also the user the engine helper and the
// file-tools child run as) can read them. FileVault status is reported by the System report (M8.T09), not here.
// Never loosens a mode: a stricter mode set by the user stays.
import Foundation

public enum FileProtection {
    public static let directoryMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600

    /// What `ensure` changed (tests, the launch log).
    public struct Report: Sendable, Equatable {
        public var directories: [String] = []
        public var files: [String] = []
        public var failures: [String] = []
        public init() {}
    }

    /// Creates nothing: a missing directory or file is skipped (it gets its mode when it is created and the next
    /// launch runs this again).
    /// - Parameters:
    ///   - directories: the app's container, caches and logs.
    ///   - database: the SQLite file; its `-wal`/`-shm` siblings are included.
    ///   - fileDirectories: directories whose regular files are private (Backups, Exports, the logs directory).
    @discardableResult
    public static func ensure(directories: [URL], database: URL?, fileDirectories: [URL] = []) -> Report {
        var report = Report()
        let fm = FileManager.default
        for dir in directories {
            restrict(dir.path, to: directoryMode, report: &report.directories, failures: &report.failures)
        }
        if let database {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let path = database.path + suffix
                if fm.fileExists(atPath: path) {
                    restrict(path, to: fileMode, report: &report.files, failures: &report.failures)
                }
            }
        }
        for dir in fileDirectories {
            restrict(dir.path, to: directoryMode, report: &report.directories, failures: &report.failures)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let path = dir.appendingPathComponent(name).path
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    restrict(path, to: directoryMode, report: &report.directories, failures: &report.failures)
                } else {
                    restrict(path, to: fileMode, report: &report.files, failures: &report.failures)
                }
            }
        }
        return report
    }

    /// One file the app wrote to its own default location (an export, a backup copy).
    @discardableResult
    public static func protectFile(_ url: URL) -> Bool {
        var changed: [String] = [], failures: [String] = []
        restrict(url.path, to: fileMode, report: &changed, failures: &failures)
        return failures.isEmpty
    }

    /// The permission bits of `path` (nil when it does not exist).
    public static func mode(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & 0o7777
    }

    private static func restrict(_ path: String, to target: mode_t, report: inout [String], failures: inout [String]) {
        var st = stat()
        // lstat: a symlink (e.g. a moved Models folder bookmark target) is never followed or changed.
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return }
        let current = st.st_mode & 0o7777
        // Already the target, or stricter (a subset of it): leave it. Anything else (group/other bits) → the target.
        guard current & ~target != 0 else { return }
        if chmod(path, target) == 0 { report.append(path) } else { failures.append(path) }
    }
}
