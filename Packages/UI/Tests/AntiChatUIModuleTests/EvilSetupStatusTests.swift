// Owner bug 2026-11-16 (Evil Mode picked, typed, then "Chat Evil not available on this Mac yet"): what the composer
// and the mode picker say while Evil's chat model is not usable — from the same facts Settings › Capabilities shows.
//   downloading → "Evil is still downloading — 23%"; every byte here, no install view yet → "Finishing Evil setup…";
//   an install that did not finish, or nothing fetching it → a plain line with Retry; installed → nothing (Evil works).
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import Foundation
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct EvilSetupStatusTests {
    typealias M = OnboardingModelTests

    /// A tier whose Evil chat model is its own download, with Evil Mode on.
    func model(installed: Set<String> = [], jobs: [DownloadJob] = [], present: @escaping (String) -> Bool = { _ in false },
               failures: [String: String] = [:], evilOn: Bool = true) throws -> (PackManagementModel, InstallPlan.Item) {
        for t in LaunchOptions.Tier.allCases.reversed() {
            let m = PackManagementModel(defaults: UserDefaults.inMemory())
            m.evilIsOn = { evilOn }
            m.load(profile: M.profile(t), catalog: M.catalog, installed: installed, jobs: jobs, present: present, failures: failures)
            if let item = m.evilItems().first(where: { $0.pack == .chat && $0.role == "chat" && !$0.requests.isEmpty }) { return (m, item) }
        }
        throw CancellationError()
    }

    @Test func linesPerState() {
        func line(_ s: PackRowState?) -> String? { EvilSetupStatus(s)?.line.string }
        #expect(line(.downloading(percent: 23, paused: false)) == "Evil is still downloading — 23%")
        #expect(line(.downloading(percent: 0, paused: false, done: 19_700_000_000, total: 85_282_201_280)) == "Evil is still downloading — 23%")
        #expect(line(.downloading(percent: 23, paused: true)) == "Evil download paused — 23%")
        #expect(line(.checking) == "Finishing Evil setup…")
        #expect(line(.notDownloaded(downloadBytes: 1, queued: true)) == "Evil is waiting to download.")
        #expect(line(.notDownloaded(downloadBytes: 1, queued: false)) == "Evil isn't downloaded yet.")
        #expect(line(.failed) == "Evil setup didn't finish.")
        // Ready, off, unknown: nothing to say, Evil can be picked.
        #expect(EvilSetupStatus(.ready(bytesOnDisk: 1)) == nil)
        #expect(EvilSetupStatus(.off(downloadBytes: 1)) == nil)
        #expect(EvilSetupStatus(nil) == nil)
        // Retry only where nothing moves by itself.
        #expect(EvilSetupStatus(.failed)?.canRetry == true)
        #expect(EvilSetupStatus(.notDownloaded(downloadBytes: 1, queued: false))?.canRetry == true)
        #expect(EvilSetupStatus(.downloading(percent: 23, paused: false))?.canRetry == false)
        #expect(EvilSetupStatus(.checking)?.canRetry == false)
    }

    @Test func evilChatStateFollowsTheStoreTheQueueAndTheInstall() throws {
        let (none, item) = try model()
        let shas = Set(item.requests.map(\.sha256))
        let big = try #require(item.requests.max { $0.size < $1.size })
        // Nothing here, nothing fetching it.
        #expect(none.evilChatState == .notDownloaded(downloadBytes: item.requests.reduce(0) { $0 + $1.size }, queued: false))
        // The download runs: its percentage.
        let job = DownloadJob(id: "j", request: big, state: .running, pauseReason: nil, bytesDone: big.size / 4, retries: 0, errorKey: nil, createdAt: Date())
        let (running, _) = try model(jobs: [job])
        guard case .downloading(let pct, false, _, _) = running.evilChatState else { Issue.record("\(String(describing: running.evilChatState))"); return }
        #expect(pct > 0 && pct < 100)
        #expect(EvilSetupStatus(running.evilChatState)?.line.string.hasPrefix("Evil is still downloading — ") == true)
        // The owner's Mac: every byte verified in the store, no install view — being finished, never "not available".
        let (inStore, _) = try model(present: { shas.contains($0) })
        #expect(inStore.evilChatState == .checking)
        #expect(EvilSetupStatus(inStore.evilChatState)?.line.string == "Finishing Evil setup…")
        // The install did not finish: a plain line with Retry (Settings shows Didn't finish + Retry).
        let (failed, _) = try model(present: { shas.contains($0) }, failures: [item.modelID: InstallFailure.view])
        #expect(failed.evilChatState == .failed)
        #expect(failed.evilState == .failed)
        #expect(EvilSetupStatus(failed.evilChatState)?.canRetry == true)
        // Installed: nothing to say.
        let (ready, _) = try model(installed: Set(failed.evilItems().map(\.modelID)), present: { _ in true })
        guard case .ready = ready.evilChatState else { Issue.record("\(String(describing: ready.evilChatState))"); return }
        #expect(EvilSetupStatus(ready.evilChatState) == nil)
        // Evil Mode off: no state at all.
        let (off, _) = try model(evilOn: false)
        #expect(off.evilChatState == nil)
    }

    /// What the reconcile asks the installer to finish: the enabled packs' Normal models and, with Evil on, the Evil
    /// variants — each with every file — minus the models an update is bringing in.
    @Test func wantedItemsAreTheEnabledPacksPlusEvil() throws {
        let (m, item) = try model()
        let wanted = m.wantedItems()
        #expect(wanted.contains { $0.modelID == item.modelID && $0.mode == .evil })
        #expect(wanted.contains { $0.pack == .chat && $0.mode == .normal && $0.role == "chat" })
        #expect(!wanted.contains { $0.role == "chat_fast" })
        #expect(!wanted.contains { $0.pack != .chat }, "only Chat is enabled here")
        #expect(!m.wantedItems(excluding: [item.modelID]).contains { $0.modelID == item.modelID })
        let (off, _) = try model(evilOn: false)
        #expect(!off.wantedItems().contains { $0.mode == .evil })
    }

    /// The line is under the field as soon as the shown chat is an Evil one — before anything is typed.
    @Test func composerSaysItBeforeSend() {
        let c = ComposerModel(evilEnabled: true)
        c.evilUnavailableLine = CopyText(CopyKey("evil.setup.finishing"))
        #expect(c.evilSetupNotice == nil)  // a Normal chat is not bothered
        c.mode = .evil
        #expect(c.evilSetupNotice?.string == "Finishing Evil setup…")
        c.evilUnavailableLine = nil
        #expect(c.evilSetupNotice == nil)
    }
}
}
