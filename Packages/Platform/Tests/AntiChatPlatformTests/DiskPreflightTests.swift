// AT-204 part 2 (R-204 AC1) + AT-NFR-D2 unit leg — M2.T09: the single disk rule free ≥ total + 10 GB, exactly at the
// boundary, and the "Needs {gb} GB more free space." figure.
@testable import AntiChatFoundation
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct DiskPreflightTests {
    let gb: Int64 = 1_000_000_000

    @Test func boundary() {
        let total: Int64 = 5 * gb
        #expect(DiskPreflight.check(total: total, free: total + 10 * gb) == .ok)
        #expect(DiskPreflight.check(total: total, free: total + 9_990_000_000) == .short(gbNeeded: 1))
        #expect(DiskPreflight.check(total: total, free: total + 10 * gb + 1) == .ok)
        #expect(DiskPreflight.check(total: total, free: total + 10 * gb - 1) == .short(gbNeeded: 1))
        ATLog.write("AT-NFR-D2", "unit.log", "DiskPreflight boundary: total+9.99 GB → short, total+10.00 GB → ok")
    }

    /// The UI test's case: `-FakeFreeDiskGB 12` with a 5 GB selection → "Needs 3 GB more free space."
    @Test func fakeFreeDiskNeedsThree() {
        var o = LaunchOptions()
        o.fakeFreeDiskGB = 12
        #expect(DiskPreflight.freeBytes(volume: URL(fileURLWithPath: "/"), options: o) == 12 * gb)
        #expect(DiskPreflight.check(total: 5 * gb, volume: URL(fileURLWithPath: "/"), options: o) == .short(gbNeeded: 3))
        #expect(DiskPreflight.check(total: 2 * gb, volume: URL(fileURLWithPath: "/"), options: o) == .ok)
    }

    @Test func roundsUpToWholeGB() {
        #expect(DiskPreflight.check(total: 2_300_000_000, free: 10 * gb) == .short(gbNeeded: 3))
        #expect(DiskPreflight.isBelowHeadroom(free: 9 * gb))
        #expect(!DiskPreflight.isBelowHeadroom(free: 10 * gb))
    }

    @Test func liveFreeSpaceIsRead() {
        #expect(DiskPreflight.freeBytes(volume: FileManager.default.temporaryDirectory, options: LaunchOptions()) > 0)
    }

    /// The policy's watcher holds the queue below the headroom, and every entry point uses the same rule.
    @Test func policyHoldsBelowHeadroom() async throws {
        let free = Box<Int64>(9 * gb)
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("disk")), database: nil)
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "ok"), network: .testStore(),
                                    power: { PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false) }, freeBytes: { free.value })
        #expect(await policy.preflight(total: 5 * gb) == .short(gbNeeded: 6))
        await dl.setHeld(true)
        await dl.enqueue(DownloadRequest(sha256: String(repeating: "e", count: 64), size: 10, sources: [URL(string: "http://127.0.0.1:9/x")!]))
        await policy.evaluate()
        #expect(await policy.status.holds == [.disk])
        #expect(await policy.status.noticeKey == "download.diskFull")
        #expect(await dl.isHeld)
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

import AntiChatNetwork
extension NetworkPolicyStore {
    /// A store on its own defaults suite (no Offline only from another test).
    static func testStore() -> NetworkPolicyStore {
        NetworkPolicyStore(defaults: UserDefaults.inMemory(), launch: LaunchOptions())
    }
}
