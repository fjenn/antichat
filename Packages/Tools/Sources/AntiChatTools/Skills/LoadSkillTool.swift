// `load_skill` (M7.T13 step 3; R-262): progressive disclosure. The prompt lists only the
// top-M skills as `name: description` lines (`<available_skills>`); a skill's instructions enter the turn only when
// the model calls `load_skill(name)` (or, on T0, when the selector pre-loads a clear match). The body is cut to the
// tier's `body_tokens` with a notice line, and at most `max_active` bodies are loaded per turn. `read_skill_file`
// returns one text file of the skill's `references/` or `assets/` (≤ 20K characters). Read-only, offline.
import AntiChatFoundation
import Foundation

public enum LoadSkillTool {
    public static let name = "load_skill"
    public static let description = "Load the full instructions of one skill from the available skills list. Call it before answering when a listed skill matches the request; then follow those instructions."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","description":"The skill name exactly as listed"}},"required":["name"]}"#

    struct Args: Decodable { var name: String }

    /// The skill name of a call's arguments (nil = malformed).
    public static func skillName(_ argumentsJSON: String) -> String? {
        (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8)))?.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Token estimate of the app's other budgets (`CountTokensRequest.estimate`: 4 characters per token).
    public static func estimateTokens(_ s: String) -> Int { (s.count + 3) / 4 }

    /// The body cut to `budgetTokens` (whole lines where possible) plus a notice line when it was cut.
    public static func truncated(_ body: String, budgetTokens: Int) -> (text: String, truncated: Bool) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard budgetTokens > 0, estimateTokens(trimmed) > budgetTokens else { return (trimmed, false) }
        let notice = "[Skill instructions shortened to fit this Mac: the first \(budgetTokens) tokens are shown. Use read_skill_file for its references.]"
        let room = max(0, (budgetTokens - estimateTokens(notice) - 1) * 4)
        var cut = String(trimmed.prefix(room))
        if let nl = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: nl) > room / 2 { cut = String(cut[..<nl]) }
        return (cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + notice, true)
    }

    /// The `<skill>` element the model gets (also the T0 pre-load's text).
    public static func element(name: String, body: String, budgetTokens: Int) -> String {
        "<skill name=\"\(name)\">\n\(UntrustedText.neutralised(truncated(body, budgetTokens: budgetTokens).text))\n</skill>"
    }
}
