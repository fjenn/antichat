// AT-001 in-process window probe (M1.T07). XCUITest cannot start on this Mac (Q-015: automation mode needs an
// interactive authorisation), so — like M0's SpikeProbe — the app measures itself: every `probeID` element (the
// identifiers XCUITest queries) carries a DEBUG AppKit anchor whose live window frame the probe reads
// (UIProbeRegistry; SwiftUI builds no accessibility tree without an AX client, so the AX tree is not readable
// in-process), clicks are synthesised mouse events sent to the window, and the results go to `<dir>/probe.json`
// plus window captures. `WindowLayoutTests` / `SidebarChatManagementTests` assert the
// same legs once automation mode is enabled. DEBUG only (`-UIProbe <dir>`, M1.md convention 10).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatHarness
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum WindowProbe {
    private static var started = false

    static func start(_ state: WindowState, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("WindowProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    // MARK: Geometry (window coordinates, origin bottom-left)

    struct Node { var frame: CGRect }

    static func find(_ window: NSWindow, _ id: String) -> Node? {
        UIProbeRegistry.frame(id, in: window).map { Node(frame: $0) }
    }

    static func ids(_ window: NSWindow, prefix: String) -> [String] { UIProbeRegistry.ids(prefix: prefix, in: window) }

    /// A real click: mouse down + up at the centre of `id`, sent through the window's event dispatch.
    @discardableResult
    static func click(_ window: NSWindow, _ id: String) -> Bool {
        guard let f = UIProbeRegistry.frame(id, in: window) else { return false }
        let p = CGPoint(x: f.midX, y: f.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(e)
        }
        return true
    }

    static func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Waits until `cond` holds (polling every 10 ms) and returns the elapsed seconds, or nil on timeout.
    static func waitUntil(timeout: Double = 2, _ cond: () -> Bool) async -> Double? {
        let start = ContinuousClock.now
        while true {
            if cond() { return seconds(ContinuousClock.now - start) }
            if seconds(ContinuousClock.now - start) > timeout { return nil }
            await settle(10)
        }
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Captures this app's own window only (`screencapture -l <window id>`, so the macOS 26 glass sidebar is
    /// included); falls back to `cacheDisplay` (which misses the sidebar glass layer) if screencapture fails.
    static func capture(_ window: NSWindow, to url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) { return }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The transcript's NSScrollView: the scroll view whose document is tallest.
    static func transcriptScrollView(_ window: NSWindow) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView,
               doc.frame.height > (best?.documentView?.frame.height ?? 0), s.frame.minX > 200 || s.frame.width > 500 {
                best = s
            }
            v.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return best
    }

    // MARK: Run

    static func run(_ state: WindowState, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var legs: [String: [String: Any]] = [:]
        var notes: [String] = []
        await settle(1500)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }) else {
            write(["error": "no AntiChat window", "windows": NSApp.windows.map { "\($0.title) visible=\($0.isVisible)" }],
                  dir: dir)
            return
        }
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        await settle(600)
        capture(window, to: dir.appendingPathComponent("S-05-empty-light.png"))

        // Leg 1: sidebar 260 ± 1, collapsible, auto-collapse < 900, no icon rail / product switcher.
        do {
            let sidebar = find(window, "sidebar")
            let width = sidebar?.frame.width ?? -1
            state.toggleSidebar()
            let collapsedAfter = await waitUntil { (find(window, "sidebar")?.frame.width ?? 0) < 1 }
            state.toggleSidebar()
            let reopened = await waitUntil { abs((find(window, "sidebar")?.frame.width ?? 0) - 260) <= 1 }
            window.setFrame(CGRect(x: 80, y: 80, width: 860, height: 820), display: true)
            let narrowCollapsed = await waitUntil { (find(window, "sidebar")?.frame.width ?? 0) < 1 }
            capture(window, to: dir.appendingPathComponent("MainWindow-narrow.png"))
            window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
            let restored = await waitUntil { abs((find(window, "sidebar")?.frame.width ?? 0) - 260) <= 1 }
            let allIDs = Set(ids(window, prefix: ""))
            let forbidden = allIDs.filter { $0.localizedCaseInsensitiveContains("iconRail")
                || $0.localizedCaseInsensitiveContains("productSwitcher") }
            let pass = abs(width - 260) <= 1 && collapsedAfter != nil && reopened != nil && narrowCollapsed != nil
                && restored != nil && forbidden.isEmpty
            legs["1-sidebar"] = ["pass": pass, "sidebarWidth": width, "collapsed": collapsedAfter != nil,
                                 "reopened": reopened != nil, "autoCollapseUnder900": narrowCollapsed != nil,
                                 "restoredAt1180": restored != nil, "forbiddenIDs": Array(forbidden)]
        }

        // Leg 2: toolbar contents and centred title.
        do {
            let required = ["sidebarToggle", "navBack", "navForward", "toolbarTitle", "chatMoreMenu"]
            let present = Dictionary(uniqueKeysWithValues: required.map { id in (id, find(window, id) != nil) })
            let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .allSatisfy { window.standardWindowButton($0).map { !$0.isHidden } ?? false }
            // The title re-centres after toolbar relayout (WindowCentered); wait for it to settle (≤ 1.5 s).
            let settleSeconds = await waitUntil(timeout: 1.5) {
                abs((find(window, "toolbarTitle")?.frame.midX ?? 0) - window.frame.width / 2) <= 2
            }
            let title = find(window, "toolbarTitle")?.frame ?? .zero
            let offset = abs(title.midX - window.frame.width / 2)
            let pass = present.values.allSatisfy { $0 } && lights && offset <= 2
            legs["2-toolbar"] = ["pass": pass, "present": present, "trafficLights": lights,
                                 "titleCentreOffsetPt": offset, "titleSettleSeconds": settleSeconds ?? -1, "titleFrame": "\(title)",
                                 "windowFrame": "\(window.frame)"]
        }

        // Leg 3a: headline from empty.headline.1…5, ≥ 5 distinct over seeds 1…30; composer centred ±10 %.
        do {
            let allowed = Set(EmptyHeadline.keys.map { $0.string() })
            var seen: [String] = []
            for seed in UInt64(1)...30 {
                state.newChat(seed: seed)
                await settle(30)
                seen.append(find(window, "emptyHeadline") != nil ? state.headline.string() : "")
            }
            let distinct = Set(seen)
            let composer = find(window, "composer")?.frame ?? .zero
            let column = find(window, "chatColumn")?.frame ?? .zero
            let dy = abs(composer.midY - column.midY)
            let pass = distinct.isSubset(of: allowed) && distinct.count >= 5 && column.height > 0
                && dy <= 0.1 * column.height
            legs["3a-headline-centre"] = ["pass": pass, "distinct": Array(distinct).sorted(), "count": distinct.count,
                                         "composerMidY": composer.midY, "columnMidY": column.midY,
                                         "offsetFraction": column.height > 0 ? dy / column.height : -1]
        }

        // Leg 4: ≤ 4 suggestions from the enabled packs' lists; a click fills the composer (no send).
        do {
            state.newChat(seed: 7)
            await settle(100)
            let cards = ids(window, prefix: "suggestion.")
            let allowed = Set(SuggestionProvider.catalog.filter { state.enabledPacks.contains($0.key) }
                .flatMap(\.value).map(\.id))
            let keys = cards.map { String($0.dropFirst("suggestion.".count)) }
            var filled = false
            var expected = ""
            if let first = cards.first, let s = state.suggestions.first(where: { "suggestion.\($0.id)" == first }) {
                expected = s.text
                click(window, first)
                filled = await waitUntil { state.composerText == s.text } != nil
            }
            let stillNew = state.route == .newChat
            let pass = !cards.isEmpty && cards.count <= 4 && Set(keys).isSubset(of: allowed) && filled && stillNew
            legs["4-suggestions"] = ["pass": pass, "count": cards.count, "keys": keys, "filledComposer": filled,
                                     "expectedText": expected, "notSent": stillNew,
                                     "network": "checked outside the app (sandbox-exec deny network-outbound)"]
        }

        // Leg 3b: first send docks the composer at the bottom in ≤ 300 ms (signpost composerDock).
        do {
            state.composerText = "Hello there"
            state.send(state.composerText)
            let docked = await waitUntil { state.lastDockDuration != nil }
            await settle(400)
            let composer = find(window, "composer")?.frame ?? .zero
            let column = find(window, "chatColumn")?.frame ?? .zero
            // AX frames are screen coordinates (origin bottom-left): the composer's minY is near the column's minY.
            let gapToBottom = composer.minY - column.minY
            let d = state.lastDockDuration ?? -1
            let pass = docked != nil && d <= 0.3 && d >= 0 && gapToBottom >= 0 && gapToBottom <= 64
            legs["3b-dock"] = ["pass": pass, "dockSeconds": d, "composerGapToColumnBottomPt": gapToBottom]
            capture(window, to: dir.appendingPathComponent("S-08-docked-light.png"))
        }

        // Leg 5: disclaimer under the docked composer.
        do {
            let disc = find(window, "composerDisclaimer")
            let composer = find(window, "composer")?.frame ?? .zero
            let below = (disc?.frame.maxY ?? .infinity) <= composer.minY + 1
            let text = disc != nil ? CopyKey("composer.disclaimer").string() : ""
            let pass = disc != nil && below && text == CopyKey("composer.disclaimer").string()
            legs["5-disclaimer"] = ["pass": pass, "text": text, "belowComposer": below]
        }

        // Leg 6: StartSeparator at the top; scroll up 500 pt → JumpToBottom; click → bottom, hidden.
        do {
            let separator = find(window, "startSeparator") != nil
            // A long conversation (60 messages) so the transcript can scroll.
            var chatID = ""
            if let chat = try? state.service.create(title: "Long conversation") {
                chatID = chat.id
                for i in 0..<30 {
                    _ = try? state.service.appendUserMessage(chat.id, text: "Question \(i + 1): how does this work?")
                    _ = try? state.service.appendAssistantMessage(chat.id, text: String(
                        repeating: "Answer \(i + 1) explains it in a few sentences of plain text. ", count: 4))
                }
            }
            state.open(.chat(chatID))
            await settle(800)
            var detachedShown = false
            var returned = false
            var hiddenAfter = false
            var scrollInfo = ""
            if let sv = transcriptScrollView(window), let doc = sv.documentView {
                let clip = sv.contentView
                let y0 = clip.bounds.origin.y
                let newY = doc.isFlipped ? max(0, y0 - 500) : y0 + 500
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
                sv.reflectScrolledClipView(clip)
                scrollInfo = "flipped=\(doc.isFlipped) y0=\(y0) y1=\(newY) doc=\(doc.frame.height)"
                detachedShown = await waitUntil { find(window, "jumpToBottom") != nil } != nil
                capture(window, to: dir.appendingPathComponent("S-08-jump-to-bottom.png"))
                if click(window, "jumpToBottom") {
                    hiddenAfter = await waitUntil(timeout: 3) { find(window, "jumpToBottom") == nil } != nil
                    await settle(300)
                    let b = sv.contentView.bounds
                    let docH = sv.documentView?.frame.height ?? 0
                    returned = doc.isFlipped ? (docH - b.maxY) <= 30 : b.minY <= 30
                    scrollInfo += " end=\(b) docH=\(docH)"
                }
            }
            let pass = separator && detachedShown && returned && hiddenAfter
            legs["6-separator-jump"] = ["pass": pass, "startSeparator": separator, "jumpShownAfterScrollUp": detachedShown,
                                        "returnedToBottom": returned, "jumpHiddenAfter": hiddenAfter,
                                        "scroll": scrollInfo]
        }

        // SidebarChatManagement (R-011 / step 6): each operation writes through ChatRepository and the sidebar row
        // updates through ValueObservation in ≤ 100 ms (signpost sidebarUpdate).
        do {
            var ops: [String: Any] = [:]
            var ok = true
            func latency() -> Double { state.lastSidebarUpdateLatency ?? -1 }
            guard let chat = try? state.service.create(title: "Probe chat") else { return }
            _ = await waitUntil { state.sidebar.contains { $0.id == chat.id } }
            state.rename(chat.id, to: "Renamed by probe")
            let r1 = await waitUntil { find(window, "chatRow.\(chat.id)") != nil
                && state.sidebar.first { $0.id == chat.id }?.title == "Renamed by probe" }
            ops["rename"] = ["visibleSeconds": r1 ?? -1, "observationSeconds": latency()]
            ok = ok && r1 != nil && latency() <= 0.1
            state.togglePin(chat.id)
            let r2 = await waitUntil { find(window, "sidebarSection.pinned") != nil
                && state.sidebar.first?.id == chat.id }
            ops["pin"] = ["visibleSeconds": r2 ?? -1, "observationSeconds": latency()]
            ok = ok && r2 != nil && latency() <= 0.1
            capture(window, to: dir.appendingPathComponent("sidebar-pinned.png"))
            state.archive([chat.id])
            let r3 = await waitUntil { find(window, "chatRow.\(chat.id)") == nil }
            ops["archive"] = ["visibleSeconds": r3 ?? -1, "observationSeconds": latency()]
            ok = ok && r3 != nil && latency() <= 0.1
            try? state.service.unarchive(chat.id)
            _ = await waitUntil { find(window, "chatRow.\(chat.id)") != nil }
            state.requestDelete([chat.id], anchor: .row)
            await settle(400)
            capture(window, to: dir.appendingPathComponent("sidebar-delete-confirm.png"))
            state.confirmDelete()
            let r4 = await waitUntil { find(window, "chatRow.\(chat.id)") == nil }
            ops["delete"] = ["visibleSeconds": r4 ?? -1, "observationSeconds": latency()]
            ok = ok && r4 != nil && latency() <= 0.1
            if let md = state.export(state.sidebar.first?.id ?? "", as: .markdown) {
                ops["exportMarkdownBytes"] = md.data.count
            }
            legs["7-chat-management"] = ["pass": ok, "ops": ops]
        }

        // Dark appearance captures (S-05 / S-08 dark).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        state.newChat(seed: 3)
        await settle(500)
        capture(window, to: dir.appendingPathComponent("S-05-empty-dark.png"))
        if let first = state.sidebar.first { state.open(.chat(first.id)) }
        await settle(500)
        capture(window, to: dir.appendingPathComponent("S-08-docked-dark.png"))
        NSApp.appearance = nil

        notes.append("Frames are window coordinates (origin bottom-left) from the probeID anchors; identifiers match App/UITests/WindowLayoutTests.swift.")
        let pass = legs.values.allSatisfy { ($0["pass"] as? Bool) == true }
        write(["pass": pass, "legs": legs, "notes": notes], dir: dir)
    }

    static func write(_ obj: [String: Any], dir: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("probe.json"))
        }
    }
}
#endif
