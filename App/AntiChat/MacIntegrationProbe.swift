// M8.T12–T14 in-process probe (AT-108, AT-042, AT-105, AT-106, AT-109). XCUITest is blocked on this Mac (Q-015), so —
// like TurnProbe / MenusProbe — the app drives itself and records what happened. `<dir>/mode` picks the legs:
//   notifications  (AT-108) `-NotificationSpy` + `-FakePermission notifications=notDetermined`: nothing asked at
//                  launch; the first answer (the app runs in the background, so it is unfocused) shows the explainer
//                  banner, [Allow notifications] → the request → 1 `answer` request with the chat title, thread and
//                  message ids; Always / Never / Responses off / a sound; a download finishing; a click on the
//                  recorded userInfo opens the chat at that message and flashes it.
//   denied         (AT-108 AC2) `notifications=denied`: no request; Settings › General shows the banner, its button
//                  records the Notifications pane URL (opened-urls.txt, nothing opened).
//   video          (AT-042) a `video`-kind job through the generic job queue (scripted media path): progress goes on
//                  after switching chats; the Dock badge while it runs; the last window closing keeps the app; its end
//                  posts one `video` request; ⌘Q during a second job asks Wait / Cancel video and quit, Wait holds
//                  the quit (`.terminateLater`) and the app quits by itself after the job — the script checks that.
//   menubar        (AT-105) the item is in the menu bar by default; its menu (as AppKit builds it on open) is New
//                  Chat, Quick Panel (⌥Space), Start Voice (disabled with the reason without the Voice pack), Open,
//                  Quit; a download at 42 % adds "Photo 42%" and a video job a "Video …" row, with the busy icon;
//                  each item acts; turning the setting off removes the item; Quit AntiChat quits (script checks).
//   quickpanel     (AT-106) the panel exists hidden after launch; opens floating, non-activating, on all Spaces, with
//                  its field first responder; Return streams the reply in the 640×480 panel; Esc while streaming hides
//                  it and the answer goes on; Esc collapses then hides; ⌘O hands the same conversation to the main
//                  window, which finishes the reply; recorder: another combo / Off; 20 in-process open times.
//   jit            (AT-109) `-FakePermission microphone,location,notifications=notDetermined`: nothing asked at launch;
//                  the composer's mic → the explainer sheet → Continue → the request (step log: explained before
//                  requested); Settings › Tools › location switch → its explainer → Continue → the request.
//   jit-denied     (AT-109 AC2) everything denied: the mic shows the denied popover (no request), the location row
//                  its notice with [Open System Settings]; each kind's inline fix names its pane.
// Writes `<dir>/probe.json` and quits (the `video` mode's last leg quits through the guard). DEBUG only.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AntiChatUI
import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

@MainActor
enum MacIntegrationProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        let mode = (try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "notifications"
        FileHandle.standardError.write(Data("MacIntegrationProbe: \(mode) → \(out)\n".utf8))
        Task { @MainActor in
            await PaletteProbe.settle(800)  // launch work (AppNotifications.start, the first window pass)
            var result: [String: Any] = ["mode": mode]
            switch mode {
            case "notifications": result.merge(await notifications(state, sessions)) { a, _ in a }
            case "denied": result.merge(await denied(state)) { a, _ in a }
            case "menubar":
                result.merge(await menubar(state, dir: dir)) { a, _ in a }
                return  // the last leg quits through the menu's Quit AntiChat
            case "quickpanel": result.merge(await quickpanel(state, sessions)) { a, _ in a }
            case "s2-stream":
                await s2Stream(state, sessions, dir: dir)
                return  // the runner kills the process (SIGKILL) mid-stream
            case "s2-check": result.merge(await s2Check(state, sessions, dir: dir)) { a, _ in a }
            case "jit": result.merge(await jit(state, denied: false)) { a, _ in a }
            case "jit-denied": result.merge(await jit(state, denied: true)) { a, _ in a }
            case "video":
                result.merge(await video(state, sessions, dir: dir)) { a, _ in a }
                return  // the quit guard ends the process
            default: result["error"] = "unknown mode \(mode)"
            }
            write(result, dir: dir)
            NSApp.terminate(nil)
        }
    }

    /// A key press delivered to `w` itself (its first responder handles it; the background panel is never key).
    static func windowKey(_ w: NSWindow, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            w.sendEvent(e)
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("MacIntegrationProbe: \(s)\n".utf8)) }

    /// Each job's latest progress (fed by the queue's update stream in the `video` mode).
    static var progress: [String: Double] = [:]

    static func write(_ obj: [String: Any], dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }

    static var spy: SpyUserNotificationClient? { NotificationService.shared.client as? SpyUserNotificationClient }
    static func requests() -> [NotificationRequestSpec] { spy?.requests ?? [] }
    static func steps() -> [String] {
        PermissionCoordinator.shared.steps.map { s in
            switch s {
            case .explained(let k): "explained:\(k.rawValue)"
            case .requested(let k): "requested:\(k.rawValue)"
            case .declined(let k): "declined:\(k.rawValue)"
            case .openedSettings(let k): "openedSettings:\(k.rawValue)"
            }
        }
    }

    static func spec(_ r: NotificationRequestSpec?) -> [String: Any] {
        guard let r else { return [:] }
        return ["category": r.category.rawValue, "title": r.title, "body": r.body, "sound": r.sound ?? "none",
                "threadID": r.threadID ?? "", "userInfo": r.userInfo]
    }

    /// Sends `text` in a new chat and waits for the reply to end; returns (chatID, assistantID).
    static func answer(_ text: String, _ state: WindowState, _ sessions: ChatSessions) async -> (String?, String?) {
        state.newChat()
        await PaletteProbe.settle(150)
        sessions.composer.text = text
        _ = sessions.composer.send()
        _ = await PaletteProbe.waitUntil(timeout: 3) { state.currentChatID != nil }
        let m = state.currentChatID.map(sessions.model(for:))
        _ = await PaletteProbe.waitUntil(timeout: 60) { m.map { !$0.isGenerating && $0.messages.last?.role == .assistant } ?? false }
        return (state.currentChatID, m?.messages.last { $0.role == .assistant }?.id)
    }

    /// Waits until the spy holds `n` requests (or `timeout` s); returns whether it did.
    static func awaitRequests(_ n: Int, timeout: Double = 10) async -> Bool {
        await PaletteProbe.waitUntil(timeout: timeout) { requests().count >= n } != nil
    }

    // MARK: notifications (AT-108)

    static func notifications(_ state: WindowState, _ sessions: ChatSessions) async -> [String: Any] {
        var legs: [String: Any] = [:]
        legs["stepsAtLaunch"] = steps()
        legs["appActive"] = NSApp.isActive

        // 1. The first answer while unfocused: explainer banner → Allow → request → 1 answer notification.
        let (chat, reply) = await answer("Hello there", state, sessions)
        let bannerShown = await PaletteProbe.waitUntil(timeout: 10) { MenusProbe.present("notif.explainer") } != nil
        legs["explainerShown"] = bannerShown
        legs["requestsBeforeAllow"] = requests().count
        legs["allowClicked"] = MenusProbe.click("notif.explainer.allow")
        _ = await awaitRequests(1)
        legs["first"] = spec(requests().first)
        legs["firstChatID"] = chat ?? ""
        legs["firstReplyID"] = reply ?? ""
        legs["stepsAfterFirst"] = steps()
        legs["explainerGone"] = await PaletteProbe.waitUntil(timeout: 3) { !MenusProbe.present("notif.explainer") } != nil

        // 2. Never → nothing; Responses off → nothing; Always → one; a sound → on the request.
        Defaults[.notifyWhen] = NotifyWhen.never.rawValue
        _ = await answer("Second question", state, sessions)
        legs["neverAdded"] = await awaitRequests(2, timeout: 2) ? 1 : 0
        Defaults[.notifyWhen] = NotifyWhen.unfocused.rawValue
        Defaults[.notifyResponses] = false
        _ = await answer("Third question", state, sessions)
        legs["responsesOffAdded"] = await awaitRequests(2, timeout: 2) ? 1 : 0
        Defaults[.notifyResponses] = true
        Defaults[.notifyWhen] = NotifyWhen.always.rawValue
        Defaults[.notificationSound] = "Submarine"
        _ = await answer("Fourth question", state, sessions)
        legs["alwaysAdded"] = await awaitRequests(2) ? 1 : 0
        legs["soundRequest"] = spec(requests().dropFirst().first)
        Defaults[.notificationSound] = "default"
        Defaults[.notifyWhen] = NotifyWhen.unfocused.rawValue

        // 3. A pack download finishing → "{pack} is ready" (category download).
        let before = requests().count
        DownloadsLaunch.menuBar.update([PackProgress(pack: "photo", bytesDone: 5, bytesTotal: 10, bytesPerSecond: 1, etaSeconds: 5,
                                                     state: .downloading, errorKey: nil)])
        DownloadsLaunch.menuBar.update([PackProgress(pack: "photo", bytesDone: 10, bytesTotal: 10, bytesPerSecond: 1, etaSeconds: nil,
                                                     state: .done, errorKey: nil)])
        _ = await awaitRequests(before + 1)
        legs["download"] = spec(requests().count > before ? requests()[before] : nil)
        DownloadsLaunch.menuBar.update([])

        // 4. A click on the first notification: the chat opens at the reply, which flashes.
        state.newChat()
        await PaletteProbe.settle(200)
        if let info = requests().first?.userInfo {
            NotificationRouter.shared.open(userInfo: info)
            let opened = await PaletteProbe.waitUntil(timeout: 5) { state.currentChatID == chat } != nil
            let m = chat.map(sessions.model(for:))
            let revealed = await PaletteProbe.waitUntil(timeout: 5) { m?.revealID == reply && m?.flashID == reply } != nil
            let flashOnScreen = await PaletteProbe.waitUntil(timeout: 3) { MenusProbe.present("revealFlash") } != nil
            legs["click"] = ["opened": opened, "revealed": revealed, "flashOnScreen": flashOnScreen,
                             "flashEnds": await PaletteProbe.waitUntil(timeout: 4) { m?.flashID == nil } != nil]
        }
        legs["outcomes"] = AppNotifications.posted.map { "\($0.event.category.rawValue):\($0.outcome.rawValue)" }
        legs["total"] = requests().count
        return legs
    }

    // MARK: denied (AT-108 AC2)

    static func denied(_ state: WindowState) async -> [String: Any] {
        var legs: [String: Any] = [:]
        legs["status"] = await PermissionCoordinator.shared.status(.notifications).rawValue
        SettingsNavigator.shared.request(.general, row: "notifyWhen")
        // ⌘, to the main window (SettingsProbe's way; the menu action alone does not open Settings in a background run).
        if let w = state.window {
            BackgroundRun.makeKeyAndOrderFront(w)
            await PaletteProbe.settle(150)
            SettingsProbe.key(",", code: 43, flags: .command, in: w)
        }
        if await PaletteProbe.waitUntil(timeout: 3, { MenusProbe.present("settings.root") }) == nil {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        legs["settingsOpen"] = await PaletteProbe.waitUntil(timeout: 10) { MenusProbe.present("settings.root") } != nil
        legs["rowShown"] = await PaletteProbe.waitUntil(timeout: 10) { MenusProbe.present("settings.row.notifyWhen") } != nil
        legs["bannerShown"] = await PaletteProbe.waitUntil(timeout: 10) { MenusProbe.present("notif.deniedBanner") } != nil
        // The banner's button is the Banner action (a plain SwiftUI Button inside the anchored view).
        PermissionCoordinator.shared.openSystemSettings(.notifications)
        legs["steps"] = steps()
        legs["fixURL"] = PermissionCoordinator.shared.inlineFix(.notifications)?.settingsURL.absoluteString ?? ""
        legs["requests"] = requests().count
        return legs
    }

    // MARK: menubar (AT-105)

    static func menubar(_ state: WindowState, dir: URL) async -> [String: Any] {
        var legs: [String: Any] = [:]
        let mb = MenuBarController.shared
        legs["insertedByDefault"] = mb.isInserted
        legs["iconTemplate"] = mb.button?.image?.isTemplate ?? false
        legs["idleIcon"] = mb.button?.accessibilityValue() as? String ?? ""
        legs["idleMenu"] = mb.renderedMenu().map(\.title)
        legs["idleSubtitles"] = mb.renderedMenu().compactMap(\.subtitle)
        legs["idleShortcuts"] = mb.renderedMenu().compactMap(\.shortcut)
        legs["voiceEnabled"] = mb.renderedMenu().first { $0.title == "Start Voice" }?.enabled ?? true
        // A download at 42 % and a running video job → progress rows + the busy icon.
        DownloadsLaunch.menuBar.update([PackProgress(pack: "photo", bytesDone: 42, bytesTotal: 100, bytesPerSecond: 1, etaSeconds: 58,
                                                     state: .downloading, errorKey: nil)])
        var jobID = ""
        if let queue = MediaJobQueue.shared, let chat = try? ChatRepository(state.service.database).create(title: "Waves") {
            Task { @MainActor in for await u in await queue.subscribe() { progress[u.job] = u.progress } }
            let set = ImageModelSet(key: "scripted-image", diffusionModel: "scripted:30:150", llm: "", vae: "", footprintBytes: 64 << 20)
            let req = ImageRequest(model: set, prompt: "waves", width: 64, height: 64, steps: 30, seed: 1, preview: "none", outputPath: "")
            jobID = (try? await queue.enqueue(chatID: chat.id, kind: .video, image: req)) ?? ""
            _ = await PaletteProbe.waitUntil(timeout: 20) { JobActivity.shared.jobs.contains { $0.id == jobID } && (progress[jobID] ?? 0) > 0 }
        }
        await PaletteProbe.settle(300)
        legs["busyMenu"] = mb.renderedMenu().map(\.title)
        legs["busyIcon"] = mb.button?.accessibilityValue() as? String ?? ""
        DownloadsLaunch.menuBar.update([])
        // Each item acts.
        state.open(.chat(state.sidebar.first?.id ?? ""))
        mb.run(.newChat)
        legs["newChat"] = await PaletteProbe.waitUntil(timeout: 3) { state.route == .newChat } != nil
        mb.run(.quickPanel)
        legs["quickPanel"] = await PaletteProbe.waitUntil(timeout: 3) { QuickPanelController.shared.isVisible } != nil
        QuickPanelController.shared.hide()
        mb.run(.openApp)
        legs["openApp"] = await PaletteProbe.waitUntil(timeout: 3) { state.window?.isVisible == true } != nil
        if let job = JobActivity.shared.jobs.first(where: { $0.id == jobID }) {
            state.newChat()
            mb.run(.openChat(job.chatID))
            legs["jobRowOpensChat"] = await PaletteProbe.waitUntil(timeout: 3) { state.currentChatID == job.chatID } != nil
        }
        // The setting removes and restores the item at once.
        Defaults[.menuBarItem] = false
        mb.sync()
        legs["removedWhenOff"] = !mb.isInserted
        Defaults[.menuBarItem] = true
        mb.sync()
        legs["backWhenOn"] = mb.isInserted
        // Let the job finish (a running video would hold the quit), then Quit AntiChat from the menu.
        if !jobID.isEmpty { _ = await PaletteProbe.waitUntil(timeout: 60) { !JobActivity.shared.jobs.contains { $0.id == jobID } } }
        legs["performed"] = mb.performed.map { "\($0)" }
        legs["quit"] = "started"
        write(legs, dir: dir)
        RunLoop.main.perform { MenuBarController.shared.run(.quit) }
        return legs
    }

    // MARK: quickpanel (AT-106)

    static func quickpanel(_ state: WindowState, _ sessions: ChatSessions) async -> [String: Any] {
        var legs: [String: Any] = [:]
        let qp = QuickPanelController.shared
        legs["preparedHidden"] = await PaletteProbe.waitUntil(timeout: 5) { qp.window != nil } != nil && !qp.isVisible
        let now = { ProcessInfo.processInfo.systemUptime }
        legs["backgroundRun"] = BackgroundRun.isOn
        legs["appActiveBefore"] = NSApp.isActive
        qp.toggle(.posted(at: now()))
        await PaletteProbe.settle(100)
        let w = qp.window as? NSPanel
        legs["open"] = ["visible": qp.isVisible, "floating": w?.level == .floating,
                        "nonActivating": w?.styleMask.contains(.nonactivatingPanel) ?? false,
                        "allSpaces": w?.collectionBehavior.contains(.canJoinAllSpaces) ?? false,
                        "fullScreenAux": w?.collectionBehavior.contains(.fullScreenAuxiliary) ?? false,
                        "fieldFocused": qp.fieldIsFirstResponder, "size": "\(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0))",
                        "appActive": NSApp.isActive]
        // Return streams the reply in the panel.
        qp.model.text = "What's 2+2?"
        await PaletteProbe.settle(100)
        if let p = w { windowKey(p, "\r", code: 36) }
        let chat = await PaletteProbe.waitUntil(timeout: 3) { qp.model.chatID != nil } != nil ? qp.model.chatID : nil
        let streamed = await PaletteProbe.waitUntil(timeout: 20) { !qp.model.reply.text.isEmpty } != nil
        let firstModel = chat.flatMap { qp.conversation(for: $0) }
        legs["firstReplyDiag"] = ["generating": firstModel?.isGenerating ?? false, "chars": qp.model.reply.text.count,
                                  "status": firstModel?.messages.last?.status.rawValue ?? "", "readiness": "\(sessions.readiness)"]
        legs["send"] = ["chat": chat ?? "", "streamed": streamed, "phase": qp.model.phase.rawValue,
                        "size": "\(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0))",
                        "replyOnScreen": MenusProbe.present("quickPanel.reply"),
                        "rowInDB": (try? ChatRepository(state.service.database).chat(chat ?? "")) != nil]
        // Esc while streaming: hidden, the answer goes on.
        let wasStreaming = qp.model.phase == .streaming
        if let p = w { windowKey(p, "\u{1b}", code: 53) }
        legs["escWhileStreaming"] = ["wasStreaming": wasStreaming, "hidden": !qp.isVisible]
        let finished = await PaletteProbe.waitUntil(timeout: 60) { qp.model.phase != .streaming } != nil
        legs["finishedInBackground"] = finished && !qp.model.reply.text.isEmpty
        let fullReply = qp.model.reply.text
        // Reopen: a finished reply starts fresh; Esc on an empty panel hides.
        qp.toggle(.posted(at: now()))
        legs["reopenFresh"] = qp.isVisible && qp.model.chatID == nil && qp.fieldIsFirstResponder
        // A done reply: Esc collapses, Esc hides.
        qp.model.text = "Again?"
        _ = qp.model.send()
        _ = await PaletteProbe.waitUntil(timeout: 60) { qp.model.phase == .done }
        if let p = w { windowKey(p, "\u{1b}", code: 53) }
        let r1: QuickPanelViewModel.EscapeResult = qp.model.showsReply ? .hidePanel : .collapsedReply
        await PaletteProbe.settle(500)
        let collapsedSize = "\(Int(w?.frame.width ?? 0))x\(Int(w?.frame.height ?? 0))"
        let stillVisible = qp.isVisible
        if let p = w { windowKey(p, "\u{1b}", code: 53) }
        let r2: QuickPanelViewModel.EscapeResult = qp.isVisible ? .collapsedReply : .hidePanel
        legs["escCollapseThenHide"] = ["first": r1.rawValue, "visibleAfterFirst": stillVisible, "sizeAfterFirst": collapsedSize,
                                       "second": r2.rawValue, "hiddenAfterSecond": !qp.isVisible]
        // ⌘O while streaming: the main window takes the same conversation and finishes the reply.
        qp.toggle(.posted(at: now()))
        qp.model.text = "Tell me more"
        _ = qp.model.send()
        let handed = qp.model.chatID ?? ""
        let panelModel = qp.conversation(for: handed)
        _ = await PaletteProbe.waitUntil(timeout: 10) { !(panelModel?.messages.last { $0.role == .assistant }?.text.isEmpty ?? true) }
        let streamingAtHandoff = panelModel?.isGenerating ?? false
        if let p = w {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: now(), windowNumber: p.windowNumber,
                                     context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)
            if let e { _ = p.performKeyEquivalent(with: e) }
        }
        let opened = await PaletteProbe.waitUntil(timeout: 5) { state.currentChatID == handed } != nil
        let same = state.conversation?() === panelModel
        _ = await PaletteProbe.waitUntil(timeout: 60) { !(state.conversation?()?.isGenerating ?? true) }
        let mainReply = state.conversation?()?.messages.last { $0.role == .assistant }?.text ?? ""
        legs["openInApp"] = ["streamingAtHandoff": streamingAtHandoff, "opened": opened, "sameConversation": same,
                             "panelHidden": !qp.isVisible, "mainReplyComplete": !mainReply.isEmpty,
                             "mainStatus": state.conversation?()?.messages.last?.status.rawValue ?? ""]
        legs["fullReplyChars"] = fullReply.count
        // Recorder: another combination, then Off.
        KeyboardShortcuts.setShortcut(.init(.q, modifiers: [.control, .option]), for: .quickPanel)
        GlobalShortcuts.shared.recheck()
        let other = KeyboardShortcuts.getShortcut(for: .quickPanel)?.description ?? ""
        KeyboardShortcuts.setShortcut(nil, for: .quickPanel)
        GlobalShortcuts.shared.recheck()
        legs["recorder"] = ["other": other, "offIsNil": KeyboardShortcuts.getShortcut(for: .quickPanel) == nil,
                            "conflictWhenOff": GlobalShortcuts.shared.conflict]
        KeyboardShortcuts.reset(.quickPanel)
        GlobalShortcuts.shared.recheck()
        legs["defaultBack"] = KeyboardShortcuts.getShortcut(for: .quickPanel)?.description ?? ""
        // 20 opens (in-process trigger time → field focused + panel displayed), hidden between.
        let before = qp.openTimes.count
        for _ in 0..<20 {
            qp.show(.posted(at: now()))
            await PaletteProbe.settle(250)
            qp.hide()
            await PaletteProbe.settle(150)
        }
        let times = qp.openTimes.dropFirst(before).map(\.ms).sorted()
        func pct(_ q: Double) -> Double { times.isEmpty ? -1 : times[min(times.count - 1, Int((Double(times.count - 1) * q).rounded()))] }
        legs["openMs"] = ["n": times.count, "p50": pct(0.5), "p95": pct(0.95), "max": times.last ?? -1]
        return legs
    }

    // MARK: S2 (AT-NFR-S2 re-run, journey 13 in-process): a window chat and a quick-panel chat streaming when the
    // process is killed; after the relaunch both replies are `interrupted` with their partial text kept.

    static func s2Stream(_ state: WindowState, _ sessions: ChatSessions, dir: URL) async {
        state.newChat()
        await PaletteProbe.settle(150)
        sessions.composer.text = "Tell me a long story"
        _ = sessions.composer.send()
        _ = await PaletteProbe.waitUntil(timeout: 5) { state.currentChatID != nil }
        let windowChat = state.currentChatID ?? ""
        let qp = QuickPanelController.shared
        _ = await PaletteProbe.waitUntil(timeout: 5) { qp.window != nil }
        qp.show(.menu)
        qp.model.text = "Another long story please"
        _ = qp.model.send()
        let panelChat = qp.model.chatID ?? ""
        // Both streaming, with some text persisted (the persister flushes ≤ 1 s / 50 tokens).
        _ = await PaletteProbe.waitUntil(timeout: 20) {
            (sessions.model(for: windowChat).liveReply(for: sessions.model(for: windowChat).messages.last?.id ?? "")?.text.count ?? 0) > 200
                && qp.model.reply.text.count > 200
        }
        await PaletteProbe.settle(1500)
        let w = sessions.model(for: windowChat)
        write(["windowChat": windowChat, "panelChat": panelChat,
               "windowStreaming": w.isGenerating, "panelStreaming": qp.model.phase == .streaming,
               "windowChars": w.liveReply(for: w.messages.last?.id ?? "")?.text.count ?? 0, "panelChars": qp.model.reply.text.count],
              dir: dir.appendingPathComponent("stream"))
        log("s2: streaming, ready for SIGKILL")
    }

    static func s2Check(_ state: WindowState, _ sessions: ChatSessions, dir: URL) async -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("stream/probe.json")),
              let ids = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return ["error": "no stream/probe.json"] }
        var legs: [String: Any] = [:]
        for key in ["windowChat", "panelChat"] {
            guard let chat = ids[key] as? String, !chat.isEmpty else { legs[key] = ["error": "no id"]; continue }
            state.open(.chat(chat))
            let m = sessions.model(for: chat)
            _ = await PaletteProbe.waitUntil(timeout: 5) { m.messages.contains { $0.role == .assistant } }
            let last = m.messages.last { $0.role == .assistant }
            legs[key] = ["status": last?.status.rawValue ?? "", "chars": last?.text.count ?? 0,
                         "retryShown": await PaletteProbe.waitUntil(timeout: 3) { MenusProbe.present("interruptedRetry") } != nil]
        }
        return legs
    }

    // MARK: jit (AT-109)

    static func jit(_ state: WindowState, denied: Bool) async -> [String: Any] {
        var legs: [String: Any] = [:]
        let pc = PermissionCoordinator.shared
        await PaletteProbe.settle(1500)
        legs["atLaunch"] = ["steps": steps(), "micRequests": PermissionCenter.shared.requestCount,
                            "locationRequests": LocationPermission.shared.requestCount]
        // Microphone: the composer's mic button.
        if let w = state.window { BackgroundRun.makeKeyAndOrderFront(w) }
        let micShown = await PaletteProbe.waitUntil(timeout: 10) { MenusProbe.present("composer.mic") } != nil
        legs["micButton"] = micShown
        _ = SettingsProbe.click("composer.mic")
        if denied {
            legs["micDeniedPopover"] = await PaletteProbe.waitUntil(timeout: 5) { MenusProbe.present("permissionDeniedPopover") } != nil
        } else {
            legs["micExplainer"] = await PaletteProbe.waitUntil(timeout: 5) { MenusProbe.present("permissionPromptSheet") } != nil
            legs["micRequestsBeforeContinue"] = PermissionCenter.shared.requestCount
            for _ in 0..<3 where PermissionCenter.shared.requestCount == 0 {
                await PaletteProbe.settle(600)
                _ = SettingsProbe.click("voice.permission.continue")
                _ = await PaletteProbe.waitUntil(timeout: 3) { PermissionCenter.shared.requestCount > 0 }
            }
            _ = await PaletteProbe.waitUntil(timeout: 3) { PermissionCenter.shared.microphone != .notDetermined }
            legs["micStatus"] = PermissionCenter.shared.microphone.rawValue
        }
        legs["micRequests"] = PermissionCenter.shared.requestCount
        // Location: Settings › Tools & Connections › "Use my approximate location for search".
        SettingsNavigator.shared.request(.tools, row: "searchUsesLocation")
        if let w = state.window {
            BackgroundRun.makeKeyAndOrderFront(w)
            await PaletteProbe.settle(200)
            SettingsProbe.key(",", code: 43, flags: .command, in: w)
        }
        if await PaletteProbe.waitUntil(timeout: 3, { MenusProbe.present("settings.root") }) == nil {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        let row = await PaletteProbe.waitUntil(timeout: 10) { MenusProbe.present("settings.control.searchUsesLocation") } != nil
        legs["locationRow"] = row
        _ = SettingsProbe.click("settings.control.searchUsesLocation")
        legs["locationExplainer"] = await PaletteProbe.waitUntil(timeout: 5) { MenusProbe.present("location.explainer") } != nil
        legs["locationRequestsBeforeContinue"] = LocationPermission.shared.requestCount
        // The sheet animates in: click Continue once it has settled, again if the first click landed mid-animation.
        for _ in 0..<3 where LocationPermission.shared.requestCount == 0 {
            await PaletteProbe.settle(600)
            _ = SettingsProbe.click("location.explainer.continue")
            _ = await PaletteProbe.waitUntil(timeout: 3) { LocationPermission.shared.requestCount > 0 }
        }
        legs["locationRequests"] = LocationPermission.shared.requestCount
        legs["locationStatus"] = LocationPermission.shared.status.rawValue
        if denied {
            legs["locationFix"] = await PaletteProbe.waitUntil(timeout: 5) { MenusProbe.present("location.openSettings") } != nil
        }
        // Each kind's inline fix (read the statuses first).
        var fixes: [String: String] = [:]
        for k in PermissionRequestKind.allCases {
            _ = await pc.status(k)
            if let f = pc.inlineFix(k) { fixes[k.rawValue] = f.settingsURL.absoluteString }
        }
        legs["fixes"] = fixes
        legs["steps"] = steps()
        legs["requestedWithoutExplainer"] = pc.requestedWithoutExplainer.map(\.rawValue)
        return legs
    }

    // MARK: video (AT-042)

    static func video(_ state: WindowState, _ sessions: ChatSessions, dir: URL) async -> [String: Any] {
        var legs: [String: Any] = [:]
        guard let queue = MediaJobQueue.shared else {
            legs["error"] = "no media job queue"
            write(legs, dir: dir)
            NSApp.terminate(nil)
            return legs
        }
        Task { @MainActor in for await u in await queue.subscribe() { progress[u.job] = u.progress } }
        // The helper runs the job (no `-UseScriptedEngine` here: the in-process chat replay has no media transport).
        let chatRow = try? ChatRepository(state.service.database).create(title: "Waves at dusk")
        guard let chat = chatRow?.id else {
            legs["error"] = "no chat"
            write(legs, dir: dir)
            NSApp.terminate(nil)
            return legs
        }
        let reply: String? = nil
        state.open(.chat(chat))
        func job(steps: Int, ms: Int) async throws -> String {
            let set = ImageModelSet(key: "scripted-image", diffusionModel: "scripted:\(steps):\(ms)", llm: "", vae: "",
                                    footprintBytes: 64 << 20)
            // `preview: none`: progress only, so the job runs every step (no detectors in a dev container: the final
            // check fails closed → `safety.missing`, the "didn't finish" notification).
            let req = ImageRequest(model: set, prompt: "waves", width: 64, height: 64, steps: steps, seed: 1, preview: "none",
                                   outputPath: "")
            return try await queue.enqueue(chatID: chat, messageID: reply, kind: .video, image: req)
        }
        var id = ""
        do { id = try await job(steps: 20, ms: 150) } catch { legs["enqueueError"] = "\(error)" }
        _ = await PaletteProbe.waitUntil(timeout: 10) { AppNotifications.activeJobs[id] == .video }
        legs["tracked"] = AppNotifications.activeJobs[id]?.rawValue ?? ""
        legs["dockBadgeWhileRunning"] = NSApp.dockTile.badgeLabel ?? ""
        // R-042 AC1: switching chats does not cancel it.
        state.newChat()
        _ = await PaletteProbe.waitUntil(timeout: 20) { (progress[id] ?? 0) > 0 }
        let p0 = progress[id] ?? 0
        await PaletteProbe.settle(900)
        let p1 = progress[id] ?? 0
        legs["progressAfterNavigate"] = ["before": p0, "after": p1, "advanced": p1 > p0 && p0 > 0,
                                         "stillRunning": AppNotifications.activeJobs[id] == .video]
        // R-042 AC3: closing the last window with the menu bar item off still keeps the app (and the job) running.
        let menuBar = Defaults[.menuBarItem]
        Defaults[.menuBarItem] = false
        legs["terminateAfterLastWindowWhileJob"] = NSApp.delegate?.applicationShouldTerminateAfterLastWindowClosed?(NSApp) ?? true
        // R-042 AC2: its end posts one `video` notification (the probe is unfocused: background run).
        let end = await queue.finished(id)
        legs["firstJobState"] = end.state.rawValue
        legs["firstJobError"] = end.errorCode ?? ""
        _ = await awaitRequests(1)
        legs["videoRequests"] = requests().filter { $0.category == .video }.map(spec)
        legs["terminateAfterLastWindowIdle"] = NSApp.delegate?.applicationShouldTerminateAfterLastWindowClosed?(NSApp) ?? false
        Defaults[.menuBarItem] = menuBar
        _ = await PaletteProbe.waitUntil(timeout: 3) { (NSApp.dockTile.badgeLabel ?? "").isEmpty }
        legs["dockBadgeAfter"] = NSApp.dockTile.badgeLabel ?? ""
        // R-042 AC3: ⌘Q during a second video job → Wait → the quit is held and completes by itself after the job.
        do { id = try await job(steps: 12, ms: 150) } catch { legs["enqueueError2"] = "\(error)" }
        _ = await PaletteProbe.waitUntil(timeout: 10) { AppNotifications.activeJobs[id] == .video }
        let job2Ran = await PaletteProbe.waitUntil(timeout: 20) { (progress[id] ?? 0) > 0 } != nil
        MediaJobQuitGuard.scriptedChoice = .wait
        legs["quit"] = ["started": true, "job2Ran": job2Ran, "job2Tracked": AppNotifications.activeJobs[id]?.rawValue ?? ""]
        write(legs, dir: dir)
        log("quit: job2Ran=\(job2Ran) tracked=\(AppNotifications.activeJobs[id]?.rawValue ?? "-")")
        // The real ⌘Q path: applicationShouldTerminate → the guard holds the quit (.terminateLater) until the job ends.
        // AppKit keeps running the main queue meanwhile, so this task records what the guard shows, then the job's
        // end lets the app quit by itself (the script checks the exit and the second `video` request).
        Task { @MainActor in
            log("quit: held, recording")
            await PaletteProbe.settle(300)
            legs["quit"] = ["asked": MediaJobQuitGuard.lastAsked ?? "", "waiting": MediaJobQuitGuard.waiting,
                            "toast": AppToasts.shared.current?.message.string ?? "", "requestsBeforeQuit": requests().count,
                            "jobStillRunning": AppNotifications.activeJobs[id] == .video]
            write(legs, dir: dir)
        }
        // ⌘Q arrives from the run loop (an event), never from inside a main-queue job: the guard's own main-actor
        // tasks must be able to run while AppKit waits for its reply. CFRunLoopPerformBlock does the same here.
        RunLoop.main.perform { NSApp.terminate(nil) }
        return legs
    }
}
#endif
