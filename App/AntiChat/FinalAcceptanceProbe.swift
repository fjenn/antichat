// M10.T09 in-process final-acceptance probe (AT-FA-04/07/09/10/11). XCUITest cannot start on this Mac (Q-015) and a
// clean Tart VM has no UI automation either, so — like the other probes — the app drives its own main window with the
// REAL installed models (no scripted engine): the composer (ComposerModel.send → TurnController → the XPC helper), the
// window's routes (WindowState) and the anchors the UI shows (UIProbeRegistry probe ids). The guest step scripts
// (tools/install-test/steps/fa-*.sh) write `<dir>/leg`, launch the app with `-FinalAcceptanceProbe <dir>`, do the
// outside part (network off, kill -9, relaunch) and check the database with sqlite3. Legs:
//   chat          AT-FA-04: a new chat, one prompt, the streamed answer; records the sidebar network state
//                 (PathStatus offline → `net.offline`, Offline only → `net.offlineOnly`) and the model slot.
//   evil          AT-FA-07: Evil off → the 18+ consent is refused without the adult box → enabled with it (the S-24
//                 sheet's Continue) → ⇧⌘E new Evil chat → frame + text badge → a lawful prompt answered on the Evil
//                 slot → the mode switch is locked once the chat has messages.
//   import        AT-FA-09: ImportCoordinator (the Import sheet's own path after Choose File) on `<dir>/import-file`
//                 → summary; the sidebar shows the chats tagged Imported; one imported chat opens with branches.
//   crash-stream  AT-FA-10 a: a long reply streams; a draft is typed in the composer; `<dir>/streaming.json` tells the
//                 step script to `kill -9` the app (the probe never ends this launch itself).
//   crash-check   AT-FA-10 b: relaunch after the kill: the chat reopens, the partial reply is "Response interrupted."
//                 with Retry, the draft is back, the crash prompt (Crash reports = Ask) is up and nothing was sent;
//                 Retry then answers.
//   engine-kill   AT-FA-10 c: a long reply streams → `<dir>/streaming.json`; the step script kills the helper
//                 (`<dir>/killed` = epoch s) → the S-25 `engine.restarted` notice → Retry → the first new token
//                 (NFR-S4 ≤ 5 s from the notice).
//   image         AT-FA-06 (host): a picture from the real Photo models through the gate; % progress + AI mark.
//   idle          AT-FA-10 b: a launch that only waits (the step script crashes it with SIGSEGV for a real report).
//   relaunch      AT-FA-11: an idle launch: what the window shows (sidebar total, the reopened chat); the step script
//                 compares the canonical database dump and the settings before and after.
// Writes `<dir>/probe.json` (`pass` + per-check fields, captures beside it) and quits (crash-stream excepted).
// DEBUG only (`-FinalAcceptanceProbe <dir>`).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatPlatform
import AntiChatStorage
import AntiChatUI
import AppKit

@MainActor
enum FinalAcceptanceProbe {
    private static var started = false
    /// A reply on the VM's paravirtual GPU (or CPU) can be slow: correctness only, never a speed bar here.
    static let replyTimeout: Double = 900

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        let leg = ((try? String(contentsOf: dir.appendingPathComponent("leg"), encoding: .utf8)) ?? "chat")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        log("start leg \(leg) → \(out)")
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await SettingsProbe.settle(2000)
            var result: [String: Any] = ["leg": leg, "slot": sessions.environment.slot().key]
            switch leg {
            case "chat": await chat(state, sessions, dir, &result)
            case "evil": await evil(state, sessions, dir, &result)
            case "import": await importExport(state, sessions, dir, &result)
            case "crash-stream", "engine-kill": await streamThenWait(state, sessions, dir, leg: leg, &result)
            case "crash-check": await crashCheck(state, sessions, dir, &result)
            case "relaunch": await relaunch(state, sessions, dir, &result)
            case "image": await image(state, sessions, dir, &result)
            case "idle":  // a launch the step script crashes (SIGSEGV) for the crash prompt; quits after 10 min otherwise
                try? await Task.sleep(for: .seconds(600))
                result["pass"] = true
            default: result["error"] = "unknown leg"; result["pass"] = false
            }
            write(result, dir)
            log("done leg \(leg) pass=\(result["pass"] as? Bool ?? false)")
            NSApp.terminate(nil)
            // A quit that something holds (an open sheet, a running job's guard) must not hang the suite.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { log("quit held; exiting"); exit(0) }
        }
    }

    // MARK: Helpers

    static func log(_ s: String) { FileHandle.standardError.write(Data("FinalAcceptanceProbe: \(s)\n".utf8)) }

    static func write(_ obj: [String: Any], _ dir: URL, name: String = "probe.json") {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The window's offscreen capture (PaletteProbe.capture); skipped when the window is not there yet.
    static func snap(_ state: WindowState, _ name: String, _ dir: URL) {
        guard let w = state.window ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            log("no window for \(name)")
            return
        }
        PaletteProbe.window = w
        PaletteProbe.capture(name, dir)
    }

    static func current(_ state: WindowState, _ sessions: ChatSessions) -> ConversationModel? {
        state.currentChatID.map(sessions.model(for:))
    }

    /// The shown chat's last reply is done (finished, interrupted or failed).
    static func replyDone(_ m: ConversationModel?) -> Bool {
        guard let m, let last = m.messages.last, last.role == .assistant else { return false }
        return !m.isGenerating && last.status != .pending && last.status != .streaming
    }

    /// Sends `text` in the shown chat and waits for the reply; returns its fields.
    static func ask(_ text: String, _ state: WindowState, _ sessions: ChatSessions) async -> [String: Any] {
        sessions.composer.text = text
        let start = ContinuousClock.now
        guard sessions.composer.send() else { return ["sent": false] }
        var out: [String: Any] = ["sent": true]
        let first = await PaletteProbe.waitUntil(timeout: replyTimeout) {
            guard let m = current(state, sessions), let id = m.messages.last?.id, m.messages.last?.role == .assistant
            else { return false }
            return !m.receivedText(of: id).isEmpty || replyDone(m)
        }
        out["firstTokenS"] = first ?? NSNull()
        out["finished"] = await SettingsProbe.waitUntil(timeout: replyTimeout) { replyDone(current(state, sessions)) }
        out["totalS"] = PaletteProbe.seconds(ContinuousClock.now - start)
        if let m = current(state, sessions), let last = m.messages.last {
            out["chatID"] = m.chatID
            out["status"] = last.status.rawValue
            out["errorCode"] = last.errorCode ?? NSNull()
            out["text"] = String(last.text.prefix(600))
        }
        return out
    }

    static func ok(_ r: [String: Any]) -> Bool {
        r["finished"] as? Bool == true && r["status"] as? String == MessageStatus.done.rawValue
            && !((r["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func newChat(_ state: WindowState) async {
        state.newRegularChat()
        await SettingsProbe.settle(800)
    }

    // MARK: Legs

    /// AT-FA-04 (and the plain chat any leg needs).
    static func chat(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, _ r: inout [String: Any]) async {
        await newChat(state)
        let reply = await ask("In one short sentence: what is the capital of France?", state, sessions)
        r["reply"] = reply
        r["pathOffline"] = PathStatus.shared.isOffline
        r["offlineOnly"] = NetworkPolicyStore.shared.offlineOnly
        r["indicator"] = NetworkPolicyStore.shared.offlineOnly ? "net.offlineOnly"
            : PathStatus.shared.isOffline ? "net.offline" : "net.onlineOn"
        r["indicatorShown"] = SettingsProbe.present("networkIndicator")
        snap(state, "chat.png", dir)
        r["pass"] = ok(reply)
    }

    /// AT-FA-07, journey 7.
    static func evil(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, _ r: inout [String: Any]) async {
        guard let evil = EvilModeModel.shared else { r["error"] = "no EvilModeModel"; r["pass"] = false; return }
        evil.disable()
        r["offAfterDisable"] = !evil.isOn
        r["switchHiddenWhenOff"] = !evil.showsSwitch
        // The S-24 sheet's Continue stays disabled without the adult box: the manager refuses it too.
        r["refusedWithoutAdultBox"] = (try? evil.enable(adultSelfDeclared: false)) == nil && !evil.isOn
        evil.requestEnable()  // Settings › Evil Mode toggle
        if evil.showEnableSheet { try? evil.enable(adultSelfDeclared: true) }  // the sheet: 18+ ticked → Continue
        r["sheetShownForConsent"] = evil.needsConsent == false
        r["enabled"] = evil.isOn && evil.showsSwitch
        // ⇧⌘E, as the File menu item does (it exists while the switch shows).
        if let w = state.window {
            BackgroundRun.makeKeyAndOrderFront(w)
            SettingsProbe.key("E", code: 14, flags: [.command, .shift], in: w)
            await SettingsProbe.settle(800)
        }
        if state.shownMode != .evil { state.newEvilChat() }
        // The composer takes the new chat's mode from its view (`onChange(of: newChatMode)`); when the window is not
        // on screen (a background run with no display) that view update may not come, so the probe then moves the
        // switch the way the ModeSwitch does (its binding sets composer.mode, then modeChanged).
        var via = "shortcut"
        if !(await SettingsProbe.waitUntil(timeout: 3) { sessions.composer.mode == .evil }) {
            via = "switch"
            sessions.composer.mode = .evil
            sessions.modeChanged(.evil)
        }
        r["composerModeVia"] = via
        r["newEvilChat"] = await SettingsProbe.waitUntil(timeout: 5) { state.shownMode == .evil && sessions.composer.mode == .evil }
        r["evilSlot"] = sessions.environment.evilSlot()?.key ?? NSNull()
        let reply = await ask("Name three classic cocktails made with gin, one line each.", state, sessions)
        r["reply"] = reply
        _ = await SettingsProbe.waitUntil(timeout: 5) { SettingsProbe.present("evil.frame") }
        r["frameShown"] = SettingsProbe.present("evil.frame")
        r["badgeShown"] = SettingsProbe.present("evil.badge")
        r["modeLocked"] = sessions.composer.modeLocked
        r["sidebarEvilRow"] = state.sidebar.contains { $0.id == (reply["chatID"] as? String) && $0.isEvil }
        snap(state, "evil-chat.png", dir)
        r["pass"] = ok(reply) && r["refusedWithoutAdultBox"] as? Bool == true && r["enabled"] as? Bool == true
            && r["newEvilChat"] as? Bool == true && r["frameShown"] as? Bool == true && r["badgeShown"] as? Bool == true
            && r["modeLocked"] as? Bool == true && r["sidebarEvilRow"] as? Bool == true
    }

    /// AT-FA-09.
    static func importExport(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, _ r: inout [String: Any]) async {
        let path = ((try? String(contentsOf: dir.appendingPathComponent("import-file"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let before = state.sidebar.filter(\.imported).count
        let c = ImportCoordinator(database: sessions.environment.database)
        var summary: ImportSummary?
        var failure: String?
        for await e in c.start(URL(fileURLWithPath: path)) {
            switch e {
            case .finished(let s): summary = s
            case .failed(let key): failure = key
            default: break
            }
            if summary != nil || failure != nil { break }
        }
        r["failed"] = failure ?? NSNull()
        if let s = summary {
            r["summary"] = ["format": s.format.map { "\($0)" } ?? "", "chats": s.chats, "messages": s.messages,
                            "images": s.images, "skipped": s.skipped, "kept": s.kept, "missingMedia": s.missingMedia]
        }
        let n = summary?.chats ?? 0
        let shown = await SettingsProbe.waitUntil(timeout: 10) { state.sidebar.filter(\.imported).count >= before + min(n, state.sidebarLimit) }
        r["sidebarImported"] = state.sidebar.filter(\.imported).count
        r["sidebarShowsImported"] = shown
        // Open the imported chat with the most versions (branches) and read what the conversation shows.
        var branched = 0
        for id in summary?.chatIDs ?? [] {
            state.open(.chat(id))
            await SettingsProbe.settle(300)
            let m = sessions.model(for: id)
            branched = max(branched, m.messages.map(\.versionCount).max() ?? 0)
            if branched > 1 { break }
        }
        r["maxVersionsShown"] = branched
        snap(state, "imported-chat.png", dir)
        r["pass"] = failure == nil && n > 0 && shown && branched > 1
    }

    /// AT-FA-10 a / c: stream a long reply, tell the step script, then wait for the kill (crash-stream) or the
    /// engine.restarted notice + Retry (engine-kill).
    static func streamThenWait(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, leg: String,
                               _ r: inout [String: Any]) async {
        await newChat(state)
        // A long reply in the chat itself: a story prompt made the T0 model call create_document (a file, not a
        // streamed reply), so the prompt asks for plain counting, which every model streams as text.
        sessions.composer.text = "Answer here in the chat, no files or tools: count from one to three hundred in words, separated by commas."
        guard sessions.composer.send() else { r["error"] = "send refused"; r["pass"] = false; return }
        let streaming = await PaletteProbe.waitUntil(timeout: replyTimeout) {
            guard let m = current(state, sessions), let id = m.messages.last?.id else { return false }
            // A reasoning model thinks before it answers: either stream counts as "streaming".
            return m.receivedText(of: id).count + (m.liveReply(for: id)?.reasoning.count ?? 0) > 200
        } != nil
        guard let m = current(state, sessions), let replyID = m.messages.last?.id, streaming else {
            r["error"] = "no streaming reply"; r["pass"] = false; return
        }
        let draft = "draft kept across the crash"
        if leg == "crash-stream" {
            for ch in draft { sessions.composer.text.append(ch); await SettingsProbe.settle(20) }
            await SettingsProbe.settle(1500)  // DraftStore's autosave (≤ 1 s after the last keystroke)
        }
        write(["chatID": m.chatID, "replyID": replyID, "chars": m.receivedText(of: replyID).count, "draft": draft],
              dir, name: "streaming.json")
        log("streaming \(m.chatID)")
        guard leg == "engine-kill" else {
            // The step script kills this process; never reached unless it does not.
            try? await Task.sleep(for: .seconds(600))
            r["error"] = "not killed"; r["pass"] = false
            return
        }
        let noticeAt = await PaletteProbe.waitUntil(timeout: 120) {
            m.messages.last(where: { $0.id == replyID })?.errorCode == AntiChatError.Code.engineRestarted.rawValue
        }
        let killed = (try? String(contentsOf: dir.appendingPathComponent("killed"), encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        r["engineRestartedErrorCode"] = noticeAt != nil
        _ = await SettingsProbe.waitUntil(timeout: 5) { SettingsProbe.present("engineRestartedNotice") }
        r["noticeShown"] = SettingsProbe.present("engineRestartedNotice")
        r["retryShown"] = SettingsProbe.present("interruptedRetry")
        if let killed { r["killToNoticeS"] = Date().timeIntervalSince1970 - killed }
        snap(state, "engine-restarted.png", dir)
        let t0 = ContinuousClock.now
        m.retry(replyID)
        let token = await PaletteProbe.waitUntil(timeout: replyTimeout) {
            guard let last = m.messages.last, last.role == .assistant else { return false }
            return !m.receivedText(of: last.id).isEmpty || !(m.liveReply(for: last.id)?.reasoning.isEmpty ?? true)
        }
        r["retryToFirstTokenS"] = token.map { _ in PaletteProbe.seconds(ContinuousClock.now - t0) } ?? NSNull()
        _ = await SettingsProbe.waitUntil(timeout: replyTimeout) { replyDone(m) }
        r["retryStatus"] = m.messages.last?.status.rawValue ?? ""
        r["pass"] = noticeAt != nil && r["noticeShown"] as? Bool == true && token != nil
    }

    /// AT-FA-10 b: the launch after `kill -9`.
    static func crashCheck(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, _ r: inout [String: Any]) async {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("streaming.json")),
              let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let chatID = s["chatID"] as? String, let replyID = s["replyID"] as? String else {
            r["error"] = "no streaming.json"; r["pass"] = false; return
        }
        // The crash prompt is decided at the first window's appearance (MainWindow.onAppear).
        // The window's sheet state is the prompt (MainWindow presents `.crashPrompt` as its sheet); whether the sheet's
        // anchor is laid out on screen is recorded separately (a background window may not lay it out).
        r["crashPromptShown"] = await SettingsProbe.waitUntil(timeout: 20) { state.presentedSheet == .crashPrompt }
        r["crashPromptAnchor"] = SettingsProbe.present("crashPrompt")
        r["crashReportMode"] = UserDefaults.antichat.string(forKey: "crashReportMode") ?? "ask (default)"
        snap(state, "crash-prompt.png", dir)
        // Leave the prompt unanswered (nothing is sent without a tap) and look at the chat behind it.
        let reopened = state.currentChatID == chatID
        r["reopenedChat"] = reopened
        // Who reopened it: the app's own store (LastShownChatStore) or macOS window restoration.
        r["lastShownStore"] = LastShownChatStore.shared.launchSummary
        r["reopenedByStore"] = LastShownChatStore.shared.reopened.contains(chatID)
        if !reopened { state.open(.chat(chatID)); await SettingsProbe.settle(800) }
        let m = sessions.model(for: chatID)
        let reply = m.messages.first { $0.id == replyID }
        r["replyStatus"] = reply?.status.rawValue ?? ""
        r["partialChars"] = reply?.text.count ?? 0
        r["retryShown"] = await SettingsProbe.waitUntil(timeout: 5) { SettingsProbe.present("interruptedRetry") }
        let draft = s["draft"] as? String ?? ""
        r["draftRestored"] = await SettingsProbe.waitUntil(timeout: 5) { sessions.composer.text == draft }
        r["composerText"] = sessions.composer.text
        snap(state, "interrupted.png", dir)
        // Retry answers again.
        if let reply {
            m.retry(reply.id)
            r["retryFinished"] = await SettingsProbe.waitUntil(timeout: replyTimeout) { replyDone(m) }
            r["retryStatus"] = m.messages.last?.status.rawValue ?? ""
        }
        r["pass"] = r["crashPromptShown"] as? Bool == true && reply?.status == .interrupted && (reply?.text.count ?? 0) > 0
            && r["retryShown"] as? Bool == true && r["draftRestored"] as? Bool == true
            && r["retryStatus"] as? String == MessageStatus.done.rawValue
    }

    /// AT-FA-11: an idle relaunch; the window's view of the history.
    static func relaunch(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, _ r: inout [String: Any]) async {
        _ = await SettingsProbe.waitUntil(timeout: 10) { !state.sidebar.isEmpty }
        r["sidebarTotal"] = state.sidebar.count  // the rows the sidebar shows (sidebarTotal is the paging count)
        r["sidebarImported"] = state.sidebar.filter(\.imported).count
        r["sidebarEvil"] = state.sidebar.filter(\.isEvil).count
        r["shownChat"] = state.currentChatID ?? NSNull()
        r["evilOn"] = EvilModeModel.shared?.isOn ?? false
        snap(state, "relaunch.png", dir)
        r["pass"] = !state.sidebar.isEmpty
    }

    /// AT-FA-06 (image half): "Draw me …" → the chat turn's create_image call (the step script's turn script: the
    /// real chat model's tool choice is not what is tested) → the REAL Photo models in the helper, every output
    /// through the MediaOutputGate → the picture in the chat. Records the job's progress values as the menu bar /
    /// card show them, the picture file and its AI-generated mark (XMP DigitalSourceType trainedAlgorithmicMedia).
    static func image(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL, _ r: inout [String: Any]) async {
        await newChat(state)
        sessions.composer.text = "Draw me a lighthouse at dusk"
        guard sessions.composer.send() else { r["error"] = "send refused"; r["pass"] = false; return }
        var progress: [Double] = []
        let start = ContinuousClock.now
        // `<dir>/expect` = `missing` (AT-FA-08 b): the detectors are absent, so the job must be refused with the repair
        // card and no picture; otherwise a picture is expected.
        let expectMissing = ((try? String(contentsOf: dir.appendingPathComponent("expect"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "missing"
        let done = await SettingsProbe.waitUntil(timeout: expectMissing ? 600 : 1800) {
            for j in JobActivity.shared.jobs where progress.last != j.progress { progress.append(j.progress) }
            if SettingsProbe.present("safety.missing") || SettingsProbe.present("safety.missing.repair") { return true }
            return current(state, sessions)?.debugLatestImage() != nil && JobActivity.shared.jobs.isEmpty
        }
        r["seconds"] = PaletteProbe.seconds(ContinuousClock.now - start)
        r["progress"] = progress
        r["turn"] = await current(state, sessions)?.debugTurnState() ?? ""
        let img = current(state, sessions)?.debugLatestImage()
        r["imagePath"] = img?.path ?? NSNull()
        var marked = false
        if let p = img?.path, let d = FileManager.default.contents(atPath: p) {
            marked = d.range(of: Data("trainedAlgorithmicMedia".utf8)) != nil
            r["imageBytes"] = d.count
        }
        r["aiMark"] = marked
        await SettingsProbe.settle(1500)
        snap(state, "image-done.png", dir)
        let realProgress = Set(progress.filter { $0 > 0 && $0 < 1 }).count >= 2
        r["realProgress"] = realProgress
        let missingShown = SettingsProbe.present("safety.missing") || SettingsProbe.present("safety.missing.repair")
        r["safetyMissingShown"] = missingShown
        r["expect"] = expectMissing ? "missing" : "picture"
        r["pass"] = expectMissing ? (missingShown && img == nil) : (done && img != nil && marked && realProgress)
    }
}
#endif
