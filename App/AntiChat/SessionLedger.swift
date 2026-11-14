// M9.T06 (AT-NFR-S1): every launch of a test-flavoured build (Debug or the perf harness: UI suites, probes, benches,
// perf runs, the soak) appends one `start` line to `~/Library/Logs/AntiChat-Dev/sessions.jsonl`, and a normal exit an
// `end` line. tools/perf/crash-free.py counts sessions from it (outside every container, so throwaway dev containers
// do not take the count with them) and matches crash reports to them by pid. Release builds never write it.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatFoundation
import Darwin
import Foundation

enum SessionLedger {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AntiChat-Dev/sessions.jsonl")
    nonisolated(unsafe) static var startedAt = Date()

    /// The `start` line; `atexit` writes `end` on a normal exit (crashes and SIGKILL leave none).
    static func start() {
        startedAt = Date()
        let args = CommandLine.arguments
        let kind = args.contains("-Bench") ? "bench"
            : args.firstIndex(where: { $0.hasSuffix("Probe") && $0.hasPrefix("-") }).map { String(args[$0].dropFirst()) }
            ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ? "xctest-host" : "app")
        let container = args.firstIndex(of: "-ANTICHAT_DEV_CONTAINER").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        append(["event": "start", "pid": Int(getpid()), "t": startedAt.timeIntervalSince1970, "kind": kind,
                "bundle": Bundle.main.bundlePath, "bundleID": Bundle.main.bundleIdentifier ?? "",
                "container": container ?? NSNull(), "uitest": ProcessInfo.processInfo.environment["ANTICHAT_BACKGROUND"] == "0"])
        atexit { SessionLedger.end() }
    }

    /// `create: false`: a session that ran Remove everything (or an uninstall) deleted `Logs/AntiChat-Dev` on purpose;
    /// its `end` line must not bring the folder back (AT-NFR-D7 zero files). See LedgerFile.
    static func end() {
        LedgerFile.append(["event": "end", "pid": Int(getpid()), "t": Date().timeIntervalSince1970], to: url, create: false)
    }

    private static func append(_ obj: [String: Any]) {
        LedgerFile.append(obj, to: url, create: true)
    }
}
#endif
