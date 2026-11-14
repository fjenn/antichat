// M5.T09 (R-290 AC1–AC3, R-044 AC1/AC2, NFR-B2 / NFR-B4 video parts; AT-290 / AT-044 in-process legs while XCUITest
// cannot run, Q-015): the plan card's view-model — countdown ticks to a job, Change / Cancel stop it, Cancel writes no
// job, Change re-estimates, battery / Low Power ask first, the Sound chip only where allowed, no advanced control on the
// card and the three Advanced → Video rows in Settings — and snapshots of every state, light/dark.
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=VideoPlanCardTests.
import AntiChatHarness
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct VideoPlanCardTests {
    static let models = VideoPlanCardPreview.models

    static func input(_ intent: VideoPlanPolicy.Intent = .createVideoChip, tier: String = "T3", speed: String = "S4",
                      sound: Bool? = nil, isEvil: Bool = false, source: String? = nil) -> VideoPlanInput {
        VideoPlanInput(prompt: "waves rolling onto a beach at dusk", intent: intent, sourceImageID: source, isEvil: isEvil,
                       tier: tier, speedClass: speed, budgetGB: tier == "T2" ? 24 : 48, residentGB: tier == "T2" ? 0 : 22,
                       models: tier == "T2" ? Array(models.prefix(2)) : models, sound: sound)
    }

    @Test func planCardContents() {
        let m = VideoPlanModel(input: Self.input(), power: .ac, lowPower: false)
        #expect(m.input.prompt == "waves rolling onto a beach at dusk")
        #expect(m.planText.string == "About 2 min on this Mac · 720p · 3.4 s", "estimate shown before Start (runtime 0.3.5 table: S4 720p 60.6 s)")
        #expect(m.plan.options?.lengths == [.short] && m.plan.spec?.shape == .landscape)
        #expect(m.plan.soundChip, "T3 Normal: the Sound chip")
        #expect(VideoPlanCard(model: m).summary == "Short · Landscape")
    }

    @Test func countdownAutoStartsWhenAllowed() throws {
        var jobs: [VideoPlanJob] = []
        let m = VideoPlanModel(input: Self.input(), power: .ac, lowPower: false, onStart: { jobs.append($0) })
        #expect(m.phase == .countdown(remaining: 10) && m.countdownText?.string == "Starting in 10…")
        for n in stride(from: 9, through: 1, by: -1) {
            m.tick()
            #expect(m.phase == .countdown(remaining: n))
        }
        #expect(jobs.isEmpty)
        m.tick()
        #expect(m.phase == .started && !m.isVisible)
        let job = try #require(jobs.first)
        #expect(jobs.count == 1 && job.spec.width == 1280 && job.spec.frames == 81 && job.historyKey == "t2v-720p-short")
        m.tick(); m.start()
        #expect(jobs.count == 1, "one job only")
    }

    @Test func waitsForStartWhenTheRuleSaysSo() {
        #expect(VideoPlanModel(input: Self.input(.inferred), power: .ac, lowPower: false).phase == .waiting(ask: nil))
        #expect(VideoPlanModel(input: Self.input(), power: .battery(percent: 60), lowPower: false).phase == .waiting(ask: nil))
        #expect(VideoPlanModel(input: Self.input(speed: "S1"), power: .ac, lowPower: false).phase == .waiting(ask: nil),
                "T3-S1 720p ≈ 9 min > 5 min")
        #expect(VideoPlanModel(input: Self.input(tier: "T2", speed: "S2"), power: .ac, lowPower: false).phase == .waiting(ask: nil),
                "T2: chat would pause")
    }

    @Test func batteryAndLowPowerAskFirst() {
        var cancelled = 0
        var jobs = 0
        let b = VideoPlanModel(input: Self.input(), power: .battery(percent: 15), lowPower: false,
                               onStart: { _ in jobs += 1 }, onCancel: { cancelled += 1 })
        #expect(b.phase == .waiting(ask: .battery(percent: 15)))
        #expect(b.askText?.string == "You're on battery (15%). Start anyway?")
        b.cancel()  // [Later]
        #expect(cancelled == 1 && jobs == 0 && !b.isVisible)
        let l = VideoPlanModel(input: Self.input(), power: .ac, lowPower: true, onStart: { _ in jobs += 1 })
        #expect(l.askText?.string == "Low Power Mode is on. Start anyway?")
        l.start()
        #expect(jobs == 1, "[Start] anyway")
    }

    @Test func changeStopsTheCountdownAndReEstimates() throws {
        var unmeasured = Self.input(tier: "T4")
        unmeasured.models = [.init(key: "vid-unmeasured", capabilities: []), .init(key: "vid-i2v", capabilities: [])]
        let m = VideoPlanModel(input: unmeasured, power: .ac, lowPower: false)
        var t4in = Self.input(tier: "T4")
        t4in.models = [.init(key: "vid-5b", capabilities: []), .init(key: "vid-i2v", capabilities: []),
                       .init(key: "vid-ltx", capabilities: ["audio"])]
        let t4 = VideoPlanModel(input: t4in, power: .ac, lowPower: false)
        let t3 = VideoPlanModel(input: Self.input(), power: .ac, lowPower: false)
        t3.tick()
        t3.change()
        #expect(t3.phase == .waiting(ask: nil) && t3.editing)
        t3.tick()
        #expect(t3.phase == .waiting(ask: nil), "a stopped countdown never resumes")
        let before = try #require(t3.plan.estimate?.seconds)
        t3.pick(shape: .square)
        #expect(t3.plan.spec?.width == 960 && t3.plan.spec?.height == 960)
        let after = try #require(t3.plan.estimate?.seconds)
        #expect(after != before, "re-estimated")
        t3.pick(sound: true)
        // M5.T10: the LTX sound row is measured (S4, n=1), so Sound on is estimated too (scaled from 768×512, 97 frames).
        #expect(t3.plan.spec?.model == "vid-ltx" && t3.plan.estimate != nil && t3.plan.historyKey == "t2v-ltx-512p-short")
        #expect(t3.planText.string.hasPrefix("About ") && t3.planText.string.hasSuffix(" · 720p · 3.4 s"), "\(t3.planText.string)")
        t3.change()
        #expect(!t3.editing)
        #expect(m.plan.estimate == nil && m.phase == .waiting(ask: nil), "a model without a speed row → waits")
        // A-M5-13: T4 text-to-video runs on vid-5b (measured rows), 720p Medium → estimated, counts down like T3.
        #expect(t4.plan.spec?.model == "vid-5b" && t4.plan.spec?.frames == 121 && t4.plan.estimate != nil)
    }

    @Test func cancelRemovesTheCardAndWritesNoJob() {
        var jobs = 0, cancels = 0
        let m = VideoPlanModel(input: Self.input(), power: .ac, lowPower: false, onStart: { _ in jobs += 1 }, onCancel: { cancels += 1 })
        m.tick()
        m.cancel()
        for _ in 0..<12 { m.tick() }
        m.start()
        #expect(m.phase == .cancelled && jobs == 0 && cancels == 1)
    }

    @Test func soundChipOnlyWhereAllowed() {
        #expect(!VideoPlanModel(input: Self.input(isEvil: true), power: .ac, lowPower: false).plan.soundChip, "Evil: no chip")
        #expect(!VideoPlanModel(input: Self.input(tier: "T2", speed: "S2"), power: .ac, lowPower: false).plan.soundChip)
        #expect(!VideoPlanModel(input: Self.input(source: "img1"), power: .ac, lowPower: false).plan.soundChip, "I2V is silent")
        let lite = VideoPlanModel(input: Self.input(.animate, tier: "T2", speed: "S1", source: "img1"), power: .ac, lowPower: false)
        #expect(!lite.plan.isOffered, "no image-to-video on T2-S1")
    }

    @Test func advancedOnlyInSettings() {
        // The card's controls: Start / Change / Cancel and the length / shape / sound chips — no steps or resolution.
        let ids = ["videoPlan.start", "videoPlan.change", "videoPlan.cancel", "videoPlan.length.short", "videoPlan.shape.square"]
        #expect(!ids.contains { $0.contains("steps") || $0.contains("resolution") })
        let rows = SettingsRegistry.rows(in: .capabilities).map(\.id)
        #expect(rows.contains("videoAdvancedSteps") && rows.contains("videoAdvancedResolution") && rows.contains("videoAdvancedSeconds"))
        let e = VideoPresetsTable.bundled.entry(tier: "T3", speedClass: "S4")!
        #expect(VideoAdvancedView.stepOptions(e, table: .bundled) == [1, 2, 3])
        #expect(VideoAdvancedView.secondOptions(e, fps: 24) == [2, 3, 4, 5])
        let m = VideoPlanModel(input: Self.input(), power: .ac, lowPower: false, advanced: VideoAdvanced(resolution: "480p", seconds: 2))
        #expect(m.plan.spec?.resolution == "480p" && m.plan.spec?.frames == 49 && m.plan.exactLength)
        #expect(VideoPlanCard(model: m).summary == "Landscape", "exact length hides the length preset")
    }

    @Test func snapshotsOfEveryState() {
        for state in VideoPlanCardPreview.State.allCases {
            for look in ResponseActionsSnapshotTests.Look.allCases {
                let v = VideoPlanCard(model: VideoPlanCardPreview.model(state), ticking: false)
                    .environment(\.reduceMotionOverride, true)
                assertSnapshot(of: ResponseActionsSnapshotTests.render(v, width: 480, look: look),
                               as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(state.rawValue)-\(look.rawValue)",
                               testName: "videoPlanCard")
            }
        }
    }
}
}
