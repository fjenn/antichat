// M2.T09 definition of done: StatusPill in every state (hidden · downloading "Photo 42%" · paused · error), the two
// download sheets (disk short "Needs 3 GB more free space.", metered "This is 1.2 GB. …") and the paused-connection
// notice, Light and Dark, on the ResponseActionsSnapshotTests rig; plus the state rule from pack progress.
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=StatusPillSnapshotTests.
import AntiChatFoundation
import AntiChatPlatform
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct StatusPillSnapshotTests {
    func check(_ view: some View, width: CGFloat, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: width, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "downloads")
        }
    }

    @Test func pillStates() {
        let states: [(String, StatusPill.State)] = [("downloading", .downloading(pack: "photo", percent: 42)),
                                                    ("paused", .paused(pack: "voice")), ("error", .error(pack: "chat"))]
        for (name, s) in states { check(StatusPill(fixed: s, model: nil), width: 240, name: "StatusPill.\(name)") }
        #expect(StatusPill.title(.hidden) == nil)
        #expect(StatusPill.title(.downloading(pack: "photo", percent: 42))?.string == "Images 42%")
        #expect(StatusPill.title(.downloading(pack: "evil", percent: 7))?.string == "Evil 7%")
    }

    @Test func sheetsAndNotice() {
        check(DiskShortSheet(gbNeeded: 3, onOpenStorage: {}, onClose: {}), width: 400, name: "DiskShortSheet")
        check(DownloadAskSheet(bytes: 1_200_000_000, onDownload: {}, onLater: {}), width: 420, name: "DownloadAskSheet")
        check(DownloadPausedNotice(onRetry: {}), width: 260, name: "DownloadPausedNotice")
        #expect(CopyText(CopyKey("download.diskFull"), ["gb": "3"]).string == "Needs 3 GB more free space. AntiChat keeps 10 GB free beyond its downloads.")
        #expect(CopyText(CopyKey("download.expensiveAsk"), ["size": DownloadAskSheet.size(1_200_000_000)]).string
                == "This is 1.2 GB. You're on a personal hotspot. Download anyway?")
        #expect(CopyKey("download.pausedConnection").string() == "Download paused — check your connection")
    }

    @Test func stateRule() {
        func p(_ state: PackProgress.State, _ pct: Int64) -> PackProgress {
            PackProgress(pack: "photo", bytesDone: pct, bytesTotal: 100, bytesPerSecond: 0, etaSeconds: nil, state: state, errorKey: nil)
        }
        #expect(StatusPill.state(nil) == .hidden)
        #expect(StatusPill.state(p(.downloading, 42)) == .downloading(pack: "photo", percent: 42))
        #expect(StatusPill.state(p(.paused, 10)) == .paused(pack: "photo"))
        #expect(StatusPill.state(p(.failed, 10)) == .error(pack: "photo"))
        #expect(StatusPill.state(p(.done, 100)) == .hidden)
    }
}
}  // extension WindowSuites

@MainActor extension WindowSuites.StatusPillSnapshotTests {
    /// M2.T10: the corrupt-model row (NFR-S5).
    @Test func repairButton() {
        check(RepairButton(bytes: 1_840_000_000, action: {}), width: 420, name: "RepairButton")
        #expect(CopyText(CopyKey("model.corrupt.redownload"), ["size": DownloadAskSheet.size(1_840_000_000)]).string == "Re-download (1.84 GB)")
    }

    /// M9.T08 R3 (S-25 "Corrupt model: Re-download"): a `model.corrupt` reply offers [Re-download ({size})], not [Retry];
    /// {size} is the bad files only, or the whole model when nothing on disk measures as bad (an engine-side fault).
    @Test func corruptReplyOffersRedownload() {
        check(ModelCorruptNotice(modelID: "chat-9b-q4", onRepaired: {}, onRetry: {}, fixedBytes: 1_840_000_000), width: 560,
              name: "ModelCorruptNotice")
        #expect(AntiChatError(.modelCorrupt).recovery == [.redownload(slot: nil)])
        let bad: [Repair.Problem] = [.size(path: "model.gguf", sha256: "a")]
        #expect(ModelRepair.redownloadBytes(problems: bad, measured: { _ in 512 }, catalogBytes: 5_000) == 512)
        #expect(ModelRepair.redownloadBytes(problems: [], measured: { _ in 0 }, catalogBytes: 5_000) == 5_000)
        #expect(ModelRepair.redownloadBytes(problems: [.noView], measured: { _ in 0 }, catalogBytes: 5_000) == 5_000)
        #expect(ModelRepair.redownloadBytes(problems: [], measured: { _ in 0 }, catalogBytes: nil) == nil)
    }
}
