// Journey 03 (M1.T10 AT-005 / AT-006; S-09; ChatGPT FL-12/FL-13): response actions, regenerate with versions,
// rate (local only), copy formats, edit (also with an image attachment) and branch in new chat. ScriptedEngine
// `regen.jsonl`: `{{v}}` numbers each play of a turn ("Answer v1:", "Answer v2:", …), so versions differ.
// Not run in the agent session (Q-015: XCUITest automation mode is blocked on this Mac); the serial UI-test run
// (M1.T27 step 8) runs it. The same flows run in-process in `ResponseActionsTests` (AntiChatUIModuleTests).
import AppKit
import XCTest

final class J03EditVersionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Helpers

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Launches on `regen.jsonl`, sends one prompt and waits for the finished reply (its ActionBar is shown).
    @MainActor private func chatWithReply(_ extra: [String] = [], prompt: String = "Tell me about the harbour town.",
                                          script: String = "regen.jsonl") -> TurnApp {
        let t = TurnApp(script: script)
        t.app.launchArguments += extra
        t.launch()
        t.send(prompt)
        XCTAssertTrue(element(t.app, "actionBar").waitForExistence(timeout: 10), "no ActionBar on the finished reply")
        return t
    }

    @MainActor private func versionLabel(_ t: TurnApp, _ id: String = "assistantVersion") -> String {
        let v = t.app.staticTexts[id]
        return v.waitForExistence(timeout: 3) ? v.displayText : ""  // the text is the AX value (Q-015 r2)
    }

    @MainActor private func regenerate(_ t: TurnApp, steering: String? = nil) {
        t.app.buttons["action.regenerate"].click()
        XCTAssertTrue(element(t.app, "regeneratePopover").waitForExistence(timeout: 2))
        if let steering {
            let field = element(t.app, "regenerate.field")
            field.click()
            field.typeText(steering)
            t.app.buttons["regenerate.send"].clickReliably()
        } else {
            t.app.buttons["regenerate.tryAgain"].clickReliably()
        }
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10), "regenerate did not finish")
        XCTAssertTrue(element(t.app, "actionBar").waitForExistence(timeout: 5))
    }

    // MARK: AT-005

    /// (1) Copy, Regenerate, 👍, 👎, ⋯ (timestamp + Branch); tooltips; Read aloud always (Basic voice until the Voice pack, M3.T04).
    @MainActor
    func testActionBar() throws {
        // Q-015 r5: regen-slow.jsonl, so the regenerated reply streams long enough to be seen streaming (below).
        let t = chatWithReply(script: "regen-slow.jsonl")
        for id in ["action.copy", "action.regenerate", "action.like", "action.dislike"] {
            let b = t.app.buttons[id]
            XCTAssertTrue(b.exists, "\(id) missing")
            XCTAssertFalse(b.displayText.isEmpty, "\(id) has no tooltip label")  // label = the tooltip text
        }
        XCTAssertTrue(t.app.buttons["action.readAloud"].exists, "Read aloud is always offered (Basic voice without the pack, M3.T04 R-281)")
        let more = element(t.app, "action.more")
        XCTAssertTrue(more.exists)
        more.click()
        XCTAssertTrue(t.app.menuItems["Branch in new chat"].waitForExistence(timeout: 2))
        let stamp = t.app.menuItems.allElementsBoundByIndex.map(\.title).first { $0.contains(":") } ?? ""
        XCTAssertFalse(stamp.isEmpty, "no timestamp line in ⋯")
        t.app.typeKey(.escape, modifierFlags: [])
        // Hidden while streaming: regenerate and look for the bar mid-stream.
        t.app.buttons["action.regenerate"].click()
        t.app.buttons["regenerate.tryAgain"].clickReliably()
        XCTAssertTrue(t.stopButton.waitForExistence(timeout: 2))
        XCTAssertFalse(element(t.app, "actionBar").exists, "ActionBar visible while streaming")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        add(XCTAttachment(screenshot: t.window.screenshot()))
        t.app.terminate()

        let voice = chatWithReply(["-FakeVoiceInstalled", "YES"])
        XCTAssertTrue(voice.app.buttons["action.readAloud"].exists, "Read aloud missing with -FakeVoiceInstalled YES")
        TurnApp.evidence("AT-005", ["case": "testActionBar", "timestamp": stamp, "readAloudWithVoice": true])
    }

    /// (2) the popover; (3) two regenerates → 3/3; ‹ → 2/3 → 1/3 with the original text; Versions lists 3 and
    /// "Use this version" on 1 restores it.
    @MainActor
    func testRegenerateVersions() throws {
        let t = chatWithReply()
        let original = t.currentText()
        XCTAssertTrue(original.hasPrefix("Answer v1:"))
        t.app.buttons["action.regenerate"].click()
        XCTAssertTrue(element(t.app, "regenerate.field").waitForExistence(timeout: 2))
        XCTAssertEqual(element(t.app, "regenerate.field").placeholderValue, "Ask to change response")
        XCTAssertTrue(t.app.buttons["regenerate.tryAgain"].exists)
        XCTAssertTrue(t.app.buttons["regenerate.thinkHarder"].exists)
        t.app.typeKey(.escape, modifierFlags: [])

        regenerate(t)
        regenerate(t, steering: "shorter please")
        XCTAssertEqual(versionLabel(t), "3 / 3")
        XCTAssertTrue(t.currentText().hasPrefix("Answer v3:"))
        // The steering text is never stored.
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message_part WHERE body LIKE '%shorter please%'"), "0")

        t.app.buttons["assistantVersion.previous"].click()
        XCTAssertTrue(t.app.staticTexts["assistantVersion"].wait(3) { $0.displayText == "2 / 3" })
        t.app.buttons["assistantVersion.previous"].click()
        XCTAssertTrue(t.app.staticTexts["assistantVersion"].wait(3) { $0.displayText == "1 / 3" })
        XCTAssertEqual(t.currentText(), original)

        // Versions viewer: 3 rows; pick 3, then 1 with "Use this version".
        element(t.app, "action.more").click()
        t.app.menuItems["Versions"].click()
        XCTAssertTrue(element(t.app, "versionsViewer").waitForExistence(timeout: 2))
        for n in 1...3 { XCTAssertTrue(element(t.app, "versionsViewer.row.\(n)").exists, "row \(n) missing") }
        XCTAssertFalse(element(t.app, "versionsViewer.row.4").exists)
        element(t.app, "versionsViewer.row.3").click()
        t.app.buttons["versionsViewer.use"].click()
        XCTAssertTrue(t.app.staticTexts["assistantVersion"].wait(3) { $0.displayText == "3 / 3" })
        element(t.app, "action.more").click()
        t.app.menuItems["Versions"].click()
        element(t.app, "versionsViewer.row.1").click()
        t.app.buttons["versionsViewer.use"].click()
        XCTAssertTrue(t.app.staticTexts["assistantVersion"].wait(3) { $0.displayText == "1 / 3" })
        XCTAssertEqual(t.currentText(), original)
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-005", ["case": "testRegenerateVersions", "versions": 3, "restored": true])
    }

    /// (4) 👍 → Liked + feedback(kind=liked); 👎 → "What went wrong?" with four options; It refused → refused row;
    /// Report a problem… → sheet with the excerpt checkbox off and Send disabled. Local only: the deny-outbound leg
    /// runs the same flow under `sandbox-exec` in the serial run (XCUITest launches the app itself, Q-015).
    @MainActor
    func testRateLocalOnly() throws {
        let t = chatWithReply()
        t.app.buttons["action.like"].click()
        XCTAssertTrue(t.app.staticTexts["likedLabel"].waitForExistence(timeout: 2))
        XCTAssertEqual(t.app.staticTexts["likedLabel"].displayText, "Liked")
        XCTAssertEqual(t.sql("SELECT kind FROM feedback"), "liked")

        t.app.buttons["action.dislike"].click()
        XCTAssertTrue(t.app.staticTexts["dislike.title"].waitForExistence(timeout: 2))
        XCTAssertEqual(t.app.staticTexts["dislike.title"].displayText, "What went wrong?")
        for id in ["dislike.tryAgain", "dislike.thinkHarder", "dislike.refused", "dislike.report"] {
            XCTAssertTrue(t.app.buttons[id].exists, "\(id) missing")
        }
        t.app.buttons["dislike.refused"].click()
        XCTAssertEqual(t.sql("SELECT group_concat(kind, ',') FROM (SELECT kind FROM feedback ORDER BY kind)"), "disliked,refused")

        t.app.buttons["action.dislike"].click()
        t.app.buttons["dislike.report"].click()
        XCTAssertTrue(element(t.app, "reportSheet").waitForExistence(timeout: 2))
        let excerpt = t.app.checkBoxes["report.includeChat"]  // M8.T09: "Include this chat's text"
        XCTAssertTrue(excerpt.exists)
        XCTAssertEqual(excerpt.value as? Int, 0, "chat-text checkbox must default off")
        XCTAssertFalse(t.app.buttons["report.github"].isEnabled, "nothing to send before \"What happened\" is filled in")
        add(XCTAttachment(screenshot: t.window.screenshot()))
        t.app.buttons["report.cancel"].click()
        TurnApp.evidence("AT-005", ["case": "testRateLocalOnly", "feedback": t.sql("SELECT group_concat(kind) FROM feedback")])
    }

    /// (5) the pasteboard after Copy: plain text = the Markdown source, plus RTF.
    @MainActor
    func testCopyFormats() throws {
        let t = chatWithReply()
        t.app.buttons["action.copy"].click()
        XCTAssertTrue(t.app.buttons["action.copy"].wait(2) { $0.displayText == "Copied" })
        let id = t.sql("SELECT id FROM message WHERE role = 'assistant' ORDER BY created_at DESC LIMIT 1")
        let source = t.sql("SELECT group_concat(body, '') FROM message_part WHERE message_id = '\(id)' AND kind = 'text'")
        let pb = NSPasteboard.general
        XCTAssertEqual(pb.string(forType: .string), source)
        XCTAssertTrue(source.contains("**three**"))
        let rtf = try XCTUnwrap(pb.data(forType: .rtf), "no RTF flavour")
        let rich = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        XCTAssertFalse(rich.string.contains("**"))
        XCTAssertNotNil(pb.string(forType: .html))
        TurnApp.evidence("AT-005", ["case": "testCopyFormats", "plainChars": source.count, "rtfBytes": rtf.count])
    }

    // MARK: AT-006

    /// (1) hover on a user message → Copy + Edit; Edit → inline editor with Cancel/Send; (2) Send → version 2 of
    /// that turn; ‹ 1/2 › returns to the original branch with its original reply.
    @MainActor
    func testEditCreatesVersion() throws {
        let t = chatWithReply()
        let original = t.currentText()
        let bubble = element(t.app, "userBubble")
        bubble.hover()
        XCTAssertTrue(t.app.buttons["userAction.copy"].waitForExistence(timeout: 2))
        XCTAssertTrue(t.app.buttons["userAction.edit"].exists)
        t.app.buttons["userAction.edit"].click()
        let editor = element(t.app, "inlineEditor")
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        XCTAssertTrue(t.app.buttons["inlineEditorCancel"].exists)
        XCTAssertTrue(t.app.buttons["inlineEditorSend"].exists)
        add(XCTAttachment(screenshot: t.window.screenshot()))
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Tell me about the lighthouse instead.")
        t.app.buttons["inlineEditorSend"].click()
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        XCTAssertEqual(versionLabel(t, "userVersion"), "2 / 2")
        XCTAssertTrue(t.currentText().hasPrefix("Answer v2:"))

        t.app.buttons["userVersion.previous"].click()
        XCTAssertTrue(t.app.staticTexts["userVersion"].wait(3) { $0.displayText == "1 / 2" })
        XCTAssertEqual(element(t.app, "userText").displayText, "Tell me about the harbour town.")
        XCTAssertEqual(t.currentText(), original)
        TurnApp.evidence("AT-006", ["case": "testEditCreatesVersion", "versions": 2])
    }

    /// The inline editor also opens on a message with an image attachment (fixture photo), shown above the field
    /// and removable; the new version keeps the photo (same blob).
    @MainActor
    func testEditWithImageAttachment() throws {
        let photo = try Self.fixturePhoto()
        let t = chatWithReply()
        t.app.terminate()
        // Attach the fixture photo to the sent user message (the M1 composer has no image intake yet, M5).
        let user = t.sql("SELECT id FROM message WHERE role = 'user' LIMIT 1")
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(t.write("""
            INSERT INTO file_blob (id, sha256, size, path, created_at, origin)
              VALUES ('blob-j03', '\(String(repeating: "f", count: 64))', 1, '\(photo)', \(now), 'upload');
            INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at)
              VALUES ('att-j03', '\(user)', 'blob-j03', '001.jpg', 'public.jpeg', \(now));
            """))
        t.launch()
        t.openMostRecentChat()
        XCTAssertTrue(element(t.app, "messageAttachment.0").waitForExistence(timeout: 5), "photo not shown on the bubble")
        element(t.app, "userBubble").hover()
        t.app.buttons["userAction.edit"].click()
        XCTAssertTrue(element(t.app, "inlineEditor").waitForExistence(timeout: 2))
        XCTAssertTrue(element(t.app, "editAttachmentRemove.0").exists, "attachment not removable in the editor")
        add(XCTAttachment(screenshot: t.window.screenshot()))
        let editor = element(t.app, "inlineEditor")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("What is in this photo?")
        t.app.buttons["inlineEditorSend"].click()
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        let edited = t.sql("SELECT id FROM message WHERE role = 'user' ORDER BY created_at DESC LIMIT 1")
        XCTAssertEqual(t.sql("SELECT blob_id FROM attachment WHERE message_id = '\(edited)'"), "blob-j03")
        TurnApp.evidence("AT-006", ["case": "testEditWithImageAttachment", "photo": photo])
    }

    /// (3) ⋯ → Branch in new chat: "Branch · <title>" with the path up to that reply; the original unchanged.
    @MainActor
    func testBranchInNewChat() throws {
        let t = chatWithReply()
        t.send("And the ferry?")
        XCTAssertTrue(t.sendButton.waitForExistence(timeout: 10))
        let source = t.sql("SELECT id FROM chat LIMIT 1")
        let before = (count: t.sql("SELECT COUNT(*) FROM message WHERE chat_id = '\(source)'"),
                      leaf: t.sql("SELECT leaf_message_id FROM chat WHERE id = '\(source)'"),
                      title: t.sql("SELECT title FROM chat WHERE id = '\(source)'"))
        // ⋯ of the first reply.
        let mores = t.app.descendants(matching: .any).matching(identifier: "action.more")
        let first = mores.element(boundBy: 0)
        element(t.app, "assistantMessage").hover()
        first.click()
        t.app.menuItems["Branch in new chat"].click()
        let branchTitle = "Branch · \(before.title.isEmpty ? "New chat" : before.title)"
        XCTAssertTrue(t.wait(10) { t.sql("SELECT COUNT(*) FROM chat") == "2" })
        let branch = t.sql("SELECT id FROM chat WHERE id != '\(source)'")
        XCTAssertEqual(t.sql("SELECT title FROM chat WHERE id = '\(branch)'"), branchTitle)
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message WHERE chat_id = '\(branch)'"), "2")
        XCTAssertEqual(t.sql("SELECT COUNT(*) FROM message WHERE chat_id = '\(source)'"), before.count)
        XCTAssertEqual(t.sql("SELECT leaf_message_id FROM chat WHERE id = '\(source)'"), before.leaf)
        XCTAssertEqual(t.sql("SELECT title FROM chat WHERE id = '\(source)'"), before.title)
        // The window shows the branch: one reply, the first answer.
        XCTAssertTrue(t.wait(5) { t.app.staticTexts.matching(identifier: "assistantText").count == 1 })
        XCTAssertTrue(t.currentText().hasPrefix("Answer v1:"))
        add(XCTAttachment(screenshot: t.window.screenshot()))
        TurnApp.evidence("AT-006", ["case": "testBranchInNewChat", "title": branchTitle])
    }

    /// `fixtures/images/photos-cc0/001.jpg` from `ANTICHAT_FIXTURES` (TEST_RUNNER_) or the repo's fixtures checkout.
    static func fixturePhoto() throws -> String {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] { roots.append(URL(fileURLWithPath: env)) }
        roots.append(TurnApp.repoRoot.appendingPathComponent("fixtures"))
        for root in roots {
            let p = root.appendingPathComponent("images/photos-cc0/001.jpg").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        throw XCTSkip("fixtures/images/photos-cc0/001.jpg not found (set ANTICHAT_FIXTURES or pull the fixtures repo)")
    }
}

extension TurnApp {
    /// Runs SQL against the app database (the app must not be running). Returns false on failure.
    func write(_ statements: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [databasePath, statements]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Polls `predicate` until it holds or `timeout` passes.
    @MainActor func wait(_ timeout: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(50_000)
        }
        return predicate()
    }
}
