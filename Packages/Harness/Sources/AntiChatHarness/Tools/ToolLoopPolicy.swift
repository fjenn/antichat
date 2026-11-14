// Tool-loop bounds (M1.T16 step 2; R-232 AC1; P-shell-12).
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/AgentToolLoop.swift:L40-118
// (AgentLoopPolicy: maxIterations clamped ≥ 1, the dedupe notice switch). Osaurus' todo, data-movement and
// wrap-up knobs belong to its agent surfaces and are dropped; the cap comes from the hardware tier instead of a
// user setting: T0 3, T1–T3 6, T4 8 model steps per turn (R-232 AC1).
import AntiChatFoundation
import Foundation

/// Hardware tier for the loop budget (hardware-tiers §2). M1 reads `-FakeHardware`; M2's probe sets it.
public enum DeviceTier: String, Sendable, CaseIterable, Codable {
    case t0 = "T0", t1 = "T1", t2 = "T2", t3 = "T3", t4 = "T4"

    public init(_ launch: LaunchOptions.Tier) { self = DeviceTier(rawValue: launch.rawValue) ?? .t1 }

    /// The tier for this launch: `-FakeHardware` in DEBUG, else T1 until M2.T01's probe (the conservative middle).
    public static func current(options: LaunchOptions = .current) -> DeviceTier {
        options.fakeHardware.map(DeviceTier.init) ?? .t1
    }
}

public struct ToolLoopPolicy: Sendable, Hashable {
    /// Model steps per turn that may call tools; after the last one's calls ran, the turn stops with
    /// `tool.loopLimit` and [Continue] (a fresh budget).
    public var maxSteps: Int
    /// After a duplicate call was skipped, the model gets this notice as the call's result (Osaurus dedupeNotice).
    public var dedupeNoticeEnabled: Bool

    public init(maxSteps: Int, dedupeNoticeEnabled: Bool = true) {
        self.maxSteps = max(1, maxSteps)
        self.dedupeNoticeEnabled = dedupeNoticeEnabled
    }

    /// R-232 AC1.
    public static func steps(for tier: DeviceTier) -> Int {
        switch tier {
        case .t0: 3
        case .t1, .t2, .t3: 6
        case .t4: 8
        }
    }

    public static func forTier(_ tier: DeviceTier) -> ToolLoopPolicy { ToolLoopPolicy(maxSteps: steps(for: tier)) }

    /// Ported from AgentToolLoop.swift:L1243-1245 (`dedupeNotice`), worded for a skipped (not replayed) call.
    /// M6.T21: the tool result for a call the engine dropped because the output limit cut it off.
    public static func cutOffNotice(_ name: String) -> String {
        let base = "[System Notice] Your \(name) call was cut off: it reached the output limit before its arguments were complete, so it "
            + "was not run. Call \(name) again with shorter arguments: only the keys that are needed, no repeated or nested "
            + "copies of the same keys."
        // AT-273 (T05 csv-16 / md-16 / pdf-16 / xlsx-16: a "long" table or a year of daily rows): a concrete size that fits.
        return fileSizeHint[name].map { base + " " + $0 } ?? base
    }

    /// AT-273 round 65 (T05 csv-25 "large numbers with thousands separators": both the call and its cut-off retry
    /// counted up without end — "1,000", "1,000,000", … one more group per row — until the engine's repetition guard
    /// stopped them): `runaway` = the engine stopped the call because it repeated a pattern. The first such cut says so;
    /// `last` (the one extra retry a runaway gets) asks for a small, concrete shape.
    /// AT-273 round 67 (T05 xlsx-28): `last` is also a file tool's second plain cut (the same one extra retry).
    public static func cutOffNotice(_ name: String, runaway: Bool, last: Bool = false) -> String {
        guard runaway || last else { return cutOffNotice(name) }
        let said = runaway
            ? "[System Notice] Your \(name) call was stopped and not run: it kept repeating the same pattern (each row "
                + "like the one before, longer and longer or without end)."
            : "[System Notice] Your \(name) call was cut off again: it reached the output limit before its arguments were "
                + "complete, so it was not run."
        guard last else {
            return said + " Call \(name) again now with the full content, without repeating."
                + (fileSizeHint[name].map { " " + $0 } ?? "")
        }
        let shape = name == "create_document" || name == "create_presentation"
            ? "Write a short version now: at most 5 sections or slides, at most 10 table rows, each item different."
            : "Write exactly 10 rows now, each row different, and keep every value short (at most 20 characters)."
        return said + " Call \(name) once more. " + shape + " Do not continue a sequence; pick 10 representative examples."
    }

    static let fileSizeHint: [String: String] = [
        "create_spreadsheet": "Keep it to at most 40 rows per sheet (a representative sample) and say in your reply that the user can ask for more rows.",
        "create_document": "Keep the document under about 1,200 words and any table to at most 40 rows, and say in your reply that it is shortened.",
        "create_presentation": "Keep it to at most 12 slides with short bullets.",
    ]

    public static let duplicateNotice =
        "[System Notice] Duplicate call skipped: you already made this exact call this turn. Use the result you already have and answer."
}
