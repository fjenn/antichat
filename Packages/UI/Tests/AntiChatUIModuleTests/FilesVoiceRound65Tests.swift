// VQ-M10 round 65 (S-14, S-15, S-16): the failure toast names every unreadable file, a reading tile never shows 100 %,
// page citations carry their range / file for the pill, the side panel collapses the sidebar when the chat would be
// squeezed (and gives it back), and the voice orb's meter follows the input level.
//   make test-unit FILTER=FilesVoiceRound65Tests
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct FilesVoiceRound65Tests {
    @Test func failureToastNamesEveryFile() {
        #expect(IntakeTray.failedToast(["a.pdf"]) == CopyText(CopyKey("upload.failed.reason"), ["file": "a.pdf"]))
        let three = IntakeTray.failedToast(["a.pdf", "b.doc", "c.bin"])
        #expect(three.key == CopyKey("upload.failed.many"))
        #expect(three.string.contains("a.pdf") && three.string.contains("b.doc") && three.string.contains("c.bin"), "\(three.string)")
        #expect(three.string.contains("3"))
        let five = IntakeTray.failedToast(["a", "b", "c", "d", "e"]).string
        #expect(five.contains(CopyText(CopyKey("upload.failed.more"), ["count": "2"]).string), "\(five)")
    }

    @Test func readingTileNeverShowsAHundred() {
        #expect(AttachmentTileView.shownPercent(1) == 99)
        #expect(AttachmentTileView.shownPercent(0.456) == 45)
        #expect(AttachmentTileView.shownPercent(nil) == 0)
        #expect(abs(AttachmentIntake.extractionShare(1) - 0.9) < 1e-9)
        #expect(abs(AttachmentIntake.extractionShare(0) - 0.3) < 1e-9)
    }

    @Test func pagePillLinkCarriesRangeAndName() throws {
        let uses = [MessageProvenance.FileUse(attachmentID: "att", mode: ExcerptPolicy.whole.rawValue, pages: [],
                                              name: "Weir notes (v2).pdf", pageCount: 10, pdf: true)]
        let text = PageCitePill.linkify("Chapter 3 is about the weir (p. 3). See also (pp. 4–5).", uses: uses)
        #expect(!text.contains("(["), "the pill replaces the parentheses: \(text)")
        #expect(text.contains("weir [p. 3](antichat-page://att/3?name="), "\(text)")
        let links = try NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).flatMap { URL(string: String(text[$0])) } }
        #expect(links.count == 2, "\(text)")
        let first = try #require(links.first.flatMap(PageCitePill.pill))
        #expect(first.label == CopyText(CopyKey("files.pageCite"), ["page": "3"]).string)
        #expect(first.name == "Weir notes (v2).pdf")
        #expect(PageCitePill.target(links[1])?.page == 4)
        #expect(PageCitePill.pill(links[1])?.label == CopyText(CopyKey("files.pageCite"), ["page": "4–5"]).string)
    }

    private func state() throws -> WindowState {
        let env = ChatEnvironment(
            database: try AppDatabase.inMemory(),
            engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok","delayMs":1}"#)),
            slot: { .scripted("inline") })
        return WindowState(service: ChatListService(environment: env), seed: 1)
    }

    @Test func panelCollapsesTheSidebarWhenTheChatWouldBeSqueezed() throws {
        let s = try state()
        s.windowWidthChanged(1440)
        s.sidePanelChanged(open: true, panelWidth: 480)  // 1440 − 260 − 480 = 700: room enough
        #expect(s.columnVisibility != .detailOnly)
        s.sidePanelChanged(open: false, panelWidth: 480)
        s.sidePanelChanged(open: true, panelWidth: 766)  // 414 pt left: the sidebar makes room
        #expect(s.columnVisibility == .detailOnly)
        s.sidePanelChanged(open: false, panelWidth: 766)
        #expect(s.columnVisibility != .detailOnly, "closing the panel gives the sidebar back")
        // A sidebar the user hid stays hidden when the panel closes.
        s.toggleSidebar()
        s.sidePanelChanged(open: true, panelWidth: 766)
        s.sidePanelChanged(open: false, panelWidth: 766)
        #expect(s.columnVisibility == .detailOnly)
    }

    @Test func orbMeterFollowsTheLevel() {
        let quiet = VoiceOrb.meter(VoiceOrb.levelFraction(-60))
        let loud = VoiceOrb.meter(VoiceOrb.levelFraction(-15))
        #expect(quiet.allSatisfy { abs($0 - 0.12) < 0.001 }, "dots in silence")
        #expect(zip(quiet, loud).allSatisfy { $0 < $1 })
        #expect(loud.max() ?? 0 <= 0.5)
    }
}
