// M6.T13 steps 3–4 (R-016 AC3/AC4): "Edit selection" and "Fix with AntiChat" on an artifact in the side panel. Both
// send a follow-up turn in the artifact's chat that asks for the full revised artifact; the reply's first promoted block
// becomes version n + 1 of the same artifact (TurnController.setRevisesNextTurn → ArtifactPromotionService), and the
// panel switches to it while the version picker keeps the old ones.
//   Edit: "Edit only this part of <title>: «selection» — instruction: <instruction>"
//   Fix:  "Fix this error in <title>: <message>"
// The current version's full source rides along as a pasted-text attachment of the turn (the M1 paste card), so the
// user bubble stays one line and the model sees the whole artifact.
import Foundation

public struct ArtifactEditRequest: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case editSelection(selection: String, instruction: String)
        case fix(message: String)
    }

    public var artifactID: String
    public var title: String
    /// The fence language of the source (html, jsx, mermaid, …; empty for plain text).
    public var language: String
    /// The current version's full source.
    public var source: String
    public var action: Action
    /// The version on screen whose source this edits (M6 review #11: the new version's parent; nil = the newest).
    public var baseVersion: Int?

    public init(artifactID: String, title: String, language: String, source: String, action: Action, baseVersion: Int? = nil) {
        self.artifactID = artifactID; self.title = title; self.language = language; self.source = source
        self.action = action; self.baseVersion = baseVersion
    }
}

public enum ArtifactEditService {
    /// The turn's user text (one line + the reply format instruction).
    public static func prompt(for r: ArtifactEditRequest) -> String {
        let fence = r.language.isEmpty ? "" : r.language
        switch r.action {
        case .editSelection(let selection, let instruction):
            return "Edit only this part of \(r.title): «\(selection)» — instruction: \(instruction)\n\n"
                + "Reply with the full revised \(r.title) in one ```\(fence) block; leave everything outside that part unchanged."
        case .fix(let message):
            return "Fix this error in \(r.title): \(message)\n\n"
                + "Reply with the full corrected \(r.title) in one ```\(fence) block."
        }
    }

    /// The pasted-text attachment: the current version as a fenced block.
    public static func context(for r: ArtifactEditRequest) -> String {
        let longest = r.source.components(separatedBy: "\n").map { $0.prefix { $0 == "`" }.count }.max() ?? 0
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return "\(r.title) (current version):\n\(ticks)\(r.language)\n\(r.source)\n\(ticks)"
    }

    /// Does `revised` change only the selected span of `original`? (AT-016 check 4: the text before and after the
    /// selection is kept byte for byte.)
    public static func changesOnlySelection(original: String, revised: String, selection: String) -> Bool {
        guard let r = original.range(of: selection) else { return false }
        let before = original[..<r.lowerBound], after = original[r.upperBound...]
        return revised.hasPrefix(before) && revised.hasSuffix(after) && revised.count >= before.count + after.count
            && revised != original
    }
}
