// Tool selection for one model step (M1.T16; D-023 (b) tuning; G-012). Decides, before the request is built, which
// of the turn's tools the model sees and with which `tool_choice`:
//   1. no tools, or a chat-only model (D-023 (a), `ModelToolCapability`) → no tools;
//   2. a purely conversational user turn (greeting, thanks, farewell) → no tools: the vendored Osaurus
//      `CapabilityQueryIntent` abstain gate (P-shell-12; M1.T16 failure mode "small models loop on get_time");
//   3. otherwise every tool, `tool_choice: auto`, plus the selection clause in the tool layer (layer (5)).
// The clause is about WHEN to call a tool (call it when the request needs what it does or the user asks for it;
// otherwise answer directly). It says nothing about content, so it is not a safety/behaviour clause in the R-241
// sense (test-strategy §9 rule 4 covers the Normal prompt without tools, which stays base persona + date).
// The decision is a pure function of the tool set and the newest user text: no model, no content judgement.
import AntiChatEngineProtocol
import Foundation
import OsaurusVendored

public enum ToolSelection {
    /// The clause variants measured for D-023 (`build/at/AT-229/tuning/`). `.standard` ships.
    public enum Variant: String, Sendable, CaseIterable {
        /// No selection tuning (the M1.T13 measurement).
        case off
        /// Abstain gate only.
        case abstain
        /// Abstain gate + selection clause.
        case standard
    }

    /// Layer (5) addition when tools are offered (byte-stable; part of the stable prefix, so the same tool set keeps
    /// the cached prefix, R-269).
    public static let clause = """
        Call a tool only when the request needs what that tool does, or when the user asks you to use it; \
        then call it instead of writing out what it would do. For a tool that runs code, run the code with it \
        rather than only showing the code. Otherwise answer directly without calling any tool.
        """

    public struct Plan: Sendable, Hashable {
        public var tools: [ToolSchema]
        public var toolChoice: ToolChoice?
        /// The selection clause for the tool layer; nil when no tools are offered.
        public var clause: String?
        /// Why tools were withheld (diagnostics / tests): nil when offered.
        public var withheld: Withheld?

        public enum Withheld: String, Sendable, Hashable { case noTools, chatOnlyModel, conversational }
    }

    /// The plan for a step whose newest user text is `userText`.
    public static func plan(
        tools: [ToolSchema], userText: String?, modelKey: String? = nil, variant: Variant = .standard
    ) -> Plan {
        if tools.isEmpty { return Plan(tools: [], toolChoice: nil, clause: nil, withheld: .noTools) }
        if let modelKey, !ModelToolCapability.supportsTools(modelKey: modelKey) {
            return Plan(tools: [], toolChoice: nil, clause: nil, withheld: .chatOnlyModel)
        }
        if variant != .off, let userText, CapabilityQueryIntent.isConversationalAbstain(userText) {
            return Plan(tools: [], toolChoice: nil, clause: nil, withheld: .conversational)
        }
        return Plan(tools: tools, toolChoice: .auto, clause: variant == .standard ? clause : nil, withheld: nil)
    }

    /// Request items for a conversation that brings its own leading system message(s) (eval sets): those become
    /// leading layers and the clause follows them, the order the app's composer uses (layers 1-4, then the tool
    /// layer). Without a clause the items are the messages unchanged.
    public static func items(_ conversation: [ChatMessage], clause: String?) -> [PromptItem] {
        guard let clause else { return conversation.map(PromptItem.message) }
        let head = conversation.prefix(while: { $0.role == .system })
        return head.map { .layer(PromptLayer(id: "system", content: $0.content)) }
            + [.layer(PromptLayer(id: PromptLayerID.tools, content: clause))]
            + conversation.dropFirst(head.count).map(PromptItem.message)
    }

    /// The newest user message's text in `conversation`.
    public static func newestUserText(_ conversation: [ChatMessage]) -> String? {
        conversation.last(where: { $0.role == .user })?.content
    }
}
