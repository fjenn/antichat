// In-process perf log for `make perf` (M1.T26a; test-strategy §6). Off unless `ANTICHAT_PERF_LOG=<path>` is set in
// the environment; then every `Signposts` interval/event is appended to <path> as one JSON line:
//   {"name":"sendAck","kind":"interval","dur_ns":1234567,"end_ns":<CLOCK_UPTIME_RAW ns>,"pid":123,"proc":"AntiChat","meta":{…}}
// An environment variable rather than a LaunchOptions argument because perf runs use Release builds, where the
// LaunchOptions registry is compiled out (convention 10) — A-M1-T26a-b.
// `ANTICHAT_PERF_QUIT_AFTER=<name>[,<name>…]`: after recording an interval of that name, the process quits via the
// registered quit handler (the app sets NSApp.terminate), else `exit(0)` — the launch loop of `make perf METRIC=U1`.
// Privacy: names and developer metadata only (counts, ids, sizes), never content (architecture §7.2).
import Foundation
import os

public enum PerfRecorder {
    public enum Kind: String, Sendable { case interval, event }

    struct Config: Sendable {
        var path: String?
        var quitAfter: Set<String>
    }

    private struct State {
        var config: Config
        var handle: FileHandle?
        var open: [ObjectIdentifier: (name: String, start: UInt64)] = [:]
        var quitHandler: (@Sendable () -> Void)?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State(config: environmentConfig()))

    /// `ANTICHAT_PERF_LOG` / `ANTICHAT_PERF_QUIT_AFTER` (tools/perf): DEBUG and perf-harness builds only. A release
    /// build reads neither, so it never writes a perf log and never quits after a phase.
    static func environmentConfig(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Config {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let p = env["ANTICHAT_PERF_LOG"].flatMap { $0.isEmpty ? nil : $0 }
        let q = (env["ANTICHAT_PERF_QUIT_AFTER"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return Config(path: p, quitAfter: Set(q.filter { !$0.isEmpty }))
        #else
        return Config(path: nil, quitAfter: [])
        #endif
    }

    /// True when a perf log is being written (cheap; callers may skip extra work otherwise).
    public static var isEnabled: Bool { state.withLock { $0.config.path != nil } }

    /// Redirects the log (tests; nil turns it off). Closes the previous file.
    public static func configure(path: String?, quitAfter: Set<String> = []) {
        state.withLock { s in
            try? s.handle?.close()
            s.handle = nil
            s.open = [:]
            s.config = Config(path: path, quitAfter: quitAfter)
        }
    }

    /// The app registers how to quit cleanly (NSApp.terminate) for `ANTICHAT_PERF_QUIT_AFTER`.
    public static func setQuitHandler(_ h: @escaping @Sendable () -> Void) {
        state.withLock { $0.quitHandler = h }
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func began(_ name: String, _ token: AnyObject) {
        let t = now()
        let key = ObjectIdentifier(token)
        state.withLock { s in
            guard s.config.path != nil else { return }
            s.open[key] = (name, t)
        }
    }

    static func ended(_ name: String, _ token: AnyObject, meta: [String: String]) {
        let t = now()
        let key = ObjectIdentifier(token)
        let start: UInt64? = state.withLock { s in
            guard s.config.path != nil else { return nil }
            return s.open.removeValue(forKey: key)?.start
        }
        guard let start else { return }
        record(name, kind: .interval, durationNs: t >= start ? t - start : 0, meta: meta, endNs: t)
    }

    /// Appends one record. `durationNs` 0 for events.
    public static func record(_ name: String, kind: Kind, durationNs: UInt64, meta: [String: String] = [:], endNs: UInt64? = nil) {
        let end = endNs ?? now()
        let quit: (@Sendable () -> Void)?? = state.withLock { s in
            guard let path = s.config.path else { return nil }
            var obj: [String: Any] = [
                "name": name, "kind": kind.rawValue, "dur_ns": durationNs, "end_ns": end,
                "pid": Int(getpid()), "proc": ProcessInfo.processInfo.processName,
            ]
            if !meta.isEmpty { obj["meta"] = meta }
            guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            line.append(0x0A)
            if s.handle == nil {
                if !FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                s.handle = FileHandle(forWritingAtPath: path)
                _ = try? s.handle?.seekToEnd()
            }
            try? s.handle?.write(contentsOf: line)
            guard kind == .interval, s.config.quitAfter.contains(name) else { return nil }
            try? s.handle?.synchronize()
            return .some(s.quitHandler)
        }
        if let quit {
            // Let the current run-loop pass finish (the focus change that ended the interval) before quitting.
            DispatchQueue.main.async {
                if let quit { quit() } else { exit(0) }
            }
        }
    }
}
