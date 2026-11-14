// M5.T08 (R-046 AC2, AT-046 AC2 unit leg; P-media-12): the estimator, the history factor, the live ETA and the
// slowdown flag. The donor's `.test.ts` fixtures (atomic-chat-core@6c7e9e8) are not in this repo: the cases below
// restate the donor behaviour named in the PRD (verdict fits/tight/exceeds, encode + steps × t_step + decode,
// median-of-last-5 recalibration, live ETA + slowdown) on our own coefficients (catalog/video-speed.yaml).
//   make test-unit FILTER=VideoEstimatorTests
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("VideoEstimatorTests") struct VideoEstimatorTests {
    static let table = VideoSpeedTable(presets: [
        .init(key: "p", model: "vid-5b", mode: "t2v", width: 832, height: 480, frames: 73, steps: 3),
    ], rows: [
        .init(speedClass: "S4", preset: "p", encodeS: 2, tStepS: 3, decodeSPerFrame: 0.01, peakGB: 12, source: "measured"),
        .init(speedClass: "S1", preset: "p", encodeS: 20, tStepS: 30, decodeSPerFrame: 0.1, peakGB: 12, source: "scaled"),
    ])

    static func run(_ est: Double, _ act: Double, _ i: Int, preset: String = "p") -> VideoHistory.Run {
        VideoHistory.Run(presetKey: preset, speedClass: "S4", estimatedS: est, actualS: act, createdAt: Date(timeIntervalSince1970: Double(i)))
    }

    // MARK: Coefficients

    @Test func timeIsEncodePlusStepsPlusDecode() throws {
        let e = try #require(VideoEstimator.estimate(preset: "p", speedClass: "S4", budgetGB: 100, table: Self.table))
        #expect(abs(e.seconds - (2 + 3 * 3 + 73 * 0.01)) < 1e-9)
        #expect(e.historyFactor == 1 && e.source == "measured" && e.minutes == 1)
        let s1 = try #require(VideoEstimator.estimate(preset: "p", speedClass: "S1", budgetGB: 100, table: Self.table))
        #expect(abs(s1.seconds - (20 + 90 + 7.3)) < 1e-9 && s1.minutes == 2 && s1.source == "scaled")
        #expect(VideoEstimator.estimate(preset: "p", speedClass: "S2", budgetGB: 100, table: Self.table) == nil)
        #expect(VideoEstimator.estimate(preset: "nope", speedClass: "S4", budgetGB: 100, table: Self.table) == nil)
    }

    @Test func memoryVerdictAgainstB() {
        #expect(VideoEstimator.verdict(peakGB: 12, budgetGB: 16) == .fits)        // 12 ≤ 0.85 × 16 = 13.6
        #expect(VideoEstimator.verdict(peakGB: 14, budgetGB: 16) == .tight)
        #expect(VideoEstimator.verdict(peakGB: 16, budgetGB: 16) == .tight)
        #expect(VideoEstimator.verdict(peakGB: 16.5, budgetGB: 16) == .exceeds)
        #expect(VideoEstimator.verdict(peakGB: 12, residentGB: 22, budgetGB: 36) == .tight)  // T3: chat stays resident
        #expect(VideoEstimator.verdict(peakGB: 12, residentGB: 30, budgetGB: 36) == .exceeds)
    }

    /// The bundled table: S4 measured, S1–S3 scaled by pp512 (K-015), every preset on every class, and its S4 sum
    /// reproduces the measured M0.T07 medians (480p 11.97 s, 720p 37.27 s request → MP4, S-10).
    @Test func bundledTableCoefficients() throws {
        let t = VideoSpeedTable.bundled
        #expect(!t.presets.isEmpty)
        for p in t.presets {
            for c in ["S1", "S2", "S3", "S4"] {
                let r = try #require(t.row(speedClass: c, preset: p.key), "\(c) \(p.key)")
                #expect(r.source == (c == "S4" ? "measured" : "scaled"))
            }
            let s4 = try #require(VideoEstimator.baseSeconds(preset: p.key, speedClass: "S4"))
            let s3 = try #require(VideoEstimator.baseSeconds(preset: p.key, speedClass: "S3"))
            let s1 = try #require(VideoEstimator.baseSeconds(preset: p.key, speedClass: "S1"))
            #expect(abs(s3 / s4 - 3220.0 / 723) < 0.01 && abs(s1 / s4 - 3220.0 / 221) < 0.01)
        }
        let s480 = try #require(VideoEstimator.baseSeconds(preset: "t2v-480p-short", speedClass: "S4"))
        let s720 = try #require(VideoEstimator.baseSeconds(preset: "t2v-720p-short", speedClass: "S4"))
        // M9.T05 round 66: the table measured on the shipped runtime 0.3.5 (S4, n 3 per preset).
        #expect(abs(s480 - 13.80) / 13.80 < 0.05, "480p \(s480)")
        #expect(abs(s720 - 60.64) / 60.64 < 0.05, "720p \(s720)")
        // A T2-24 Mac (B 16 GB, chat unloaded) fits the 5B jobs. The I2V job does not on runtime 0.3.5 (peak 17.71 GB,
        // was 14.19 on 0.3.3; known S2 regression, fix in runtime 0.3.6): a preset is offered only where the shipped
        // runtime can run it. LTX with sound does not either — it is T3+ only (model-matrix §2.2) and fits a T3-48 budget.
        for p in t.presets where p.model == "vid-5b" {
            #expect(VideoEstimator.estimate(preset: p.key, speedClass: "S1", budgetGB: 16)?.verdict != .exceeds, "\(p.key)")
        }
        #expect(VideoEstimator.estimate(preset: "i2v-480p-short", speedClass: "S1", budgetGB: 16)?.verdict == .exceeds)
        #expect(VideoEstimator.estimate(preset: "t2v-ltx-512p-short", speedClass: "S1", budgetGB: 16)?.verdict == .exceeds)
        #expect(VideoEstimator.estimate(preset: "t2v-ltx-512p-short", speedClass: "S4", budgetGB: 36)?.verdict != .exceeds)
    }

    /// `catalog/video-speed.yaml` (reviewed source) and the bundled JSON carry the same presets and rows (A-M5-10).
    @Test func yamlMatchesBundledJSON() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let yaml = try String(contentsOf: root.appendingPathComponent("catalog/video-speed.yaml"), encoding: .utf8)
        var section = ""
        var presets: [VideoSpeedTable.Preset] = [], rows: [VideoSpeedTable.Row] = []
        for line in yaml.split(separator: "\n").map(String.init) where !line.hasPrefix("#") {
            if line.hasPrefix("  - ") {
                let data = Data(line.dropFirst(4).utf8)
                if section == "presets" { presets.append(try JSONDecoder().decode(VideoSpeedTable.Preset.self, from: data)) }
                if section == "rows" { rows.append(try JSONDecoder().decode(VideoSpeedTable.Row.self, from: data)) }
            } else if let key = line.split(separator: ":").first {
                section = String(key)
            }
        }
        #expect(!rows.isEmpty)
        #expect(presets == VideoSpeedTable.bundled.presets)
        #expect(rows == VideoSpeedTable.bundled.rows)
    }

    // MARK: History

    @Test func historyFactorIsOneUntilFiveRuns() {
        let four = (0..<4).map { Self.run(10, 20, $0) }
        #expect(VideoHistory.factor(four, preset: "p") == 1.0)
        #expect(VideoHistory.factor([], preset: "p") == 1.0)
    }

    @Test func historyFactorIsTheMedianOfTheLastFive() {
        // Ratios oldest → newest: 9 (dropped: 6th oldest), 1.0, 1.5, 2.0, 0.5, 3.0 → median of the newest five = 1.5.
        let runs = [Self.run(10, 90, 0), Self.run(10, 10, 1), Self.run(10, 15, 2), Self.run(10, 20, 3), Self.run(10, 5, 4), Self.run(10, 30, 5)]
        #expect(VideoHistory.factor(runs, preset: "p") == 1.5)
        // Other presets and invalid rows do not count.
        let mixed = runs + [Self.run(10, 1000, 9, preset: "q"), Self.run(0, 50, 8)]
        #expect(VideoHistory.factor(mixed, preset: "p") == 1.5)
        #expect(VideoHistory.median([1, 2, 3, 4]) == 2.5)
    }

    @Test func historyScalesTheEstimate() throws {
        let runs = (0..<5).map { Self.run(10, 12, $0) }
        let e = try #require(VideoEstimator.estimate(preset: "p", speedClass: "S4", budgetGB: 100, history: runs, table: Self.table))
        #expect(abs(e.historyFactor - 1.2) < 1e-9)
        #expect(abs(e.seconds - 1.2 * (2 + 9 + 0.73)) < 1e-9 && abs(e.tStepS - 3.6) < 1e-9)
    }

    @Test func storeWritesAndReadsButNeverInIncognito() throws {
        let db = try AppDatabase.inMemory()
        let store = VideoHistoryStore(db)
        for i in 0..<6 { #expect(try store.record(Self.run(10, Double(10 + i), i), incognito: false)) }
        #expect(try store.record(Self.run(10, 99, 100), incognito: true) == false)
        let recent = store.recent(preset: "p")
        #expect(recent.count == 5 && recent.first?.actualS == 15 && !recent.contains { $0.actualS == 99 })
        let rows = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM video_run_history") }
        #expect(rows == 6)
        #expect(abs(VideoHistory.factor(recent, preset: "p") - 1.3) < 1e-9)
    }

    // MARK: Live ETA + slowdown

    @Test func etaRuleAndSlowdownThreshold() {
        #expect(VideoETA.remaining(estimateS: 100, progress: 0.25, observedStepS: nil, expectedStepS: 10) == 75)
        #expect(VideoETA.remaining(estimateS: 100, progress: 0.25, observedStepS: 20, expectedStepS: 10) == 150)
        #expect(VideoETA.remaining(estimateS: 100, progress: 1.5, observedStepS: nil, expectedStepS: 10) == 0)
        #expect(!VideoETA.isSlowdown(observedStepS: 13, expectedStepS: 10))
        #expect(VideoETA.isSlowdown(observedStepS: 13.1, expectedStepS: 10))
        #expect(!VideoETA.isSlowdown(observedStepS: nil, expectedStepS: 10))
    }

    @Test func liveETAFollowsObservedSteps() throws {
        let e = try #require(VideoEstimator.estimate(preset: "p", speedClass: "S4", budgetGB: 100, table: Self.table))  // 2 + 9 + 0.73
        var eta = VideoETA(estimate: e)
        #expect(eta.progress == 0 && abs(eta.remainingS - e.seconds) < 1e-9 && !eta.slowdown)
        eta.denoiseStarted(at: 2)
        #expect(abs(eta.progress - 2 / e.seconds) < 1e-9)
        eta.stepFinished(1, at: 5)    // on time: 3 s
        #expect(eta.observedStepS == 3 && !eta.slowdown)
        #expect(abs(eta.remainingS - (e.seconds - 5)) < 1e-9)
        eta.stepFinished(2, at: 11)   // 9 s for 2 steps: 4.5 s/step = 1.5× → slower, ETA stretched
        #expect(eta.observedStepS == 4.5 && eta.slowdown)
        #expect(abs(eta.remainingS - (e.seconds - 8) * 1.5) < 1e-9)
        eta.stepFinished(3, at: 14)
        #expect(eta.stepsDone == 3 && abs(eta.progress - 11 / e.seconds) < 1e-9)
    }
}
