// M4 lead decision: the ChildSafetyCheck compile runs at install time. Once the `csam_check` detectors are installed,
// SafetyPreparation asks the helper once per manifest; while it runs, the Photo/Video install rows read "Checking"
// (PackRowState / SetupProgress), and they turn Ready when it ends. A manifest already prepared is not asked again.
import AntiChatEngineProtocol
import AntiChatPlatform
import Foundation
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SafetyPreparationTests {
    static let manifest = SafetyManifest(nudityPath: "/x/n", agePath: "/x/a", ageBinsPath: "/x/b",
                                         sha256: ["csc-nudity": "aa", "csc-age": "bb", "csc-age-bins": "cc"], sizeBytes: 1)

    final class Gate: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
    }

    @Test func compilesOnceAfterInstallAndHoldsTheRowsInChecking() async throws {
        let p = SafetyPreparation()
        let gate = Gate()
        p.prepare = { _ in
            gate.lock.withLock { gate.calls += 1 }
            await withCheckedContinuation { c in gate.lock.withLock { gate.release = c } }
            return true
        }
        var changes = 0
        p.onChange = { changes += 1 }
        let ids = ["csc-nudity", "csc-age", "csc-age-bins"]
        // Not every detector installed yet: nothing starts.
        p.ensure(Self.manifest, detectorIDs: ids, installed: ["csc-nudity"])
        #expect(p.running == nil && p.preparingGroups.isEmpty)
        p.ensure(Self.manifest, detectorIDs: ids, installed: Set(ids))
        #expect(p.preparingGroups == ["photo", "video"])
        p.ensure(Self.manifest, detectorIDs: ids, installed: Set(ids))  // a refresh while it runs: no second request
        for _ in 0..<200 where gate.lock.withLock({ gate.release == nil }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.lock.withLock { gate.calls } == 1)
        gate.lock.withLock { gate.release }?.resume()
        for _ in 0..<200 where p.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(p.preparingGroups.isEmpty && changes == 1)
        p.ensure(Self.manifest, detectorIDs: ids, installed: Set(ids))  // prepared: never asked again in this process
        #expect(p.running == nil && gate.lock.withLock { gate.calls } == 1)
        // A model change (other sha256) is a new manifest: compiled again.
        var changed = Self.manifest
        changed.sha256["csc-age"] = "dd"
        p.prepare = { _ in true }
        p.ensure(changed, detectorIDs: ids, installed: Set(ids))
        #expect(p.running == changed)
    }

    @Test func installedPackReadsCheckingWhilePreparing() {
        let items = CapabilitiesPackTests().model(.T1, enabled: [.chat, .photo]).items(.photo, modes: [.normal])
        let ids = Set(items.map(\.modelID))
        #expect(items.contains { $0.role == "csam_check" })
        let ready = PackRowState.compute(eligible: true, reason: nil, enabled: true, items: items, jobs: [], present: { _ in true },
                                         installed: ids, hasUpdate: false)
        let preparing = PackRowState.compute(eligible: true, reason: nil, enabled: true, items: items, jobs: [], present: { _ in true },
                                             installed: ids, hasUpdate: false, preparing: true)
        guard case .ready = ready else { Issue.record("\(ready)"); return }
        guard case .checking = preparing else { Issue.record("\(preparing)"); return }
        let setup = SetupProgress.compute(normal: items, evil: [], jobs: [], present: { _ in true }, installed: ids, preparing: ["photo"])
        #expect(setup.rows.first?.state == .checking)
        #expect(SetupProgress.compute(normal: items, evil: [], jobs: [], present: { _ in true }, installed: ids).rows.first?.state == .ready)
    }

    /// Owner bug 2026-11-15: after Pause the row kept "Pause" (SetupProgress counts user-paused files as downloading)
    /// and nothing could resume it. Every open file user-paused ⇒ paused (Resume); one running again ⇒ downloading.
    @Test func userPausedPackReadsPaused() {
        let items = CapabilitiesPackTests().model(.T1, enabled: [.chat, .photo]).items(.photo, modes: [.normal])
        let reqs = items.flatMap(\.requests)
        func job(_ r: DownloadRequest, _ s: DownloadJob.State, _ why: DownloadJob.PauseReason?) -> DownloadJob {
            DownloadJob(id: r.sha256, request: r, state: s, pauseReason: why, bytesDone: r.size / 4, retries: 0, errorKey: nil, createdAt: Date())
        }
        let paused = reqs.map { job($0, .paused, .user) }
        let state = PackRowState.compute(eligible: true, reason: nil, enabled: true, items: items, jobs: paused, present: { _ in false },
                                         installed: [], hasUpdate: false)
        guard case .downloading(_, true, _, _) = state else { Issue.record("\(state)"); return }
        var oneRunning = paused
        oneRunning[0].state = .running
        let resumed = PackRowState.compute(eligible: true, reason: nil, enabled: true, items: items, jobs: oneRunning, present: { _ in false },
                                           installed: [], hasUpdate: false)
        guard case .downloading(_, false, _, _) = resumed else { Issue.record("\(resumed)"); return }
    }
}
}
