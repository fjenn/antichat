// M0.T01 placeholder: proves the module graph compiles (architecture.md §2, §3).
// The real contents land with the gaps that own this module (PRD §7).
import Foundation
import AntiChatEngineProtocol
import MLXLMCommon
import FluidAudio
import Subprocess
import EventSource

/// Marker for the AntiChatEngines module.
public enum AntiChatEnginesModule {
    public static let name = "AntiChatEngines"
    /// Direct module dependencies this placeholder imports (architecture.md §3 edges).
    public static let imports: [String] = ["AntiChatEngineProtocol"]
}
