// AT-008 (M1.T09) XCUITest form: streams `mixed-3k.jsonl` with the S1 stand-in (`-RendererCPUScale 0.25`) and checks
// the rendered reply (code block header: language, wrap, Copy; table "Copy as CSV"; ⌘⇧; puts the last code block on
// the pasteboard). The NFR-U5 numbers (cadence, hitches, layout jumps) come from the display-rate recording and the
// in-app RendererProbe (`tools/at/at-008-probe.sh`), which is also the runnable fallback while XCUITest is blocked on
// this Mac (Q-015).
import AppKit
import XCTest

final class RendererStreamingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testMixedReplyRendersWhileStreamingAndWhenDone() throws {
        let t = TurnApp(script: "mixed-3k.jsonl")
        t.app.launchArguments += ["-RendererCPUScale", "0.25"]
        t.launch()
        t.send("Walk me through a market day in numbers, with code and a table.")
        // While streaming: text arrives and the stop button is shown.
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 10))
        t.waitForText(atLeast: 2_000, timeout: 30)
        // Done: the whole reply, with a code block header and a table.
        t.waitForText(atLeast: 13_000, timeout: 60)
        let any = t.app.descendants(matching: .any)
        XCTAssertTrue(any.matching(identifier: "codeLanguage").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(any.matching(identifier: "codeWrap").firstMatch.exists)
        XCTAssertTrue(any.matching(identifier: "codeCopy").firstMatch.exists)
        XCTAssertTrue(any.matching(identifier: "tableCopyCSV").firstMatch.exists)

        // ⌘⇧; copies the last code block of the visible chat.
        NSPasteboard.general.clearContents()
        t.window.typeKey(";", modifierFlags: [.command, .shift])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, NSPasteboard.general.string(forType: .string) == nil { usleep(50_000) }
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.hasPrefix("from dataclasses import dataclass"), "pasteboard: \(copied.prefix(80))")
        XCTAssertTrue(copied.hasSuffix("print(f\"{name:>10}: {total:8.2f}\")"))
    }
}
