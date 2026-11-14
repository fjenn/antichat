// R-229 AC1 event-ordering rules (M1.T13 step 4, `EventOrderingTests`): the checker the conformance suite runs on
// every recorded stream. Rules: exactly one terminal event (`done` | `error`) and it is last; `usage` precedes the
// terminal and, for a finished turn (`done` other than `cancelled`), is present exactly once; every `toolCallDone`
// follows at least one `toolCallDelta` of the same id, the first delta of an id carries the name, no delta of an
// id follows its `toolCallDone`, and the done's name matches the delta's; `done(toolCalls)` only after at least
// one `toolCallDone`. The seven kinds themselves are guaranteed by `EngineEvent`'s exhaustive enum.
import Foundation

public enum EventOrdering {
    public struct Violation: Error, Hashable, Sendable, CustomStringConvertible {
        public var index: Int
        public var rule: String
        public var description: String { "event \(index): \(rule)" }
    }

    /// The seven event kinds of the contract (stable names for traces and reports).
    public static let kinds = ["reasoningDelta", "textDelta", "toolCallDelta", "toolCallDone", "usage", "done", "error"]

    public static func kind(_ e: EngineEvent) -> String {
        switch e {
        case .reasoningDelta: "reasoningDelta"
        case .textDelta: "textDelta"
        case .toolCallDelta: "toolCallDelta"
        case .toolCallDone: "toolCallDone"
        case .usage: "usage"
        case .done: "done"
        case .error: "error"
        }
    }

    /// All violations of one request's stream (empty = conformant).
    public static func violations(_ events: [EngineEvent]) -> [Violation] {
        var out: [Violation] = []
        func v(_ i: Int, _ r: String) { out.append(Violation(index: i, rule: r)) }
        guard let last = events.last else { return [Violation(index: 0, rule: "empty stream (no terminal event)")] }
        if !last.isTerminal { v(events.count - 1, "stream does not end with done/error") }
        var usages = 0
        var deltaName: [String: String] = [:]
        var doneIDs: Set<String> = []
        for (i, e) in events.enumerated() {
            if e.isTerminal, i != events.count - 1 { v(i, "terminal event before the end (events after done)") }
            switch e {
            case .usage:
                usages += 1
            case .toolCallDelta(let id, let name, _):
                if doneIDs.contains(id) { v(i, "toolCallDelta \(id) after its toolCallDone") }
                if deltaName[id] == nil {
                    guard let n = name, !n.isEmpty else {
                        v(i, "first toolCallDelta of \(id) has no name")
                        deltaName[id] = ""
                        continue
                    }
                    deltaName[id] = n
                }
            case .toolCallDone(let id, let name, _):
                guard let n = deltaName[id] else {
                    v(i, "toolCallDone \(id) without a preceding toolCallDelta")
                    doneIDs.insert(id)
                    continue
                }
                if !n.isEmpty, n != name { v(i, "toolCallDone \(id) name \(name) ≠ delta name \(n)") }
                if doneIDs.contains(id) { v(i, "second toolCallDone for \(id)") }
                doneIDs.insert(id)
            case .done(let reason):
                if reason != .cancelled, usages != 1 { v(i, "done(\(reason.rawValue)) with \(usages) usage events (want 1, before done)") }
                if reason == .toolCalls, doneIDs.isEmpty { v(i, "done(toolCalls) without a toolCallDone") }
            default:
                break
            }
        }
        if usages > 1 { v(events.count - 1, "\(usages) usage events") }
        let open = Set(deltaName.keys).subtracting(doneIDs)
        if !open.isEmpty, case .done(let r) = last, r != .cancelled {
            v(events.count - 1, "toolCallDelta without toolCallDone: \(open.sorted())")
        }
        return out
    }
}
