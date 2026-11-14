// M2 review #12: cancelling an image job while sd-server loads its model (the readiness loop's Task.sleep throws
// CancellationError) used to skip `stop()` and leave the process — and its GBs — running. A stand-in server that
// never becomes ready (a shell script that only sleeps) shows the teardown.
import AntiChatEngineProtocol
import Darwin
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct SDServerCancelTests {
    @Test func cancelDuringModelLoadStopsTheServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sd-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appending(path: "fake-sd-server")
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        let sup = SDServerSupervisor(config: .init(binary: bin.path, modelDir: dir.appending(path: "models").path))
        let set = ImageModelSet(key: "img-test", diffusionModel: "/dev/null", llm: "/dev/null", vae: "/dev/null", footprintBytes: 1)
        try await LlamaFixtures.reaping({ await sup.stop() }) {
            let job = Task { try await sup.start(set, timeout: .seconds(30)) }
            var pid: pid_t = 0
            for _ in 0..<200 where pid <= 0 {
                pid = sup.pidUnsafe
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(pid > 0)
            try await Task.sleep(for: .milliseconds(100))  // inside the readiness loop
            job.cancel()
            await #expect(throws: CancellationError.self) { try await job.value }
            #expect(await !sup.isRunning)
            var gone = false
            for _ in 0..<100 where !gone {
                gone = kill(pid, 0) != 0
                if !gone { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(gone, "sd-server \(pid) still running after the cancel")
            await sup.stop()
            if !gone { kill(pid, SIGKILL) }
        }
    }

    /// M9.T05 (JOB_CANCEL_FREE ≤ 2 s): `abort` ends the server at once even when it would not stop on SIGTERM — a
    /// stand-in that ignores TERM (SIG_IGN survives exec) and so stands for a server busy inside one long sampling step.
    /// `stop` alone would wait the 3 s teardown step before its SIGKILL.
    @Test func abortKillsAServerThatIgnoresTerm() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sd-abort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appending(path: "fake-sd-server")
        try "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 60\n".write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        let sup = SDServerSupervisor(config: .init(binary: bin.path, modelDir: dir.appending(path: "models").path))
        let set = ImageModelSet(key: "img-test", diffusionModel: "/dev/null", llm: "/dev/null", vae: "/dev/null", footprintBytes: 1)
        try await LlamaFixtures.reaping({ await sup.stop() }) {
            let job = Task { try await sup.start(set, timeout: .seconds(30)) }
            var pid: pid_t = 0
            for _ in 0..<200 where pid <= 0 {
                pid = sup.pidUnsafe
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(pid > 0)
            try await Task.sleep(for: .milliseconds(200))  // the TERM trap is installed
            let t0 = ContinuousClock.now
            let took = await sup.abort()
            let wall = ContinuousClock.now - t0
            #expect(await !sup.isRunning)
            #expect(kill(pid, 0) != 0, "sd-server \(pid) still exists after abort")
            #expect(wall < .seconds(1), "abort took \(wall) (reported \(took) s)")
            _ = try? await job.value  // the readiness loop sees the exit and fails (sdNotReady)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}
