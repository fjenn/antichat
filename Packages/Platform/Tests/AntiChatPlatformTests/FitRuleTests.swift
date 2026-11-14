// M2.T06 (blueprint E §E.2.3 steps 2–4): the resident formula, the FitPill classes, the context ladder (never
// silently below the default: `model.contextLowered`) and the speed guard (hardware-tiers §3 step 2 example:
// a 16 GB M1 at 68 GB/s runs a ~9B at ≈ 9 tok/s and gets the ~4B).
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct FitRuleTests {
    let catalog: ModelCatalog = try! SelectorFixtures.baseline()

    @Test func residentFormula() throws {
        let m = try #require(catalog.models["chat-9b-q4"])
        // 5.977 + 32 × 16384 / 1e6 + 0.5 (model-matrix §2.1: ≈ 7.0 at 16K)
        #expect(abs(FitRule.resident(m, ctx: 16384) - (m.footprint.weightsGB + 0.524288 + 0.5)) < 1e-9)
        #expect(abs(FitRule.resident(m, ctx: 16384) - 7.0) < 0.05)
    }

    @Test func fitClasses() throws {
        let p = try SelectorFixtures.profile("t1-m1-16")  // B = 9.5
        #expect(FitRule.classify(residentGB: 6, mustStayGB: 1, profile: p) == .fits)        // 7 ≤ 8.075
        #expect(FitRule.classify(residentGB: 7.5, mustStayGB: 1.5, profile: p) == .tight)   // 9 ≤ 9.5
        #expect(FitRule.classify(residentGB: 9, mustStayGB: 1, profile: p) == .tooLarge)
        #expect(p.fits(residentGB: 8, mustStayGB: 1.5))
    }

    @Test func ladderKeepsTheDefaultWhenItFits() throws {
        let p = try SelectorFixtures.profile("t3-m4pro-48")
        let m = try #require(catalog.models["chat-35b-q4"])
        #expect(ContextLadder.choose(m, cellDefault: 65536, mustStayGB: 1.5, profile: p) == 65536)
    }

    @Test func ladderLowersAndSaysSo() throws {
        let t1 = try SelectorFixtures.profile("t1-m3pro-18")  // B = 11.5
        let m = try #require(catalog.models["chat-9b-q4"])
        // 16K: 7.02 + 4.0 = 11.02 ≤ 11.5; 32K: 7.55 + 4.0 > 11.5 → the largest rung that fits, below the 128K default.
        #expect(ContextLadder.choose(m, cellDefault: 131072, mustStayGB: 4.0, profile: t1) == 16384)
        // Not even 8K fits a T0 budget (6.74 > 4.0).
        #expect(ContextLadder.choose(m, cellDefault: 16384, mustStayGB: 0, profile: try SelectorFixtures.profile("t0-m1-8")) == nil)
        #expect(SelectionSlot.Note.contextLowered.copyKey == "model.contextLowered")
    }

    @Test func speedGuard() throws {
        let nine = try #require(catalog.models["chat-9b-q4"]), four = try #require(catalog.models["chat-4b"])
        #expect(SpeedGuard.predictedTokPerSec(nine, bandwidthGBs: 68) < 15)          // ≈ 9.3
        #expect(SpeedGuard.predictedTokPerSec(four, bandwidthGBs: 68) >= 15)         // ≈ 18
        #expect(SpeedGuard.predictedTokPerSec(nine, bandwidthGBs: 120) >= 15)        // M4 ≈ 16.5
        #expect(!SpeedGuard.passes(nine, profile: try SelectorFixtures.profile("t1-m2-16")))  // 100 GB/s ≈ 13.7
        var unknown = try SelectorFixtures.profile("t1-m1-16"); unknown.bandwidthGBs = nil
        #expect(SpeedGuard.passes(nine, profile: unknown))
    }

    @Test func contextLoweredNoteWhenBudgetIsTight() throws {
        // A Mac whose W is smaller than the table: the T2-24 cell's 32K no longer fits with Voice resident.
        var p = try SelectorFixtures.profile("t2-m4-24"); p.B = 8.6
        let s = ModelSelector(catalog: catalog).select(profile: p)
        let chat = try #require(s.slot(.chat, .normal, role: "chat"))
        #expect(chat.modelID == "chat-9b-q4")
        #expect((chat.ctx ?? 0) < 32768)
        #expect(chat.notes.contains(.contextLowered))
    }
}
