// AT-302 in-process draft probe (M1.T21). XCUITest is blocked on this Mac (Q-015), so — like the other probes — the
// app drives its own window: characters go into the real composer (ComposerModel → LiveComposer → DraftBinding →
// DraftStore → the on-disk `draft` table of `-ANTICHAT_DEV_CONTAINER`), and two launches on the same container check
// the restore. `<dir>/mode` (written by tools/at/at-302-probe.sh) picks the leg:
//   switch  one launch: two chats, a draft (text + 12k-char paste card) in each, switch back and forth, restored each
//           time; `draft.updated_at − last keystroke` ≤ 1 s; send clears the row.
//   quit    launch 1 types, then quits at once (NSApp.terminate → willTerminate flush, ⌘Q path); launch 2 restores.
//   crash   launch 1 types, waits 1.2 s after the last keystroke, then SIGKILLs itself; launch 2 restores.
// Launch 1 writes `<dir>/typed.json`; launch 2 (typed.json present) writes `<dir>/probe.json` and quits.
// DEBUG only (`-DraftProbe <dir>`).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatUI
import AppKit
import Darwin
import SwiftUI

@MainActor
enum DraftProbe {
    private static var started = false
    static let card = String(repeating: "pasted card line\n", count: 750)  // 12,750 characters → a paste card

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        FileHandle.standardError.write(Data("DraftProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(1500))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }) {
                PaletteProbe.window = window
                BackgroundRun.makeKeyAndOrderFront(window)
            }
            let mode = (try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "switch"
            let typed = dir.appendingPathComponent("typed.json")
            if mode == "switch" {
                await runSwitch(state, sessions: sessions, dir: dir)
            } else if FileManager.default.fileExists(atPath: typed.path) {
                await verifyRelaunch(sessions: sessions, dir: dir, mode: mode)
            } else {
                await typeAndLeave(sessions: sessions, dir: dir, mode: mode)
            }
            NSApp.terminate(nil)
        }
    }

    static func write(_ obj: [String: Any], _ name: String = "probe.json", dir: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name))
        }
    }

    /// Types like the keyboard does: one composer change per character.
    static func type(_ text: String, _ sessions: ChatSessions) async -> Date {
        for ch in text {
            sessions.composer.text.append(ch)
            await PaletteProbe.settle(25)
        }
        return Date()
    }

    static func row(_ key: String, _ sessions: ChatSessions) -> DraftRecord? {
        try? DraftRepository(sessions.environment.database).draft(chatID: key)
    }

    /// Launch 1 of quit / crash: type into the new chat (+ a paste card), then leave.
    static func typeAndLeave(sessions: ChatSessions, dir: URL, mode: String) async {
        let text = "draft before \(mode)"
        _ = sessions.composer.handlePaste(card)
        await PaletteProbe.settle(100)
        let last = await type(text, sessions)
        write(["mode": mode, "text": text, "lastKeystroke": last.timeIntervalSince1970, "pid": getpid()],
              "typed.json", dir: dir)
        if mode == "crash" {
            try? await Task.sleep(for: .milliseconds(1200))
            let onDisk = row(DraftRecord.newChatKey, sessions)
            var before: [String: Any] = ["rowBeforeKill": onDisk?.text ?? "nil"]
            before["updatedAt"] = onDisk?.updatedAt.timeIntervalSince1970 ?? -1
            write(before, "before-kill.json", dir: dir)
            kill(getpid(), SIGKILL)
        }
        // quit: terminate right away (inside the 500 ms debounce): the willTerminate flush must write it.
    }

    /// Launch 2: the window opened on the new chat; its composer shows the draft and the card.
    static func verifyRelaunch(sessions: ChatSessions, dir: URL, mode: String) async {
        let typed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("typed.json")))) as? [String: Any] ?? [:]
        let expected = typed["text"] as? String ?? ""
        let restored = await PaletteProbe.waitUntil(timeout: 5) { sessions.composer.text == expected } != nil
        PaletteProbe.capture("relaunch.png", dir)
        let r = row(DraftRecord.newChatKey, sessions)
        let cards = sessions.composer.attachments.compactMap(\.pastedText)
        let last = typed["lastKeystroke"] as? Double ?? 0
        let lag = r.map { $0.updatedAt.timeIntervalSince1970 - last }
        var pass = restored && cards == [card] && r?.text == expected
        if mode == "crash" { pass = pass && (lag ?? 99) <= 1.0 }
        var out: [String: Any] = ["mode": mode, "pass": pass, "composerText": sessions.composer.text, "expected": expected]
        out["cardRestored"] = cards == [card]
        out["rowText"] = r?.text ?? "nil"
        out["updatedAtMinusLastKeystroke"] = lag ?? -1
        write(out, dir: dir)
    }

    /// One launch: two chats, a draft in each, switch back and forth.
    static func runSwitch(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        var result: [String: Any] = ["mode": "switch"]
        do {
            let a = try state.service.create(firstPrompt: "Chat A")
            try state.service.appendUserMessage(a.id, text: "Chat A")
            let b = try state.service.create(firstPrompt: "Chat B")
            try state.service.appendUserMessage(b.id, text: "Chat B")
            state.open(.chat(a.id))
            await PaletteProbe.settle(300)
            let lastA = await type("unsent in A", sessions)
            state.open(.chat(b.id))
            let bEmpty = await PaletteProbe.waitUntil(timeout: 3) { sessions.composer.text.isEmpty } != nil
            _ = sessions.composer.handlePaste(card)
            let lastB = await type("unsent in B", sessions)
            state.open(.chat(a.id))
            let aBack = await PaletteProbe.waitUntil(timeout: 3) { sessions.composer.text == "unsent in A" } != nil
            let aNoCard = sessions.composer.attachments.isEmpty
            PaletteProbe.capture("chat-a.png", dir)
            state.open(.chat(b.id))
            let bBack = await PaletteProbe.waitUntil(timeout: 3) { sessions.composer.text == "unsent in B" } != nil
            let bCard = sessions.composer.attachments.compactMap(\.pastedText) == [card]
            PaletteProbe.capture("chat-b.png", dir)
            _ = await PaletteProbe.waitUntil(timeout: 3) { row(a.id, sessions) != nil && row(b.id, sessions) != nil }
            let ra = row(a.id, sessions), rb = row(b.id, sessions)
            let lagA = ra.map { $0.updatedAt.timeIntervalSince(lastA) } ?? 99
            let lagB = rb.map { $0.updatedAt.timeIntervalSince(lastB) } ?? 99
            // Send from B clears its draft.
            sessions.composer.restoreDraft(text: "sent now", attachments: [])
            await PaletteProbe.settle(100)
            let sent = sessions.composer.send()
            _ = await PaletteProbe.waitUntil(timeout: 20) { !(sessions.current?.isGenerating ?? true) }
            await PaletteProbe.settle(900)
            let clearedOnSend = row(b.id, sessions) == nil
            let restoredOK = bEmpty && aBack && aNoCard && bBack && bCard
            let rowsOK = ra?.text == "unsent in A" && rb?.text == "unsent in B" && lagA <= 1.0 && lagB <= 1.0
            result["pass"] = restoredOK && rowsOK && sent && clearedOnSend
            result["bStartsEmpty"] = bEmpty
            result["aRestored"] = aBack
            result["aNoCard"] = aNoCard
            result["bRestored"] = bBack
            result["bCardRestored"] = bCard
            result["rowA"] = ra?.text ?? "nil"
            result["rowB"] = rb?.text ?? "nil"
            result["lagA"] = lagA
            result["lagB"] = lagB
            result["sendAccepted"] = sent
            result["clearedOnSend"] = clearedOnSend
        } catch {
            result["error"] = "\(error)"
            result["pass"] = false
        }
        write(result, dir: dir)
    }
}
#endif
