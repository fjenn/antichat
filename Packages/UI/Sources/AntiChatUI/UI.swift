// M0.T01 placeholder: proves the module graph compiles (architecture.md §2, §3).
// The real contents land with the gaps that own this module (PRD §7).
import Foundation
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import KeyboardShortcuts

/// Marker for the AntiChatUI module.
public enum AntiChatUIModule {
    public static let name = "AntiChatUI"
    /// Direct module dependencies this placeholder imports (architecture.md §3 edges).
    public static let imports: [String] = ["AntiChatDesign", "AntiChatHarness", "AntiChatPlatform"]
}
