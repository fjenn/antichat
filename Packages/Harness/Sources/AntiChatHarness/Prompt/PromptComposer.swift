// PromptComposer (M1.T14 steps 1-3; P-shell-07; G-007; R-230, R-269): renders the layered system prompt
// deterministically — fixed layer order, normalised text, sorted-key JSON, no timestamps or ids in the stable
// part — and the vendored Osaurus `PromptManifest` over it (token accounting + prefix hash).
//
// The stable prefix (layers 1-5) changes only when its inputs change (the user edits instructions, memory or the
// tool set); the caller composes once per turn, so a change starts a new prefix at the next turn, never mid-turn.
// The date line (day granularity) is the last stable layer; the conversation follows the system turn, and the
// current time (to the minute) rides on the newest user turn as `ChatRequest.turnContext`, never persisted (D-022).
//
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift:L19-50
// (append skips empty sections / render / manifest); Osaurus' agent, sandbox and skill sections do not apply.
import AntiChatEngineProtocol
import CryptoKit
import Foundation
import OsaurusVendored

/// One turn's prompt: the layers for `ChatRequest.messages`, the canonical tools for `ChatRequest.tools`, and the
/// hashes recorded in `message.provenance_json.promptHash`.
public struct ComposedPrompt: Sendable {
    /// Stable layers (non-empty only, in order), the date layer last.
    public let layers: [PromptLayer]
    /// Canonical, compacted tool schemas (sorted by name). Passed as `ChatRequest.tools`.
    public let tools: [ToolSchema]
    /// The rendered tool block (one sorted-key JSON object per line); empty without tools.
    public let toolBlock: String
    public let manifest: PromptManifest
    /// The whole system turn as hashed: layers 1-5 (the tool block included) and the date line.
    public let stablePrefix: String
    /// SHA-256 (hex, 64 chars) of `stablePrefix` (AT-230 (1)).
    public let stableSHA256: String
    /// The vendored manifest's prefix hash (`PromptManifest.prefixHash`), stored per turn as `promptHash`.
    public let promptHash: String
    public let dateLine: String
    /// The ephemeral time line for the newest user turn (`ChatRequest.turnContext`).
    public let timeLine: String

    /// The system turn's text as the chat template receives it: stable layers, the date line last.
    public var systemText: String {
        layers.map(\.content).joined(separator: "\n\n")
    }

    /// `ChatRequest.messages`: the layers, then the conversation (the persisted history, unchanged).
    public func items(conversation: [ChatMessage]) -> [PromptItem] {
        layers.map(PromptItem.layer) + conversation.map(PromptItem.message)
    }

    /// A ready request for `conversation` (requestID/sessionID/slot/sampling from the caller).
    public func request(
        requestID: UUID = UUID(), sessionID: UUID, modelSlot: ModelSlot, conversation: [ChatMessage],
        reasoning: ReasoningOptions = .off, sampling: Sampling = Sampling(), toolChoice: ToolChoice? = nil
    ) -> ChatRequest {
        ChatRequest(
            requestID: requestID, sessionID: sessionID, modelSlot: modelSlot, messages: items(conversation: conversation),
            tools: tools, toolChoice: tools.isEmpty ? nil : toolChoice, reasoning: reasoning, sampling: sampling,
            turnContext: timeLine)
    }
}

public struct PromptComposer: Sendable {
    /// Layer (1): one neutral sentence naming AntiChat (`Resources/prompts/base.txt`).
    public let basePersona: String
    public let toolRenderer: ToolBlockRenderer

    public init(basePersona: String = PromptComposer.bundledBasePersona, toolRenderer: ToolBlockRenderer = ToolBlockRenderer()) {
        self.basePersona = PromptText.normalize(basePersona)
        self.toolRenderer = toolRenderer
    }

    public static let bundledBasePersona: String = {
        guard let url = Bundle.module.url(forResource: "base", withExtension: "txt", subdirectory: "prompts"),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("AntiChatHarness: Resources/prompts/base.txt missing") }
        return s
    }()

    public func compose(_ inputs: PromptInputs, context: VolatileContext = VolatileContext()) -> ComposedPrompt {
        let tools = toolRenderer.canonical(inputs.tools)
        let toolBlock = toolRenderer.render(tools)
        var sections: [PromptSection] = []
        func append(_ s: PromptSection) {
            guard !s.isEmpty else { return }
            sections.append(s)
        }
        append(.static(id: PromptLayerID.base, label: "Base persona", content: basePersona))
        append(.static(id: PromptLayerID.mode, label: "Mode", content: PromptText.normalize(inputs.mode.clause)))
        append(.static(id: PromptLayerID.instructions, label: "Custom instructions",
                       content: PersonalizationLayer.render(inputs.personalization)))
        append(.static(id: PromptLayerID.project, label: "Project instructions", content: ProjectLayer.render(inputs.projectInstructions)))
        append(.static(id: PromptLayerID.projectFiles, label: "Project files", content: inputs.projectFiles))
        append(.static(id: PromptLayerID.memory, label: "Memory", content: PromptText.normalize(inputs.memorySnapshot)))
        append(.static(id: PromptLayerID.skills, label: "Skills", content: PromptText.normalize(inputs.activeSkills)))
        append(.static(id: PromptLayerID.tools, label: "Tools", content: toolBlock))
        if !tools.isEmpty {
            append(.static(id: PromptLayerID.toolUse, label: "Tool use", content: PromptText.normalize(inputs.toolClause)))
        }
        let dateLine = context.dateLine
        append(.static(id: PromptLayerID.date, label: "Date", content: dateLine))
        let manifest = PromptManifest(sections: sections)

        // Wire layers: every stable section except the tool block under `.templateSlot` (the template renders the
        // canonical `tools` in its own slot at the head of the system turn, inside the stable prefix).
        var layers: [PromptLayer] = []
        for s in sections {
            if s.id == PromptLayerID.tools, inputs.toolPlacement == .templateSlot { continue }
            let content = s.content.trimmingCharacters(in: .whitespacesAndNewlines)
            layers.append(PromptLayer(id: s.id, content: content, stable: s.cacheability == .static))
        }
        let stablePrefix = manifest.staticPrefixContent
        let digest = SHA256.hash(data: Data(stablePrefix.utf8)).map { String(format: "%02x", $0) }.joined()
        return ComposedPrompt(
            layers: layers, tools: tools, toolBlock: toolBlock, manifest: manifest, stablePrefix: stablePrefix,
            stableSHA256: digest, promptHash: manifest.prefixHash, dateLine: dateLine, timeLine: context.timeLine)
    }
}
