// M0.T07 (S-10): sd progress parsing and the child process plumbing (fd 3, cancel). The one-shot command lines went in M5.T14.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct VideoSpikeTests {
    @Test func sdProgressLines() {
        let a = VideoRuntimeSupervisor.parseSDProgress("  |==>      |  1/20 -   6.15s/it - ETA 01:56\u{1b}[K")
        #expect(a?.0 == 1 && a?.1 == 20)
        let b = VideoRuntimeSupervisor.parseSDProgress("  |=====|  20/20 - 5.10s/it")
        #expect(b?.0 == 20 && b?.1 == 20)
        #expect(VideoRuntimeSupervisor.parseSDProgress("[I] sampling completed, taking 105.91s") == nil)
    }

    @Test func childFD3AndExit() async throws {
        let c = try VideoChild(executable: "/bin/sh", args: ["-c", "echo '{\"event\":\"step\"}' >&3; echo noise; exit 0"],
                               env: VideoChild.environment(), progressFD3: true, logFile: nil, watchdogExecutable: nil)
        var got: [String] = []
        for await l in c.lines { got.append(l) }
        #expect(got == ["{\"event\":\"step\"}"])
        #expect(VideoChild.succeeded(await c.wait()))
    }

    @Test func childEnvironmentIsAllowListed() async throws {
        let c = try VideoChild(executable: "/usr/bin/env", args: [], env: VideoChild.environment(), progressFD3: false,
                               logFile: nil, watchdogExecutable: nil)
        var got: [String] = []
        for await l in c.lines { got.append(l) }
        _ = await c.wait()
        #expect(got.contains("HF_HUB_OFFLINE=1") && got.contains("PYTHONNOUSERSITE=1"))
        #expect(!got.contains { $0.hasPrefix("HF_TOKEN") || $0.lowercased().hasPrefix("https_proxy") })
    }

    @Test func cancelKillsProcessGroup() async throws {
        let c = try VideoChild(executable: "/bin/sh", args: ["-c", "trap '' TERM; sleep 30 & wait"], env: VideoChild.environment(),
                               progressFD3: true, logFile: nil, watchdogExecutable: nil)
        try await Task.sleep(for: .milliseconds(200))
        let s = await c.terminate(grace: .milliseconds(300))
        #expect(!c.isRunning)
        #expect(s < 3)
    }
}
