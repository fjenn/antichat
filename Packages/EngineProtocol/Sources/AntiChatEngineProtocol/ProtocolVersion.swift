// Wire version of the app ↔ helper contract (architecture.md §4.3). A Hello with another version makes the
// helper answer `error(engine.versionMismatch)` and exit, so a half-updated install never mixes versions.
import Foundation

public enum EngineProtocolVersion {
    /// Bump on any wire-incompatible change to `ClientMessage` / `ServerMessage`.
    /// 2: M0.T05 voice + M0.T06 image lanes; 3: M0.T07 video lane; 4: M1.T05 contract (seven-event
    /// `EngineEvent`, separate `LifecycleEvent`, `HelloAck.capabilities`, `ServerMessage` envelope).
    /// 5: M6.T02 `ClientMessage.countTokens` (answered in `SearchReply.tokens`).
    /// 6: M6.T03 `ChatRequest.prefixPin`.
    /// 7: M3.T01 `ClientMessage.voiceService(VoiceMessage)` + `StreamItem.voice(VoiceEvent)`.
    /// 8: M4.T04 `ClientMessage.mediaJob`, `MediaEvent.job`, `HelloAck.engineInstanceID`, `ImageRequest.safety`.
    /// 9: M4 `ClientMessage.prepareSafety` (install-time ChildSafetyCheck compile; reply `SearchReply.error`).
    /// 10: M4.T13 `ImageRequest.refImagePaths` / `strength`, `ImageModelSet.loras`; M4.T15 `ImageRequest.localOperation`,
    /// `MediaJobKind.local`.
    /// 11: AT-273 round 65 `LifecycleEvent.generating(tokens:)` (generation liveness inside a tool call).
    public static let current = 11
    /// Mach service name of the bundled XPC service (project.yml `AntiChatEngine`).
    public static let serviceName = "app.antichat.AntiChat.Engine"
    /// The second launchd job for the same helper binary (project.yml `AntiChatEngineStandby`, M1.T12): after a
    /// crash the app connects to the other job, so launchd's respawn throttle never delays a restart (NFR-S4).
    public static let standbyServiceName = "app.antichat.AntiChat.EngineStandby"
    /// Both jobs, in rotation order.
    public static let serviceNames = [serviceName, standbyServiceName]
}
