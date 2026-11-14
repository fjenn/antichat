// M0.T01 placeholder: proves the module graph compiles (architecture.md §2, §3).
// The real contents land with the gaps that own this module (PRD §7).
import Foundation
import AntiChatStorage
import AntiChatEngineProtocol

/// Marker for the AntiChatKnowledge module.
public enum AntiChatKnowledgeModule {
    public static let name = "AntiChatKnowledge"
    /// Direct module dependencies this placeholder imports (architecture.md §3 edges).
    public static let imports: [String] = ["AntiChatStorage", "AntiChatEngineProtocol"]
}
