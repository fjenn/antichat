// Journey 4 (test-strategy §4.1; M6.T21 step 4), in-process leg: the XCUITest App/UITests/FilesJourneyTests.swift is
// pending Q-015. Attach a PDF → the tile reads and ends ready (`tile.pages`) → ask → while the whole document is
// prefilled the reply's status reads `status.reading` with a real percent (NFR-C5) → the answer cites a page and the
// citation becomes a page pill (R-270 AC4) → an upload that cannot be read ends as an error tile + toast (IS-10).
//   make test-unit FILTER=FilesJourneyHostTests
import AntiChatDesign
import AppKit
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct FilesJourneyHostTests {
    static let script = """
    {"t":"prefill","ms":600,"steps":6}
    {"t":"textDelta","v":"Chapter 3 is about the almanac weir (p. 3).","delayMs":1}
    {"t":"done","reason":"stop"}
    """

    private func until(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<1500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
        return cond()
    }

    @Test func journey4AttachReadAskCiteAndAnUploadError() async throws {
        _ = NSApplication.shared  // the reply's VoiceOver announcement posts to NSApp
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: Self.script)),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        let composer = sessions.composer
        // 1. Attach: the tile reads, then is ready with its page count.
        composer.addFiles([FilesIntakeHostTests.fixtures.appendingPathComponent("docs/pdf/text-10p.pdf")])
        let id = try #require(composer.attachments.first?.id)
        #expect(await until { composer.intake.readyCount == 1 })
        let item = try #require(composer.intake.items[id])
        #expect(AttachmentTileView.readyDetail(item) == CopyText(CopyKey("tile.pages"), ["count": "10"]).string)
        // 2. Ask: the whole document goes in; during its prefill the status shows the real reading percent.
        sessions.stagedFileIDs = composer.intake.readyFileIDs(composer.attachments)
        state.send("What does chapter 3 say?", hasFiles: true, reduceMotion: true, turn: sessions.slots.startTurn)
        sessions.stagedFileIDs = []
        let chatID = try #require(state.currentChatID)
        let m = sessions.model(for: chatID)
        var percents: [Int] = []
        for _ in 0..<1500 where m.isGenerating || m.messages.count < 2 {
            if let r = m.reading { percents.append(r.percent) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!percents.isEmpty, "status.reading was shown during the document prefill")
        #expect(Set(percents).count >= 2, "a real, changing percent, not a fixed label: \(Set(percents).sorted())")
        let status = StatusLine.reading(file: "text-10p.pdf", percent: 50)
        #expect(CopyText(CopyKey(try #require(status.copyKey)), status.copyArgs).string.contains("50"))
        // 3. The answer cites page 3 of the attached PDF: a page pill linking to that attachment and page.
        let reply = try #require(m.messages.last)
        #expect(!reply.fileUses.isEmpty, "the reply records the document it used")
        let linked = PageCitePill.linkify(reply.text, uses: reply.fileUses)
        #expect(linked.contains("\(PageCitePill.scheme)://"), "\(linked)")
        // Round 65: the pill replaces "(p. 3)" (no parentheses around it); the link names page 3 of that attachment.
        #expect(linked.contains("://\(reply.fileUses[0].attachmentID)/3"), "\(linked)")
        #expect(!linked.contains("(["), "\(linked)")
        // 4. An upload that cannot be read: error on the tile itself and a toast.
        composer.addFiles([FilesIntakeHostTests.fixtures.appendingPathComponent("docs/pdf/corrupt.pdf")])
        let bad = try #require(composer.attachments.last?.id)
        #expect(await until { composer.intake.items[bad]?.state.isTerminalError == true })
        #expect(composer.intake.toast?.message == CopyText(CopyKey("upload.failed.reason"), ["file": "corrupt.pdf"]))
    }
}
