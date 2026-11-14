// AntiChatEngine.xpc entry point (M0.T04 step 2; architecture §4).
// Serves the XPC contract of AntiChatEngineProtocol under this job's service name: AntiChatEngine.xpc, or
// AntiChatEngineStandby.xpc, whose trampoline re-executes this binary with ANTICHAT_ENGINE_SERVICE set
// (M1.T12, A-M1-T12a). The legacy `--llama-watchdog <pgid>` re-exec stays as the fallback watchdog when the
// bundled `Contents/Helpers/llama-watchdog` is missing (Watchdog.swift).
import AntiChatEngineHost
import AntiChatEngines
import Foundation

LlamaWatchdog.runIfRequested()

let service = ProcessInfo.processInfo.environment["ANTICHAT_ENGINE_SERVICE"] ?? EngineListener.defaultServiceName
unsetenv("ANTICHAT_ENGINE_SERVICE")  // not inherited by llama-server / sd-server
let engine = EngineListener(paths: .fromBundle())
do {
    try engine.start(service: service)
} catch {
    FileHandle.standardError.write(Data("AntiChatEngine: listener for \(service) failed: \(error)\n".utf8))
    exit(1)
}
dispatchMain()
