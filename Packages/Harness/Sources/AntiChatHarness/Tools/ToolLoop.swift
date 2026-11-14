// The tool loop of one turn (M1.T16; G-012; R-232). TurnController runs it: a model step that ends with calls →
// each call is validated (RepairRetry), de-duplicated (DuplicateCallGuard), permitted (PermissionGate, ApprovalCard)
// and run (ToolRegistry); the results go back as `.tool` messages and the next step starts with the same stable
// prefix (R-269), until the model answers without calls, a step is text-only (`tool_choice: none` after a duplicate
// or a second malformed call), or the step budget (ToolLoopPolicy, by tier) is spent → `tool.loopLimit` + [Continue].
// This file holds the per-turn state; the async driver lives in TurnController (it owns the stream and the DB rows).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation

struct ToolLoopState: Sendable {
    let policy: ToolLoopPolicy
    /// The tools offered on every step (canonical, as in the prompt). M7.T14: a `find_tools` call replaces them (and
    /// the composed prompt) for the following steps.
    var offered: [ToolSchema]
    var composed: ComposedPrompt
    /// M7.T14 (R-266): what `find_tools` searches and keeps (nil = find_tools not offered this turn).
    var discovery: Discovery?

    struct Discovery: Sendable {
        /// The turn's eligible tools (switch-, Block- and offline-gated).
        var eligible: [ToolSchema]
        /// Chip tools and skill `allowed-tools` (always kept).
        var forced: [String]
        var tier: DeviceTier
        var access: ToolAccess
        /// The prompt inputs the step's prompt was composed from (tools replaced on discovery).
        var inputs = PromptInputs()
    }
    /// The visible path up to the user message.
    let conversation: [ChatMessage]
    let reasoning: ReasoningOptions
    let modelSlot: ModelSlot
    /// The turn's sampling (after M1.T15's Think harder preset), the same on every step.
    var sampling = Sampling()

    /// Steps whose calls ran (the budget counter).
    var steps = 0
    var duplicates = DuplicateCallGuard()
    var repair = RepairRetry()
    /// Assistant steps with their calls, and the tool results, since the user message.
    var history: [ChatMessage] = []
    /// The running step's calls and text.
    var stepCalls: [ToolCallRef] = []
    var stepText = ""
    /// The running step's `tool_choice` (`none` = text-only last step).
    var stepChoice: ToolChoice?
    /// Tool output is in context (NFR-SEC5).
    var untrusted = false

    init(policy: ToolLoopPolicy, offered: [ToolSchema], composed: ComposedPrompt, conversation: [ChatMessage],
         reasoning: ReasoningOptions, modelSlot: ModelSlot) {
        self.policy = policy
        self.offered = offered
        self.composed = composed
        self.conversation = conversation
        self.reasoning = reasoning
        self.modelSlot = modelSlot
    }

    /// The running step ended with calls: it joins the history and counts against the budget.
    mutating func finishStep() {
        steps += 1
        history.append(ChatMessage(role: .assistant, content: stepText, toolCalls: stepCalls))
        stepCalls = []
        stepText = ""
    }

    /// [Continue]: the history from the reply's persisted parts, a fresh budget, the earlier calls kept as seen (a
    /// repeat after Continue is still a duplicate) and the untrusted flag set if a result of `untrustedTool` exists.
    mutating func resume(from parts: [PartContent], untrustedTool: (String) -> Bool) {
        history = ToolLoopHistory.messages(from: parts)
        for m in history { for c in m.toolCalls { _ = duplicates.admit(name: c.name, argumentsJSON: c.argumentsJSON) } }
        untrusted = history.contains { $0.role == .tool && untrustedTool($0.toolName ?? "") }
        steps = 0
    }
}

/// Rebuilds the model-visible tool-loop history from a reply's `tool_call` / `tool_result` parts (in part order):
/// consecutive calls become one assistant step, each result a `.tool` message. Calls without a result are dropped
/// (they never ran).
public enum ToolLoopHistory {
    public static func messages(from parts: [PartContent]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pending: [ToolCallRef] = []
        var answered: Set<String> = []
        let results = parts.filter { $0.kind == .toolResult }.compactMap(object)
        for r in results { if let id = r["id"] as? String { answered.insert(id) } }
        for p in parts {
            switch p.kind {
            case .toolCall:
                guard let o = object(p), let id = o["id"] as? String, answered.contains(id) else { continue }
                pending.append(ToolCallRef(id: id, name: o["name"] as? String ?? "", argumentsJSON: o["arguments"] as? String ?? "{}"))
            case .toolResult:
                if !pending.isEmpty {
                    out.append(ChatMessage(role: .assistant, content: "", toolCalls: pending))
                    pending = []
                }
                guard let o = object(p) else { continue }
                let name = o["name"] as? String ?? ""
                out.append(ChatMessage(role: .tool, content: MediaToolResult.forModel(name: name, result: o["result"] as? String ?? ""),
                                       toolCallID: o["id"] as? String, toolName: o["name"] as? String))
            default:
                continue
            }
        }
        return out
    }

    static func object(_ p: PartContent) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(p.body.utf8))) as? [String: Any]
    }
}
