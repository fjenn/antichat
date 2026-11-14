// M2 review fixes in the onboarding / Capabilities layer and lead decision B (ModelPack.shipped):
//   B   every pack ships since M4.T16 (Voice M3.T14, Photo M4.T16, Video M5.T14), so this build shows no "Coming soon".
//       The mechanism stays for any later pack: with one held back (the `shipped` seam) it is "Coming soon" in step 2
//       and Settings › Capabilities (not tickable, not counted, never enqueued) and its install card says so;
//   #5  a relaunch resume plans only what is still missing and leaves out on-demand models;
//   #6  an Advanced override drops the chats' selection memo; "Allow over budget" is part of its key;
//   #14 an Enable the catalog refuses stays Off with the reason (no "downloading 0 %" forever).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ShippedPacksAndSetupTests {
    typealias M = OnboardingModelTests
    /// A build that holds Photo back: exercises the "Coming soon" path, which no pack takes in this build.
    static let heldBack: Set<ModelPack> = [.chat, .voice, .video]

    @Test func thisBuildShipsEveryPack() {
        #expect(ModelPack.shipped == [.chat, .voice, .photo, .video])  // M3.T14 Voice, M4.T16 Photo, M5.T14 Video
        #expect(ModelPack.allCases.allSatisfy { $0.isShipped })
        for t in [LaunchOptions.Tier.T0, .T1, .T4] {
            #expect(M.model(t, shipped: ModelPack.shipped).cards.allSatisfy { !$0.comingSoon }, "no Coming soon card at \(t)")
        }
        let d = UserDefaults.inMemory()
        d.set(["chat", "voice", "photo", "video"], forKey: PackManagementModel.enabledKey)
        let m = PackManagementModel(defaults: d)
        #expect(m.enabled == Set(ModelPack.allCases), "every saved pack is restored")
        m.load(profile: M.profile(.T2), catalog: M.catalog, installed: [])
        for p in ModelPack.allCases { #expect(m.state(p) != .comingSoon, "\(p) ships") }
    }

    @Test func step2ShowsAHeldBackPackAsComingSoon() {
        for t in [LaunchOptions.Tier.T0, .T1, .T4] {
            let m = M.model(t, shipped: Self.heldBack)
            for c in m.cards where !Self.heldBack.contains(c.pack) {
                #expect(c.comingSoon && !c.ticked && !c.toggleable && c.bytes == 0)
                #expect(c.dimmedReason?.key.rawValue == "onb.pack.comingSoon.note")
            }
            #expect(m.cards.first { $0.pack == .photo }?.comingSoon == true)
            #expect(m.cards.first { $0.pack == .video }?.comingSoon == false)
            let before = m.chosenPacks
            m.toggle(.photo)
            #expect(m.chosenPacks == before && !m.chosenPacks.contains(.photo), "an unshipped pack cannot be ticked")
            #expect(m.chosenPacks.isSubset(of: Self.heldBack))
            // The total counts only the shipped packs chosen (what the full-ship model counts for them).
            #expect(m.totalBytes == M.model(t).bytes(packs: m.chosenPacks))
            #expect(m.continueBlocked == nil)
        }
    }

    @Test func capabilitiesRowsOfAHeldBackPackAreComingSoonAndCannotBeEnabled() {
        let d = UserDefaults.inMemory()
        d.set(["chat", "voice", "photo"], forKey: PackManagementModel.enabledKey)  // saved by a build that shipped Photo
        let m = PackManagementModel(defaults: d, shipped: Self.heldBack)
        #expect(m.enabled == [.chat, .voice])
        m.load(profile: M.profile(.T2), catalog: M.catalog, installed: [])
        #expect(m.state(.video) != .comingSoon && m.state(.voice) != .comingSoon && m.state(.chat) != .comingSoon)
        #expect(m.state(.photo) == .comingSoon)
        #expect(m.modesLine(.photo) == nil && !m.isInstalled(.photo))
        m.enable(.photo)
        #expect(!m.enabled.contains(.photo))
        #expect(CapabilitiesPackInstaller.availability(.comingSoon, installed: false) == .comingSoon)
        let card = InstallCardPolicy.card(.photo, availability: .comingSoon, userMessageID: "u")!
        #expect(InstallCardView.text(card).key.rawValue == "install.comingSoon" && !card.hasButtons)
    }

    @Test func resumePlansOnlyWhatIsMissingWithoutOnDemand() {
        let sel = ChatModels.selection(profile: M.profile(.T2), catalog: M.catalog)
        let choice = SetupChoice(packs: ["chat", "photo"], evil: true)
        let (none, _) = SetupLaunch.resumePlan(choice: choice, selection: sel, catalog: M.catalog, present: { _ in true })
        #expect(none.totalBytes == 0, "everything already on disk: nothing counts against the disk rule")
        let (all, evil) = SetupLaunch.resumePlan(choice: choice, selection: sel, catalog: M.catalog, present: { _ in false })
        let ids = Set(all.stages.flatMap(\.items).map(\.modelID))
        #expect(!ids.isEmpty && ids.isDisjoint(with: M.catalog.onDemand))
        #expect(Set(all.stages.flatMap(\.items).map(\.pack)) == [.chat, .photo], "Photo ships: its saved choice is resumed")
        #expect(evil != nil)
        let (held, _) = SetupLaunch.resumePlan(choice: choice, selection: sel, catalog: M.catalog, present: { _ in false },
                                               shipped: Self.heldBack)
        #expect(held.stages.flatMap(\.items).allSatisfy { $0.pack == .chat }, "an unshipped pack saved by an earlier build is dropped")
    }

    @Test func advancedOverrideInvalidatesTheChatSelection() throws {
        let cm = ChatModels()
        let adv = AdvancedModel(database: try AppDatabase.inMemory(), catalogStore: nil, chatModels: cm)
        let before = cm.invalidations
        adv.pick(.chat, .normal, "chat-x")
        adv.reset(.chat)
        #expect(cm.invalidations == before + 2)
        let p = M.profile(.T1)
        #expect(ChatModels.memoKey(catalogVersion: 1, profile: p, allowOverBudget: false)
            != ChatModels.memoKey(catalogVersion: 1, profile: p, allowOverBudget: true))
    }

    /// Q-015 r3: a throwaway UI-test container installs no Voice pack; `-FakeVoiceInstalled` (DEBUG) hands the
    /// helper the dev store's models through `voiceFallback`, so a voice session no longer ends as `voice.unavailable`.
    /// Installed models always win, and without the fallback nothing changes.
    @Test func voiceFallbackOnlyWhenNothingIsInstalled() {
        let cm = ChatModels()
        #expect(cm.voiceModelSet().slots.isEmpty, "no catalog, no fallback: no voice models")
        let dev = VoiceModelSet(slots: [.stt: ModelSlot(engine: .coreml, key: "stt", path: "/dev/stt", footprintBytes: 1)])
        cm.voiceFallback = { dev }
        #expect(cm.voiceModelSet().slots[.stt]?.path == "/dev/stt")
        cm.voiceFallback = { nil }
        #expect(cm.voiceModelSet().slots.isEmpty)
    }

    @Test func catalogRefusalLeavesThePackOffWithItsReason() throws {
        let d = UserDefaults.inMemory()
        let m = PackManagementModel(defaults: d)
        m.shipped = Set(ModelPack.allCases)
        m.load(profile: M.profile(.T1), catalog: M.catalog, installed: [])
        let root = FileManager.default.temporaryDirectory.appending(path: "refuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dl = DownloadCoordinator(models: ModelsDirectory(root: root), database: nil)
        let cat = M.catalog
        let installer = SetupInstaller(coordinator: dl, database: nil, catalog: { cat })
        m.installer = { installer }
        m.freeBytes = { 10_000_000_000_000 }
        m.mayInstallNew = { false }
        m.enable(.voice)
        #expect(!m.enabled.contains(.voice))
        #expect(m.refused[.voice]?.key.rawValue == "catalog.badSignature")
        #expect(d.array(forKey: PackManagementModel.enabledKey) == nil, "the refused pack is not persisted")
        // A refusal reported by the queue after the start (catalog went stale meanwhile) turns the pack back off.
        m.mayInstallNew = { true }
        m.enabled.insert(.photo)
        m.refusedAfterStart(.photo, .catalogRefused)
        #expect(!m.enabled.contains(.photo) && m.refused[.photo] != nil)
    }
}
