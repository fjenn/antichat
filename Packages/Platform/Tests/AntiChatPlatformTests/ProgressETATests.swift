// AT-204 part 2 (R-204 AC2) — M2.T09: progress per pack (bytes, %), speed as an EWMA over 10 s and the TUFF ETA
// (estimating during the 10 s / 32 MB warm-up, then remaining = bytes left ÷ rate), and the menu-bar model.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct ProgressETATests {
    func job(_ id: String, pack: String, size: Int64, done: Int64, state: DownloadJob.State = .running) -> DownloadJob {
        DownloadJob(id: id, request: DownloadRequest(sha256: String(repeating: id.first!, count: 64), size: size, sources: [], pack: pack),
                    state: state, pauseReason: nil, bytesDone: done, retries: 0, errorKey: nil, createdAt: Date())
    }

    @Test func perPackSpeedAndETA() {
        let t = Box(0.0)
        let agg = ProgressAggregator(clock: { t.value })
        let mb: Int64 = 1_000_000
        agg.ingest(.state(job("p1", pack: "photo", size: 600 * mb, done: 0)))
        agg.ingest(.state(job("p2", pack: "photo", size: 400 * mb, done: 0)))
        agg.ingest(.state(job("c1", pack: "chat", size: 100 * mb, done: 100 * mb, state: .done)))
        #expect(agg.progress("photo")?.bytesTotal == 1000 * mb)
        #expect(agg.progress("photo")?.etaSeconds == nil)  // estimating
        // 10 MB/s for 40 s (TUFF refreshes the ETA every 30 s: computed at 10 s, then at 40 s).
        for s in 1...40 {
            t.value = Double(s)
            agg.ingest(.progress(id: "p1", bytesDone: Int64(s) * 10 * mb, total: 600 * mb))
        }
        let p = try! #require(agg.progress("photo"))
        #expect(p.bytesDone == 400 * mb)
        #expect(p.percent == 40)
        #expect(abs(p.bytesPerSecond - 10e6) / 10e6 < 0.06, "EWMA \(p.bytesPerSecond)")
        let eta = try! #require(p.etaSeconds)
        #expect(abs(eta - 60) < 3, "ETA \(eta) s for 600 MB at 10 MB/s")
        #expect(agg.progress("chat")?.state == .done)
        #expect(agg.progress("chat")?.percent == 100)
        #expect(agg.snapshot.map(\.pack) == ["chat", "photo"])
        ATLog.write("AT-204", "part2.log", String(format: "ProgressETA: photo 40%% at EWMA %.2f MB/s, ETA %.0f s (600 MB left)", p.bytesPerSecond / 1e6, eta))
    }

    @Test func percentNeverHundredBeforeDone() {
        let agg = ProgressAggregator(clock: { 0 })
        agg.ingest(.state(job("v", pack: "voice", size: 1000, done: 999, state: .verifying)))
        #expect(agg.progress("voice")?.percent == 99)
        #expect(agg.progress("voice")?.state == .verifying)
    }

    @MainActor @Test func menuBarModel() {
        let agg = ProgressAggregator(clock: { 0 })
        agg.ingest(.state(job("a", pack: "chat", size: 100, done: 100, state: .done)))
        agg.ingest(.state(job("b", pack: "photo", size: 100, done: 42)))
        let m = MenuBarProgressModel()
        m.update(agg.snapshot)
        #expect(m.isActive)
        #expect(m.current?.pack == "photo")
        #expect(m.current?.percent == 42)
        #expect(abs(m.overallFraction - 0.71) < 0.001)
    }
}
