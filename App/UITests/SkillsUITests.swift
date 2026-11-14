// M7.T12 AT-082 (R-082 AC1–AC5; S-21 §8): Settings → Skills (list, review sheet before install for folder / .zip /
// .skill / SKILL.md, delete, export), "+" → Skills › per-chat switches, "/" explicit use with the
// "Using skill <name> ▸" activity line and its "Turn off for this chat", Offline only, "needs Web search (off)", and
// the starter skills. `-SkillImportFile <path>` stands in for the open panel, `-SkillExportDir <dir>` for the save
// panel (XCUITest cannot drive NSOpenPanel/NSSavePanel reliably). Committed, not run on this Mac (Q-015: XCUITest
// cannot enable automation mode); the same behaviour runs in-process in ImportTests, ExportRoundTripTests,
// ZipSlipTests (AntiChatToolsTests), SkillsTurnTests (AntiChatHarnessTests) and SkillsModelTests (AntiChatUIModuleTests).
// M7.T13 adds testCreateByChatInstallCard (in-process: CreateSkillTests, SkillCreateTurnTests).
import XCTest

final class SkillsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    static var repo: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }

    static var examples: URL { repo.appendingPathComponent("fixtures/skills/agentskills-examples@2c5958e") }

    @MainActor private func launch(_ extra: [String] = [], container: URL? = nil) -> XCUIApplication {
        let dir = container ?? FileManager.default.temporaryDirectory.appendingPathComponent("skills-ui-\(UUID().uuidString)")
        let app = XCUIApplication.foreground()
        app.launchArguments += ["-ANTICHAT_DEV_CONTAINER", dir.path, "-SkipOnboarding", "YES", "-ApplePersistenceIgnoreState", "YES",
                                "-UseScriptedEngine", "basic"] + extra
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func openSkillsSettings(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let nav = element(app, "settings.nav.skills")
        XCTAssertTrue(nav.waitForExistence(timeout: 10))
        nav.click()
    }

    /// c1: each Add form shows the review sheet with the full SKILL.md text before anything is installed.
    @MainActor func testAddFolderZipSkillMdWithReview() throws {
        let forms = Self.repo.appendingPathComponent("fixtures/skills/forms")
        let folder = Self.examples.appendingPathComponent("brand-guidelines")
        let zip = forms.appendingPathComponent("brand-guidelines.zip")
        let skill = forms.appendingPathComponent("brand-guidelines.skill")
        let md = forms.appendingPathComponent("single/SKILL.md")
        let full = try String(contentsOf: md, encoding: .utf8)
        for source in [folder, zip, skill, md] {
            let app = launch(["-SkillImportFile", source.path])
            openSkillsSettings(app)
            element(app, "skills.add").click()
            let sheet = element(app, "skillReview")
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), source.lastPathComponent)
            XCTAssertEqual(element(app, "skillReview.text").value as? String, full, "full text before install")
            XCTAssertFalse(element(app, "skills.row.brand-guidelines").exists, "nothing installed before Install")
            element(app, "skillReview.install").click()
            XCTAssertTrue(element(app, "skills.row.brand-guidelines").waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    /// c1: rows show name, description, source and a switch; Export writes a zip; Delete removes the row.
    @MainActor func testDeleteExport() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("skills-ui-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = launch(["-SkillExportDir", out.path])
        openSkillsSettings(app)
        let row = element(app, "skills.row.email-polish")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "skills.toggle.email-polish").exists)
        XCTAssertTrue(element(app, "skills.source.email-polish").exists)
        element(app, "skills.menu.email-polish").click()
        element(app, "skills.export.email-polish").click()
        let zip = out.appendingPathComponent("email-polish.zip")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: zip.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        element(app, "skills.menu.email-polish").click()
        element(app, "skills.delete.email-polish").click()
        element(app, "skills.delete.confirm").click()
        XCTAssertFalse(row.waitForExistence(timeout: 2))
    }

    /// c2: "/" → the skill → a chip; the reply shows "Using skill email-polish ▸"; ▸ → "Turn off for this chat".
    @MainActor func testSlashExplicitAndActivityLineTurnOff() throws {
        let app = launch()
        let field = element(app, "composerText")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("/email")
        let row = element(app, "menuRow.skill:email-polish")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(element(app, "toolChip.skill:email-polish").waitForExistence(timeout: 2))
        field.typeText("please polish: hi i want refund\r")
        let line = element(app, "activitySkill-email-polish")
        XCTAssertTrue(line.waitForExistence(timeout: 20))
        XCTAssertTrue((line.displayText).contains("Using skill email-polish"))
        line.click()
        element(app, "activitySkill.turnOff").clickReliably()
        XCTAssertFalse(element(app, "toolChip.skill:email-polish").exists)
    }

    /// c3: a per-chat switch in "+" → Skills › does not change Settings; Apply to every chat is off by default.
    @MainActor func testPerChatToggleAndApplyAll() throws {
        let app = launch()
        element(app, "composerAdd").click()
        element(app, "addRow.skills").click()
        let toggle = element(app, "skillsMenu.meeting-notes")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        openSkillsSettings(app)
        XCTAssertEqual(element(app, "skills.toggle.meeting-notes").value as? Int, 1, "global switch unchanged")
        // Apply to every chat is off: the row shows no "Apply to every chat" caption, and the More menu offers the
        // switch (SwiftUI menu items carry no identifiers; Q-015 r2).
        let row = element(app, "skills.row.meeting-notes")
        XCTAssertFalse(row.staticTexts["Apply to every chat"].exists, "Apply to every chat is off")
        element(app, "skills.menu.meeting-notes").click()
        XCTAssertTrue(app.menuItems["Apply to every chat"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }

    /// c4: Offline only — a skill turn completes; a skill with `allowed-tools: web_search` says "needs Web search (off)".
    @MainActor func testOfflineAndNeedsWebSearchOff() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("skills-ui-web-\(UUID().uuidString)/web-helper")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "---\nname: web-helper\ndescription: Looks things up.\nallowed-tools: web_search\n---\nSearch first."
            .write(to: tmp.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let app = launch(["-OfflineOnly", "YES", "-SkillImportFile", tmp.path])
        openSkillsSettings(app)
        element(app, "skills.add").click()
        element(app, "skillReview.install").click()
        let needs = element(app, "skills.needs.web-helper")
        XCTAssertTrue(needs.waitForExistence(timeout: 5))
        XCTAssertTrue(needs.displayText.contains("needs Web search"))
        app.typeKey("w", modifierFlags: .command)
        let field = element(app, "composerText")
        field.click()
        field.typeText("/email")
        element(app, "menuRow.skill:email-polish").click()
        field.typeText("tidy this up\r")
        XCTAssertTrue(element(app, "activitySkill-email-polish").waitForExistence(timeout: 20))
    }

    /// c5: 4–6 starter skills, editable (meeting-notes and email-polish on).
    @MainActor func testStarterSkillsPresentEditable() throws {
        let app = launch()
        openSkillsSettings(app)
        for name in ["meeting-notes", "email-polish", "study-flashcards", "trip-planner", "recipe-scaler"] {
            XCTAssertTrue(element(app, "skills.row.\(name)").waitForExistence(timeout: 5), name)
        }
        XCTAssertEqual(element(app, "skills.toggle.meeting-notes").value as? Int, 1)
        XCTAssertEqual(element(app, "skills.toggle.trip-planner").value as? Int, 0)
        element(app, "skills.menu.meeting-notes").click()  // the row's More menu (menu items have no identifiers)
        XCTAssertTrue(app.menuItems["Show in Finder"].waitForExistence(timeout: 3), "Show in Finder (edit the SKILL.md)")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// M7.T13 AT-264 (ScriptedEngine variant; R-264 AC1): a `create_skill` call shows the SkillInstallCard with the
    /// generated SKILL.md; [Install] installs it (on for this chat) and the `skills.created` toast appears.
    @MainActor func testCreateByChatInstallCard() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("create-skill-\(UUID().uuidString).jsonl")
        let args = ##"{\"name\":\"weekly-status-email\",\"description\":\"Turns notes into a weekly status email. Use when the user pastes weekly notes.\",\"body\":\"# Weekly status\\n\\n1. Group notes.\\n2. Write the email.\"}"##
        try """
            {"t":"toolCallDone","id":"call_1","name":"create_skill","args":"\(args)","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Your skill is ready to install.","delayMs":1}
            """.write(to: script, atomically: true, encoding: .utf8)
        // Q-015 r5: a tool-capable chat slot. A fresh container's default is the chat-only starter, which is offered no
        // tools (D-023 a), so the scripted create_skill call never ran and the reply stayed empty (as MediaUIApp does).
        let app = launch(["-UseScriptedEngine", script.path, "-ChatModel", "chat-9b-q4"])
        let composer = element(app, "composerText")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("Build me a skill that turns my notes into a weekly status email\r")
        XCTAssertTrue(element(app, "skillInstallCard").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "skillInstallCard.markdown").exists, "the generated SKILL.md is shown")
        XCTAssertFalse(element(app, "skillInstallCard.installed").exists, "nothing installed before Install")
        element(app, "skillInstallCard.install").clickReliably()
        XCTAssertTrue(element(app, "skillInstallCard.installed").waitForExistence(timeout: 5))
        openSkillsSettings(app)
        XCTAssertTrue(element(app, "skills.row.weekly-status-email").waitForExistence(timeout: 5))
    }
}
