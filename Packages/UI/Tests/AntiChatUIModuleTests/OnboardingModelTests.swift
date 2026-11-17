// M2.T18 (R-201 AC2, AC3; AT-201 part 1 unit legs): OnboardingModel over the five tier fixtures and the bundled,
// signed baseline catalog. Sizes = Σ unique sha256 of InstallQueue's plan (±5% of the catalog bytes, never 0.0 GB),
// defaults (Chat locked, Voice/Photo ticked when eligible, Video unticked), truthful dimming (hardware-tiers §4.5:
// no "Needs N GB" on a Mac with N GB or more), the disk rule (NFR-D2) and the no-internet CTA (S-00).
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite("OnboardingModelTests", .isolatedSettings) struct OnboardingModelTests {
    static let catalog: ModelCatalog = try! ModelCatalog.decode(CatalogStore.bundledBaseline()!.data)

    static func profile(_ t: LaunchOptions.Tier) -> HardwareProfile {
        var o = LaunchOptions()
        o.fakeHardware = t
        return HardwareProbe.fixtureProfile(options: o)!
    }

    /// `shipped` defaults to every pack: these tests cover the later milestones' card logic too (lead decision B keeps
    /// it behind ModelPack.shipped in the build).
    static func model(_ t: LaunchOptions.Tier, freeGB: Int64 = 1000, online: Bool = true,
                      shipped: Set<ModelPack> = Set(ModelPack.allCases)) -> OnboardingModel {
        OnboardingModel(profile: profile(t), catalog: catalog, freeBytes: freeGB * 1_000_000_000, online: online, shipped: shipped)
    }

    @Test func testSizesMatchCatalog() {
        for t in LaunchOptions.Tier.allCases {
            let m = Self.model(t)
            let sel = m.selection!
            for card in m.cards where card.eligible {
                // Σ catalog bytes of the pack's unique files (independent of InstallQueue).
                var ids = sel.installIDs(packs: [card.pack], modes: [.normal], onDemand: Set(Self.catalog.onDemand))
                // The ChildSafetyCheck detectors (csam_check slot, M4.T02) come with Photo and with Video; the
                // placeholder share applies only while a catalog leaves the slot unassigned.
                let csam = sel.slot(.photo, .normal, role: "csam_check")
                if card.pack == .video, let c = csam, c.modelID != nil { ids.formUnion(c.installIDs) }
                var expected = DownloadSize.bytes(ids: ids, catalog: Self.catalog)
                if (card.pack == .photo || card.pack == .video) && csam?.modelID == nil { expected += OnboardingModel.csamPlaceholderBytes }
                #expect(card.bytes > 0, "\(t) \(card.pack) 0 bytes")
                #expect(abs(Double(card.bytes - expected)) <= 0.05 * Double(expected), "\(t) \(card.pack) \(card.bytes) vs \(expected)")
                // A zero size, not e.g. "10.0 GB" (the Photo pack with img-erase is 10.0 GB on some tiers).
                #expect(m.sizeLine(card).string.range(of: #"(^|[^0-9.])0\.0 GB"#, options: .regularExpression) == nil, "\(m.sizeLine(card).string)")
            }
            #expect(m.totalBytes > 0)
            #expect(m.totalLine.string.range(of: #"(^|[^0-9.])0\.0 GB"#, options: .regularExpression) == nil)
        }
    }

    @Test func defaultsAndDisplayMatrix() {
        // hardware-tiers §4.5: Photo dimmed on T0 (16 GB), Video dimmed on T0/T1 (24 GB), everything else shown.
        let expectEligible: [LaunchOptions.Tier: [ModelPack: Bool]] = [
            .T0: [.chat: true, .voice: true, .photo: false, .video: false],
            .T1: [.chat: true, .voice: true, .photo: true, .video: false],
            .T2: [.chat: true, .voice: true, .photo: true, .video: true],
            .T3: [.chat: true, .voice: true, .photo: true, .video: true],
            .T4: [.chat: true, .voice: true, .photo: true, .video: true],
        ]
        for t in LaunchOptions.Tier.allCases {
            let m = Self.model(t)
            let ram = Self.profile(t).ramGB
            for card in m.cards {
                #expect(card.eligible == expectEligible[t]![card.pack], "\(t) \(card.pack)")
                switch card.pack {
                case .chat: #expect(card.ticked && !card.toggleable)
                case .voice, .photo: #expect(card.ticked == card.eligible)
                case .video: #expect(!card.ticked)
                }
                if let r = card.dimmedReason {
                    // Truthful: a "Needs N GB" line never names N ≤ this Mac's memory.
                    if let n = r.args["gb"].flatMap(Int.init) { #expect(n > ram, "\(t) \(card.pack) says needs \(n) GB on \(ram) GB") }
                    #expect(!card.ticked)
                }
            }
        }
        let t0 = Self.model(.T0)
        #expect(t0.cards.first { $0.pack == .photo }?.dimmedReason?.key.rawValue == "onb.pack.dimmed.photo.t0")
        #expect(Self.model(.T1).cards.first { $0.pack == .video }?.dimmedReason == CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": "24"]))
    }

    /// M2.T26 VQ defect: in the app the hardware probe lands after step 1 is shown, so the first cards are
    /// placeholders; the defaults must still apply once the facts arrive, and only the user's own ticks survive.
    @Test func defaultsApplyAfterTheProbeLandsAndUserTicksSurvive() {
        let m = OnboardingModel(profile: nil, catalog: nil, freeBytes: 1_000_000_000_000, online: true, shipped: Set(ModelPack.allCases))
        m.update(profile: Self.profile(.T1), catalog: Self.catalog)
        #expect(m.chosenPacks == [.chat, .voice, .photo])
        m.toggle(.voice)
        m.update(profile: Self.profile(.T1), catalog: Self.catalog)  // a catalog refresh
        #expect(m.chosenPacks == [.chat, .photo])
    }

    @Test func toggleAndTotal() {
        let m = Self.model(.T2)
        let before = m.totalBytes
        m.toggle(.video)
        #expect(m.cards.first { $0.pack == .video }?.ticked == true)
        #expect(m.totalBytes > before)
        m.toggle(.chat)  // locked
        #expect(m.cards.first { $0.pack == .chat }?.ticked == true)
        // Dimmed cards never toggle.
        let t0 = Self.model(.T0)
        t0.toggle(.photo)
        #expect(t0.cards.first { $0.pack == .photo }?.ticked == false)
    }

    @Test func diskShortBlocksContinueUntilAPackIsDropped() {
        // AT-201 OnboardingDiskShortTests (unit leg): T1 with 16 GB free (the AT's 15 GB predates the pinned sizes:
        // Chat + Voice alone are 5.02 GB, so 15 GB stays 0.02 GB short of the 10 GB headroom even without Photo).
        let m = Self.model(.T1, freeGB: 16)
        guard case .short = m.disk else { Issue.record("T1 default set should not fit 15 GB + 10 GB headroom"); return }
        #expect(m.continueBlocked?.key.rawValue == "onb.diskShort")
        m.step = .capabilities
        m.next()
        #expect(m.step == .capabilities)
        m.toggle(.photo)
        #expect(m.disk == .ok)
        #expect(m.continueBlocked == nil)
    }

    @Test func noInternetDisablesTheStep2CTA() {
        let m = Self.model(.T1, online: false)
        #expect(m.continueBlocked?.key.rawValue == "onb.noInternet")
        m.next()  // step 1 still works offline
        #expect(m.step == .capabilities)
        m.next()
        #expect(m.step == .capabilities)
        m.online = true
        var planned: InstallPlan?
        m.onInstall = { planned = $0 }
        m.next()
        #expect(m.step == .evil)
        #expect(planned?.stages.first?.kind == .chatFast)  // starter first (E.2.4)
    }

    @Test func probingAndSizeFormat() {
        let m = OnboardingModel(profile: nil, catalog: Self.catalog, freeBytes: 100_000_000_000, shipped: Set(ModelPack.allCases))
        #expect(m.hardwareLine.key.rawValue == "onb.hardware.probing")
        #expect(m.continueBlocked != nil)
        #expect(OnboardingModel.size(6_449_000_000) == "6.4 GB")
        #expect(OnboardingModel.size(21_405_714_908) == "21 GB")
        #expect(OnboardingModel.size(10_000_000) == "0.1 GB")
        let t1 = Self.model(.T1)
        #expect(t1.hardwareLine.string.contains("16 GB memory"))
    }
}

/// R66 F4 (S-04): title, subtitle, row states, footer and primary button come from one Step4State over the same rows,
/// so step 4 never contradicts itself.
@MainActor
@Suite("Step4StateTests", .isolatedSettings) struct Step4StateTests {
    func row(_ g: String, _ s: SetupProgress.RowState) -> SetupProgress.Row { .init(group: g, state: s, bytesDone: 0, bytesTotal: 10) }

    /// Nothing answers yet: "Preparing", "Getting Chat ready first", 0 ready, Open chat disabled (the user waits).
    @Test func waiting() {
        let s = Step4State(rows: [row("chat", .downloading(percent: 4)), row("voice", .waiting), row("photo", .waiting)],
                           starterReady: false)
        #expect(s.titleKey == "onb.4.title" && s.subtitleKey == "onb.4.subtitle.waiting")
        #expect(s.readyCount == 0 && s.total == 3)
        #expect(s.primary == .wait)
    }

    /// The vq-m2 chatready shot: the starter answers, the Chat row is at 99 %. Chat is not "ready", it does not count
    /// in the footer, and the subtitle says only that a chat can start.
    @Test func starterAnswersWhileChatRowDownloads() {
        let s = Step4State(rows: [row("chat", .downloading(percent: 99)), row("voice", .downloading(percent: 1)), row("photo", .waiting)],
                           starterReady: true)
        #expect(s.subtitleKey == "onb.4.subtitle.starter")
        #expect(s.readyCount == 0 && s.total == 3)
        #expect(s.titleKey == "onb.4.title")
        #expect(s.primary == .openChat)
    }

    /// The Chat row installed and verified: "Chat is ready", it counts, the others still run.
    @Test func chatRowReadyOthersRunning() {
        let s = Step4State(rows: [row("chat", .ready), row("voice", .downloading(percent: 30)), row("photo", .checking)],
                           starterReady: true)
        #expect(s.subtitleKey == "onb.4.subtitle.ready" && s.titleKey == "onb.4.title")
        #expect(s.readyCount == 1 && s.total == 3)
        #expect(s.primary == .openChat)
    }

    /// Every row ready: the title changes, the footer reads n of n.
    @Test func everythingReady() {
        let s = Step4State(rows: [row("chat", .ready), row("voice", .ready), row("evil", .ready)], starterReady: true)
        #expect(s.titleKey == "onb.4.title.allReady" && s.subtitleKey == "onb.4.subtitle.allReady")
        #expect(s.readyCount == 3 && s.total == 3)
        #expect(s.primary == .openChat)
        #expect(CopyKey("onb.4.title.allReady").string() != CopyKey("onb.4.title").string())
    }

    /// A row still checking (bytes in, not yet verified) is not ready and keeps the "Preparing" title.
    @Test func checkingIsNotReady() {
        let s = Step4State(rows: [row("chat", .ready), row("photo", .checking)], starterReady: true)
        #expect(s.readyCount == 1 && s.titleKey == "onb.4.title" && s.subtitleKey == "onb.4.subtitle.ready")
    }

    /// The vq-m2 chatfailed shot: Chat failed → the failed subtitle and Retry as the primary; Open chat never is.
    @Test func chatFailedMakesRetryPrimary() {
        for starter in [false, true] {
            let s = Step4State(rows: [row("chat", .failed), row("voice", .failed), row("photo", .failed)], starterReady: starter)
            #expect(s.subtitleKey == "onb.4.subtitle.failed")
            #expect(s.primary == .retry)
            #expect(s.readyCount == 0 && s.total == 3 && s.titleKey == "onb.4.title")
        }
    }

    /// Review S2: a permanent Chat failure (download unavailable, a second hash mismatch) must not lock the user in.
    /// The starter answers → Retry stays primary, Open chat is offered beside it as the secondary action.
    @Test func chatFailedWithStarterOffersOpenChatAsSecondary() {
        let s = Step4State(rows: [row("chat", .failed), row("voice", .ready)], starterReady: true)
        #expect(s.primary == .retry)
        #expect(s.secondary == .openChat)
    }

    /// Review S2: Chat failed and nothing answers → Retry primary, "Continue without Chat" the way out.
    @Test func chatFailedWithoutStarterOffersContinueWithoutChat() {
        let s = Step4State(rows: [row("chat", .failed), row("voice", .downloading(percent: 40))], starterReady: false)
        #expect(s.primary == .retry)
        #expect(s.secondary == .continueWithoutChat)
        #expect(CopyKey("onb.4.skip").string() == "Continue without Chat")
    }

    /// No secondary action unless Chat failed (the primary Open chat is the only button then).
    @Test func noSecondaryWhileChatIsFine() {
        for starter in [false, true] {
            for chat in [SetupProgress.RowState.ready, .downloading(percent: 50), .waiting, .checking] {
                #expect(Step4State(rows: [row("chat", chat), row("voice", .failed)], starterReady: starter).secondary == nil)
            }
        }
        #expect(Step4State(rows: [], starterReady: false).secondary == nil)
    }

    /// Another row failed but Chat is fine: that row has its own Retry; the primary stays Open chat.
    @Test func otherRowFailedKeepsOpenChat() {
        let ready = Step4State(rows: [row("chat", .ready), row("voice", .failed)], starterReady: true)
        #expect(ready.primary == .openChat && ready.subtitleKey == "onb.4.subtitle.ready" && ready.readyCount == 1)
        let early = Step4State(rows: [row("chat", .downloading(percent: 5)), row("voice", .failed)], starterReady: false)
        #expect(early.primary == .wait && early.subtitleKey == "onb.4.subtitle.waiting")
    }

    /// No rows yet (before the first refresh): nothing claims to be ready.
    @Test func noRows() {
        let s = Step4State(rows: [], starterReady: false)
        #expect(s.titleKey == "onb.4.title" && s.subtitleKey == "onb.4.subtitle.waiting" && s.readyCount == 0 && s.total == 0)
    }

    /// A ready row reads "Ready", never a percentage; the subtitles never promise typing before Chat answers.
    @Test func rowTextAndCopy() {
        let ready = ProgressRow(row: row("chat", .ready)).stateText.string
        #expect(ready == CopyKey("onb.4.row.ready").string() && !ready.contains("%"))
        #expect(!CopyKey("onb.4.subtitle.waiting").string().localizedCaseInsensitiveContains("typing"))
        #expect(!CopyKey("onb.4.subtitle.starter").string().localizedCaseInsensitiveContains("is ready"))
    }
}

@Suite("OnboardingGateTests", .isolatedSettings) struct OnboardingGateTests {
    @Test func gate() {
        let d = UserDefaults.inMemory()
        #expect(OnboardingGate.shouldShow(options: LaunchOptions(), defaults: d))
        OnboardingGate.markCompleted(defaults: d)
        #expect(!OnboardingGate.shouldShow(options: LaunchOptions(), defaults: d))
        #expect(OnboardingGate.shouldShow(options: LaunchOptions.parse(["x", "-ResetOnboarding", "YES"]), defaults: d))
        let fresh = UserDefaults.inMemory()
        #expect(!OnboardingGate.shouldShow(options: LaunchOptions.parse(["x", "-SkipOnboarding", "YES"]), defaults: fresh))
        #expect(!OnboardingGate.shouldShow(options: LaunchOptions.parse(["x", "-UIProbe", "/tmp/p"]), defaults: fresh))
    }
}
