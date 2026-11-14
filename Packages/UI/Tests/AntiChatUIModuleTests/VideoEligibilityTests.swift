// M5.T08 (R-046 AC1, R-040 AC4; AT-046 AC1 unit leg): VideoEligibility over the `-FakeHardware` fixtures (T0, T1,
// T2-S1, T2-S2, T3, T4) with the signed baseline catalog and the bundled speed table, and the four surfaces that show
// the reason: the onboarding Video card, Settings → Capabilities' Video row, the + menu's Create video row (disabled,
// reason as tooltip/grey line) and the explanation card for a video request (`video.notEligible` + images line).
// Video is never hidden. The XCUITest leg (App/UITests/VideoEligibilityTests.swift) is pending (Q-015).
//   make test-unit FILTER=VideoEligibilityTests
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite("VideoEligibilityTests", .isolatedSettings) struct VideoEligibilityTests {
    typealias M = OnboardingModelTests

    /// `-FakeHardware <fixture>` profiles: the tier defaults plus the two T2 speed classes.
    static func profile(_ fixture: String) -> HardwareProfile {
        var o = LaunchOptions()
        o.fakeHardwareFixture = fixture
        o.fakeHardware = LaunchOptions.Tier(rawValue: String(fixture.prefix(2)).uppercased())
        return HardwareProbe.fixtureProfile(options: o)!
    }

    static let fixtures: [(name: String, fixture: String)] = [
        ("T0", "t0-m1-8"), ("T1", "t1-m2-16"), ("T2-S1", "t2-m4-24"), ("T2-S2", "t2-m2pro-32"),
        ("T3", "t3-m4pro-48"), ("T4", "t4-m3max-96"),
    ]

    static func selection(_ p: HardwareProfile) -> Selection {
        ModelSelector(catalog: M.catalog).select(profile: p, enabledPacks: Set(ModelPack.allCases), modes: [.normal, .evil])
    }

    static func evaluate(_ fixture: String) -> (HardwareProfile, VideoEligibility.Result) {
        let p = profile(fixture)
        return (p, VideoEligibility.evaluate(profile: p, selection: selection(p), catalog: M.catalog))
    }

    @Test func fixturesHaveTheExpectedTierAndClass() {
        #expect(Self.profile("t2-m4-24").tier == .T2 && Self.profile("t2-m4-24").speedClass == .S1)
        #expect(Self.profile("t2-m2pro-32").tier == .T2 && Self.profile("t2-m2pro-32").speedClass == .S2)
    }

    @Test func t0AndT1AreDimmedNeeds24GB() {
        for f in ["t0-m1-8", "t1-m2-16", "t1-m3pro-18"] {
            let (p, r) = Self.evaluate(f)
            #expect(r == .dimmed(.needsMemory(gb: 24)), "\(f) \(r)")
            #expect(r.reason?.copyText == CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": "24"]))
            #expect(r.reason?.copyText.string == "Needs 24 GB memory")
            #expect(24 > p.ramGB)  // truthful: never "Needs N GB" on a Mac with N GB
        }
    }

    @Test func t2S1IsShownLite480pOnly() throws {
        let (_, r) = Self.evaluate("t2-m4-24")
        guard case .eligible(let offer) = r else { Issue.record("\(r)"); return }
        #expect(offer.lite && !offer.needsRuntime)
        #expect(!offer.presets.isEmpty && offer.presets.allSatisfy { $0.hasSuffix("480p-short") }, "\(offer.presets)")
        #expect(offer.presets.contains("t2v-480p-short"))
    }

    @Test func t2S2T3T4GetEveryPreset() {
        for f in ["t2-m2pro-32", "t3-m4pro-48", "t4-m3max-96"] {
            let (_, r) = Self.evaluate(f)
            guard case .eligible(let offer) = r else { Issue.record("\(f) \(r)"); continue }
            #expect(!offer.lite, "\(f)")
            #expect(offer.presets.contains("t2v-720p-short") && offer.presets.contains("t2v-480p-short"), "\(f) \(offer.presets)")
        }
    }

    @Test func runtimeMissingIsAnInstallCardNotDimmed() {
        let p = Self.profile("t3-m4pro-48")
        let r = VideoEligibility.evaluate(VideoEligibility.Input(profile: p, selection: Self.selection(p), catalog: M.catalog,
                                                                 runtimeInstalled: false))
        guard case .eligible(let offer) = r else { Issue.record("\(r)"); return }
        #expect(offer.needsRuntime)
    }

    @Test func chipAndCatalogRefusals() {
        let base = VideoEligibility.Input(tier: "T2", speedClass: "S2", ramGB: 32, budgetGB: 21, videoModelID: nil,
                                          catalogReason: "too_slow_for_speed_class")
        #expect(VideoEligibility.evaluate(base) == .dimmed(.chipTooSlow))
        #expect(VideoEligibility.evaluate(base).reason?.copyText.string == "Too slow on this Mac's chip")
        // A class with no speed-table row: the chip cannot be estimated → too slow, never silently offered.
        var noRow = base
        noRow.videoModelID = "vid-5b"
        noRow.catalogReason = nil
        #expect(VideoEligibility.evaluate(noRow, table: VideoSpeedTable(presets: [], rows: [])) == .dimmed(.chipTooSlow))
        // A catalog RAM floor above this Mac's memory wins (truthful number).
        let floor = VideoEligibility.Input(tier: "T2", speedClass: "S3", ramGB: 24, budgetGB: 16, videoModelID: nil,
                                           catalogReason: "needs_ram_32")
        #expect(VideoEligibility.evaluate(floor) == .dimmed(.needsMemory(gb: 32)))
    }

    // MARK: Surfaces (never hidden, always the reason)

    @Test func onboardingAndCapabilitiesShowTheReason() {
        for t in [LaunchOptions.Tier.T0, .T1] {
            let card = M.model(t).cards.first { $0.pack == .video }
            #expect(card != nil, "Video card missing on \(t)")
            #expect(card?.eligible == false && card?.dimmedReason == CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": "24"]))
            let caps = PackManagementModel(defaults: UserDefaults.inMemory())
            caps.shipped = Set(ModelPack.allCases)
            caps.load(profile: M.profile(t), catalog: M.catalog, installed: [])
            #expect(caps.state(.video) == .notAvailable(reason: CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": "24"])))
            #expect(caps.menuIneligible["video"] == .notOnThisMac(reasonKey: "onb.pack.dimmed.ram", args: ["gb": "24"]))
        }
        let t3 = PackManagementModel(defaults: UserDefaults.inMemory())
        t3.load(profile: M.profile(.T3), catalog: M.catalog, installed: [])
        #expect(t3.menuIneligible.isEmpty)
        #expect(M.model(.T2).cards.first { $0.pack == .video }?.eligible == true)
    }

    @Test func plusMenuRowIsDisabledWithTheReason() throws {
        var ctx = ComposerMenuContext(installedPacks: ["chat", "video"], activeModelKey: "chat-9b")
        ctx.ineligiblePacks = ["video": .notOnThisMac(reasonKey: "onb.pack.dimmed.ram", args: ["gb": "24"])]
        let row = try #require(SlashCommandRegistry.addItems(ctx).first { $0.id == "video" }, "Create video hidden")
        #expect(!row.state.isEnabled && !row.state.isPickable && !row.state.isSettingsLink)
        #expect(ComposerMenus.reason(row.state)?.string == "Needs 24 GB memory")
        // Eligible Mac: the usual pack states.
        let ok = SlashCommandRegistry.addItems(ComposerMenuContext(activeModelKey: "chat-9b")).first { $0.id == "video" }
        #expect(ok?.state == .needsPack("video"))
    }

    @Test func ineligibleRequestExplains() throws {
        let p = M.profile(.T1)
        let a = try #require(CapabilitiesPackInstaller.videoIneligible(profile: p, selection: Self.selection(p), catalog: M.catalog))
        #expect(a == .videoNotEligible(gb: 24, ram: p.ramGB))
        let card = try #require(InstallCardPolicy.card(.video, availability: a, userMessageID: "u1"))
        #expect(!card.hasButtons && card.userMessageID == nil && card.copyKey == "video.notEligible")
        #expect(InstallCardView.text(card).string == "Video needs 24 GB memory. This Mac has \(p.ramGB) GB.")
        #expect(InstallCardView.secondaryText(card)?.string == "You can still make images.")
        // Eligible Mac: no explanation card (the usual install / coming-soon path).
        let t3 = M.profile(.T3)
        #expect(CapabilitiesPackInstaller.videoIneligible(profile: t3, selection: Self.selection(t3), catalog: M.catalog) == nil)
    }

    @Test func everyFixtureGivesAnAnswer() {
        var lines: [String] = []
        for (name, f) in Self.fixtures {
            let (p, r) = Self.evaluate(f)
            switch r {
            case .eligible(let o): lines.append("\(name) \(p.chip) B=\(p.B): eligible lite=\(o.lite) presets=\(o.presets.joined(separator: ","))")
            case .dimmed(let why): lines.append("\(name) \(p.chip): dimmed \(why.copyText.string)")
            }
            #expect(r.isEligible == !(name == "T0" || name == "T1"), "\(name) \(r)")
        }
        print("VideoEligibility matrix:\n" + lines.joined(separator: "\n"))
    }
}
