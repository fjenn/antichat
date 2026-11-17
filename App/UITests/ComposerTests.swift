// AT-002 (R-002, all seven criteria; docs/prd/M1.md M1.T08). Runs against the composer-only debug host
// (`-ComposerHarness <fixture>`, M1.md convention 10) until the lead wires the composer into MainWindow (W2 merge);
// a send "generates" for 1.5 s or until Stop. Settings toggles use the Defaults launch arguments until M1.T22
// (convention 9). Every test attaches a screenshot of its end state.
import AppKit
import XCTest

final class ComposerTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if let app {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    @MainActor
    private func launch(_ fixture: String = "empty", _ extra: [String] = []) {
        app = XCUIApplication.antichat(["-ComposerHarness", fixture] + extra)
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 15), "composer host did not appear")
    }

    @MainActor private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// A harness probe shows "id=value" (ComposerHarness); the text reaches XCUITest as the label or the value.
    @MainActor private func probe(_ id: String) -> String {
        let t = element(id).displayText
        guard let eq = t.firstIndex(of: "=") else { return t }
        return String(t[t.index(after: eq)...])
    }

    @MainActor private func waitProbe(_ id: String, _ expected: String, timeout: TimeInterval = 5) {
        let ok = element(id).wait(timeout) { _ in probe(id) == expected }
        XCTAssertTrue(ok, "\(id) stayed \(probe(id)), expected \(expected)")
    }

    @MainActor private var text: XCUIElement { app.textViews["composerText"] }
    @MainActor private var scroll: XCUIElement { app.scrollViews["composerScroll"] }
    @MainActor private var send: XCUIElement { app.buttons["voiceOrSend"] }
    @MainActor private var stop: XCUIElement { app.buttons["stop"] }

    @MainActor private func focusText() {
        text.click()
    }

    @MainActor private func wait(_ predicate: String, _ object: Any, timeout: TimeInterval = 5) {
        let e = expectation(for: NSPredicate(format: predicate), evaluatedWith: object)
        wait(for: [e], timeout: timeout)
    }

    // MARK: (1) Elements

    @MainActor func testLeg1_ControlsLeftAndRightModeSwitchHiddenWithoutEvil() {
        launch()
        let add = app.buttons["composerAdd"], think = app.buttons["thinkHarder"], mic = app.buttons["composer.mic"]
        for e in [add, think, mic, send] { XCTAssertTrue(e.exists) }
        XCTAssertLessThan(add.frame.maxX, scroll.frame.minX + 1, "+ is left of the text")
        for e in [think, mic, send] { XCTAssertGreaterThan(e.frame.minX, scroll.frame.maxX - 1, "right cluster") }
        XCTAssertLessThan(think.frame.minX, mic.frame.minX)
        XCTAssertLessThan(mic.frame.minX, send.frame.minX)
        XCTAssertFalse(element("modeSwitch").exists, "modeSwitch absent while Evil is disabled")
    }

    @MainActor func testLeg1_ModeSwitchPresentWithFakeEvil() {
        launch("empty", ["-FakeEvilEnabled", "YES"])
        let mode = element("modeSwitch")
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        // ux/simplify: the picker sits in the window toolbar, above and left of the composer's controls.
        XCTAssertLessThan(mode.frame.maxY, app.buttons["composer.mic"].frame.minY)
        XCTAssertLessThan(mode.frame.minX, app.buttons["composer.mic"].frame.minX)
    }

    // MARK: (2) Growth, scrolling, bottom row

    @MainActor func testLeg2_GrowsToExactlyTwelveLinesThenScrollsAndControlsMoveDown() {
        launch()
        focusText()
        text.typeText("line 1")
        var heights: [CGFloat] = [scroll.frame.height]
        XCTAssertEqual(send.frame.midY, scroll.frame.midY, accuracy: 4, "one line: controls beside the text")
        for n in 2...15 {
            app.typeKey(.return, modifierFlags: .shift)
            text.typeText("line \(n)")
            waitProbe("harnessLineCount", "\(n)", timeout: 3)
            heights.append(scroll.frame.height)
        }
        let lineHeight = heights[1] - heights[0]
        XCTAssertEqual(lineHeight, 24, accuracy: 0.5, "one type.body line box per line")
        for n in 1..<12 {
            XCTAssertEqual(heights[n] - heights[n - 1], lineHeight, accuracy: 0.5, "line \(n + 1) grows by one line")
        }
        XCTAssertEqual(heights[11], heights[0] + 11 * lineHeight, accuracy: 0.5)
        for n in 12..<15 { XCTAssertEqual(heights[n], heights[11], accuracy: 0.5, "stops at 12 lines") }
        XCTAssertEqual(probe("harnessLineCount"), "15")
        XCTAssertGreaterThan(text.frame.height, scroll.frame.height + lineHeight, "the 15-line text scrolls inside")
        XCTAssertGreaterThanOrEqual(send.frame.minY, scroll.frame.maxY - 1, "multi-line: controls on the bottom row")
        XCTAssertNotEqual(probe("harnessSendCount"), "1")
    }

    @MainActor func testLeg2_WrappedTextMovesControlsBelowTheLastLine() {
        launch()
        focusText()
        text.typeText(String(repeating: "wrap ", count: 60))
        XCTAssertGreaterThanOrEqual(send.frame.minY, scroll.frame.maxY - 1, "wrapped text: bottom row")
        XCTAssertGreaterThanOrEqual(app.buttons["composerAdd"].frame.minY, scroll.frame.maxY - 1)
    }

    // MARK: (3) Send / Stop

    @MainActor func testLeg3_SendDisabledWhenEmptyStopWhileGeneratingBackOnDone() {
        launch()
        XCTAssertFalse(send.isEnabled, "empty: disabled")
        // M9.T08 (c9f4afcc2): empty = a disabled Send; the spoken conversation has its own composer button.
        XCTAssertTrue(send.displayText.hasPrefix("Send"), "empty composer shows a disabled Send, got \(send.displayText)")
        focusText()
        text.typeText("hi")
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.displayText.hasPrefix("Send"), send.displayText)
        let sendFrame = send.frame
        send.click()
        XCTAssertTrue(stop.exists, "Stop right after the send")
        XCTAssertEqual(stop.frame, sendFrame, "same position")
        XCTAssertEqual(stop.displayText, "Stop generating")  // a11y.stop (M9.T01)
        XCTAssertEqual(probe("harnessSendCount"), "1")
        XCTAssertEqual(probe("harnessLastSent"), "hi")
        wait("exists == false", stop, timeout: 5)
        XCTAssertTrue(send.displayText.hasPrefix("Send"), "done + empty → disabled Send again")
        XCTAssertFalse(send.isEnabled, "done + empty → disabled Send again")
        text.typeText("again")
        XCTAssertTrue(send.displayText.hasPrefix("Send"))
        // Stop path.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(stop.exists)
        stop.click()
        wait("exists == false", stop, timeout: 3)
        XCTAssertEqual(probe("harnessSendCount"), "2")
    }

    // MARK: (4) Keys

    @MainActor func testLeg4_ReturnSendsShiftReturnInsertsNewlineByDefault() {
        launch()
        focusText()
        text.typeText("a")
        app.typeKey(.return, modifierFlags: .shift)
        text.typeText("b")
        XCTAssertEqual(probe("harnessSendCount"), "0")
        XCTAssertEqual(text.value as? String, "a\nb")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(probe("harnessSendCount"), "1")
        XCTAssertEqual(probe("harnessLastSent"), "a\nb")
    }

    @MainActor func testLeg4_CommandEnterSetting() {
        launch("empty", ["-sendWithCommandEnter", "YES"])
        focusText()
        text.typeText("a")
        app.typeKey(.return, modifierFlags: [])
        text.typeText("b")
        XCTAssertEqual(probe("harnessSendCount"), "0", "Return inserts a newline")
        XCTAssertEqual(text.value as? String, "a\nb")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertEqual(probe("harnessSendCount"), "1", "⌘Return sends")
        XCTAssertEqual(probe("harnessLastSent"), "a\nb")
    }

    // MARK: (5) Rich text

    @MainActor func testLeg5_RichTextByDefaultBoldRunRendersBold() {
        launch()
        focusText()
        text.typeText("make **this** bold")
        waitProbe("harnessBoldRuns", "1")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(probe("harnessLastSent"), "make **this** bold", "payload is Markdown")
    }

    @MainActor func testLeg5_PlainTextComposerIsUnstyled() {
        launch("empty", ["-plainTextComposer", "YES"])
        focusText()
        text.typeText("make **this** bold")
        XCTAssertEqual(probe("harnessBoldRuns"), "0")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(probe("harnessLastSent"), "make **this** bold", "payload is Markdown in plain mode too")
    }

    // MARK: (6) Paste card

    @MainActor private func paste(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        focusText()
        app.typeKey("v", modifierFlags: .command)
    }

    @MainActor func testLeg6_PasteOver10000BecomesACardThatOpensAndIsRemovable() {
        launch()
        paste(String(repeating: "x", count: 10_001))
        let card = app.buttons["pasteCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "10,001 characters → card")
        XCTAssertEqual((text.value as? String) ?? "", "", "not inserted as text")
        XCTAssertTrue(card.displayText.contains("10,001"), card.displayText)
        XCTAssertGreaterThanOrEqual(send.frame.minY, card.frame.maxY, "tray above, controls on the bottom row")
        card.click()
        let viewer = element("pasteViewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "card opens the viewer")
        app.buttons["pasteViewerDone"].click()
        wait("exists == false", viewer)
        app.buttons["pasteCardRemove"].click()
        wait("exists == false", card)
        XCTAssertTrue(send.displayText.hasPrefix("Send"), "empty again → disabled Send (M9.T08)")
        XCTAssertFalse(send.isEnabled, "empty again → disabled Send (M9.T08)")
    }

    @MainActor func testLeg6_PasteOfExactly10000StaysInline() {
        launch()
        paste(String(repeating: "y", count: 10_000))
        XCTAssertFalse(app.buttons["pasteCard"].waitForExistence(timeout: 2))
        XCTAssertEqual((text.value as? String)?.count, 10_000)
    }

    @MainActor func testLeg6_CardIsSentAsAnAttachment() {
        launch()
        paste(String(repeating: "z", count: 10_001))
        XCTAssertTrue(app.buttons["pasteCard"].waitForExistence(timeout: 5))
        text.typeText("summarise")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(probe("harnessLastAttachments"), "1")
        XCTAssertEqual(probe("harnessLastSent"), "summarise")
        XCTAssertFalse(app.buttons["pasteCard"].exists)
    }

    // MARK: (7) Status row

    @MainActor func testLeg7_StatusRowShowsProjectAndModeChips() {
        launch("project+mode")
        let project = element("statusProject"), mode = element("statusMode")
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.exists)
        XCTAssertGreaterThan(project.frame.minY, scroll.frame.maxY, "status row is under the composer")
    }

    @MainActor func testLeg7_NoChipsWithoutFixture() {
        launch()
        XCTAssertFalse(element("statusProject").exists)
        XCTAssertFalse(element("statusMode").exists)
    }

    // MARK: Mic install card (step 1; voice is M3)

    @MainActor func testMicShowsTheVoiceInstallCard() {
        // Q-015 r5: the composer harness has no voice session, so it draws no conversation button at all; the app does
        // (ChatSessions wires the composer's voice), so this leg runs in the app.
        app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                        "-FakePackState", "voice=absent"])
        app.launch()
        XCTAssertTrue(element("composer").waitForExistence(timeout: 15))
        // Since M3.T04 (R-281) dictation can work without the pack (Basic voice, when the on-device SpeechTranscriber is
        // installed), so the mic may ask for the microphone instead; the voice conversation always needs the pack: its
        // button shows the install card (Q-015 r3).
        app.descendants(matching: .any).matching(identifier: "composer.voice").firstMatch.click()
        XCTAssertTrue(element("micInstallCard").waitForExistence(timeout: 5))
    }
}
