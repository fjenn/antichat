// M5.T09 (R-290 AC2, AT-290 AC2 unit leg; NFR-B2 / NFR-B4 video parts, AT-NFR-B2/B4 unit legs; P-media-12): the
// countdown rule as a full truth table — intent (4 kinds) × power (AC / battery 60 % / battery 15 % / unknown %) ×
// Low Power × estimate (≤ 5 min, exactly 5 min, > 5 min, unknown) × chat would pause — and the asks.
//   make test-unit FILTER=VideoPlanPolicyTests
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("VideoPlanPolicyTests") struct VideoPlanPolicyTests {
    typealias P = VideoPlanPolicy

    static let powers: [P.Power] = [.ac, .battery(percent: 60), .battery(percent: 15), .battery(percent: nil)]
    static let estimates: [Double?] = [120, 300, 301, nil]

    @Test func truthTableOfAllConditions() {
        var autoStarts = 0, cases = 0
        for intent in P.Intent.allCases {
            for power in Self.powers {
                for low in [false, true] {
                    for est in Self.estimates {
                        for pause in [false, true] {
                            cases += 1
                            let want = intent.isExplicit && power == .ac && !low && est != nil && est! <= 300 && !pause
                            let got = P.shouldAutoStart(intent: intent, power: power, lowPower: low, estimateS: est,
                                                        chatWouldPause: pause)
                            #expect(got == want, "\(intent) \(power) low=\(low) est=\(String(describing: est)) pause=\(pause)")
                            let d = P.decide(intent: intent, power: power, lowPower: low, estimateS: est, chatWouldPause: pause)
                            if want {
                                autoStarts += 1
                                #expect(d == .countdown(seconds: 10))
                            } else {
                                guard case .waitForStart = d else { Issue.record("\(d) should wait"); continue }
                            }
                        }
                    }
                }
            }
        }
        #expect(cases == 4 * 4 * 2 * 4 * 2)
        #expect(autoStarts == 3 * 2, "explicit (3 kinds) × AC × no Low Power × {2 min, 5 min} × chat stays")
    }

    @Test func eachConditionAloneBlocksAutoStart() {
        let ok = { (i: P.Intent, p: P.Power, l: Bool, e: Double?, c: Bool) in
            P.shouldAutoStart(intent: i, power: p, lowPower: l, estimateS: e, chatWouldPause: c)
        }
        #expect(ok(.createVideoChip, .ac, false, 120, false))           // testCountdownAutoStartsWhenAllowed
        #expect(ok(.animate, .ac, false, 120, false))
        #expect(ok(.namedVideo, .ac, false, 120, false))
        #expect(!ok(.inferred, .ac, false, 120, false))                 // testWaitsForStartOnInferredIntent
        #expect(!ok(.createVideoChip, .battery(percent: 60), false, 120, false))  // testWaitsOnBattery
        #expect(!ok(.createVideoChip, .ac, true, 120, false))           // testLowPowerAsks
        #expect(!ok(.createVideoChip, .ac, false, 301, false))          // testWaitsWhenEstimateOver5Min
        #expect(!ok(.createVideoChip, .ac, false, nil, false))          // unknown estimate is never ≤ 5 min
        #expect(!ok(.createVideoChip, .ac, false, 120, true))           // testWaitsWhenChatWouldPause
        #expect(ok(.createVideoChip, .ac, false, 300, false), "exactly 5 min still counts down")
    }

    @Test func batteryAskBelow20PercentNotCharging() {
        #expect(P.ask(power: .battery(percent: 19), lowPower: false) == .battery(percent: 19))
        #expect(P.ask(power: .battery(percent: 0), lowPower: false) == .battery(percent: 0))
        #expect(P.ask(power: .battery(percent: 20), lowPower: false) == nil, "20 % is not below 20 %")
        #expect(P.ask(power: .battery(percent: 60), lowPower: false) == nil)
        #expect(P.ask(power: .battery(percent: nil), lowPower: false) == nil)
        #expect(P.ask(power: .ac, lowPower: false) == nil, "charging never asks for battery")
        #expect(P.decide(intent: .createVideoChip, power: .battery(percent: 15), lowPower: false, estimateS: 60,
                         chatWouldPause: false) == .waitForStart(ask: .battery(percent: 15)))
        #expect(P.Ask.battery(percent: 15).copyKey == "video.battery")
    }

    @Test func lowPowerAsksFirst() {
        #expect(P.ask(power: .ac, lowPower: true) == .lowPower)
        #expect(P.ask(power: .battery(percent: 50), lowPower: true) == .lowPower)
        #expect(P.ask(power: .battery(percent: 10), lowPower: true) == .battery(percent: 10), "both: the battery ask")
        #expect(P.decide(intent: .animate, power: .ac, lowPower: true, estimateS: 60, chatWouldPause: false)
                == .waitForStart(ask: .lowPower))
        #expect(P.Ask.lowPower.copyKey == "video.lowPower")
    }

    @Test func noAskWaitsSilently() {
        #expect(P.decide(intent: .inferred, power: .ac, lowPower: false, estimateS: 60, chatWouldPause: false)
                == .waitForStart(ask: nil))
        #expect(P.decide(intent: .namedVideo, power: .battery(percent: 80), lowPower: false, estimateS: 60, chatWouldPause: false)
                == .waitForStart(ask: nil))
    }

    @Test func chatPausesOnT2OrWhenItDoesNotFit() {
        #expect(P.chatWouldPause(tier: "T2", verdict: .fits))
        #expect(!P.chatWouldPause(tier: "T3", verdict: .fits))
        #expect(!P.chatWouldPause(tier: "T3", verdict: .tight))
        #expect(P.chatWouldPause(tier: "T3", verdict: .exceeds))
        #expect(!P.chatWouldPause(tier: "T4", verdict: nil))
    }

    // MARK: The plan as M5.T10 builds it

    static let models: [VideoSound.Model] = [.init(key: "vid-5b", capabilities: []), .init(key: "vid-i2v", capabilities: []),
                                             .init(key: "vid-ltx", capabilities: ["audio"])]

    @Test func planDecisionUsesTheEstimateAndTier() throws {
        // T3-S4 (dev Mac class), 720p Short on runtime 0.3.5: 1.981 + 3 × 19.0347 + 81 × 0.01917 ≈ 61 s → countdown on AC.
        let input = VideoPlanInput(prompt: "waves at dusk", intent: .createVideoChip, tier: "T3", speedClass: "S4",
                                   budgetGB: 48, residentGB: 22, models: Self.models)
        let plan = VideoPlan.make(input)
        let e = try #require(plan.estimate)
        #expect(abs(e.seconds - (1.981 + 3 * 19.0347 + 81 * 0.01917)) < 1e-6)
        #expect(!plan.chatWouldPause)
        #expect(plan.decision(power: .ac, lowPower: false) == .countdown(seconds: 10))
        #expect(plan.decision(power: .battery(percent: 60), lowPower: false) == .waitForStart(ask: nil))
        // T2-S2 720p Short ≈ 486 s on 0.3.5 (> 5 min), and T2 unloads chat → waits.
        let t2 = VideoPlan.make(VideoPlanInput(prompt: "p", intent: .createVideoChip, tier: "T2", speedClass: "S2",
                                               budgetGB: 24, models: Array(Self.models.prefix(2))))
        #expect(t2.chatWouldPause && t2.decision(power: .ac, lowPower: false) == .waitForStart(ask: nil))
        // T3-S1 720p Short ≈ 9 min → waits.
        let slow = VideoPlan.make(VideoPlanInput(prompt: "p", intent: .createVideoChip, tier: "T3", speedClass: "S1",
                                                 budgetGB: 48, models: Self.models))
        #expect((slow.estimate?.seconds ?? 0) > 300 && slow.decision(power: .ac, lowPower: false) == .waitForStart(ask: nil))
    }

    @Test func soundOnIsEstimatedFromTheMeasuredLTXRow() {
        // M5.T10: the LTX row is measured on S4. On runtime 0.3.5 (M9.T05 round 66, n 3: 78.2 s for 768×512 × 97
        // frames) 720p Short scales to about 2.5 min on S4, under 5 min, so a Sound-on request counts down like any job.
        let input = VideoPlanInput(prompt: "p", intent: .createVideoChip, tier: "T3", speedClass: "S4", budgetGB: 48,
                                   models: Self.models, sound: true)
        let plan = VideoPlan.make(input)
        #expect(plan.soundChip && plan.spec?.model == "vid-ltx" && plan.spec?.sound == true)
        #expect(plan.historyKey == "t2v-ltx-512p-short" && plan.planArgs["minutes"] != nil)
        let s = plan.estimate?.seconds ?? 0
        #expect(s > 140 && s < 160, "\(s)")
        #expect(plan.decision(power: .ac, lowPower: false) == .countdown(seconds: 10), "under 5 min: countdown")
        let evil = VideoPlan.make(VideoPlanInput(prompt: "p", intent: .createVideoChip, isEvil: true, tier: "T3", speedClass: "S4",
                                                 budgetGB: 48, models: Self.models, sound: true))
        #expect(!evil.soundChip && evil.spec?.model == "vid-5b" && evil.spec?.sound == false)
    }

    @Test func jobCarriesTheHistoryFreeEstimate() throws {
        let runs = (0..<5).map { VideoHistory.Run(presetKey: "t2v-720p-short", speedClass: "S4", estimatedS: 10, actualS: 20,
                                                  createdAt: Date(timeIntervalSince1970: Double($0))) }
        let plan = VideoPlan.make(VideoPlanInput(prompt: "p", intent: .namedVideo, tier: "T3", speedClass: "S4", budgetGB: 48,
                                                 models: Self.models, history: runs))
        let e = try #require(plan.estimate)
        #expect(e.historyFactor == 2)
        let job = try #require(plan.job)
        #expect(job.historyKey == "t2v-720p-short")
        #expect(abs((job.estimatedS ?? 0) * 2 - e.seconds) < 1e-6)
        #expect(job.prompt == "p" && job.mode == .t2v && job.sourceImageID == nil)
    }

    @Test func secondsFormatting() {
        #expect(VideoPlan.seconds(73.0 / 24) == "3")
        #expect(VideoPlan.seconds(81.0 / 24) == "3.4")
        #expect(VideoPlan.seconds(121.0 / 24) == "5")
    }
}
