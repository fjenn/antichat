// AntiChatEngineStandby.xpc (M1.T12, A-M1-T12a): the second launchd job for the same engine helper.
// launchd defers the relaunch of an XPC service that ran < 10 s by the rest of its ThrottleInterval
// ("Service only ran for N seconds. Pushing respawn out by 10-N seconds"), measured 9.1–10.1 s for a helper
// killed 0.5 s after its start (build/at/AT-NFR-S4/throttle-probe.json). After a crash, EngineSupervisorClient
// connects to the other job, which is not throttled, so a restart stays ≤ 5 s (NFR-S4) whatever the age of the
// helper that died. This job carries no engine code: it re-executes the real helper binary in place (same pid,
// same launchd job, so the Mach service check-in below is this job's) and tells it which service name to serve.
import Darwin
import Foundation

let standby = Bundle.main.bundleURL  // …/Contents/XPCServices/AntiChatEngineStandby.xpc
let helper = standby.deletingLastPathComponent()
    .appendingPathComponent("AntiChatEngine.xpc/Contents/MacOS/AntiChatEngine").path
setenv("ANTICHAT_ENGINE_SERVICE", Bundle.main.bundleIdentifier ?? "app.antichat.AntiChat.EngineStandby", 1)
var argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), nil]
execv(helper, &argv)
FileHandle.standardError.write(Data("AntiChatEngineStandby: execv \(helper) failed: errno \(errno)\n".utf8))
exit(1)
