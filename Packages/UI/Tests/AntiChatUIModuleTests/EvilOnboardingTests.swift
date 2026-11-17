// M2.T19 (AT-227, AT-201 part 2 unit legs): EvilVariantPlanner per tier fixture (extra bytes = the Evil chat
// variant's unique files − what Normal already brings, Photo/Video Evil add 0 under Q-009 a), truthful availability
// (never "not available" for a pack whose Evil variant exists), the step-3 Continue rules (adult box, disk re-check
// with Evil included, Evil off always continues) and evilOnlyIDs (what "Remove Evil models" may delete).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite("EvilVariantPlannerTests", .isolatedSettings) struct EvilVariantPlannerTests {
    typealias M = OnboardingModelTests

    @Test func extraBytesPerTier() {
        let cat = M.catalog
        for t in LaunchOptions.Tier.allCases {
            let m = M.model(t)
            guard let sel = m.selection, let plan = m.evilPlan else { Issue.record("no selection \(t)"); continue }
            // Independent: unique sha256 of the Evil chat closure minus every file of the Normal set.
            let normalIDs = sel.installIDs(packs: m.chosenPacks, modes: [.normal], onDemand: Set(cat.onDemand))
            let evilIDs = sel.installIDs(packs: [.chat], modes: [.evil], onDemand: Set(cat.onDemand))
            let normalSHA = Set(normalIDs.flatMap { cat.models[$0]?.files.map(\.sha256) ?? [] })
            var seen: [String: Int64] = [:]
            for id in evilIDs { for f in cat.models[id]?.files ?? [] where !normalSHA.contains(f.sha256) { seen[f.sha256] = f.size } }
            let expected = seen.values.reduce(0, +)
            #expect(abs(Double(plan.extraBytes - expected)) <= 0.01 * Double(max(expected, 1)), "\(t) \(plan.extraBytes) vs \(expected)")
            // Q-009 a: Photo / Video Evil = the Normal ids → adding them costs nothing.
            let withMedia = EvilVariantPlanner.plan(selection: sel, catalog: cat, packs: m.chosenPacks.union([.photo, .video]))
            let mediaNormal = InstallQueue.plan(selection: sel, catalog: cat, packs: m.chosenPacks.union([.photo, .video]), modes: [.normal])
            let chatOnly = EvilVariantPlanner.plan(selection: sel, catalog: cat, packs: [.chat])
            #expect(withMedia.extraBytes == chatOnly.extraBytes || mediaNormal.isEmpty)
            if plan.isAvailable { #expect(plan.extraBytes > 0) }
        }
        // T1 fixture t1-m2-16 (M2, 100 GB/s < 120): the speed guard steps Normal down to chat-4b and Evil, same family,
        // to evil-4b → "Evil adds 3.1 GB". AT-227's "6.5 GB" is evil-9b, the pick on a ≥ 120 GB/s T1 (M3/M4 16 GB).
        let t1 = M.model(.T1)
        let evilID = t1.selection?.slot(.chat, .evil, role: "chat")?.modelID
        let normalID = t1.selection?.slot(.chat, .normal, role: "chat")?.modelID
        #expect(evilID == "evil-4b" && normalID == "chat-4b", "\(String(describing: evilID)) \(String(describing: normalID))")
        #expect(t1.evilCostLine.string == "Evil adds 3.1 GB", "\(t1.evilCostLine.string)")
    }

    @Test func availabilityIsTruthful() {
        for t in LaunchOptions.Tier.allCases {
            let m = M.model(t)
            let plan = m.evilPlan!
            for p in plan.unavailablePacks {
                let role = p == .chat ? "chat" : p.rawValue
                #expect(m.selection?.slot(p, .evil, role: role)?.modelID == nil, "\(t) \(p) claimed unavailable but has a variant")
            }
            // Dimmed (unchosen) packs are never listed.
            #expect(Set(plan.availablePacks + plan.unavailablePacks).isSubset(of: m.chosenPacks))
        }
        #expect(M.model(.T1).evilAvailabilityLine.key.rawValue == "onb.3.availability.all")
        #expect(!M.model(.T0).evilPlan!.availablePacks.contains(.photo))
    }

    @Test func evilOnlyIDsNeverIncludeNormalModels() {
        let ids = EvilVariantPlanner.evilOnlyIDs(catalog: M.catalog)
        #expect(ids.contains("evil-9b"))
        #expect(ids.allSatisfy { $0.hasPrefix("evil-") }, "\(ids)")
        #expect(!ids.contains("chat-0.8b"))
    }

    @Test func readiness() {
        let plan = M.model(.T1).evilPlan!
        #expect(EvilReadiness.state(enabled: false, plan: plan, remainingBytes: 1, verifying: false, bytesPerSecond: nil) == .notEnabled)
        #expect(EvilReadiness.state(enabled: true, plan: plan, remainingBytes: 600_000_000, verifying: false, bytesPerSecond: 5_000_000)
                == .downloading(etaMinutes: 2))
        #expect(EvilReadiness.state(enabled: true, plan: plan, remainingBytes: 1, verifying: false, bytesPerSecond: nil).copyKey
                == "evil.downloading.queued")
        #expect(EvilReadiness.state(enabled: true, plan: plan, remainingBytes: 0, verifying: false, bytesPerSecond: nil) == .ready)
        var none = plan
        none.availablePacks = []
        #expect(EvilReadiness.state(enabled: true, plan: none, remainingBytes: 0, verifying: false, bytesPerSecond: nil)
                == .unavailable(reason: "evil_not_available"))
    }
}

@MainActor
@Suite("OnboardingEvilTests", .isolatedSettings) struct OnboardingEvilTests {
    typealias M = OnboardingModelTests

    @Test func adultBoxGatesContinue() {
        let m = M.model(.T1)
        m.step = .evil
        var accepted: EvilPlan?
        var finished = false
        m.onEvilAccepted = { accepted = $0 }
        m.onFinish = { finished = true }
        let normalTotal = m.totalBytes
        m.evilOn = true
        #expect(m.totalBytes > normalTotal)  // total updated
        #expect(m.evilContinueBlocked?.key.rawValue == "onb.3.adult")
        m.next()
        #expect(!finished && m.step == .evil)
        m.adultConfirmed = true
        #expect(m.evilContinueBlocked == nil)
        m.next()
        #expect(m.step == .preparing && !finished)  // M2.T20: step 4 follows; Open chat finishes
        #expect(accepted != nil && accepted!.requests.allSatisfy { $0.pack == "evil" || $0.pack != "chat" })
    }

    @Test func evilOffContinuesWithoutEvil() {
        let m = M.model(.T1)
        m.step = .evil
        var accepted = false, finished = false
        m.onEvilAccepted = { _ in accepted = true }
        m.onFinish = { finished = true }
        m.next()
        #expect(m.step == .preparing && !finished && !accepted)
        m.next()
        #expect(finished)
    }

    /// M10 visual QA (S-04 Back): Back from step 4 to step 3, Evil turned off, Continue → the queued Evil is dropped
    /// ; Continue again with Evil off declines again (idempotent: off at step 3 always means off, 2026-11-15).
    @Test func backFromStep4ThenEvilOffDeclinesTheQueuedEvil() {
        let m = M.model(.T1)
        m.step = .evil
        var accepted = 0, declined = 0
        m.onEvilAccepted = { _ in accepted += 1 }
        m.onEvilDeclined = { declined += 1 }
        m.evilOn = true
        m.adultConfirmed = true
        m.next()
        #expect(m.step == .preparing && accepted == 1 && m.evilQueued)
        m.back()
        #expect(m.step == .evil)
        m.evilOn = false
        m.next()
        #expect(m.step == .preparing && declined == 1 && !m.evilQueued)
        m.back()
        m.next()
        #expect(declined == 2 && accepted == 1 && !m.evilQueued)
    }

    /// Review S1: a relaunch mid-onboarding resumes at step 4 with Evil queued by SetupLaunch.resume (no step-3
    /// Continue in this process). Back, Evil off, Continue still withdraws it: consent off, the queued Evil downloads
    /// dropped, and the saved choice says `evil: false`.
    @Test func resumedEvilCanBeWithdrawnAfterBack() throws {
        // Consent given in the first run (the onboarding sheet's EvilModeModel.enable).
        let d = UserDefaults.inMemory()
        let manager = EvilModeManager(database: try AppDatabase.inMemory(), termsVersion: "v", defaults: d, flagDefaults: d)
        try manager.enable(adultSelfDeclared: true)
        let evilModel = EvilModeModel(manager: manager)
        #expect(evilModel.isEnabled)
        // What SetupLaunch.resume left behind: the saved choice and the queued Evil variants.
        let m = M.model(.T1)
        let plan = try #require(m.evilPlan)
        #expect(!plan.items.isEmpty)
        SetupChoice(packs: ["chat", "voice", "photo"], evil: true).save()
        let status = SetupStatus()
        status.evilEnabled = true
        status.evilItems = plan.items
        status.evilPlan = plan
        m.onEvilDeclined = { SetupLaunch.withdrawEvil(evilModel, status: status) }
        var accepted = 0
        m.onEvilAccepted = { _ in accepted += 1 }

        m.resume(packs: [.chat, .voice, .photo], evil: true)
        #expect(m.step == .preparing && m.evilOn && m.evilQueued)
        m.back()
        #expect(m.step == .evil)
        m.evilOn = false
        m.next()
        #expect(m.step == .preparing && !m.evilQueued && accepted == 0)
        #expect(!evilModel.isEnabled && !manager.isEnabled, "consent withdrawn")
        #expect(!status.evilEnabled && status.evilItems.isEmpty && status.evilPlan == nil, "Evil downloads dropped")
        #expect(SetupChoice.load()?.evil == false)
    }

    /// The resume path keeps the saved choice's packs and leaves Evil unqueued when it was not chosen; Continue with
    /// Evil off still declines (a leftover enabled Evil from an earlier install is withdrawn; harmless otherwise).
    @Test func resumeWithoutEvilQueuesNothing() {
        let m = M.model(.T1)
        var declined = 0
        m.onEvilDeclined = { declined += 1 }
        m.resume(packs: [.chat], evil: false)
        #expect(m.step == .preparing && !m.evilOn && !m.evilQueued && m.chosenPacks == [.chat])
        m.back()
        m.next()
        #expect(declined == 1 && !m.evilQueued)
    }

    @Test func diskRecheckIncludesEvil() {
        // EvilDiskRecheckTests (unit leg): free = Normal + 10 GB headroom exactly → Evil on is short, off is fine.
        let probe = M.model(.T1)
        let freeGB = Int64((Double(probe.totalBytes + DiskPreflight.headroomBytes) / 1e9).rounded(.up))
        let m = M.model(.T1, freeGB: freeGB)
        m.step = .evil
        #expect(m.disk == .ok)
        m.evilOn = true
        m.adultConfirmed = true
        #expect(m.evilContinueBlocked?.key.rawValue == "onb.diskShort")
        m.evilOn = false
        #expect(m.evilContinueBlocked == nil)
    }
}
