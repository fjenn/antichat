// SkillManifestBlock (M7.T13 step 2; R-262 AC1; format after agentskills `skills-ref/src/skills_ref/prompt.py`, one
// `name: description` line per skill instead of its XML elements — fewer tokens on small models). The top-M skills of
// the turn (SkillSelector) as `<available_skills>`, ordered by name (stable for a stable set, K-NEW-TOOLS-2), placed
// in the volatile tail of the newest user turn (`ChatRequest.turnContext`, after the time line), never in the stable
// prefix: the prefix hash is the same with skills on or off (R-230/R-269). No skill body is in it; a body enters only
// through `load_skill` or the T0 pre-load (`<skill>` element, also volatile).
import AntiChatTools
import Foundation

public enum SkillManifestBlock {
    public static let open = "<available_skills>"
    public static let close = "</available_skills>"
    public static let lead = "Skills on this Mac. If one fits the request, call load_skill with its name before you answer; otherwise ignore them:"

    /// The block for `skills` (empty = none). Descriptions are flattened to one line.
    public static func render(_ skills: [SkillSelector.Scored]) -> String {
        guard !skills.isEmpty else { return "" }
        let lines = skills.sorted { $0.name < $1.name }.map { "\($0.name): \(oneLine($0.description))" }
        return ([open, lead] + lines + [close]).joined(separator: "\n")
    }

    /// The skill names listed in a rendered block (tests, AT-262).
    public static func names(in text: String) -> [String] {
        guard let a = text.range(of: open, options: .backwards), let b = text.range(of: close, range: a.upperBound..<text.endIndex) else { return [] }
        return text[a.upperBound..<b.lowerBound].split(separator: "\n").dropFirst().compactMap { line in
            line.firstIndex(of: ":").map { String(line[..<$0]) }
        }
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}
