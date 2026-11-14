// AT-204 part 2 (R-204 AC5) — M2.T09: connection failures back off 1 → 2 → 4 … ≤ 60 s (virtual clock), and after three
// in a row the notice is "Download paused — check your connection" [Retry].
@testable import AntiChatPlatform
import AntiChatNetwork
import Foundation
import Testing

@Suite(.serialized) struct BackoffTests {
    @Test func delaySequence() {
        var b = Backoff()
        let seq = (0..<8).map { _ in b.failed() }
        #expect(seq == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(b.showsPausedNotice)
        b.succeeded()
        #expect(!b.showsPausedNotice && b.failed() == 1)
    }

    /// The policy schedules exactly that sequence for a job whose source refuses connections, and shows the notice
    /// from the third failure on; [Retry] resets it.
    @Test func policyBacksOffAndShowsPausedNotice() async throws {
        let delays = Delays()
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("backoff")), database: nil,
                                     config: TransferConfig(perChunkAttempts: 1), sleep: { _ in })
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "ok"), network: .testStore(),
                                    power: { PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false) },
                                    freeBytes: { 500_000_000_000 },
                                    sleep: { d in
                                        if d >= 1, d <= 60 { delays.add(d) }
                                        try await Task.sleep(for: .milliseconds(5))
                                    })
        let notices = Notices()
        policy.observe { notices.add($0.noticeKey) }
        await policy.start()
        // Port 9 (discard) is closed on loopback: every attempt fails fast with "could not connect".
        await dl.enqueue(DownloadRequest(sha256: String(repeating: "b", count: 64), size: 1000, sources: [URL(string: "http://127.0.0.1:9/f")!]))
        try await until(20) { delays.backoff.count >= 8 }
        await policy.stop()
        #expect(Array(delays.backoff.prefix(8)) == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(notices.all.contains("download.pausedConnection"))
        #expect(await policy.failures >= 3)
        await policy.retryNow()
        #expect(await policy.failures == 0)
        ATLog.write("AT-204", "part2.log", "Backoff: virtual delays \(Array(delays.backoff.prefix(8))) s; notice download.pausedConnection after 3 failures; Retry resets")
    }

    /// M2 review #8: a file every source reports gone (404/410) is not retried forever — no backoff, the job stays
    /// failed with `download.unavailable`, and the notice is not "check your connection".
    @Test func unavailableIsNotRetried() async throws {
        let dir = DL.tempDir("backoff-404")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "gone.bin", size: 64 * 1024)
        let server = try RangeServer(root: dir, args: ["--404", "gone.bin"])
        let delays = Delays()
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil,
                                     config: TransferConfig(perChunkAttempts: 1), sleep: { _ in })
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "ok"), network: .testStore(),
                                    power: { PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false) },
                                    freeBytes: { 500_000_000_000 },
                                    sleep: { d in
                                        if d >= 1, d <= 60 { delays.add(d) }
                                        try await Task.sleep(for: .milliseconds(5))
                                    })
        let notices = Notices()
        policy.observe { notices.add($0.noticeKey) }
        await policy.start()
        let job = await dl.enqueue(DL.request(blob, server: server))
        #expect(await dl.wait(job.id)?.errorKey == "download.unavailable")
        try await Task.sleep(for: .milliseconds(300))
        await policy.stop()
        #expect(delays.backoff.isEmpty, "no backoff for a gone file: \(delays.backoff)")
        #expect(await dl.job(job.id)?.state == .failed)
        #expect(server.records().filter { $0.status == 404 }.count == 1)
        #expect(!notices.all.contains("download.pausedConnection"))
    }

    /// M2 review #4: `waitOutcome` (the update fetch) follows the policy's retry of a transient failure to `done`
    /// instead of giving up on the first `.failed`.
    @Test func waitOutcomeFollowsTheRetryToDone() async throws {
        let dir = DL.tempDir("backoff-outcome")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "flaky.bin", size: 8 * TransferConfig.mib)
        let chunk = TransferConfig.mib
        // The fault lands in the MIDDLE of chunk 5 (4.5 MiB), so that response is cut short and the client fails
        // whatever its timing. On a chunk boundary (4 MiB) the 4th response was already complete when the fault fired;
        // the only failure the client could see was the next request landing inside the 0.3 s outage, which a loaded
        // host (the cut's send-buffer drain + the client's next request) could miss — and then no failure at all.
        let server = try RangeServer(root: dir, args: ["--fail-after", "\(blob.size / 2 + chunk / 2)", "--down-for", "0.3"])
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil,
                                     config: TransferConfig(lanes: 1, chunkSize: chunk, perChunkAttempts: 1), sleep: { _ in })
        let policy = DownloadPolicy(coordinator: dl, path: PathStatus(fake: "ok"), network: .testStore(),
                                    power: { PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: false) },
                                    freeBytes: { 500_000_000_000 },
                                    sleep: { _ in try await Task.sleep(for: .milliseconds(400)) })
        let states = Notices()
        dl.observe { e in if case .state(let j) = e { states.add("\(j.state):\(j.errorKey ?? "")") } }
        await policy.start()
        let job = await dl.enqueue(DL.request(blob, server: server))
        let end = await dl.waitOutcome(job.id)
        await policy.stop()
        #expect(states.all.contains("failed:download.pausedConnection"), "\(states.all)")
        #expect(end?.state == .done)
    }
}

final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var d: [Double] = []
    func add(_ x: Double) { lock.withLock { d.append(x) } }
    /// Backoff delays only (the 30 s disk-watcher interval is excluded).
    var backoff: [Double] { lock.withLock { d.filter { $0 != 30 } } }
}

final class Notices: @unchecked Sendable {
    private let lock = NSLock()
    private var n: [String?] = []
    func add(_ x: String?) { lock.withLock { n.append(x) } }
    var all: [String?] { lock.withLock { n } }
}
