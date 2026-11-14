// Shared helpers for the M1.T06 turn journeys (J02 send/stream/stop, J13 crash recovery): launch with a
// ScriptedEngine script and a known container, drive the main window's composer (M1.T08 ComposerView, W2 wiring:
// `composerText`, `voiceOrSend`, `stop`), and read the app database with /usr/bin/sqlite3 (read-only).
import Foundation
import XCTest

struct TurnApp {
    let app: XCUIApplication
    let container: URL

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `fixtures/scripts/<name>` (fixtures repo) or the staging copy `tools/fixtures/scripts/<name>`.
    static func script(_ name: String) -> String {
        if name.hasPrefix("/") { return name }  // a script the test wrote (Q-015 r3)
        let f = repoRoot.appendingPathComponent("fixtures/scripts/\(name)")
        if FileManager.default.fileExists(atPath: f.path) { return f.path }
        return repoRoot.appendingPathComponent("tools/fixtures/scripts/\(name)").path
    }

    init(script name: String, container: URL? = nil) {
        self.container = container ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("antichat-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication.foreground()
        app.launchArguments = [
            "-ANTICHAT_DEV_CONTAINER", self.container.path, "-UseScriptedEngine", Self.script(name),
            "-ApplePersistenceIgnoreState", "YES",
        ]
    }

    @MainActor func launch() {
        app.launch()
        app.activate()
        XCTAssertTrue(window.waitForExistence(timeout: 15), "no AntiChat window")
    }

    @MainActor var window: XCUIElement { app.windows.firstMatch }
    @MainActor var input: XCUIElement { app.descendants(matching: .any).matching(identifier: "composerText").firstMatch }
    @MainActor var sendButton: XCUIElement { app.buttons["voiceOrSend"] }
    @MainActor var stopButton: XCUIElement { app.buttons["stop"] }
    @MainActor var assistantText: XCUIElement { app.staticTexts.matching(identifier: "assistantText").element(boundBy: lastAssistantIndex) }
    @MainActor var notice: XCUIElement { app.descendants(matching: .any).matching(identifier: "interruptedNotice").firstMatch }

    @MainActor private var lastAssistantIndex: Int {
        max(0, app.staticTexts.matching(identifier: "assistantText").count - 1)
    }

    @MainActor func send(_ text: String) {
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        // Q-015 r4: right after a send the composer re-lays out (a queued bubble slides in above it); a click in that
        // moment found no hit point and failed the test. Wait until the field can take the click.
        _ = input.wait(3) { $0.isHittable }
        // Q-015 r5: with follow-ups queued above it the field still reported no hit point ("Unable to find hit point
        // for ScrollView composerScroll"); a real click at its centre lands (as MediaUIApp.send).
        input.clickReliably()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    /// Opens the most recent chat from the sidebar (the window launches on a new chat, M1.T07).
    @MainActor func openMostRecentChat() {
        let row = window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'chatRow.' AND identifier != 'chatRow.streaming'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no chat row in the sidebar")
        row.click()
    }

    /// Waits until the last assistant text has at least `chars` characters; returns it.
    @MainActor @discardableResult
    func waitForText(atLeast chars: Int, timeout: TimeInterval = 15) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let t = currentText()
            if t.count >= chars { return t }
            usleep(20_000)
        }
        XCTFail("assistant text did not reach \(chars) characters")
        return currentText()
    }

    @MainActor func currentText() -> String {
        let q = app.staticTexts.matching(identifier: "assistantText")
        guard q.count > 0 else { return "" }
        return q.element(boundBy: q.count - 1).displayText
    }

    // MARK: Database (read-only)

    var databasePath: String { container.appendingPathComponent("antichat.sqlite").path }

    func sql(_ query: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-noheader", databasePath, query]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var s = String(decoding: data, as: UTF8.self)
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    /// Text and status of the newest assistant message on disk.
    func lastAssistantRow() -> (text: String, status: String, error: String) {
        let id = sql("SELECT id FROM message WHERE role = 'assistant' ORDER BY created_at DESC, id DESC LIMIT 1")
        let text = sql("SELECT COALESCE(group_concat(body, ''), '') FROM (SELECT body FROM message_part WHERE message_id = '\(id)' AND kind = 'text' ORDER BY idx)")
        let status = sql("SELECT status FROM message WHERE id = '\(id)'")
        let err = sql("SELECT COALESCE(error_code, '') FROM message WHERE id = '\(id)'")
        return (text, status, err)
    }

    /// One evidence line for the AT log (`tools/at/run.sh` captures the xcodebuild output).
    static func evidence(_ id: String, _ fields: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        print("AT-EVIDENCE \(id) \(String(decoding: data, as: UTF8.self))")
    }
}

extension XCUIElement {
    /// Polls `predicate` until it holds or `timeout` passes. While the element is absent the predicate is not asked
    /// (Q-015 r4: reading a gone element's label failed the test with "No matches found" instead of returning false).
    @MainActor func wait(_ timeout: TimeInterval, until predicate: (XCUIElement) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, predicate(self) { return true }
            usleep(10_000)
        }
        return exists && predicate(self)
    }
}
