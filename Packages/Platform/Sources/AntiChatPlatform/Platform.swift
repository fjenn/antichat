// M0.T01 placeholder: proves the module graph compiles (architecture.md §2, §3).
// The real contents land with the gaps that own this module (PRD §7).
import Foundation
import AntiChatNetwork
import AntiChatStorage
import HuggingFace
import Sparkle
import OsaurusVendored

/// Marker for the AntiChatPlatform module.
public enum AntiChatPlatformModule {
    public static let name = "AntiChatPlatform"
    /// Direct module dependencies this placeholder imports (architecture.md §3 edges).
    public static let imports: [String] = ["AntiChatNetwork", "AntiChatStorage", "OsaurusVendored"]
}
