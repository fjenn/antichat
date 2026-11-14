// Prompt layers (M1.T14 step 1; P-shell-07; G-007). Order, stable → volatile:
//   (1) base persona  (2) mode clause  (3) custom instructions (+ the project's frozen instructions, M8.T04)
//   (4) frozen memory snapshot  (5) tool block
//   (6) current date (day granularity), then the conversation; the current time to the minute is appended to the
//   newest user turn by the adapter (`ChatRequest.turnContext`, D-022).
// No layer carries a safety or behaviour clause (R-241 prompt rule, test-strategy §9 rule 4): the base persona is
// one neutral sentence, Normal's mode clause is empty, and everything in (3) is text the user chose.
import AntiChatEngineProtocol
import Foundation
import OsaurusVendored

/// Section ids, in render order. They are `PromptLayer.id` on the wire and `PromptSection.id` in the manifest.
public enum PromptLayerID {
    public static let base = "base"
    public static let mode = "mode"
    public static let instructions = "instructions"
    /// M8.T04: the chat's project instructions (frozen at its first send), right after (3).
    public static let project = "project"
    /// M8.T05: a whole-mode project's file texts (≤ 30 % of the context), after the instructions.
    public static let projectFiles = "projectFiles"
    public static let memory = PromptSectionID.memory
    /// M7.T12: the bodies of the skills active in this chat (explicit "/" picks, "Apply to every chat"), after memory.
    public static let skills = "skills"
    public static let tools = "tools"
    /// M1.T16: the tool-selection sentence, part of layer (5) (only when tools are offered).
    public static let toolUse = "toolUse"
    public static let date = "date"

    public static let stableOrder = [base, mode, instructions, project, projectFiles, memory, skills, tools, toolUse, date]
}

/// The chat's mode clause. Normal adds nothing; Evil adds exactly the catalog tone sentence (M2.T17 ships it in
/// the catalog and passes it here; the composer never invents one).
public enum PromptMode: Sendable, Hashable {
    case normal
    case evil(toneSentence: String)

    var clause: String {
        switch self {
        case .normal: ""
        case .evil(let s): s
        }
    }
}

/// Where the tool block goes in the rendered prompt (M1.T14 known failure mode "template drift").
public enum ToolPlacement: Sendable, Hashable {
    /// The canonical tool list is passed as `ChatRequest.tools` and the model's chat template renders it in its
    /// native tool slot. Default: the Qwen3.5/3.6 templates put that slot at the very start of the system turn,
    /// i.e. inside the stable prefix (`chat-9b-q4@…:chat_template.jinja` L44-60).
    case templateSlot
    /// Fallback for a family whose template puts tools after the system text: the rendered block becomes stable
    /// layer (5) of the system text (`ToolFormat` per-family quirk, minor).
    case systemLayer
}

/// Everything the stable prefix is made of. Equal inputs render byte-identical prefixes (PromptStabilityTests).
public struct PromptInputs: Sendable, Hashable {
    public var mode: PromptMode
    public var personalization: Personalization
    /// Frozen memory snapshot: empty in M1 (M8 fills it); frozen per chat, so it changes only on a user edit.
    public var memorySnapshot: String
    /// M8.T04: the project's instructions frozen for this chat ("" outside a project).
    public var projectInstructions: String = ""
    /// M8.T05: the whole-mode project files block (`ProjectContextLayer.wholeBlock`; "" otherwise).
    public var projectFiles: String = ""
    /// M7.T12: `SkillTools.block` of the active skills ("" = none).
    public var activeSkills: String = ""
    public var tools: [ToolSchema]
    public var toolPlacement: ToolPlacement
    /// M1.T16: the tool-selection sentence (`ToolSelection.clause`), rendered after the tool block only when tools
    /// are offered; empty = none.
    public var toolClause: String

    public init(
        mode: PromptMode = .normal, personalization: Personalization = .none, memorySnapshot: String = "",
        tools: [ToolSchema] = [], toolPlacement: ToolPlacement = .templateSlot, toolClause: String = ""
    ) {
        self.mode = mode
        self.personalization = personalization
        self.memorySnapshot = memorySnapshot
        self.tools = tools
        self.toolPlacement = toolPlacement
        self.toolClause = toolClause
    }
}

/// Byte-stable text normalisation for every layer: NFC, `\n` line endings, no trailing spaces per line, outer
/// whitespace trimmed (the same trim `PromptRenderer` applies, so manifest and request agree).
enum PromptText {
    static func normalize(_ s: String) -> String {
        let unified = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = unified.precomposedStringWithCanonicalMapping.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var l = line
                while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
                return l
            }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
