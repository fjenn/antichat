// AT-234 in-process Model info probe (M1.T25b). XCUITest is blocked on this Mac (Q-015), so the app drives its own
// window with the real starter model (`-UseScriptedEngine NO -ChatModel chat-0.8b`): 10 turns through the composer
// (turn 5 stopped mid-reply, turn 10 a regenerate of turn 9), then for every assistant row
//   (1) model_id, model_sha, mode, sampling and tok_per_s are non-null (interrupted: tok/s of the partial);
//   (2) the reply's Model info (`ConversationModel.modelInfo`, what ⋯ → Model info shows) equals the row's values,
//       and the menu item is present exactly when Advanced "Show model info" is on (`-showModelInfo YES|NO`).
// The last reply's popover is rendered in a window and captured. Writes `<dir>/probe.json`, quits. DEBUG only
// (`-ModelInfoProbe <dir>`); run by tools/at/at-234-probe.sh.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum ModelInfoProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        FileHandle.standardError.write(Data("ModelInfoProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(1500))
            await run(state, sessions: sessions, dir: dir)
            NSApp.terminate(nil)
        }
    }

    static func write(_ obj: [String: Any], dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
    }

    static func idle(_ state: WindowState, _ sessions: ChatSessions) async -> Bool {
        await PaletteProbe.waitUntil(timeout: 180) {
            guard let m = state.currentChatID.map(sessions.model(for:)) else { return false }
            return !m.isGenerating && m.messages.last?.role == .assistant
                && m.messages.last?.status != .pending && m.messages.last?.status != .streaming
        } != nil
    }

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        let menuShown = ModelInfoSetting.isEnabled()
        var result: [String: Any] = ["menuItemShown": menuShown, "slot": sessions.environment.slot().key]
        guard menuShown else {
            // Off leg: only the ⋯ item's absence is checked (the turns are the on leg's).
            result["pass"] = true
            write(result, dir: dir)
            return
        }
        var turns: [[String: Any]] = []
        var replyIDs: [String] = []
        func noteReply() {
            if let id = state.currentChatID.map(sessions.model(for:))?.messages.last?.id { replyIDs.append(id) }
        }
        for i in 0..<9 {
            sessions.composer.text = i == 4 ? "Write a long story about a lighthouse keeper and the sea."
                : "In one short sentence, say something about the number \(i)."
            guard sessions.composer.send() else { turns.append(["turn": i + 1, "error": "send refused"]); break }
            if i == 4, let m = state.currentChatID.map(sessions.model(for:)) {
                _ = await PaletteProbe.waitUntil(timeout: 120) { m.receivedText(of: m.messages.last?.id ?? "").count > 40 }
                m.stop()
            }
            turns.append(["turn": i + 1, "finished": await idle(state, sessions)])
            noteReply()
        }
        if let m = state.currentChatID.map(sessions.model(for:)), let last = m.messages.last?.id {
            m.regenerate(last)
            turns.append(["turn": 10, "regenerate": true, "finished": await idle(state, sessions)])
            noteReply()
        }
        result["turns"] = turns
        PaletteProbe.window = NSApp.windows.first { $0.isVisible && $0.title == "AntiChat" }
        if PaletteProbe.window != nil { PaletteProbe.capture("conversation.png", dir) }

        guard let chatID = state.currentChatID else {
            result["pass"] = false
            write(result, dir: dir)
            return
        }
        let m = sessions.model(for: chatID)
        let repo = MessageRepository(sessions.environment.database)
        let records = replyIDs.compactMap { (try? repo.message($0)) ?? nil }
        var rows: [[String: Any]] = []
        var allPresent = true, allMatch = true
        for r in records {
            let p = r.provenance
            let present = r.modelID != nil && p?.modelSHA != nil && p?.mode != nil && !(p?.sampling ?? [:]).isEmpty
                && (p?.tokPerS ?? 0) > 0
            let info = m.modelInfo(r.id)
            let matches = info == ModelInfo(modelID: r.modelID, provenance: p)
            allPresent = allPresent && present
            allMatch = allMatch && matches
            func value(_ v: Any?) -> Any { v ?? NSNull() }
            var popover: [String: Any] = [:]
            popover["model"] = value(info?.modelID)
            popover["sha"] = value(info?.shortSHA)
            popover["sampling"] = value(info?.samplingLine)
            popover["tokPerS"] = value(info?.tokPerSText)
            var row: [String: Any] = ["id": r.id, "status": r.status.rawValue]
            row["model_id"] = value(r.modelID)
            row["engine"] = value(r.engine)
            row["model_sha"] = value(p?.modelSHA)
            row["mode"] = value(p?.mode?.rawValue)
            row["sampling"] = value(p?.sampling)
            row["tok_per_s"] = value(p?.tokPerS)
            row["tok_per_s_source"] = value(p?.tokPerSSource)
            row["fieldsPresent"] = present
            row["modelInfoMatchesRow"] = matches
            row["popover"] = popover
            rows.append(row)
        }
        let interrupted = records.filter { $0.status == .interrupted }.count
        result["rows"] = rows
        result["assistantRows"] = records.count
        result["distinctReplies"] = Set(replyIDs).count
        result["interruptedRows"] = interrupted
        result["leg1"] = ["pass": records.count == 10 && Set(replyIDs).count == 10 && interrupted >= 1 && allPresent,
                          "allFieldsPresent": allPresent]
        result["leg2"] = ["pass": allMatch, "modelInfoMatchesEveryRow": allMatch, "menuItemShown": menuShown]

        // The last reply's popover, as ⋯ → Model info shows it.
        if let last = records.last, let info = m.modelInfo(last.id) {
            let host = NSHostingView(rootView: ModelInfoPopover(info: info).background(Color(nsColor: .windowBackgroundColor)))
            let w = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 340, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
            w.title = "Model info"
            w.contentView = host
            w.setContentSize(host.fittingSize)
            BackgroundRun.orderFront(w)
            await PaletteProbe.settle(400)
            PaletteProbe.window = w
            PaletteProbe.capture("model-info-popover.png", dir)
            w.close()
        }
        result["pass"] = (result["leg1"] as? [String: Any])?["pass"] as? Bool == true && allMatch
        write(result, dir: dir)
        FileHandle.standardError.write(Data("ModelInfoProbe: done\n".utf8))
    }
}
#endif
