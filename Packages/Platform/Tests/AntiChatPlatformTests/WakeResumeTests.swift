// AT-204 part 2 (R-204 AC3) — M2.T09: system-paused downloads resume after `NSWorkspace.didWakeNotification` and when
// the network path comes back (the fake path monitor flips), within 2 s.
@testable import AntiChatNetwork
@testable import AntiChatPlatform
import AppKit
import Foundation
import Testing

@Suite(.serialized) struct WakeResumeTests {
    @Test func pathBackAndWakeResume() async throws {
        let dir = DL.tempDir("wake")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "w.bin", size: 16 * TransferConfig.mib)
        let server = try RangeServer(root: dir, args: ["--slow", "2000"])
        let path = PathStatus(fake: "ok")
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil,
                                     config: TransferConfig(chunkSize: 2 * TransferConfig.mib))
        let battery = Box(PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false))
        let assertions = Notices()
        let policy = DownloadPolicy(coordinator: dl, path: path, network: .testStore(), power: { battery.value },
                                    freeBytes: { 500_000_000_000 }, assertion: PowerAssertion(onChange: { assertions.add("\($0)") }))
        await policy.start()
        let job = await dl.enqueue(DL.request(blob, server: server))
        try await until { await dl.job(job.id)?.state == .running }

        // Network lost → system pause; back → resumed within 2 s.
        path.update(.none)
        try await until(2) { await dl.job(job.id)?.state == .paused }
        #expect(await dl.job(job.id)?.pauseReason == .system)
        let t0 = Date()
        path.update(.ok)
        try await until(2) { await dl.job(job.id)?.state == .running }
        let pathResume = Date().timeIntervalSince(t0)

        // A sleep (simulated by low battery holding the queue), then didWake → re-evaluated and resumed within 2 s.
        battery.value = PowerSource(onAC: false, batteryPercent: 5, lowPowerMode: false)
        await policy.evaluate()
        try await until(2) { await dl.job(job.id)?.state == .paused }
        battery.value = PowerSource(onAC: true, batteryPercent: 80, lowPowerMode: false)
        let t1 = Date()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await until(2) { await dl.job(job.id)?.state == .running }
        let wakeResume = Date().timeIntervalSince(t1)

        try await until(30) { await dl.job(job.id)?.state.isTerminal == true }
        let final = await dl.job(job.id)
        #expect(final?.state == .done, "\(String(describing: final))")
        try await until(2) { assertions.all.last == "false" }
        #expect(assertions.all.contains("true"), "power assertion held while downloading")
        await policy.stop()
        ATLog.write("AT-204", "part2.log", String(format: "WakeResume: path back → running in %.2f s; didWake → running in %.2f s; power assertion %@",
                                                  pathResume, wakeResume, assertions.all.compactMap { $0 }.joined(separator: "→")))
    }
}
