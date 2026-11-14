// M7.T16 AT-VQ-M7 capture legs + journey 12 in the running app (`-SearchProbe <dir>` with `<dir>/mode` = vq-chat,
// vq-settings, vq-j12 or vq-inject; run by tools/visual/vq-m7.sh). XCUITest cannot start on this Mac (Q-015), so the
// app drives its own windows like SearchProbe and captures each screen at 1440×900 under the system Light and Dark
// appearance (NSApp.appearance). Visual-QA capture is the one exception to the no-focus-steal rule: the app is
// activated so sheets and popovers are drawn on screen (a sheet is captured as the region of its parent window).
//   vq-chat      (web-search.jsonl, -ScriptedWebSearch YES) chip → answer with citation pills (hard check: every pill
//                is a fetched source; pill rows recorded for the line-break check),
//                Sources panel, web search consent sheet (S-24), Offline chip (S-25).
//   vq-settings  (-ScriptedMCP scripted-server.jsonl) Settings → Tools page, Web search rows (Search sub-page),
//                Connections + Composio (Cloud badge), add-server sheet → MCP consent sheet → Allow, Skills.
//   vq-j12       (mcp-send-message.jsonl, -ScriptedMCP) journey 12: the ApprovalCard for a connection's write call;
//                Deny (not sent), Allow once (sent, asks again next time), Always allow (sent), then no card.
//   vq-inject    (web-inject.jsonl, -ScriptedWebSearch YES, -ScriptedMCP) the untrusted ApprovalCard variant.
// Writes `<dir>/probe.json` (+ PNGs). DEBUG only.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatTools
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum VisualQAM7 {
    static var dir: URL!
    static var shots: [[String: Any]] = []

    static func run(_ mode: String, _ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow, _ out: URL) async -> [String: Any] {
        dir = out
        window.setFrame(CGRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        NSApp.activate(ignoringOtherApps: true)  // VQ capture exception (sheets must be on screen)
        window.makeKeyAndOrderFront(nil)
        await settle(1200)
        var r: [String: Any]
        switch mode {
        case "vq-chat": r = await chat(state, sessions, window)
        case "vq-settings": r = await settings(window)
        case "vq-j12": r = await journey12(state, sessions, window)
        case "vq-inject": r = await inject(state, sessions, window)
        default: r = ["error": "unknown mode \(mode)", "pass": false]
        }
        r["shots"] = shots
        return r
    }

    static func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// One capture per appearance. `region`: the window's frame on screen (includes its sheet / popover).
    static func both(_ window: NSWindow?, _ name: String, region: Bool = false, looks: [String] = VisualQAProbe.looks) async {
        FileHandle.standardError.write(Data("VisualQAM7: capture \(name)\n".utf8))
        guard let window else { shots.append(["name": name, "error": "no window"]); return }
        let saved = VisualQAProbe.currentLook
        for look in looks {
            VisualQAProbe.setLook(look, restore: saved)  // the app's own Color mode (M10 harness issue 3)
            window.orderFrontRegardless()
            await settle(900)
            let file = dir.appendingPathComponent("\(name)-\(look).png")
            var args = ["-x", "-o"]
            if region, let screen = NSScreen.screens.first {
                let f = window.frame
                let y = screen.frame.height - (f.origin.y + f.height)
                args += ["-R", "\(Int(f.origin.x)),\(Int(y)),\(Int(f.width)),\(Int(f.height))"]
            } else {
                args += ["-l", "\(window.windowNumber)"]
            }
            let rc = VisualQAProbe.screencapture(args + [file.path])
            var e: [String: Any] = ["name": "\(name)-\(look)", "size": "\(Int(window.frame.width))x\(Int(window.frame.height))",
                                    "region": region, "rc": rc]
            if let img = NSImage(contentsOf: file) { e["black"] = OnboardingProbe.isBlack(img) }
            shots.append(e)
        }
        VisualQAProbe.setLook(nil, restore: saved)
        await settle(300)
    }

    static func present(_ id: String) -> Bool { SettingsProbe.present(id) }

    /// The control's accessibility press (what VoiceOver's VO-Space does), when a synthetic click did not land.
    static func axPress(_ id: String) -> Bool {
        func find(_ e: Any, depth: Int) -> NSAccessibilityProtocol? {
            guard depth < 60, let el = e as? NSAccessibilityProtocol else { return nil }
            if el.accessibilityIdentifier() == id, el.accessibilityRole() == .button { return el }
            for c in el.accessibilityChildren() ?? [] { if let f = find(c, depth: depth + 1) { return f } }
            return nil
        }
        for w in NSApp.windows where w.isVisible {
            if let v = w.contentView, let el = find(v, depth: 0) { return el.accessibilityPerformPress() }
        }
        return false
    }

    /// Click the button `id` until `done`; falls back to its accessibility press.
    /// (A direct click only: the tracking delivery can leave a SwiftUI link-style button's mouse-down loop waiting for
    /// an up event that was already consumed, which blocks the main thread.)
    static var tapNotes: [String] = []

    static func tap(_ id: String, until done: () -> Bool) async -> (Bool, String) {
        diag(id)
        // R65: `VQ_EXTERNAL_AX=<dir>` hands the press to an outside accessibility client (tools/visual/axdrive press,
        // what VoiceOver's VO-Space sends): the probe writes `<dir>/ax-ready` with the id and waits for the answer. The
        // in-process accessibility press below cannot stand in for it (SwiftUI builds its tree only for a live client).
        if let ext = ProcessInfo.processInfo.environment["VQ_EXTERNAL_AX"] {
            let ready = URL(fileURLWithPath: ext).appendingPathComponent("ax-ready")
            try? Data(id.utf8).write(to: ready)
            let ok = await SettingsProbe.waitUntil(timeout: 20, done)
            try? FileManager.default.removeItem(at: ready)
            if ok { return (true, "externalAXPress") }
        }
        SettingsProbe.click(id, tracking: false)
        if await SettingsProbe.waitUntil(timeout: 2, done) { return (true, "click") }
        _ = axPress(id)
        return (await SettingsProbe.waitUntil(timeout: 3, done), "accessibilityPress")
    }

    static func diag(_ id: String) {
        if let w = SettingsProbe.window(with: id) {
            let fs = UIProbeRegistry.frames(id, in: w)
            let p = fs.first.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
            let hit = w.contentView?.superview?.hitTest(p) ?? w.contentView?.hitTest(p)
            var over: [String] = []
            for (aid, views) in UIProbeRegistry.anchorViews {
                for v in views {
                    guard v.window === w, v.convert(v.bounds, to: nil).contains(p), let host = v.superview else { continue }
                    let hp = host.superview.map { host.convert(host.convert(p, from: nil), to: $0) } ?? p
                    let ans = host.hitTest(hp)
                    over.append("\(aid) host=\(type(of: host)) subs=\(host.subviews.count) hidden=\(v.isHidden) ans=\(ans.map { "\(type(of: $0))" } ?? "nil")")
                }
            }
            if let h = hit, String(describing: type(of: h)).contains("ProbeAnchor") {
                let ids = h.subviews.compactMap { s in UIProbeRegistry.anchorViews.first { $0.value.contains { $0 === s } }?.key }
                over.append("HIT host subs=\(h.subviews.map { "\(type(of: $0))" }) ids=\(ids) frame=\(h.convert(h.bounds, to: nil))")
            }
            tapNotes.append("\(id): over=\(over)")
            tapNotes.append("\(id): frames=\(fs.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }) key=\(w.isKeyWindow) main=\(w.isMainWindow) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") windows=\(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" })")
        }
    }

    // MARK: vq-chat (S-10, S-24 search consent, S-25)

    static func chat(_ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow) async -> [String: Any] {
        var r: [String: Any] = [:]
        guard let web = SearchProbe.webItem(sessions), web.state == .enabled else { return ["error": "no Web search row", "pass": false] }
        sessions.composer.menus.pickAdd(web)
        await settle(300)
        await both(window, "s10-chip-on")
        _ = await SearchProbe.send("What's the latest macOS version?", sessions)
        // VQ-M11 S-10: the Searching state (the runner holds the scripted search, ANTICHAT_SCRIPTED_SEARCH_HOLD_MS).
        r["searchingState"] = await SettingsProbe.waitUntil(timeout: 8) {
            SearchProbe.last(state, sessions)?.activities.contains { $0.tool == "web_search" && $0.state == .running } == true
        }
        if r["searchingState"] as? Bool == true { await both(window, "s10-searching") }
        _ = await SearchProbe.waitIdle(state, sessions)
        await settle(1200)
        guard let m = SearchProbe.last(state, sessions) else { return ["error": "no reply", "pass": false] }
        let fetched = Set(m.sources.filter(\.fetched).map(\.n))
        // Pill anchors are `citation.<n>` or `citation.<n>,<m>` (a merged marker).
        var pillIDs: [String] = []
        for n in 1...9 {
            if present("citation.\(n)") { pillIDs.append("\(n)") }
            for k in (n + 1)...10 where present("citation.\(n),\(k)") { pillIDs.append("\(n),\(k)") }
        }
        let pills = Array(Set(pillIDs.flatMap { $0.split(separator: ",").compactMap { Int($0) } })).sorted()
        r["sources"] = m.sources.map(\.n)
        r["fetched"] = fetched.sorted()
        r["pills"] = pills
        // Hard check (AT-VQ-M7): zero citation pills without a fetched source.
        r["pillsWithoutFetchedSource"] = pills.filter { !fetched.contains($0) }
        // Pill line break (A-M7-T03a d): a pill must not push the rest of its paragraph onto a new line. Pills sit at
        // the end of their line (CitationPill.pillsAtLineEnd), so every pill shares the row of the reply's last text
        // line: their rows are recorded and checked on the s10-answer-pills captures (PillLineBreakTests measures it).
        let frames = pillIDs.compactMap { id in UIProbeRegistry.frame("citation.\(id)", in: window).map { (id, $0) } }
        r["pillFrames"] = frames.map { ["id": $0.0, "x": Int($0.1.minX), "y": Int($0.1.minY), "h": Int($0.1.height)] }
        r["pillRows"] = Set(frames.map { Int(($0.1.midY / 4).rounded()) }).count
        await both(window, "s10-answer-pills")
        diag("sourcesButton")
        let clicked = PaletteProbe.click("sourcesButton")
        await settle(1200)
        let rows = SearchProbe.rowsOnScreen()
        r["tapNotes"] = tapNotes
        r["sourcesButton"] = clicked
        r["panelRows"] = rows
        r["pillsMatchPanel"] = Set(pills).isSubset(of: Set(rows)) && Set(rows) == fetched
        await both(window, "s10-sources-panel")
        _ = PaletteProbe.click("sourcesButton")
        await settle(500)
        // Web search consent (S-24): search off, the + row asks.
        state.newChat()
        await settle(800)
        let policy = NetworkPolicyStore.shared
        policy.setEnabled(.search, false)
        await settle(400)
        if let w = SearchProbe.webItem(sessions) { sessions.composer.menus.pickAdd(w) }
        r["consentSheet"] = await SettingsProbe.waitUntil(timeout: 5) { present("search.consentSheet") }
        await both(window, "s24-consent-websearch", region: true)
        WebSearchConsent.shared.answer(true)
        await settle(600)
        // Offline only → the chip reads Offline (S-25).
        policy.offlineOnly = true
        await settle(600)
        r["offlineChip"] = present("toolChipOffline.web")
        await both(window, "s25-offline-chip")
        policy.offlineOnly = false
        r["pass"] = (r["pillsWithoutFetchedSource"] as? [Int])?.isEmpty == true && !pills.isEmpty
            && r["pillsMatchPanel"] as? Bool == true && r["consentSheet"] as? Bool == true
        return r
    }

    // MARK: vq-settings (S-21 §7, §8; S-24 MCP / Composio consent)

    static func settings(_ main: NSWindow) async -> [String: Any] {
        var r: [String: Any] = [:]
        SettingsProbe.main = main
        r["opened"] = await SettingsProbe.openSettingsWithCommandComma()
        guard let sw = SettingsProbe.settingsWindow else { return ["error": "no Settings window", "pass": false] }
        sw.setFrame(CGRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        NSApp.activate(ignoringOtherApps: true)
        sw.makeKeyAndOrderFront(nil)
        let model = SettingsModel.shared
        model.open(.tools)
        await settle(1500)
        r["toolsPage"] = present("settings.detail.tools")
        await both(sw, "s21-tools-page")
        // VQ (S-21 Tools): the reveal highlight lasts 2.5 s; one reveal per look so the dark shot shows it too (it
        // had faded before the second capture).
        for look in VisualQAProbe.looks {
            model.highlightedRow = nil
            await settle(200)
            r["searchRows"] = await SettingsProbe.reveal("webSearch", in: .tools, control: "settings.row.webSearch") || present("settings.row.safeSearch")
            await settle(300)
            await both(sw, "s21-search-subpage", looks: [look])
        }
        model.open(.tools, row: "connections")
        await settle(1500)
        r["composioSection"] = present("connections.composio")
        await both(sw, "s21-connections-composio")
        // [Add an MCP server] → the add sheet (URL typed like the keyboard) → Next (dry tools/list on the scripted
        // server) → the MCP consent sheet → Allow.
        r["addSheet"] = await SettingsProbe.press("connections.add") { present("connections.check") }
        if r["addSheet"] as? Bool == true {
            _ = SettingsProbe.click("connections.url", at: 0.5, tracking: true)
            await settle(300)
            if let sheet = SettingsProbe.window(with: "connections.url") {
                await SettingsProbe.type("https://chat.example/mcp", in: sheet)
            }
            await settle(400)
            await both(sw, "s21-connections-add-sheet", region: true)
            _ = await SettingsProbe.press("connections.check") { present("mcpConsent") }
            r["mcpConsent"] = await SettingsProbe.waitUntil(timeout: 10) { present("mcpConsent") }
            await both(sw, "s24-consent-mcp", region: true)
            _ = await SettingsProbe.press("mcpConsent.allow") { !present("mcpConsent") }
            await settle(1500)
            r["serverAdded"] = !present("connections.empty")
            await both(sw, "s21-connections-added")
        }
        // Composio [Connect] is not pressed here: with the Debug relay endpoint it starts the real relay sign-up
        // (install ID in the Keychain, relay calls), which blocks this unattended run. The Composio section (tiles,
        // Cloud badge) is captured above; its consent sheet is covered by the AT-255 c3 client legs (pending XCUITest).
        r["composioConsent"] = "not pressed (relay path, see header)"
        FileHandle.standardError.write(Data("VisualQAM7: skills\n".utf8))
        model.open(.skills)
        await settle(1500)
        r["skillsPage"] = present("settings.detail.skills")
        await both(sw, "s21-skills")
        r["pass"] = ["toolsPage", "composioSection", "addSheet", "mcpConsent", "skillsPage"].allSatisfy { r[$0] as? Bool == true }
        return r
    }

    // MARK: vq-j12 journey 12 (S-24 ApprovalCard)

    static func addTeamChat() async -> Bool {
        guard let host = MCPTools.host else { return false }
        guard let s = try? await host.add(name: "Team Chat", url: URL(string: "https://chat.example/mcp")!, auth: .none) else { return false }
        await host.connect(s.id, acceptListed: true)
        await settle(800)
        return await host.isConnected(s.id)
    }

    /// One send in a new chat; answers the card with `button` (nil: expect no card). Returns what happened.
    static func ask(_ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow, _ button: String?, capture: String? = nil) async -> [String: Any] {
        state.newChat()
        await settle(800)
        _ = await SearchProbe.send("Tell the team hi.", sessions)
        let card = await SettingsProbe.waitUntil(timeout: 15) { present("approvalCard") }
        var r: [String: Any] = ["card": card]
        if card {
            r["buttons"] = ["approveAllowOnce", "approveAlways", "approveDeny"].allSatisfy(present)
            if let capture { await both(window, capture) }
            if let button {
                let (ok, how) = await tap(button) { !present("approvalCard") }
                r["clicked"] = ok; r["via"] = how
            }
        }
        _ = await SearchProbe.waitIdle(state, sessions, timeout: 60)
        await settle(600)
        let m = SearchProbe.last(state, sessions)
        let step = m?.activities.first { $0.kind == .tool }
        r["stepState"] = step.map { "\($0.state)" } ?? "none"
        r["status"] = m.map { "\($0.status)" } ?? "none"
        r["answer"] = m?.text ?? ""
        return r
    }

    static func journey12(_ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow) async -> [String: Any] {
        var r: [String: Any] = ["serverConnected": await addTeamChat()]
        let deny = await ask(state, sessions, window, "approveDeny", capture: "s24-approval-card")
        let once = await ask(state, sessions, window, "approveAllowOnce")
        let onceAgain = await ask(state, sessions, window, "approveAlways")
        let after = await ask(state, sessions, window, nil, capture: "j12-after-always")
        await both(window, "j12-used-team-chat")
        r["deny"] = deny; r["allowOnce"] = once; r["always"] = onceAgain; r["afterAlways"] = after
        r["tapNotes"] = tapNotes
        let done = { (x: [String: Any]) in (x["stepState"] as? String) == "done" }
        r["pass"] = r["serverConnected"] as? Bool == true
            && deny["card"] as? Bool == true && deny["buttons"] as? Bool == true && !done(deny)
            && once["card"] as? Bool == true && done(once)
            && onceAgain["card"] as? Bool == true && done(onceAgain)  // Allow once asks again next time
            && after["card"] as? Bool == false && done(after)          // Always allow: no card
        return r
    }

    // MARK: vq-inject (untrusted ApprovalCard)

    /// The reply's tool lines (name, state, the start of the tool result: a "no tool named …" result lists what was
    /// offered), so a leg that shows no card says why.
    static func steps(_ m: ConversationModel.Message?) -> [[String: String]] {
        (m?.activities ?? []).filter { $0.kind == .tool }.map {
            ["tool": $0.tool, "state": "\($0.state)", "result": String(($0.result ?? "").prefix(240))]
        }
    }

    /// R2 (M9.T08 residual): the scripted `web_search` and `team_chat_send_message` calls both failed at M7 and M9 with
    /// "no tool named …" — the runner set Tool access to "Always offer all", which on the leg's T1 is bounded by the
    /// 1200-token schema cap (tier-budgets.json) and keeps tools in name order, so the file tools filled the cap and both
    /// calls named tools that were not offered. The leg now asks like a user: the Web search chip (the forced tool is
    /// pinned, never cut) and the default "Load tools when needed", on a T3 profile (`-FakeHardware T3` in the runner)
    /// whose per-step budget holds the connection's tools. The capture is the card with the untrusted line; Deny must
    /// leave the send not run.
    static func inject(_ state: WindowState, _ sessions: ChatSessions, _ window: NSWindow) async -> [String: Any] {
        var r: [String: Any] = ["serverConnected": await addTeamChat()]
        r["toolAccess"] = ToolSwitches.shared.access.rawValue
        state.newChat()
        await settle(800)
        guard let web = SearchProbe.webItem(sessions), web.state == .enabled else { return ["error": "no Web search row", "pass": false] }
        sessions.composer.menus.pickAdd(web)
        await settle(300)
        _ = await SearchProbe.send("Read the tips page and tell the team.", sessions)
        r["card"] = await SettingsProbe.waitUntil(timeout: 30) { present("approvalCard") }
        r["untrustedLine"] = present("approvalUntrusted")
        // VQ-M10 S-24: an untrusted request offers Allow once / Deny only (no lasting Always allow).
        r["buttons"] = ["approveAllowOnce", "approveDeny"].allSatisfy(present) && !present("approveAlways")
        r["stepsAtCard"] = steps(SearchProbe.last(state, sessions))
        await both(window, "s24-approval-untrusted")
        if r["card"] as? Bool == true {
            let (ok, how) = await tap("approveDeny") { !present("approvalCard") }
            r["denied"] = ok; r["via"] = how
            r["tapNotes"] = tapNotes
        }
        _ = await SearchProbe.waitIdle(state, sessions, timeout: 60)
        await settle(600)
        let after = steps(SearchProbe.last(state, sessions))
        r["steps"] = after
        let send = after.first { $0["tool"]?.hasSuffix("send_message") == true }
        r["sendState"] = send?["state"] ?? "none"
        // VQ-M10 S-24: after Deny the reply is the templated tool.denied.reply, never the script's "Done.".
        let answer = SearchProbe.last(state, sessions)?.text ?? ""
        r["answer"] = answer
        await both(window, "s24-approval-untrusted-denied")
        r["pass"] = r["card"] as? Bool == true && r["untrustedLine"] as? Bool == true && r["buttons"] as? Bool == true
            && after.first?["tool"] == "web_search" && after.first?["state"] == "done" && send?["state"] == "denied"
            && answer == CopyKey("tool.denied.reply").string()
        return r
    }
}
#endif
