// Duplicate-call guard (M1.T16 step 3; R-232 AC2). Ported design from
// osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/AgentToolLoop.swift:L1198-1300 (dedupe/replay +
// RecoveryCounters): a call is keyed by (name, canonical arguments JSON); a key seen before in the same turn is
// not executed. Osaurus replays the held result; AntiChat skips the call, hands the model
// `ToolLoopPolicy.duplicateNotice`, and makes the next step its last (text only), so the loop ends after at most
// one more step.
import Foundation

public struct DuplicateCallGuard: Sendable {
    private var seen: Set<String> = []
    /// Calls skipped in this turn (Osaurus RecoveryCounters analogue; diagnostics).
    public private(set) var skipped = 0

    public init() {}

    /// True when the call is new in this turn (and records it); false for a repeat.
    public mutating func admit(name: String, argumentsJSON: String) -> Bool {
        let inserted = seen.insert(Self.key(name: name, argumentsJSON: argumentsJSON)).inserted
        if !inserted { skipped += 1 }
        return inserted
    }

    static func key(name: String, argumentsJSON: String) -> String { name + "\u{1F}" + canonical(argumentsJSON) }

    /// Sorted-key, whitespace-free JSON of the arguments (key order and spacing never make a call "new"); text
    /// that is not JSON is kept as it is, trimmed.
    public static func canonical(_ argumentsJSON: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8), options: [.fragmentsAllowed]),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed])
        else { return argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(decoding: d, as: UTF8.self)
    }
}
