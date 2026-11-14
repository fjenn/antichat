// AT-016 (R-016 AC1–AC5; M6.T13) — XCUITest. XCUITest can't start on the build Mac (Q-015): recorded `pending (Q-015)`;
// the in-process legs are AntiChatHarnessTests/{OutputPromotionTests, ArtifactPromotionTurnTests} (40/41-line threshold,
// one artifact per promoted block, Fix / Edit selection → version 2 with only the span changed, v1 kept, Outputs rows)
// and AntiChatUIModuleTests/{ArtifactsPreviewTests, ArtifactPanelModelTests, ArtifactSnapshotTests} (React counter
// increments, Mermaid / Vega SVG + PNG, broken.html → previewError → panel.fix, net-probe → 0 connections, downloads).
// Setup: ScriptedEngine `artifacts-<fixture>.jsonl` (fixtures/docs/artifacts via tools/fixtures/make-artifacts.py).
import XCTest

final class ArtifactsPanelTests: XCTestCase {
    private var turn: TurnApp!
    private var app: XCUIApplication { turn.app }

    override func setUp() { continueAfterFailure = false }

    override func tearDown() { turn?.app.terminate() }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Check 1: 40 lines stay inline, 41 promote to a card that opens the resizable panel by itself.
    @MainActor
    func testThresholdAndAutoOpen() {
        turn = TurnApp(script: "artifacts-long-code-40l.jsonl")
        turn.launch()
        turn.send("Write the helper")
        XCTAssertTrue(any("codeBlock").waitForExistence(timeout: 30))
        XCTAssertFalse(any("artifactCard").exists, "40 lines stay inline")
        app.terminate()

        turn = TurnApp(script: "artifacts-long-code-41l.jsonl")
        // The remembered width lives in the app domain: pin the start to the default (a narrowed run left 320 pt).
        turn.app.launchArguments += ["-sidePanel.width.main", "480"]
        turn.launch()
        turn.send("Write the helper")
        XCTAssertTrue(any("artifactCard").waitForExistence(timeout: 30))
        XCTAssertTrue(any("sidePanel").waitForExistence(timeout: 5), "the panel opens by itself")
        // Round 65 (f5326cb5d): the conversation keeps minChatWidth 480 pt, so the auto-opened panel is already as wide
        // as the window allows; the handle is proven by narrowing it (a drag to the right).
        let handle = any("sidePanelResize")
        let before = any("sidePanel").frame.width
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 150, dy: 0)))
        XCTAssertLessThan(any("sidePanel").frame.width, before - 100, "drag handle resizes")
    }

    /// Check 2: every preview kind renders; React's button increments.
    @MainActor
    func testPreviewsRender() {
        for name in ["page", "drawing", "flow", "chart", "counter"] {
            turn = TurnApp(script: "artifacts-\(name).jsonl")
            turn.launch()
            turn.send("Make it")
            XCTAssertTrue(any("sandboxedWebPreview").waitForExistence(timeout: 30), name)
            if name == "counter" {
                let web = app.webViews.firstMatch
                web.buttons["Add one"].clickReliably()  // r5: the web view reports its button "Not hittable" (M9.T03); a real click at its centre
                // Q-015 r5: React renders "Count: " and the number as two text nodes (two AX texts, words in AXValue).
                let count = web.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "1", "1")).firstMatch
                XCTAssertTrue(count.waitForExistence(timeout: 5), "Count: 1")
                XCTAssertTrue(web.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Count:", "Count:")).firstMatch.exists)
            }
            app.terminate()
        }
    }

    /// `name`'s turn, then a second turn whose reply is the same artifact with `from` replaced by `to`. The scripted
    /// replay repeats its last segment, and a reply identical to v1 is the same promoted artifact (same SHA-256), so
    /// Fix / Edit selection never made a version 2 without a changed reply (Q-015 r3).
    static func revisingScript(_ name: String, replacing from: String, with to: String) -> String {
        let text = (try? String(contentsOfFile: TurnApp.script(name), encoding: .utf8)) ?? ""
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.contains("\"t\": \"title\"") && !$0.contains("\"t\":\"title\"") }
        let revised = body.map { $0.replacingOccurrences(of: from, with: to) }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("revise-\(UUID().uuidString).jsonl")
        try? Data((text + "\n{\"t\":\"turn\"}\n" + revised + "\n").utf8).write(to: url)
        return url.path
    }

    /// Check 3: Copy, Download per kind, version switcher, Fix on broken.html → v2.
    @MainActor
    func testCopyDownloadAndFix() {
        turn = TurnApp(script: Self.revisingScript("artifacts-broken.jsonl", replacing: "formatSteps(open)",
                                                    with: "open + ' steps left'"))
        turn.launch()
        turn.send("Make the widget")
        XCTAssertTrue(any("panelFix").waitForExistence(timeout: 30), "previewError shows Fix")
        any("panelCopy").clickReliably()
        XCTAssertNotNil(NSPasteboard.general.string(forType: .string))
        any("panelDownload").clickReliably()
        XCTAssertTrue(any("panelDownload.html").exists && any("panelDownload.pdf").exists)
        app.typeKey(.escape, modifierFlags: [])
        any("panelFix").clickReliably()
        XCTAssertTrue(any("panelVersionPicker").waitForExistence(timeout: 30), "Fix made version 2")
    }

    /// Check 4: Edit selection → v2 with the switcher keeping v1.
    @MainActor
    func testEditSelection() {
        turn = TurnApp(script: Self.revisingScript("artifacts-long-code-60l.jsonl", replacing: "def ", with: "def  "))
        turn.launch()
        turn.send("Write the helper")
        let text = any("panelText")
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        // A word on the first line: the text view is as tall as its 60 lines, so its centre lies below the visible
        // part of the panel and a double click there selected nothing (Q-015 r3).
        text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 20)).doubleClick()
        XCTAssertTrue(any("panelEditSelection").waitForExistence(timeout: 5), "the selection offers Edit selection")  // r5: it appears after the selection settles
        any("panelEditSelection").clickReliably()
        any("editSelectionField").typeText("use get_hours\r")
        XCTAssertTrue(any("panelVersionPicker").waitForExistence(timeout: 30))
    }

    /// Check 5: Outputs lists the chat's artifacts, newest first; click → panel.
    @MainActor
    func testOutputsList() {
        turn = TurnApp(script: "artifacts-page.jsonl")
        turn.launch()
        turn.send("Make the page")
        XCTAssertTrue(any("artifactCard").waitForExistence(timeout: 30))
        app.buttons["outputsButton"].click()
        XCTAssertTrue(app.staticTexts["Launch checklist.html"].waitForExistence(timeout: 5))
    }
}
