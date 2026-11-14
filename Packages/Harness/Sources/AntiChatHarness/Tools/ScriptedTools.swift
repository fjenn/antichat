// M1 tools (M1.T16 step 1): the always-on `get_time` (read) and the scripted test tools registered under
// `-UseScriptedTools YES` (`echo` read, `write_note` write: it asks first, which drives the ApprovalCard paths
// of J12ToolApprovalTests / AT-232 (4)). Real tools (web search, files, memory, MCP, …) arrive with M6–M8.
import Foundation
import Synchronization

public enum ScriptedTools {
    /// `get_time`: the current local date and time, optionally in another IANA time zone.
    public static func getTime(now: @escaping @Sendable () -> Date = { Date() },
                               timeZone: @escaping @Sendable () -> TimeZone = { .current }) -> RegisteredTool {
        RegisteredTool(
            name: "get_time",
            description: "Get the current date and time, in the user's time zone or in a given IANA time zone.",
            parametersJSON: #"{"properties":{"timezone":{"description":"IANA time zone, e.g. Asia/Tokyo; omit for the user's own.","type":"string"}},"type":"object"}"#,
            sideEffect: .read, outputIsUntrusted: false
        ) { args in
            let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
            var zone = timeZone()
            if let id = obj["timezone"] as? String, !id.isEmpty {
                guard let z = TimeZone(identifier: id) else { throw ToolRunError("unknown time zone \(id)") }
                zone = z
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx EEEE"
            return "\(f.string(from: now())) (\(zone.identifier))"
        }
    }

    /// `echo`: returns its `text` (tool-loop fixtures: `tool-call.jsonl`, `tool-loop-runaway.jsonl`). Its output is
    /// untrusted (it repeats whatever text it was given; the stand-in for web/file/MCP output in tests).
    public static func echo() -> RegisteredTool {
        RegisteredTool(
            name: "echo", description: "Repeat the given text back.",
            parametersJSON: #"{"properties":{"text":{"type":"string"}},"required":["text"],"type":"object"}"#,
            sideEffect: .read
        ) { args in
            let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
            return obj["text"] as? String ?? ""
        }
    }

    /// The notes `write_note` saved in this process (tests read them; nothing is written to disk).
    public static let notes = Mutex<[String]>([])

    /// `write_note`: saves a note (write side effect: asks first).
    public static func writeNote() -> RegisteredTool {
        RegisteredTool(
            name: "write_note", description: "Save a short note for the user.",
            parametersJSON: #"{"properties":{"text":{"type":"string"}},"required":["text"],"type":"object"}"#,
            sideEffect: .write, outputIsUntrusted: false
        ) { args in
            let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
            let text = obj["text"] as? String ?? ""
            notes.withLock { $0.append(text) }
            return "Saved the note."
        }
    }
}
