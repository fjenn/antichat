// M1.T18 AT-009 (R-009 all three criteria) through the real window. ScriptedEngine `long-context.jsonl`
// (~600-token replies, " context" × 600) with `-FakeContextWindow 4096`, so six turns cross 85 %.
//   xcodebuild test -workspace AntiChat.xcworkspace -scheme AntiChat-UITests -destination 'platform=macOS,arch=arm64' \
//     -only-testing:AntiChatUITests/ContextTests
// Not run in the agent session (Q-015: XCUITest automation mode is blocked on this Mac); the serial UI-test run
// (M1.T27 step 8) runs it. The same flows run in-process under `-ContextProbe <dir>` (App/AntiChat/ContextProbe.swift,
// tools/at/at-009-probe.sh → build/at/AT-009/probe.json) and in CompactionTests / OversizeGuardTests.
import AppKit
import XCTest

final class ContextTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func launch(_ extra: [String]) -> TurnApp {
        let t = TurnApp(script: "long-context.jsonl")
        t.app.launchArguments += ["-FakeContextWindow", "4096"] + extra
        t.launch()
        return t
    }

    @MainActor private func turn(_ t: TurnApp, _ text: String) {
        t.send(text)
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 5))
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 30), "reply did not finish")
    }

    @MainActor private func percent(_ t: TurnApp) -> Int? {
        let e = element(t.app, "contextUsage")
        guard e.waitForExistence(timeout: 3) else { return nil }
        return Int(e.value as? String ?? "") ?? Int(e.displayText.prefix { $0.isNumber })
    }

    /// (1) Hidden by default.
    @MainActor func testIndicatorHiddenByDefault() {
        let t = launch([])
        turn(t, "Hello there")
        XCTAssertFalse(element(t.app, "contextUsage").waitForExistence(timeout: 2))
    }

    /// (1) With `showContextUsage` on, the percentage rises as messages are added; (2) crossing 85 % summarises
    /// older turns, "Earlier messages summarised" appears once and expands to the summarised turns.
    @MainActor func testUsageRisesThenSummarisedNoticeOnce() {
        let t = launch(["-showContextUsage", "YES"])
        var last = -1
        for i in 1...6 {
            turn(t, "Message number \(i)")
            if element(t.app, "summaryNotice").exists { break }
            let p = percent(t) ?? -1
            XCTAssertGreaterThan(p, last, "usage did not rise after turn \(i)")
            last = p
        }
        let notice = element(t.app, "summaryNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "no summary notice")
        XCTAssertEqual(t.app.descendants(matching: .any).matching(identifier: "summaryNotice").count, 1)
        XCTAssertTrue(notice.displayText.contains("Earlier messages summarised"))
        notice.click()
        XCTAssertTrue(element(t.app, "summarisedTurns").waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(t.app.descendants(matching: .any).matching(identifier: "summarisedTurn").count, 2)
        // One more turn: still one notice.
        turn(t, "Message number 7")
        // The notice sits above the summarised turns, now scrolled out of the lazy transcript (only rows on screen are
        // in the accessibility tree): back to the top before counting (Q-015 r3).
        let transcript = t.app.scrollViews.matching(identifier: "transcript").firstMatch
        for _ in 0..<6 where !element(t.app, "summaryNotice").exists { transcript.scroll(byDeltaX: 0, deltaY: 1500) }
        XCTAssertEqual(t.app.descendants(matching: .any).matching(identifier: "summaryNotice").count, 1)
    }

    /// (3) A prompt larger than the window (pasted as text with the plain-text composer, so no paste card) is
    /// refused before any request: no new reply row, `ctx.tooLarge` shown, the text stays in the composer.
    @MainActor func testOversizePromptRefused() {
        let t = launch(["-plainTextComposer", "YES"])
        turn(t, "First")
        let replies = t.app.staticTexts.matching(identifier: "assistantText").count
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 700)  // ≈ 18,900 chars ≈ 4,700 tokens
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(big, forType: .string)
        t.input.click()
        t.input.typeKey("v", modifierFlags: .command)
        t.input.typeKey(.return, modifierFlags: [])
        let notice = element(t.app, "composerNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 3), "no ctx.tooLarge notice")
        XCTAssertTrue(notice.displayText.contains("too long"))
        XCTAssertEqual(t.app.staticTexts.matching(identifier: "assistantText").count, replies, "a request was sent")
        // A paste over ComposerRules.pasteCardThreshold (10,000) becomes a paste card in every composer mode (Q-015 r3:
        // the plain-text composer too), so "the text stays" = the card is still there, or the text is in the field.
        let card = element(t.app, "pasteCard")
        let kept = card.exists ? card.label.contains("18,900") : ((t.input.value as? String)?.count ?? 0) > 10_000
        XCTAssertTrue(kept, "the text left the composer")
    }
}
