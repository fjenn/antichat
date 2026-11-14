// M7.T06 (AT-081 c2; reused by M7.T13/T14): Debug-only `-DumpPrompts <dir>` writes each rendered prompt — the system
// turn (stable layers + date line), the tool block, the volatile tail (time line) — to `<dir>/<turn-id>.txt`, so an
// AT can show which tool schemas a turn offered (a Blocked tool must be absent). Compiled out of Release.
// M7.T13 (AT-262): also the request's whole volatile tail (`turnContext`: time line, memory/project lines, the
// `<available_skills>` manifest, pre-loaded skill bodies) and the turn's events (`skill_preload name=… score=…`).
import AntiChatFoundation
import AntiChatEngineProtocol
import Foundation

public enum PromptDump {
    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Tests set a directory directly; the app reads `-DumpPrompts`.
    nonisolated(unsafe) public static var directory: String? = LaunchOptions.current.dumpPrompts
    /// A per-task directory (wins over `directory`): parallel test suites dump without sharing the global.
    @TaskLocal public static var taskDirectory: String?

    public static func text(_ p: ComposedPrompt, turnContext: String? = nil, events: [String] = []) -> String {
        var t = """
        === system ===
        \(p.systemText)
        === tools ===
        \(p.toolBlock)
        === volatile ===
        \(turnContext ?? p.timeLine)

        """
        if !events.isEmpty { t += "=== events ===\n" + events.joined(separator: "\n") + "\n" }
        return t
    }

    public static func write(_ p: ComposedPrompt, turnID: String, turnContext: String? = nil, events: [String] = []) {
        guard let dir = taskDirectory ?? directory else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(turnID).txt")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(text(p, turnContext: turnContext, events: events).utf8).write(to: url, options: .atomic)
    }
    /// M7 bars (T1 search latency profile): every engine request of a turn as sent — each message's role and text
    /// (tool calls and results included) and the tool names — as `<turnID>.step<n>.txt`.
    public static func writeRequest(_ r: ChatRequest, turnID: String, step: Int) {
        guard let dir = taskDirectory ?? directory else { return }
        var t = "=== tools (\(r.tools.count)) ===\n" + r.tools.map(\.name).joined(separator: ", ") + "\n"
        for m in r.flattenedMessages {
            t += "=== \(m.role) (\(m.content.count) chars) ===\n\(m.content)\n"
            for c in m.toolCalls { t += "[call \(c.name)] \(c.argumentsJSON)\n" }
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(turnID).step\(step).txt")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data(t.utf8).write(to: url, options: .atomic)
    }
    #else
    @inline(__always) public static func writeRequest(_ r: ChatRequest, turnID: String, step: Int) {}
    @inline(__always) public static func write(_ p: ComposedPrompt, turnID: String, turnContext: String? = nil, events: [String] = []) {}
    #endif
}
