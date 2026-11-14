// M0.T01 placeholder: proves the module graph compiles (architecture.md §2, §3).
// The real contents land with the gaps that own this module (PRD §7).
import Foundation
import AntiChatNetwork
import AntiChatStorage
import MCP
import EventSource

/// Marker for the AntiChatTools module.
public enum AntiChatToolsModule {
    public static let name = "AntiChatTools"
    /// Direct module dependencies this placeholder imports (architecture.md §3 edges).
    public static let imports: [String] = ["AntiChatNetwork", "AntiChatStorage"]
}
