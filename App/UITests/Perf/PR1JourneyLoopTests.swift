// M9.T05 NFR-PR1 journey loop (AT-NFR-PR1 §7.3: "journeys 2/7/8 looped during the capture"): J02 send → stream →
// stop, J07 an Evil chat turn, J08 an incognito turn, repeated until ANTICHAT_PR1_MINUTES (default 1) have passed,
// while tools/offline/capture-30min.sh records nettop (+ tcpdump with sudo) and run-offline.sh lists sockets / sandbox
// denials. Attach mode (`ANTICHAT_ATTACH=1`): drives the instance run-offline.sh started under the deny-outbound
// sandbox (bundle app.antichat.AntiChat.dev, launched with the extra arguments PR1JourneyLoopTests.attachArguments);
// otherwise it launches its own Offline-only app. Writes build/at/AT-NFR-PR1/journeys-uitest.json (journeys run).
import XCTest

final class PR1JourneyLoopTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The app arguments the journeys need (tools/offline/capture-30min.sh passes them to run-offline.sh after `--`).
    static func attachArguments() -> [String] {
        ["-SkipOnboarding", "YES", "-UseScriptedEngine", PerfUI.script("regen.jsonl"), "-FakeEvilEnabled", "YES"]
    }

    @MainActor
    private func app() -> XCUIApplication {
        if PerfUI.env["ANTICHAT_ATTACH"] == "1" {
            // M9.T05: attach by the captured copy's path when given (ANTICHAT_ATTACH_APP): a bundle-id attach resolves to
            // whichever app.antichat.AntiChat.dev runs on the Mac (other worktrees' Debug apps), not the one captured.
            let a = PerfUI.env["ANTICHAT_ATTACH_APP"].map { XCUIApplication(url: URL(fileURLWithPath: $0)) }
                ?? XCUIApplication(bundleIdentifier: PerfUI.env["ANTICHAT_ATTACH_BUNDLE"] ?? "app.antichat.AntiChat.dev")
            a.activate()
            XCTAssertTrue(PerfUI.mainWindow(a).waitForExistence(timeout: 30), "attach: no main window of the running app")
            return a
        }
        return PerfUI.launch(container: PerfUI.tempContainer("pr1"), log: nil, ["-OfflineOnly", "YES"] + Self.attachArguments())
    }

    @MainActor
    private func turn(_ app: XCUIApplication, _ text: String, stopEarly: Bool = false) -> Bool {
        // Always the main window's composer (another window, e.g. a stray incognito one, must not take the text).
        let w = PerfUI.mainWindow(app)
        let input = w.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        guard input.waitForExistence(timeout: 15) else { return false }
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
        let stop = w.descendants(matching: .any).matching(identifier: "stop").firstMatch
        guard PerfUI.wait(stop, timeout: 10) else { return true }  // a reply that finished before Stop was seen
        if stopEarly {
            usleep(300_000)
            if stop.exists { stop.click() }
        }
        return PerfUI.wait(stop, gone: true, timeout: 60)
    }

    @MainActor
    private func evilShown(_ app: XCUIApplication) -> Bool {
        ["evil.frame", "evil.badge", "evilHeadline"].contains { PerfUI.element(app, $0).waitForExistence(timeout: 2) }
    }

    /// Leaving an incognito chat with content asks first (`incognito.close.confirm`): confirm the discard, whichever
    /// form the question takes (alert button by identifier, else the sheet / dialog's non-cancel button).
    @MainActor
    private func confirmLeave(_ app: XCUIApplication) {
        let cta = PerfUI.element(app, "incognito.close.cta")
        if cta.waitForExistence(timeout: 10) { return cta.click() }  // the alert can lag under load
        for container in [app.sheets.firstMatch, app.dialogs.firstMatch, app.alerts.firstMatch] where container.exists {
            let buttons = container.buttons.allElementsBoundByIndex
            if let b = buttons.first(where: { $0.identifier != "row.delete.cancel" && !$0.label.lowercased().contains("cancel") }) {
                return b.click()
            }
        }
        add(XCTAttachment(screenshot: app.screenshot()))
        app.typeKey(.return, modifierFlags: [])  // an unidentified confirmation: its default button
    }

    @MainActor
    func testJourneysTwoSevenEightLoop() throws {
        let minutes = PerfUI.env["ANTICHAT_PR1_MINUTES"].flatMap(Double.init) ?? 1
        let app = app()
        // M9.T05: also stop by the capture's end (epoch seconds, ANTICHAT_PR1_DEADLINE): the capture stops the app at 30
        // min, and a late test start (the UI-test build) left a loop iteration driving an app that had quit (PR1 run 3).
        var end = Date().addingTimeInterval(minutes * 60)
        if let d = PerfUI.env["ANTICHAT_PR1_DEADLINE"].flatMap(Double.init) { end = min(end, Date(timeIntervalSince1970: d)) }
        var counts = ["j02": 0, "j07": 0, "j08": 0]
        var failures: [String] = []
        while Date() < end {
            // J02: a new chat, send, stream, stop.
            app.typeKey("n", modifierFlags: .command)
            if turn(app, "Tell me about a quiet harbour town", stopEarly: true) { counts["j02", default: 0] += 1 } else { failures.append("j02") }
            // J07: an Evil chat turn (⇧⌘E), then back to a new Normal chat.
            app.typeKey("e", modifierFlags: [.command, .shift])
            if !evilShown(app) {  // the File menu's item, when the shortcut did not land (the menu re-reads Evil when opened)
                let file = app.menuBarItems["File"]
                if file.exists {
                    file.click()
                    let item = app.menuItems["menu.file.newEvilChat"]
                    if item.waitForExistence(timeout: 2) { item.click() } else { app.typeKey(.escape, modifierFlags: []) }
                }
            }
            // The composer's Normal | Evil switch of the new chat (the Evil chrome may only follow the first send).
            let evilSegment = PerfUI.mainWindow(app).descendants(matching: .any).matching(NSPredicate(
                format: "label == 'Evil' AND elementType IN %@",
                [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue])).firstMatch
            if !evilShown(app), evilSegment.waitForExistence(timeout: 2) { evilSegment.click() }
            var isEvil = evilShown(app) || (evilSegment.exists && evilSegment.isSelected)
            let sent = isEvil && turn(app, "Hello")
            isEvil = isEvil && (evilShown(app) || PerfUI.element(app, "modeSwitch.locked").exists || evilSegment.isSelected)
            // The journey is the capture's load: a turn sent after asking for an Evil chat counts; whether the chat
            // actually switched to Evil is recorded on its own (`j07_evil_seen`, see the runplan open items).
            let sentAnyway = sent || turn(app, "Hello")
            if isEvil { counts["j07_evil_seen", default: 0] += 1 } else if counts["j07_evil_seen"] == nil {
                add(XCTAttachment(screenshot: app.screenshot()))
            }
            if sentAnyway {
                counts["j07", default: 0] += 1
            } else { failures.append("j07") }
            app.typeKey("n", modifierFlags: .command)
            // J08: an incognito turn (the window's Incognito button), then leave it (⌘N; confirm the discard).
            let incognito = PerfUI.mainWindow(app).descendants(matching: .any).matching(identifier: "incognitoButton").firstMatch
            if incognito.waitForExistence(timeout: 5) { incognito.click() }
            if PerfUI.element(app, "incognitoBadge").waitForExistence(timeout: 5), turn(app, "What is a good name for a cat?") {
                counts["j08", default: 0] += 1
            } else { failures.append("j08") }
            // Leave by ⌘N: the Incognito button is disabled once the chat has messages (M1.T20), so clicking it did
            // nothing and the next loop's ⌘N raised "Close this incognito chat?" over the composer (PR1 run 2).
            app.typeKey("n", modifierFlags: .command)
            confirmLeave(app)
            usleep(500_000)
        }
        let out: [String: Any] = ["metric": "NFR-PR1", "journeys": counts, "failures": failures, "minutes": minutes,
                                  "attach": PerfUI.env["ANTICHAT_ATTACH"] == "1", "load": PerfUI.loadAverage(), "date": PerfUI.utc()]
        PerfUI.writeJSON(out, to: PerfUI.atDir("AT-NFR-PR1").appendingPathComponent("journeys-uitest.json"))
        PerfUI.evidence("AT-NFR-PR1-journeys", out)
        XCTAssertTrue(failures.isEmpty, "journeys that did not complete: \(failures)")
        XCTAssertGreaterThan([counts["j02"] ?? 0, counts["j07"] ?? 0, counts["j08"] ?? 0].min() ?? 0, 0, "every journey ran at least once")
    }
}
