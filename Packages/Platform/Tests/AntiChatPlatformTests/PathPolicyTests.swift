// AT-204 part 2 (R-204 AC6) — M2.T09: no route / Low Data Mode → wait; metered path and > 1 GB → ask; approve → go.
@testable import AntiChatNetwork
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct PathPolicyTests {
    @Test func decisions() {
        let big: Int64 = 1_200_000_000, small: Int64 = 900_000_000
        #expect(PathPolicy.decide(.none, pendingBytes: small) == .wait(noticeKey: "download.offline"))
        #expect(PathPolicy.decide(.constrained, pendingBytes: small) == .wait(noticeKey: "download.offline"))
        #expect(PathPolicy.decide(.expensive, pendingBytes: big) == .ask)
        #expect(PathPolicy.decide(.expensive, pendingBytes: small) == .proceed)
        #expect(PathPolicy.decide(.expensive, pendingBytes: big, approvedExpensive: true) == .proceed)
        #expect(PathPolicy.decide(.ok, pendingBytes: big) == .proceed)
    }

    @Test func policyAsksOnExpensiveThenProceedsWhenApproved() async throws {
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("path")), database: nil)
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "expensive"), network: .testStore(),
                                    power: { PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false) }, freeBytes: { 500_000_000_000 })
        await dl.setHeld(true)
        await dl.enqueue(DownloadRequest(sha256: String(repeating: "c", count: 64), size: 1_200_000_000, sources: [URL(string: "http://127.0.0.1:9/x")!]))
        await policy.evaluate()
        #expect(await policy.status.holds == [.expensive])
        #expect(await policy.status.noticeKey == "download.expensiveAsk")
        #expect(await policy.status.askBytes == 1_200_000_000)
        await policy.approveExpensive()
        #expect(await policy.status.holds.isEmpty)
        #expect(await dl.isHeld == false)
        await policy.stop()
        for j in await dl.allJobs { await dl.cancel(j.id) }
        ATLog.write("AT-204", "part2.log", "PathPolicy: none/constrained → wait download.offline; expensive + 1.2 GB → download.expensiveAsk; [Download] → proceeds")
    }

    @Test func offlineOnlyHolds() async throws {
        let net = NetworkPolicyStore.testStore()
        net.offlineOnly = true
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("off")), database: nil)
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "ok"), network: net,
                                    power: { PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false) }, freeBytes: { 500_000_000_000 })
        await policy.evaluate()
        #expect(await policy.status.holds == [.offline])
    }

    @Test func lowBatteryHolds() async throws {
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("batt")), database: nil)
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "ok"), network: .testStore(),
                                    power: { PowerSource(onAC: false, batteryPercent: 9, lowPowerMode: false) }, freeBytes: { 500_000_000_000 })
        await policy.evaluate()
        #expect(await policy.status.holds == [.battery])
        #expect(PowerSource(onAC: false, batteryPercent: 10, lowPowerMode: false).pausesDownloads == false)
        var o = AntiChatFoundation.LaunchOptions()
        o.fakePower = "battery:5"
        #expect(PowerSource.current(options: o).pausesDownloads)
    }
}

import AntiChatFoundation
