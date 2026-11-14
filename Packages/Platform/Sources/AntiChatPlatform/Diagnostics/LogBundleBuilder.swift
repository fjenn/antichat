// M8.T09 step 5 (R-218 AC3): Export logs → `AntiChat-Logs-<ts>.zip` with `system-report.json`, `app.log` and
// `engine.log` (the last 2,000 lines of each process's CocoaLumberjack files, oldest file first), the crash payloads
// of step 1 (`crashes/<id>.txt`) and `engine-state.json`. Every line passes through `Redaction`; content lines
// (`AppLog.contentMarker`, written only while "Include content in logs" was on) are dropped unless the user ticks
// "Include chat content". Written with ZIPFoundation, entry by entry.
import AntiChatFoundation
import Foundation
import ZIPFoundation

public struct LogBundleInput: Sendable {
    public var appLogDir: URL?
    public var engineLogDir: URL?
    public var crashes: [CrashReport]
    public var systemReport: SystemReport
    public var engineState: [String: String]
    public var includeContent: Bool

    public init(appLogDir: URL?, engineLogDir: URL?, crashes: [CrashReport], systemReport: SystemReport,
                engineState: [String: String] = [:], includeContent: Bool = false) {
        self.appLogDir = appLogDir; self.engineLogDir = engineLogDir; self.crashes = crashes; self.systemReport = systemReport
        self.engineState = engineState; self.includeContent = includeContent
    }
}

public enum LogBundleBuilder {
    public static let maxLines = 2_000

    public static func fileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "AntiChat-Logs-\(f.string(from: now)).zip"
    }

    /// `~/Library/Logs/AntiChat` (Release) or `AntiChat-Dev` (Debug): `app/` and `engine/` hold the file logs.
    public static func logsRoot(debug: Bool = AppDatabaseFlags.isDebugBuild) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(debug ? "AntiChat-Dev" : "AntiChat")")
    }

    /// The last `maxLines` lines over the directory's `*.log` files (oldest first), content lines dropped unless
    /// included, every line redacted.
    public static func tail(_ dir: URL?, maxLines: Int = maxLines, includeContent: Bool) -> String {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return "" }
        let files = names.filter { $0.hasSuffix(".log") }.map { dir.appendingPathComponent($0) }.sorted {
            let a = (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date ?? .distantPast
            let b = (try? FileManager.default.attributesOfItem(atPath: $1.path))?[.modificationDate] as? Date ?? .distantPast
            return a < b
        }
        var lines: [Substring] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true))
        }
        if !includeContent {
            // A content entry and its continuation lines (older logs wrote multi-line previews) are dropped together:
            // every line up to the next timestamped entry (review fix).
            var inContent = false
            lines = lines.filter { line in
                if Self.startsEntry(line) { inContent = line.contains(AppLog.contentMarker) }
                else if line.contains(AppLog.contentMarker) { inContent = true }
                return !inContent
            }
        }
        return lines.suffix(maxLines).map { Redaction.redact(String($0)) }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// A file-log entry's first line starts with its timestamp (`yyyy/MM/dd …` or `yyyy-MM-dd…`) or a `[category]`
    /// tag; anything else is the continuation of the entry above.
    static func startsEntry(_ line: Substring) -> Bool {
        if line.first == "[" { return true }
        let c = Array(line.prefix(5))
        return c.count == 5 && c[0...3].allSatisfy(\.isNumber) && (c[4] == "/" || c[4] == "-")
    }

    public static func build(to url: URL, input: LogBundleInput) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        try add("system-report.json", input.systemReport.json())
        try add("app.log", Data(tail(input.appLogDir, includeContent: input.includeContent).utf8))
        try add("engine.log", Data(tail(input.engineLogDir, includeContent: input.includeContent).utf8))
        for c in input.crashes { try add("crashes/\(c.id).txt", Data(Redaction.redact(c.payload).utf8)) }
        let state = input.engineState.mapValues { Redaction.redact($0) }
        try add("engine-state.json", (try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8))
    }
}

/// Debug vs Release without a database handle (the diagnostics code never opens the chats database).
public enum AppDatabaseFlags {
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
