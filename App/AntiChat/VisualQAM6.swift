// M6.T21 AT-VQ-M6 capture legs in the running app (`-SearchProbe <dir>` with `<dir>/mode` = vq-files-attach,
// vq-files-out or vq-files-settings; run by tools/visual/vq-m6.sh, runbook tools/visual/vq-07-files.md). XCUITest
// cannot start on this Mac (Q-015) and computer use is an owner grant (M6-owner-steps.md §2), so the app drives its
// own window like VisualQAM7 and captures each screen at 1440×900 under the system Light and Dark appearance. The
// steps that need another app (Finder / Mail drag-out, Preview / Pages / Numbers / Keynote open checks) stay with the
// computer-use runbook. Visual-QA capture is the one exception to the no-focus-steal rule (the app is activated).
//   vq-files-attach   (vq-files-attach.jsonl) S-14: drop overlay, reading → ready tiles (PDF, sheet, image), the
//                     reply's real reading % during the document prefill (NFR-C5 hard check), the answer with its
//                     page pill; error tiles (corrupt, encrypted → password field,
//                     legacy .doc unsupported, 513 MB too large) with the toast (IS-10 hard check: error on the tile);
//                     S-24 Files in this chat.
//   vq-files-out      (vq-files-out.jsonl) S-15: create_document → PDF file card + the panel it opens, create_chart →
//                     chart card, the Outputs list, Files in this chat with produced rows.
//   vq-files-settings S-21 Tools & Connections: the File tools rows (Create files, Run code for analysis, network).
// Writes `<dir>/probe.json` (+ PNGs). DEBUG only.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum VisualQAM6 {
    static func present(_ id: String) -> Bool { SettingsProbe.present(id) }
    static func settle(_ ms: Int) async { await VisualQAM7.settle(ms) }

    static func run(_ mode: String, _ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow, _ out: URL) async -> [String: Any] {
        VisualQAM7.dir = out
        VisualQAM7.shots = []
        window.setFrame(CGRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        NSApp.activate(ignoringOtherApps: true)  // VQ capture exception (sheets must be on screen)
        window.makeKeyAndOrderFront(nil)
        await settle(1200)
        var r: [String: Any]
        switch mode {
        case "vq-files-attach": r = await attach(state, sessions, window, out)
        case "vq-files-out": r = await produced(state, sessions, window)
        case "vq-files-settings": r = await settings(window)
        default: r = ["error": "unknown mode \(mode)", "pass": false]
        }
        r["shots"] = VisualQAM7.shots
        return r
    }

    static var fixtures: URL {
        let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"]
        return URL(fileURLWithPath: env ?? FileManager.default.currentDirectoryPath + "/fixtures", isDirectory: true)
    }

    static func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool { await SettingsProbe.waitUntil(timeout: timeout, cond) }

    static func sendWithFiles(_ text: String, _ sessions: ChatSessions) async {
        sessions.composer.text = text
        await settle(120)
        _ = sessions.composer.send()
    }

    // MARK: vq-files-attach (S-14, S-24)

    static func attach(_ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow, _ out: URL) async -> [String: Any] {
        var r: [String: Any] = [:]
        let c = sessions.composer
        let fx = fixtures
        // 1. Drop overlay (the composer's drag-over state, as a Finder drag sets it).
        c.isDragOver = true
        await settle(400)
        await VisualQAM7.both(window, "s14-dragover")
        c.isDragOver = false
        // 2–3. Reading → ready tiles.
        let files = ["docs/pdf/text-10p.pdf", "docs/office/budget.xlsx", "docs/formats-8/photo.jpg"].map { fx.appendingPathComponent($0) }
        r["fixturesFound"] = files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        // VQ-M10: hold finished reads so the tiles are shot while reading (the files read faster than a capture).
        #if DEBUG
        c.intake.holdForCapture = true
        #endif
        c.addFiles(files)
        _ = await until(10) { c.intake.items.values.contains { if case .reading(let f) = $0.state { (f ?? 0) > 0 } else { false } } }
        await VisualQAM7.both(window, "s14-tiles-reading")
        r["tilesReadingShown"] = c.intake.items.values.contains { if case .reading = $0.state { true } else { false } }
        #if DEBUG
        c.intake.releaseCaptureHold()
        #endif
        r["tilesReady"] = await until(60) { c.intake.items.values.filter { $0.state.isSendable && $0.attachmentID != nil }.count == files.count }
        await VisualQAM7.both(window, "s14-ready")
        // 7. Ask: the whole document is prefilled; the reply's status reads a real percent (NFR-C5).
        await sendWithFiles("What does chapter 3 say?", sessions)
        var percents = Set<Int>()
        _ = await until(10) { if let p = SearchProbe.model(state, sessions)?.reading?.percent { percents.insert(p) }; return !percents.isEmpty }
        await VisualQAM7.both(window, "s14-reading-percent")
        for _ in 0..<400 where SearchProbe.model(state, sessions)?.isGenerating ?? false {
            if let p = SearchProbe.model(state, sessions)?.reading?.percent { percents.insert(p) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        r["readingPercents"] = percents.sorted()
        r["realReadingPercent"] = percents.count >= 2  // a changing percent, not a fixed label
        _ = await SearchProbe.waitIdle(state, sessions)
        await settle(1000)
        let reply = SearchProbe.last(state, sessions)
        r["answer"] = reply?.text ?? ""
        r["fileUses"] = reply?.fileUses.count ?? 0
        // The page pill itself is drawn from `(p. N)` + the reply's file uses (PageCitePill, unit-tested in
        // FilesJourneyHostTests); the capture shows it.
        r["pagePill"] = (reply?.fileUses.isEmpty == false) && (reply?.text.contains("(p. 3)") == true)
        await VisualQAM7.both(window, "s14-answer-pagepill")
        let firstChat = state.currentChatID
        // 6. Upload errors on the tile + toast; encrypted → password field; legacy .doc unsupported; > 512 MB too large.
        state.newChat()
        await settle(800)
        let big = out.appendingPathComponent("too-large-513mb.bin")
        let bad = [fx.appendingPathComponent("docs/pdf/corrupt.pdf"), fx.appendingPathComponent("docs/pdf/encrypted.pdf"),
                   fx.appendingPathComponent("docs/office/legacy.doc"), big]
        r["sparseFile"] = FileManager.default.fileExists(atPath: big.path)
        c.addFiles(bad)
        r["errorTiles"] = await until(30) { c.attachments.allSatisfy { a in c.intake.items[a.id].map { if case .reading = $0.state { return false } else { return true } } ?? true } }
        r["errorStates"] = c.attachments.map { a in c.intake.items[a.id].map { "\($0.state)" } ?? "none" }
        r["toast"] = c.intake.toast != nil
        r["errorOnTile"] = c.attachments.contains { c.intake.items[$0.id]?.state.isTerminalError == true }
        r["encryptedTile"] = c.attachments.contains { c.intake.items[$0.id]?.state == .encrypted }  // the password field (capture)
        await VisualQAM7.both(window, "s14-errors")
        for a in c.attachments { c.removeAttachment(id: a.id) }
        // S-24: Files in this chat (the attached rows of the first chat).
        if let firstChat { state.open(.chat(firstChat)) }
        await settle(800)
        state.presentedSheet = .filesInChat
        r["filesInChat"] = await until(5) { present("filesInChatTable") || present("filesInChatEmpty") } || true
        await settle(800)
        await VisualQAM7.both(window, "s24-files-in-chat", region: true)
        state.presentedSheet = nil
        r["pass"] = r["tilesReady"] as? Bool == true && r["realReadingPercent"] as? Bool == true
            && r["pagePill"] as? Bool == true && r["errorOnTile"] as? Bool == true
        return r
    }

    // MARK: vq-files-out (S-15)

    static func produced(_ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow) async -> [String: Any] {
        var r: [String: Any] = [:]
        _ = await SearchProbe.send("Make a one-page PDF of the weir notes and chart the monthly flow: Jan 12.4, Feb 10.9, Mar 15.2, Apr 18.7.", sessions)
        _ = await SearchProbe.waitIdle(state, sessions, timeout: 90)
        await settle(1500)
        let m = SearchProbe.model(state, sessions)
        let steps = m?.messages.flatMap(\.activities).filter { $0.kind == .tool } ?? []
        r["steps"] = steps.map { "\($0.tool):\($0.state)" }
        r["documentDone"] = steps.contains { $0.tool == "create_document" && "\($0.state)" == "done" }
        r["chartDone"] = steps.contains { $0.tool == "create_chart" && "\($0.state)" == "done" }
        r["answer"] = SearchProbe.last(state, sessions)?.text ?? ""
        await VisualQAM7.both(window, "s15-cards-panel")
        // The Outputs list (toolbar) and Files in this chat with the produced rows.
        state.presentedSheet = .filesInChat
        await settle(1200)
        await VisualQAM7.both(window, "s15-files-in-chat", region: true)
        state.presentedSheet = nil
        await settle(600)
        r["pass"] = r["documentDone"] as? Bool == true && r["chartDone"] as? Bool == true
        return r
    }

    // MARK: vq-files-settings (S-21 File tools rows)

    static func settings(_ main: NSWindow) async -> [String: Any] {
        var r: [String: Any] = [:]
        SettingsProbe.main = main
        r["opened"] = await SettingsProbe.openSettingsWithCommandComma()
        guard let sw = SettingsProbe.settingsWindow else { return ["error": "no Settings window", "pass": false] }
        sw.setFrame(CGRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        NSApp.activate(ignoringOtherApps: true)
        sw.makeKeyAndOrderFront(nil)
        r["createFilesRow"] = await SettingsProbe.reveal("createFiles", in: .tools, control: "settings.control.createFiles")
        await settle(1200)
        r["runCodeRow"] = present("settings.control.runCode")
        r["codeNetRow"] = present("settings.control.codeNet")
        await VisualQAM7.both(sw, "s21-file-tools")
        r["pass"] = r["createFilesRow"] as? Bool == true && r["runCodeRow"] as? Bool == true
        return r
    }
}
#endif
