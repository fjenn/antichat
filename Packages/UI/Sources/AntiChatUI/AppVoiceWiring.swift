// The composition root's voice wiring (called from `AntiChatApp.init`; `AppVoiceWiringTests` runs the same function):
// the shared voice client (`EngineServices.voice(for:)`, the XPC helper voice goes to even when chat replays
// in-process) gets the app's memory-fit guard — the main engine's own guard when it has one, else
// `EngineServices.appFitGuard()`. Before this the voice client was the one supervisor client built with `fitGuard: nil`
// in the real app (only tests injected one).
import AntiChatHarness
import Foundation

public enum AppVoiceWiring {
    public static func attach(engine: any EngineService) {
        EngineServices.setVoiceFitGuard((engine as? EngineSupervisorClient)?.fitGuard ?? EngineServices.appFitGuard())
    }
}
