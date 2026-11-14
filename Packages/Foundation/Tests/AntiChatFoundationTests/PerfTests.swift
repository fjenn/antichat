// M1.T26a: Signposts → PerfRecorder JSONL, HitchAccumulator frame-gap accounting, process start clock.
@testable import AntiChatFoundation
import Foundation
import Testing

@Suite(.serialized)
struct PerfTests {
    private func tempLog() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).jsonl").path
    }

    private func lines(_ path: String) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    @Test func intervalsAndEventsAreRecordedWhenEnabled() throws {
        let path = tempLog()
        PerfRecorder.configure(path: path)
        defer { PerfRecorder.configure(path: nil); try? FileManager.default.removeItem(atPath: path) }
        #expect(PerfRecorder.isEnabled)
        let st = Signposts.begin(.sendAck, on: Signposts.ui)
        usleep(2000)
        Signposts.end(.sendAck, st, on: Signposts.ui, meta: ["state": "loaded"])
        Signposts.event(.hitch, value: 41.5)
        Signposts.mark(.launchToUsable, durationNs: 812_000_000)
        let rows = try lines(path)
        #expect(rows.count == 3)
        #expect(rows[0]["name"] as? String == "sendAck")
        #expect(rows[0]["kind"] as? String == "interval")
        #expect(((rows[0]["dur_ns"] as? NSNumber)?.uint64Value ?? 0) >= 2_000_000)
        #expect((rows[0]["meta"] as? [String: String])?["state"] == "loaded")
        #expect(rows[1]["name"] as? String == "hitch" && rows[1]["kind"] as? String == "event")
        #expect((rows[1]["meta"] as? [String: String])?["value"] == "41.5")
        #expect(rows[2]["name"] as? String == "launchToUsable" && (rows[2]["dur_ns"] as? NSNumber)?.uint64Value == 812_000_000)
    }

    @Test func disabledRecorderWritesNothing() throws {
        let path = tempLog()
        PerfRecorder.configure(path: nil)
        let st = Signposts.begin(.stopIdle, on: Signposts.ui)  // M1.T06 alias of stopToIdle
        Signposts.end(.stopIdle, st, on: Signposts.ui)
        #expect(!PerfRecorder.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(Signposts.Interval.stopIdle == .stopToIdle)
    }

    @Test func environmentConfigParsesQuitList() {
        let c = PerfRecorder.environmentConfig(["ANTICHAT_PERF_LOG": "/tmp/x.jsonl", "ANTICHAT_PERF_QUIT_AFTER": "launchToUsable, chatOpen"])
        #expect(c.path == "/tmp/x.jsonl")
        #expect(c.quitAfter == ["launchToUsable", "chatOpen"])
        #expect(PerfRecorder.environmentConfig(["ANTICHAT_PERF_LOG": ""]).path == nil)
    }

    @Test func hitchAccumulatorCountsFramesOver33ms() {
        var a = HitchAccumulator()
        let t: [Double] = [0, 0.0167, 0.0334, 0.0834, 0.1001, 0.1001 + 0.034]
        let hits = t.compactMap { a.tick($0) }
        #expect(a.frames == 5)
        #expect(a.hitches == 2)  // 50 ms and 34 ms gaps
        #expect(hits.count == 2)
        #expect(abs(a.longestMs - 50) < 0.01)
        a.resetClock()
        #expect(a.tick(10) == nil)  // the pause after reset is not a frame
        #expect(a.frames == 5)
    }

    @Test func processStartIsInThePast() throws {
        let start = try #require(ProcessClock.processStartDate())
        #expect(start < Date())
        let ns = try #require(ProcessClock.nanosecondsSinceProcessStart())
        #expect(ns > 0)
    }
}
