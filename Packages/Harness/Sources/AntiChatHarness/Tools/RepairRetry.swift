// Repair retry (M1.T16 step 4; R-232 AC3): a malformed call (arguments that do not parse, an undeclared tool, or
// arguments that fail the tool's schema) gets exactly one repair prompt carrying the validation error; a second
// malformed call in the same turn ends the loop with a final, text-only request (`tool_choice: none`).
// Validation reuses the conformance checker (`ToolSchemaCheck`, M1.T13), so "malformed" means the same here as in
// AT-229/AT-231.
import AntiChatEngineProtocol
import Foundation

public struct RepairRetry: Sendable {
    public enum Action: Sendable, Hashable {
        /// Send the model this text as the call's tool result and let it try again.
        case repair(prompt: String)
        /// Stop calling tools: the next (last) request asks for a text-only answer.
        case finalAnswer
    }

    /// Repair prompts already used in this turn (at most one; a forced file-tool repair: at most two).
    public private(set) var repairsUsed = 0
    public static let maxRepairs = 1
    /// AT-273 round 65 (T05 xlsx-18): a file tool's repair is a forced step (`tool_choice: function`). A forced step that
    /// called the tool again with a spec still wrong ended the loop with a text-only step (`tool_choice: none`), so the
    /// model could only apologise or ask the user: no file. A forced repair gets one more forced try with the new
    /// errors; a third malformed call ends the loop as before.
    public static let maxForcedRepairs = 2

    public init() {}

    /// The validation error of a call against the offered tools, or nil when the call is well formed.
    public static func problem(name: String, argumentsJSON: String, tools: [ToolSchema]) -> String? {
        guard let schema = tools.first(where: { $0.name == name }) else {
            return "there is no tool named \"\(name)\"; the tools are: \(tools.map(\.name).sorted().joined(separator: ", "))"
        }
        guard let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else {
            return "the arguments are not a JSON object"
        }
        let s = (try? JSONSerialization.jsonObject(with: Data(schema.parametersJSON.utf8))) as? [String: Any] ?? [:]
        let problems = ToolSchemaCheck.problems(args, s)
        return problems.isEmpty ? nil : "the arguments do not match the schema: " + problems.prefix(5).joined(separator: "; ")
    }

    /// What to do about a malformed call. `example` (AT-273, file-out tools): a minimal valid call of that kind.
    /// `forced`: the repair's next step is forced to the tool (a file tool with a valid example), which allows
    /// `maxForcedRepairs` repairs in the turn instead of `maxRepairs`.
    public mutating func onMalformed(name: String, problem: String, example: String? = nil, forced: Bool = false) -> Action {
        guard repairsUsed < (forced ? Self.maxForcedRepairs : Self.maxRepairs) else { return .finalAnswer }
        repairsUsed += 1
        let text = Self.prompt(name: name, problem: problem, example: example)
        guard repairsUsed > 1 else { return .repair(prompt: text) }
        return .repair(prompt: text + "\nThis is the last try: the previous call to \(name) was not run either. Do not ask the user"
                       + " for anything; fill in what is missing yourself.")
    }

    /// AT-273 (xlsx-18 follow-up): a tool that found a spec problem only while running answers with the repair text
    /// (`{"repair": true, "errors": […]}`, as a result or as its error). That text, or nil for any other result.
    public static func runtimeProblem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any],
              o["repair"] as? Bool == true else { return nil }
        return t
    }

    /// AT-273 (xlsx-18 follow-up): the one retry of a forced repair step the model answered in text (an engine that
    /// cannot enforce `tool_choice: function`): the call's errors again, and the tool must be called now.
    public static func textInsteadOfCallPrompt(name: String, problem: String, example: String?) -> String {
        "[System Notice] You answered in text, but no file was made: the call to \(name) was not run. Errors: \(problem)\n"
            + "Do not answer in text. Fix exactly these errors and call \(name) now with the full content."
            + (example.map { " A minimal valid call looks like this: \($0)" } ?? "")
    }

    public static func prompt(name: String, problem: String, example: String? = nil) -> String {
        guard let example else {
            return "[System Notice] The call to \(name) was not run: \(problem). Call it again with arguments that match its schema, or answer without it."
        }
        // AT-273 (T05: every repair turn of a file call ended in a text answer and no file): the exact errors, a
        // valid call of the same kind, and no invitation to give up.
        return "[System Notice] The call to \(name) was not run. Errors: \(problem)\nFix exactly these errors and call \(name) again now "
            + "with the full content. A minimal valid call looks like this: \(example)"
    }
}
