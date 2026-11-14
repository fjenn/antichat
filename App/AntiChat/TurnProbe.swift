// M1.T19 in-process turn probe (AT-003, AT-010, AT-014, AT-299). XCUITest is blocked on this Mac (Q-015), so — like
// WindowProbe / PaletteProbe / ContextProbe — the app drives its own window: the composer (ComposerModel.send /
// sendNow → LiveComposer → WindowState.send → ConversationModel → TurnController → the `-UseScriptedEngine` script),
// the sidebar (WindowState) and the queued bubbles (real clicks through `NSWindow.sendEvent` on probe anchors).
// The legs depend on the script (tools/at/t19-probe.sh runs each one in a fresh container):
//   basic.jsonl       AT-010 (1) temporary title in the send-ack pass, auto title ≤ 3 s after the first token;
//                     AT-010 (2) open + close an empty new chat leaves no row; AT-003 (1) bubble + pending dot + Stop
//                     in the send pass; AT-003 (4) the completion pass (Send, spinner, status, ActionBar together).
//   tool-call.jsonl   AT-003 (4) activity line with its seconds counter, then the completion pass.
//   stream-600w.jsonl AT-014 (2) ⌘Return stops the reply (interrupted) and sends at once; AT-014 (1) two follow-ups
//                     (+ one removed, one edited) as queued bubbles, sent in order when the turn ends;
//                     AT-010 (3) sidebar spinner while generating, unread dot for a background chat, cleared on open.
//   slow-load.jsonl   AT-299 + AT-003 (2): a send during the 8 s load is held ("Sending when Chat is ready (NN%)",
//                     NN rising, `status.loadingModel`, nothing sent), × cancels it (0 requests, no row); a second
//                     send is released ≤ 200 ms after `.ready`; the assistant area is never empty (100 ms samples).
// Writes `<dir>/probe.json` (+ window captures) and quits. DEBUG only (`-TurnProbe <dir>`).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatUI
import AppKit
import QuartzCore
import SwiftUI

@MainActor
enum TurnProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("TurnProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, sessions: sessions, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    static func present(_ id: String) -> Bool { PaletteProbe.present(id) }
    static func seconds(_ d: Duration) -> Double { PaletteProbe.seconds(d) }

    /// Runs `body` when the current Core Animation transaction commits (the frame that shows the changes so far).
    static func atNextCommit() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setCompletionBlock { c.resume() }
            CATransaction.commit()
        }
    }

    static func model(_ state: WindowState, _ sessions: ChatSessions) -> ConversationModel? {
        state.currentChatID.map(sessions.model(for:))
    }

    static func waitIdle(_ m: ConversationModel?, timeout: Double = 60) async -> Bool {
        await PaletteProbe.waitUntil(timeout: timeout) { !(m?.isGenerating ?? true) } != nil
    }

    static func engine(_ sessions: ChatSessions) -> InProcessScriptedEngine? { sessions.environment.engine as? InProcessScriptedEngine }

    static func userTexts(_ chatID: String, _ env: ChatEnvironment) -> [String] {
        (try? env.database.read { db in
            try MessageTree.visiblePath(chatID, db: db).filter { $0.role == .user }
                .map { try MessageRepository.parts(of: $0.id, db: db).filter { $0.kind == .text }.map(\.body).joined() }
        }) ?? []
    }

    static func chatRow(_ id: String, _ env: ChatEnvironment) -> ChatRecord? { try? ChatRepository(env.database).chat(id) }

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(1500))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }) else {
            write(["error": "no AntiChat window"], dir: dir)
            return
        }
        PaletteProbe.window = window
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        BackgroundRun.makeKeyAndOrderFront(window)
        BackgroundRun.activate()
        await PaletteProbe.settle(800)
        let script = (LaunchOptions.current.scriptedEngineScript ?? "") as NSString
        let name = script.lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        var result: [String: Any] = ["script": name]
        switch name {
        case "basic": result.merge(await basic(state, sessions, dir), uniquingKeysWith: { $1 })
        case "tool-call": result.merge(await toolCall(state, sessions, dir), uniquingKeysWith: { $1 })
        case "stream-600w": result.merge(await queues(state, sessions, dir), uniquingKeysWith: { $1 })
        case "slow-load": result.merge(await slowLoad(state, sessions, dir), uniquingKeysWith: { $1 })
        default: result["error"] = "no legs for script \(name)"
        }
        write(result, dir: dir)
        FileHandle.standardError.write(Data("TurnProbe: done\n".utf8))
    }

    // MARK: Send acknowledgement + completion pass (shared)

    struct SendAck {
        var sameFrame: [String: Bool]
        var dict: [String: Any]
    }

    /// Sends `text` through the composer and records what the send pass changed (before the frame commits) and what
    /// is on screen at that commit.
    static func send(_ text: String, _ state: WindowState, _ sessions: ChatSessions) async -> SendAck {
        sessions.composer.text = text
        await PaletteProbe.settle(50)
        let t0 = ContinuousClock.now
        let accepted = sessions.composer.send()
        // Same pass (no await yet): model, composer, sidebar row.
        let m = model(state, sessions)
        let last = m?.messages.last
        let row = state.sidebar.first { $0.id == state.currentChatID }
        let inPass: [String: Bool] = [
            "accepted": accepted,
            "userBubble": m?.messages.dropLast().last?.role == .user,
            "pendingAssistant": last?.role == .assistant && (last?.status == .pending),
            "pendingDotOrStatus": last.map { m?.statusModel(for: $0).status(elapsed: .zero).showsDot ?? false } ?? false,
            "stop": sessions.composer.phase == .generating,
            "sidebarRowTemporaryTitle": row?.title == TitleService.temporaryTitle(text),
        ]
        await atNextCommit()
        let ackMs = seconds(ContinuousClock.now - t0) * 1000
        return SendAck(sameFrame: inPass, dict: ["inSendPass": inPass, "commitMs": (ackMs * 10).rounded() / 10])
    }

    /// Registers a completion handler (after ChatSessions' own) that records the window state inside the pass.
    static func watchCompletion(_ sessions: ChatSessions, _ state: WindowState, into box: CompletionBox) -> UUID {
        sessions.completion.register { [weak sessions] c in
            guard let sessions else { return }
            let m = sessions.model(for: c.chatID)
            let msg = m.messages.last { $0.id == c.assistantID }
            box.passes.append([
                "chatID": c.chatID, "status": c.status.rawValue, "visible": c.visible,
                "composerIdle": c.chatID != sessions.currentChatID || sessions.composer.phase == .idle,
                "spinnerOff": !sessions.activeChats.contains(c.chatID) || m.isGenerating,
                "statusHidden": msg.map { m.statusModel(for: $0).status(elapsed: .seconds(10)) == .hidden } ?? false,
                "messageFinal": msg.map { $0.status != .pending && $0.status != .streaming } ?? false,
                "rowTitle": state.sidebar.first { $0.id == c.chatID }?.title ?? "",
            ])
        }
    }

    final class CompletionBox { var passes: [[String: Any]] = [] }

    static func passOK(_ p: [String: Any]?) -> Bool {
        guard let p else { return false }
        return ["composerIdle", "spinnerOff", "statusHidden", "messageFinal"].allSatisfy { p[$0] as? Bool == true }
    }

    // MARK: basic.jsonl

    static func basic(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let env = sessions.environment
        var out: [String: Any] = [:]
        // AT-010 (2): open and close an empty new chat → no row, nothing in the sidebar.
        let rowsBefore = (try? ChatRepository(env.database).sidebar().count) ?? -1
        state.newChat()
        await PaletteProbe.settle(300)
        state.newChat()
        await PaletteProbe.settle(300)
        let rowsAfter = (try? ChatRepository(env.database).sidebar().count) ?? -1
        out["AT-010-2"] = ["pass": rowsBefore == 0 && rowsAfter == 0 && state.sidebar.isEmpty,
                           "rowsBefore": rowsBefore, "rowsAfter": rowsAfter]

        let box = CompletionBox()
        let token = watchCompletion(sessions, state, into: box)
        defer { sessions.completion.unregister(token) }
        let prompt = "Plan a quiet weekend in the harbour town with the ferry, the market and the lighthouse"
        let ack = await send(prompt, state, sessions)
        let chatID = state.currentChatID ?? ""
        let rowOnScreen = present("chatRow.\(chatID)")
        let spinner = present("chatRow.streaming")
        PaletteProbe.capture("send-ack.png", dir)
        let done = await waitIdle(model(state, sessions))
        let titleOK = await PaletteProbe.waitUntil(timeout: 8) { state.sidebar.first { $0.id == chatID }?.titlePending == false } != nil
        let title = chatRow(chatID, env)
        let latency = sessions.titleLatency[chatID]
        await PaletteProbe.settle(300)
        PaletteProbe.capture("done.png", dir)
        let words = title?.title.split(separator: " ").count ?? 0
        out["AT-003-1"] = ["pass": ack.sameFrame.filter { $0.key != "sidebarRowTemporaryTitle" }.values.allSatisfy { $0 },
                           "ack": ack.dict]
        out["AT-010-1"] = [
            "pass": ack.sameFrame["sidebarRowTemporaryTitle"] == true && rowOnScreen && titleOK
                && title?.titleState == .auto && (2...6).contains(words) && (latency ?? 99) <= 3,
            "temporaryInSendPass": ack.sameFrame["sidebarRowTemporaryTitle"] ?? false, "rowOnScreenAtCommit": rowOnScreen,
            "autoTitle": title?.title ?? "", "titleState": title?.titleState.rawValue ?? "", "words": words,
            "firstTokenToTitleSeconds": latency ?? -1, "boundSeconds": 3,
            "note": "ScriptedEngine title line (400 ms); the real-model U7 p50 is the `make perf METRIC=U7` leg (M1.T26)",
        ]
        let pass = box.passes.last { $0["chatID"] as? String == chatID }
        let spinnerGone = await PaletteProbe.waitUntil(timeout: 1) { !present("chatRow.streaming") } != nil
        out["AT-003-4-basic"] = ["pass": done && passOK(pass) && spinner && spinnerGone && box.passes.count == 1,
                                 "completionPasses": box.passes.count, "pass0": pass ?? [:],
                                 "spinnerWhileGenerating": spinner, "spinnerGoneAfter": spinnerGone]
        return out
    }

    // MARK: tool-call.jsonl

    static func toolCall(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let box = CompletionBox()
        let token = watchCompletion(sessions, state, into: box)
        defer { sessions.completion.unregister(token) }
        _ = await send("Echo hello through the tool please", state, sessions)
        let m = model(state, sessions)
        let line = await PaletteProbe.waitUntil(timeout: 10) { !(m?.messages.last?.activities.isEmpty ?? true) } != nil
        let activityOnScreen = await PaletteProbe.waitUntil(timeout: 2) {
            !UIProbeRegistry.ids(prefix: "activityLine-", in: PaletteProbe.window).isEmpty
        } != nil
        PaletteProbe.capture("activity.png", dir)
        let done = await waitIdle(m)
        let act = m?.messages.last?.activities.first
        let pass = box.passes.last
        return ["AT-003-4-tool": [
            "pass": line && activityOnScreen && done && passOK(pass) && (act?.seconds ?? -1) >= 0 && box.passes.count == 1,
            "activityLine": line, "activityOnScreen": activityOnScreen, "activitySeconds": act?.seconds ?? -1,
            "activityState": "\(act?.state.rawValue ?? "")", "completionPasses": box.passes.count, "pass0": pass ?? [:],
        ]]
    }

    // MARK: stream-600w.jsonl

    static func queues(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let env = sessions.environment
        var out: [String: Any] = [:]
        // AT-014 (2): ⌘Return during the reply stops it (interrupted) and sends at once.
        _ = await send("Tell me a long story about the harbour town", state, sessions)
        let chatID = state.currentChatID ?? ""
        let m = sessions.model(for: chatID)
        _ = await PaletteProbe.waitUntil(timeout: 5) { m.messages.last?.status == .streaming }
        await PaletteProbe.settle(1000)
        let spinner = present("chatRow.streaming")
        let firstReply = m.messages.last?.id ?? ""
        sessions.composer.text = "Stop and answer this instead"
        let key = sessions.composer.keyAction(command: true, shift: false, option: false, hasMarkedText: false)
        let t0 = ContinuousClock.now
        let sentNow = sessions.composer.sendNow()
        let interrupted = await PaletteProbe.waitUntil(timeout: 3) { m.messages.first { $0.id == firstReply }?.status == .interrupted } != nil
        let newTurn = await PaletteProbe.waitUntil(timeout: 3) {
            m.messages.last?.role == .assistant && m.messages.last?.id != firstReply && m.isGenerating
        } != nil
        let toNewTurn = seconds(ContinuousClock.now - t0)
        let notice = await PaletteProbe.waitUntil(timeout: 2) { present("interruptedNotice") } != nil
        _ = await PaletteProbe.waitUntil(timeout: 2) { userTexts(chatID, env).last == "Stop and answer this instead" }
        PaletteProbe.capture("send-now.png", dir)
        out["AT-014-2"] = [
            "pass": key == .sendNow && sentNow && interrupted && newTurn && notice
                && userTexts(chatID, env).last == "Stop and answer this instead",
            "keyAction": "\(String(describing: key))", "interrupted": interrupted, "interruptedNotice": notice,
            "newTurnStarted": newTurn, "secondsToNewTurn": (toNewTurn * 1000).rounded() / 1000,
            "storedUserMessages": userTexts(chatID, env),
        ]

        // AT-014 (1): three follow-ups during the reply; the 2nd edited, the 3rd removed with its ×.
        let requestsBefore = engine(sessions)?.requestCount ?? -1
        for t in ["Follow-up one", "Follow-up two", "Follow-up three"] {
            sessions.composer.text = t
            _ = sessions.composer.send()
            await PaletteProbe.settle(100)
        }
        let bubbles = await PaletteProbe.waitUntil(timeout: 2) { present("queuedFollowUp.2") } != nil
        let ordered = m.followUps.items.map(\.text)
        let stillStop = sessions.composer.phase == .generating
        PaletteProbe.capture("queued.png", dir)
        // Edit the second through its pencil + field + Save; remove the third with its ×.
        let editClicked = PaletteProbe.click("queuedFollowUp.1.edit")
        _ = await PaletteProbe.waitUntil(timeout: 2) { present("queuedFollowUp.1.field") }
        if let second = m.followUps.items.dropFirst().first { m.editQueued(second.id, text: "Follow-up two, edited") }
        await PaletteProbe.settle(300)  // the edit field's layout settles before the next click
        var removeClicked = false
        for _ in 0..<3 where m.followUps.count == 3 {
            removeClicked = PaletteProbe.click("queuedFollowUp.2.remove") || removeClicked
            await PaletteProbe.settle(300)
        }
        let afterEdit = m.followUps.items.map(\.text)
        PaletteProbe.capture("queued-edited.png", dir)
        // The running reply ends naturally; each follow-up goes out after the previous reply.
        let drained = await PaletteProbe.waitUntil(timeout: 70) { m.followUps.isEmpty && !m.isGenerating } != nil
        let users = userTexts(chatID, env)
        let requestsAfter = engine(sessions)?.requestCount ?? -1
        out["AT-014-1"] = [
            "pass": bubbles && ordered == ["Follow-up one", "Follow-up two", "Follow-up three"] && stillStop
                && removeClicked && afterEdit == ["Follow-up one", "Follow-up two, edited"] && drained
                && Array(users.suffix(2)) == ["Follow-up one", "Follow-up two, edited"] && !users.contains("Follow-up three")
                && requestsAfter - requestsBefore == 2,
            "queuedInOrder": ordered, "bubblesOnScreen": bubbles, "composerStillStop": stillStop,
            "editClicked": editClicked, "removeClicked": removeClicked, "afterEditRemove": afterEdit,
            "drained": drained, "userMessages": users, "engineRequestsForFollowUps": requestsAfter - requestsBefore,
        ]

        // AT-010 (3): spinner while generating; a reply finishing in a background chat → unread dot, cleared on open.
        state.newChat()
        await PaletteProbe.settle(200)
        _ = await send("A second chat that answers in the background", state, sessions)
        let second = state.currentChatID ?? ""
        _ = await PaletteProbe.waitUntil(timeout: 5) { sessions.model(for: second).messages.last?.status == .streaming }
        state.open(.chat(chatID))
        await PaletteProbe.settle(500)
        let bgSpinner = present("chatRow.streaming") && sessions.activity(for: second) == .streaming
        PaletteProbe.capture("background-spinner.png", dir)
        let bgDone = await waitIdle(sessions.model(for: second), timeout: 40)
        let unreadDB = await PaletteProbe.waitUntil(timeout: 2) { chatRow(second, env)?.unread == true } != nil
        let unreadDot = await PaletteProbe.waitUntil(timeout: 2) { present("chatRowUnread") } != nil
        PaletteProbe.capture("unread.png", dir)
        state.open(.chat(second))
        let cleared = await PaletteProbe.waitUntil(timeout: 2) { chatRow(second, env)?.unread == false && !present("chatRowUnread") } != nil
        out["AT-010-3"] = [
            "pass": spinner && bgSpinner && bgDone && unreadDB && unreadDot && cleared,
            "spinnerWhileGenerating": spinner, "backgroundSpinner": bgSpinner, "unreadStored": unreadDB,
            "unreadDotOnScreen": unreadDot, "clearedOnOpen": cleared,
        ]
        return out
    }

    // MARK: slow-load.jsonl

    static func slowLoad(_ state: WindowState, _ sessions: ChatSessions, _ dir: URL) async -> [String: Any] {
        let env = sessions.environment
        let eng = engine(sessions)
        var out: [String: Any] = [:]
        // Typing starts the warmup (8 s load); a send during it is held.
        sessions.composer.text = "H"
        let loading = await PaletteProbe.waitUntil(timeout: 3) { !sessions.readiness.acceptsRequests } != nil
        let ack = await send("Hello before the model is ready", state, sessions)
        let chatID = state.currentChatID ?? ""
        let m = sessions.model(for: chatID)
        let held = m.heldUserID != nil
        let statusLine = m.messages.last.map { m.statusModel(for: $0).status(elapsed: .zero) == .loadingModel } ?? false
        var percents: [Int] = []
        var captions: [Bool] = []
        for _ in 0..<8 {
            await PaletteProbe.settle(200)
            if let p = m.heldPercent { percents.append(p) }
            captions.append(present("queuedBubble.caption"))
        }
        PaletteProbe.capture("held.png", dir)
        let requestsWhileHeld = eng?.requestCount ?? -1
        // × cancels: removed, nothing sent, no chat row left.
        let clicked = PaletteProbe.click("queuedBubble.remove")
        await PaletteProbe.settle(300)
        let rowGone = chatRow(chatID, env) == nil && !state.sidebar.contains { $0.id == chatID }
        let requestsAfterCancel = eng?.requestCount ?? -1
        out["AT-299-cancel"] = [
            "pass": loading && held && clicked && m.messages.isEmpty && requestsWhileHeld == 0 && requestsAfterCancel == 0 && rowGone,
            "loadingSeen": loading, "held": held, "removeClicked": clicked, "messagesAfterCancel": m.messages.count,
            "engineRequests": requestsAfterCancel, "chatRowRemoved": rowGone, "routeIsNewChat": state.route == .newChat,
        ]
        // Second send, still loading: released ≤ 200 ms after ready; the assistant area is never empty.
        let ack2 = await send("Hello again, still loading", state, sessions)
        let chat2 = state.currentChatID ?? ""
        let m2 = sessions.model(for: chat2)
        let held2 = m2.heldUserID != nil
        var samples = 0, empty = 0
        var percents2: [Int] = []
        while m2.isGenerating || m2.messages.last?.status == .pending {
            samples += 1
            if let a = m2.messages.last, a.role == .assistant {
                let dot = m2.statusModel(for: a).status(elapsed: .zero).showsDot
                let text = !(m2.receivedText(of: a.id).isEmpty)
                if !dot && !text && a.status != .done { empty += 1 }
            }
            if let p = m2.heldPercent, m2.heldUserID != nil { percents2.append(p) }
            if samples > 300 { break }
            await PaletteProbe.settle(100)
        }
        var releaseMs = -1.0
        if let ready = sessions.lastReadyAt, let released = m2.lastReleaseAt { releaseMs = seconds(released - ready) * 1000 }
        let rising = zip(percents2, percents2.dropFirst()).allSatisfy { $0 <= $1 } && (percents2.last ?? 0) > (percents2.first ?? 0)
        let replied = m2.messages.last?.status == .done && !(m2.messages.last?.text.isEmpty ?? true)
        PaletteProbe.capture("released.png", dir)
        out["AT-299-release"] = [
            "pass": held2 && rising && releaseMs >= 0 && releaseMs <= 200 && replied,
            "held": held2, "percents": percents2, "readyToReleaseMs": (releaseMs * 10).rounded() / 10, "boundMs": 200,
            "replied": replied, "acceptedInSendPass": ack2.sameFrame,
        ]
        out["AT-299-accept"] = [
            "pass": ack.sameFrame["accepted"] == true && ack.sameFrame["stop"] == true && held
                && percents.count >= 4 && zip(percents, percents.dropFirst()).allSatisfy { $0 <= $1 }
                && captions.allSatisfy { $0 },
            "ack": ack.dict, "percents": percents, "captionOnScreen": captions,
        ]
        out["AT-003-2"] = [
            "pass": statusLine && empty == 0 && samples > 10,
            "loadingModelAtSend": statusLine, "samples": samples, "emptyAssistantSamples": empty,
            "note": "status.loadingModel shows in the send pass (≤ 2 s, NFR-U3); 100 ms samples until the reply is done",
        ]
        return out
    }

    static func write(_ obj: [String: Any], dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }
}
#endif
