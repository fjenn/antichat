// AT-202 unit legs (R-202 AC1–AC3, R-298) — M2.T21: PackRow states over the tier fixtures and the signed baseline catalog
// (Off with its download size / n % / paused / Checking / Ready / Not available with a truthful reason / Didn't finish),
// Keep models → Off with the bytes kept, removable ids never include Chat's or another enabled pack's models, the
// starter is removable only once the tier model is installed, the composer menu pack sets, and PackRow / DisablePackSheet
// renders Light + Dark (ANTICHAT_ONB_SHOTS). CapabilitiesUITests / PlusMenuDisabledPackTests / J10SettingsTests: Q-015.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct CapabilitiesPackTests {
    typealias M = OnboardingModelTests

    func model(_ t: LaunchOptions.Tier, enabled: Set<ModelPack> = [.chat], installed: Set<String> = [], jobs: [DownloadJob] = [],
               present: @escaping (String) -> Bool = { _ in false },
               shipped: Set<ModelPack> = Set(ModelPack.allCases)) -> PackManagementModel {
        let d = UserDefaults.inMemory()
        d.set(enabled.map(\.rawValue), forKey: PackManagementModel.enabledKey)
        let m = PackManagementModel(defaults: d)
        m.shipped = shipped
        m.enabled = enabled.union([.chat])  // the init keeps only this build's shipped packs
        m.load(profile: M.profile(t), catalog: M.catalog, installed: installed, jobs: jobs, present: present)
        return m
    }

    /// Advanced's override picker: published names, and the precision only where two options share a name.
    @Test func pickerLabelsDisambiguateSharedNames() {
        let names = ["chat-4b": "Qwen3.5-4B", "chat-9b-q4": "Qwen3.5-9B", "chat-9b-q8": "Qwen3.5-9B"]
        let labels = ModelNames.pickerLabels([("chat-4b", "4bit"), ("chat-9b-q4", "4bit"), ("chat-9b-q8", "8bit"), ("x", nil)]) {
            names[$0] ?? $0
        }
        #expect(labels == ["chat-4b": "Qwen3.5-4B", "chat-9b-q4": "Qwen3.5-9B · 4-bit", "chat-9b-q8": "Qwen3.5-9B · 8-bit", "x": "x"])
    }

    @Test func rowStatesPerTier() {
        // T0: Photo / Video not available with a reason that never claims less memory than this Mac has.
        let t0 = model(.T0)
        guard case .notAvailable(let r) = t0.state(.photo) else { Issue.record("\(t0.state(.photo))"); return }
        #expect(r.string.contains("16"))
        #expect(t0.modesLine(.photo) == nil)
        // T1: Voice off, with what turning it on downloads (> 0, never "0.0 GB").
        let t1 = model(.T1)
        guard case .off(let bytes) = t1.state(.voice) else { Issue.record("\(t1.state(.voice))"); return }
        #expect(bytes > 0)
        // VQ (S-21): the Normal ✓ · Evil ✓ line only once the pack is installed (it claims the models are here).
        #expect(t1.modesLine(.voice) == nil)
        // Enabled, nothing fetching → not downloaded (never a 0 % bar).
        guard case .notDownloaded(let missing, false) = model(.T1, enabled: [.chat, .voice]).state(.voice) else {
            Issue.record("\(model(.T1, enabled: [.chat, .voice]).state(.voice))"); return
        }
        #expect(missing == bytes)
        // Enabled + every model installed → Ready with its size on disk.
        let voiceIDs = Set(t1.items(.voice, modes: [.normal]).map(\.modelID))
        let ready = model(.T1, enabled: [.chat, .voice], installed: voiceIDs, present: { _ in true })
        guard case .ready(let onDisk) = ready.state(.voice) else { Issue.record("\(ready.state(.voice))"); return }
        #expect(ready.modesLine(.voice) != nil)
        #expect(onDisk == bytes)
        #expect(ready.isOn(.voice))
        // VQ (S-21, NFR-D8): install views whose files are gone are not "Ready · on disk" (Storage counts 0 for them).
        let gone = model(.T1, enabled: [.chat, .voice], installed: voiceIDs)
        guard case .notDownloaded = gone.state(.voice) else { Issue.record("\(gone.state(.voice))"); return }
        // VQ (S-21): chosen but never downloaded (nothing fetching) → the switch is off; a queued download → on.
        #expect(!model(.T1, enabled: [.chat, .voice]).isOn(.voice))
        #expect(!model(.T1).isOn(.voice))
        // Keep models: turned off with the views kept → Off (nothing left to download).
        let kept = model(.T1, enabled: [.chat], installed: voiceIDs, present: { _ in true })
        #expect(kept.state(.voice) == .off(downloadBytes: 0))
        #expect(kept.menuPacks.disabled == ["voice"])
        #expect(ready.menuPacks.installed.contains("voice") && ready.menuPacks.disabled.isEmpty)
        #expect(!model(.T1).menuPacks.installed.contains("voice"))
    }

    @Test func downloadingPausedFailed() {
        let t1 = model(.T1, enabled: [.chat, .voice])
        let reqs = t1.items(.voice, modes: [.normal]).flatMap(\.requests)
        func job(_ s: DownloadJob.State, _ done: Int64, _ pause: DownloadJob.PauseReason? = nil) -> [DownloadJob] {
            [DownloadJob(id: "j", request: reqs[0], state: s, pauseReason: pause, bytesDone: done, retries: 0, errorKey: nil, createdAt: Date())]
        }
        let m = model(.T1, enabled: [.chat, .voice], jobs: job(.running, reqs[0].size / 2))
        guard case .downloading(_, false, _, _) = m.state(.voice) else { Issue.record("\(m.state(.voice))"); return }
        let p = model(.T1, enabled: [.chat, .voice], jobs: job(.paused, 10, .system))
        guard case .downloading(_, true, _, _) = p.state(.voice) else { Issue.record("\(p.state(.voice))"); return }
        #expect(model(.T1, enabled: [.chat, .voice], jobs: job(.failed, 10)).state(.voice) == .failed)
    }

    @Test func removalNeverTouchesChatOrOtherPacks() {
        let t2 = model(.T2, enabled: [.chat, .voice, .photo])
        let chatIDs = Set(t2.items(.chat, modes: [.normal, .evil]).map(\.modelID)).union([t2.starterID!])
        let all = chatIDs.union(t2.items(.voice, modes: [.normal, .evil]).map(\.modelID))
            .union(t2.items(.photo, modes: [.normal, .evil]).map(\.modelID))
        let m = model(.T2, enabled: [.chat, .voice, .photo], installed: all)
        let removable = m.removableIDs(.photo)
        #expect(!removable.isEmpty)
        #expect(removable.isDisjoint(with: chatIDs))
        #expect(removable.isDisjoint(with: m.items(.voice, modes: [.normal, .evil]).map(\.modelID)))
    }

    /// Removing a pack whose model is loaded evicts it through ModelScheduler first, then deletes its view.
    @Test func removalEvictsBeforeDeleting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "caps-evict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = ModelsDirectory(root: root)
        let id = "photo-model"
        try FileManager.default.createDirectory(at: models.install(id), withIntermediateDirectories: true)
        try Data("w".utf8).write(to: models.install(id).appending(path: "weights.bin"))
        final class Seen: @unchecked Sendable { var ids: Set<String> = []; var viewPresentAtEvict = false }
        let seen = Seen()
        let path = models.install(id).path
        await PackManagementModel.removeModels([id], models: models) { ids in
            seen.ids = ids
            seen.viewPresentAtEvict = FileManager.default.fileExists(atPath: path)
        }
        #expect(seen.ids == [id])
        #expect(seen.viewPresentAtEvict)
        #expect(!FileManager.default.fileExists(atPath: path))
        // Nothing to remove → no eviction round-trip.
        let none = Seen()
        await PackManagementModel.removeModels([], models: models) { none.ids = $0; none.viewPresentAtEvict = true }
        #expect(!none.viewPresentAtEvict)
    }

    /// M2 review #10: "Remove Evil models" evicts the loaded model before deleting its view, off the main thread.
    @Test func evilRemovalEvictsFirstOffMain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "evil-evict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = ModelsDirectory(root: root)
        let id = "evil-chat"
        try FileManager.default.createDirectory(at: models.install(id), withIntermediateDirectories: true)
        final class Seen: @unchecked Sendable { var ids: Set<String> = []; var viewPresent = false; var onMain = true }
        let seen = Seen()
        let path = models.install(id).path
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            EvilModelRemoval(ids: [id], frees: 1).run(models: models, evict: { ids in
                seen.ids = ids
                seen.viewPresent = FileManager.default.fileExists(atPath: path)
                seen.onMain = pthread_main_np() != 0
            }, done: { c.resume() })
        }
        #expect(seen.ids == [id] && seen.viewPresent && !seen.onMain)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func starterRemovableOnlyWithTierModel() {
        let t1 = model(.T1)
        let starter = t1.starterID!
        let tier = t1.selection!.slot(.chat, .normal, role: "chat")!.modelID!
        #expect(!model(.T1, installed: [starter]).starterRemovable)  // the chat would lose its only model
        #expect(model(.T1, installed: [starter, tier]).starterRemovable)
        #expect(!model(.T1, installed: [tier]).starterInstalled)
    }

    /// r66 F5: the row warns before a click (the one rule, free ≥ download + 10 GB, against free space now) and gives
    /// the same number Enable would; with room enough, or nothing to download, no warning.
    @Test func diskShortfallBeforeEnableMatchesTheRule() throws {
        let m = model(.T1)
        let plan = try #require(m.downloadPlan(.voice))
        #expect(plan.totalBytes > 0)
        m.freeBytes = { 2_000_000_000 }
        let gb = try #require(m.diskShortfall(.voice))
        #expect(DiskPreflight.check(total: plan.totalBytes, free: 2_000_000_000) == .short(gbNeeded: gb))
        // needed = size + 10 GB − free, whole GB rounded up: Photo 6.3 GB with 2.0 GB free → 15 (14.3 more).
        #expect(DiskPreflight.check(total: 6_300_000_000, free: 2_000_000_000) == .short(gbNeeded: 15))
        m.freeBytes = { plan.totalBytes + DiskPreflight.headroomBytes }
        #expect(m.diskShortfall(.voice) == nil)
        m.freeBytes = { 0 }
        #expect(m.diskShortfall(.chat) == nil)  // Chat has no Enable
        // The rule's own words are in the warning.
        #expect(CopyText(CopyKey("onb.diskShort"), ["gb": "15"]).string.contains("10 GB"))
    }

    /// r66 F1: Settings › Storage names a helper model by what it does (the embedding model was "Chat · Normal"), and
    /// its hint carries the role; a model whose files are gone says so.
    @Test func storageRowsNameTheirRole() {
        let hints = model(.T1).storageHints()
        #expect(hints.values.contains { $0.role == "embed" })
        func row(_ role: String, missing: Bool = false) -> StorageReport.ModelRow {
            StorageReport.ModelRow(slot: "chat/normal/\(role)/x", modelID: "x", pack: "chat", mode: "normal", role: role,
                                   category: .chatModels, bytes: 1, shared: false, missing: missing,
                                   installView: URL(fileURLWithPath: "/tmp/x"))
        }
        let embed = ModelRowView.modesLine(row("embed"))
        #expect(embed.contains(CopyKey("storage.role.embed").string()) && !embed.contains(CopyKey("set.cap.mode.normal").string()))
        #expect(ModelRowView.modesLine(row("chat")).contains(CopyKey("set.cap.mode.normal").string()))
        #expect(ModelRowView.modesLine(row("chat", missing: true)).contains(CopyKey("storage.model.missing").string()))
    }

    /// r66 F5: the bytes and the percent beside the bar agree ("0.1 GB of 1.0 GB · 0%" was 5 MB shown as 0.1 GB).
    @Test func downloadingBytesAgreeWithPercent() {
        #expect(PackRow.doneSize(5_000_000) == "5 MB")
        #expect(PackRow.percent(done: 5_000_000, total: 1_000_000_000) == 0)
        #expect(PackRow.doneSize(150_000_000) == "150 MB" && PackRow.percent(done: 150_000_000, total: 1_000_000_000) == 15)
        #expect(PackRow.doneSize(1_290_000_000) == "1.2 GB")
        #expect(PackRow.percent(done: 1_000_000_000, total: 1_000_000_000) == 99)
    }

    @Test func renders() {
        typealias Look = ComposerSnapshotTests.Look
        let t1 = model(.T1)
        let states: [(String, PackRowState)] = [
            ("off", t1.state(.voice)), ("downloading", .downloading(percent: 42, paused: false, done: 508_000_000, total: 1_210_000_000)),
            ("paused", .downloading(percent: 42, paused: true, done: 508_000_000, total: 1_210_000_000)),
            ("notDownloaded", .notDownloaded(downloadBytes: 1_210_000_000, queued: false)),
            ("queued", .notDownloaded(downloadBytes: 1_210_000_000, queued: true)), ("checking", .checking), ("ready", .ready(bytesOnDisk: 1_210_000_000)),
            ("update", .updateAvailable(bytesOnDisk: 1_210_000_000)), ("failed", .failed),
            ("notAvailable", model(.T0).state(.photo)),
        ]
        for look in Look.allCases {
            let list = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                    PackRow(pack: .photo, state: s.1, isOn: true)
                }
                PackRow(pack: .chat, state: .ready(bytesOnDisk: 6_400_000_000), isOn: true)
                Divider()
                DisablePackSheet(pack: .photo, frees: 2_870_000_000, onKeep: {}, onRemove: {}, onCancel: {})
            }
            .padding(20)
            .frame(width: 620)
            .background(Color.surfaceCanvas)
            .environment(\.colorScheme, look == .light ? .light : .dark)
            let img = OnboardingSnapshotTests.render(list, size: CGSize(width: 620, height: 820), look: look)
            OnboardingSnapshotTests.write(img, "settings-capabilities-packs-\(look.rawValue)")
            #expect(img.size.width == 620)
        }
    }
}
}
