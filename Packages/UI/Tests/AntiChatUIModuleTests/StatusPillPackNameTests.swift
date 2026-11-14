// RC e8fe19986: a failed background model update showed "onb.pack.update.name download stopped" in the sidebar pill.
// Every pack id a download job can carry (the shipped packs, the Evil chat variant, ModelUpdateService's "update",
// Repair's "repair", and anything unknown) names itself in words in the pill, the menu bar item and the notification.
import AntiChatDesign
import AntiChatPlatform
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct StatusPillPackNameTests {
    static let packs = ModelPack.allCases.map(\.rawValue) + ["evil", "update", "repair", "somethingNew", ""]

    @Test(arguments: packs) func everyPackIdReadsAsWords(pack: String) {
        let key = StatusPill.packNameKey(pack)
        let name = StatusPill.packName(pack)
        #expect(!name.isEmpty && name != key, "\(pack): \(key) has no copy")
        #expect(!name.contains("onb.pack") && !name.contains("pack."), "\(pack) renders a raw key: \(name)")
        for s in [StatusPill.State.error(pack: pack), .paused(pack: pack), .downloading(pack: pack, percent: 7)] {
            let title = StatusPill.title(s)?.string ?? ""
            #expect(!title.contains("onb.pack") && !title.contains("pack."), "\(pack): \(title)")
        }
    }

    @Test func namesTheBackgroundJobs() {
        #expect(StatusPill.title(.error(pack: "update"))?.string == "Model update download stopped")
        #expect(StatusPill.packName("repair") == "Model repair")
        #expect(StatusPill.packName("photo") == "Photo")
        #expect(StatusPill.packName("evil") == "Evil")
    }

    /// The menu bar's download rows use the same names.
    @Test func menuBarRowsReadAsWords() {
        let downloads = Self.packs.map { PackProgress(pack: $0, bytesDone: 1, bytesTotal: 2, bytesPerSecond: 0, etaSeconds: nil,
                                                      state: .downloading, errorKey: nil) }
        let rows = MenuBarModel.items(downloads: downloads, jobs: [], voiceReady: false, quickPanelShortcut: nil,
                                        callActive: false)
        for r in rows { #expect(!r.title.contains("onb.pack") && !r.title.contains("pack."), "\(r.title)") }
    }
}
