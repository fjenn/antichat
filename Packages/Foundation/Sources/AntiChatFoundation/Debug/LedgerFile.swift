// The append-only JSONL file behind the test-build session ledger (App/AntiChat/SessionLedger.swift, M9.T06,
// AT-NFR-S1). Split out of the app so the create rule is unit-tested: a `start` line may create the file (and its
// folder); an `end` line only appends to a file that still exists, so a session that ran Remove everything or an
// uninstall (which delete `~/Library/Logs/AntiChat-Dev` on purpose) never brings the folder back at exit
// (AT-NFR-D7 / AT-226 zero files).
import Darwin
import Foundation

public enum LedgerFile {
    /// Appends `obj` as one JSON line (sorted keys). `create == false` never creates the file or its folder.
    /// Returns whether the line was written.
    @discardableResult
    public static func append(_ obj: [String: Any], to url: URL, create: Bool) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return false }
        if create {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // O_APPEND: concurrent launches (parallel suites) never interleave inside a line.
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | (create ? O_CREAT : 0), 0o644)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let line = d + Data("\n".utf8)
        return line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == line.count
    }
}
