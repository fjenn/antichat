// D-023 (a): which chat models get tools. The 0.8B starter (`chat-0.8b`) is chat-only: AT-229 measured 31/50 on
// tool choice (it answers instead of calling), so while it is the active chat model the harness offers it no tools
// (no tool slot in the template, no tool block in the prompt hash) and the UI offers no tool chips. A tool request
// made then waits for, or routes to, the full tier model once it is installed (M1.T16 registry/pre-router,
// M2.T20 StarterHandoff); it is never sent to the starter. M2's signed catalog carries the flag per model; until
// then the list is here.
import AntiChatEngineProtocol

public enum ModelToolCapability {
    /// Catalog keys of chat-only models (model-matrix §1: the starter / `chat_fast`).
    public static let chatOnlyModelKeys: Set<String> = ["chat-0.8b"]

    /// Whether `modelKey` may be offered tools.
    public static func supportsTools(modelKey: String) -> Bool {
        // M6.T05: `<key>+vision` (the same model with its vision tower) answers for `<key>`.
        !chatOnlyModelKeys.contains(modelKey.hasSuffix("+vision") ? String(modelKey.dropLast(7)) : modelKey)
    }

    public static func supportsTools(_ slot: ModelSlot) -> Bool { supportsTools(modelKey: slot.key) }

    /// The tools the harness exposes for a turn on `slot`: all of `tools`, or none for a chat-only model.
    public static func exposedTools(_ tools: [ToolSchema], for slot: ModelSlot) -> [ToolSchema] {
        supportsTools(slot) ? tools : []
    }

    /// Whether the composer may offer tool chips / the + menu's tool entries (M1.T17) while `activeModelKey` is the
    /// chat model.
    public static func offersToolChips(activeModelKey: String) -> Bool { supportsTools(modelKey: activeModelKey) }
}
