// M2.T20 in-process onboarding probe (AT-201 part 3, AT-203, AT-NFR-M5 single run). XCUITest cannot start on this Mac
// (Q-015), so the app drives its own onboarding window the way a user would: step 2 with the smallest real choice (Chat
// only) → Continue (the NFR-M5 clock) → step 3 (Evil on + adult box when ONB_PROBE_EVIL=1) → step 4 → Open chat at once
// → a typed first message (queued while the starter downloads, R-299) → its first streamed token. Then it waits for the
// tier model, sends a second message and checks it ran on the tier model (`starter.upgraded`). Real downloads through
// the DownloadCoordinator / NetworkGate from the signed catalog's Hugging Face URLs. Renders every screen offscreen
// (cacheDisplay, Light and Dark) and also tries a live `screencapture -l` per window (reports whether it is black).
// Writes `<dir>/probe.json` and quits. DEBUG only (`-OnboardingProbe <dir>`, with `-ANTICHAT_DEV_CONTAINER <tmp>
// -ResetOnboarding YES`; tools/at/at-nfr-m5-probe.sh).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatUI
import AppKit
import SwiftUI

@MainActor
enum OnboardingProbe {
    private static var sessions: ChatSessions?
    private static var state: WindowState?
    private static var started = false
    static var dir: URL!
    static var timeline: [[String: Any]] = []
    static var t0 = ContinuousClock.now
    static var shots: [String: Any] = [:]

    static func attachMain(_ state: WindowState, sessions: ChatSessions) {
        self.state = state
        self.sessions = sessions
    }

    static func start(_ controller: OnboardingWindowController, out: String) {
        guard !started else { return }
        started = true
        dir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(controller)
            NSApp.terminate(nil)
        }
    }

    static func s(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    static func mark(_ what: String, _ extra: [String: Any] = [:]) {
        var e = extra
        e["t"] = (s(.now - t0) * 100).rounded() / 100
        e["event"] = what
        timeline.append(e)
        FileHandle.standardError.write(Data("OnboardingProbe \(e["t"]!)s \(what) \(extra)\n".utf8))
    }

    static func waitUntil(timeout: Double, poll: Int = 250, _ cond: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while s(.now - start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(poll))
        }
        return cond()
    }

    /// Main-window screens: a live `screencapture -l` per appearance (NSApp.appearance Light, then Dark). Onboarding
    /// (always dark): one live capture + an offscreen render. Offscreen-only windows (renderStep4): cacheDisplay.
    static func capture(_ window: NSWindow, _ name: String) async {
        if name.hasPrefix("onb") {
            offscreen(window, "\(name)-dark")
            shots[name] = live(window, dir.appendingPathComponent("\(name)-live.png"))
            return
        }
        let saved = VisualQAProbe.currentLook
        for look in VisualQAProbe.looks {
            VisualQAProbe.setLook(look, restore: saved)  // the app's own Color mode (M10 harness issue 3)
            try? await Task.sleep(for: .milliseconds(700))
            shots["\(name)-\(look)"] = live(window, dir.appendingPathComponent("\(name)-\(look).png"))
        }
        VisualQAProbe.setLook(nil, restore: saved)
    }

    static func offscreen(_ window: NSWindow, _ file: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(file).png"))
    }

    static func live(_ window: NSWindow, _ url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        guard (try? p.run()) != nil else { return "failed" }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let img = NSImage(contentsOf: url) else { return "failed" }
        return isBlack(img) ? "black" : "ok"
    }

    static func isBlack(_ img: NSImage) -> Bool {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return true }
        let n = CFDataGetLength(data)
        var lit = 0
        var i = 0
        while i < n { if ptr[i] > 24 || ptr[i + 1] > 24 || ptr[i + 2] > 24 { lit += 1 }; i += 4 * 97 }
        return lit < 10
    }

    static func rowsDescription() -> [String] {
        SetupLaunch.status.progress.rows.map { "\($0.group):\($0.state)" }
    }

    static func run(_ c: OnboardingWindowController) async {
        let model = c.model
        let evil = ProcessInfo.processInfo.environment["ONB_PROBE_EVIL"] == "1"
        t0 = .now
        mark("onboarding shown")
        _ = await waitUntil(timeout: 15) { model.profile != nil }
        mark("profile", ["tier": model.profile?.tierKey ?? "?", "chip": model.profile?.chip ?? "?"])
        await capture(c.window, "onb-step1")
        model.next()
        // Smallest real choice: Chat only. ONB_PROBE_ALL_PACKS=1 (M9.T05 NFR-D3 real bytes): keep every pack the
        // profile pre-selects (the default install). ONB_PROBE_VOICE=1 (M10.T09 AT-FA-05): Chat + Voice.
        let env = ProcessInfo.processInfo.environment
        if env["ONB_PROBE_ALL_PACKS"] != "1" {
            let voice = env["ONB_PROBE_VOICE"] == "1"
            for pack in [ModelPack.voice, .photo, .video] where model.chosenPacks.contains(pack) != (voice && pack == .voice) {
                model.toggle(pack)
            }
        }
        mark("packs", ["chosen": model.chosenPacks.map { "\($0)" }.sorted().joined(separator: ",")])
        try? await Task.sleep(for: .milliseconds(400))
        await capture(c.window, "onb-step2")
        let plan = model.totalLine.string
        mark("step2 continue", ["total": plan])
        let continueAt = ContinuousClock.now
        model.next()  // Continue → the starter download starts (NFR-M5 clock)
        try? await Task.sleep(for: .milliseconds(300))
        if evil {
            model.evilOn = true
            model.adultConfirmed = true
            try? await Task.sleep(for: .milliseconds(300))
            await capture(c.window, "onb-step3")
        }
        model.next()  // step 3 Continue → step 4
        mark("step4 shown", ["evil": evil])
        try? await Task.sleep(for: .milliseconds(1500))
        await capture(c.window, "onb-step4-downloading")
        mark("step4 rows", ["rows": rowsDescription()])
        // Open chat at once and type the first message (queued until the starter is ready).
        model.next()
        _ = await waitUntil(timeout: 10) { sessions != nil && NSApp.windows.contains { $0.isVisible && $0.title == "AntiChat" } }
        guard let sessions else { mark("no main window"); return write(continueAt: continueAt) }
        try? await Task.sleep(for: .milliseconds(600))
        sessions.composer.text = "Hi! In one short sentence: what can you do?"
        let accepted = sessions.composer.send()
        mark("first message typed", ["accepted": accepted, "availability": "\(sessions.composer.availability)"])
        if let w = mainWindow() { await capture(w, "chat-queued") }
        // Step 4 view once the starter is in (re-rendered offscreen from the same model).
        _ = await waitUntil(timeout: 1200) { SetupLaunch.status.progress.starterReady }
        mark("starter ready", ["rows": rowsDescription(), "sinceContinue": s(.now - continueAt)])
        renderStep4(model, "onb-step4-starterReady")
        _ = await waitUntil(timeout: 600) { SetupLaunch.firstTokenAt != nil }
        let ttfc = SetupLaunch.firstTokenAt.map { s($0 - continueAt) }
        mark("first token", ["continueToFirstToken": ttfc ?? -1, "slot": ChatModels.shared.handoff.slot().key])
        _ = await waitUntil(timeout: 120) { !(sessions.current?.isGenerating ?? false) }
        try? await Task.sleep(for: .milliseconds(500))
        mark("first reply done", ["label": "\(sessions.composer.starterLabel)", "text": String(sessions.current?.messages.last?.text.prefix(160) ?? "")])
        if let w = mainWindow() { await capture(w, "chat-starter") }
        // Hand-off: wait for the tier model, then the next turn.
        _ = await waitUntil(timeout: 2400) { SetupLaunch.status.progress.tierReady }
        mark("tier ready", ["rows": rowsDescription()])
        let allReady = await waitUntil(timeout: 2400) { SetupLaunch.status.progress.rows.allSatisfy { $0.state == .ready } }
        mark("all rows ready", ["ok": allReady, "rows": rowsDescription()])
        renderStep4(model, "onb-step4-allReady")
        try? await Task.sleep(for: .milliseconds(800))
        mark("upgrade notice", ["label": "\(sessions.composer.starterLabel)"])
        if let w = mainWindow() { await capture(w, "chat-upgradeNotice") }
        sessions.composer.text = "Thanks. Now name three colours."
        _ = sessions.composer.send()
        mark("second message", ["slot": ChatModels.shared.handoff.slot().key, "phase": "\(ChatModels.shared.handoff.phase)"])
        _ = await waitUntil(timeout: 300) { sessions.current?.isGenerating == true }
        _ = await waitUntil(timeout: 300) { !(sessions.current?.isGenerating ?? false) }
        try? await Task.sleep(for: .milliseconds(600))
        mark("second reply done", ["label": "\(sessions.composer.starterLabel)", "slot": ChatModels.shared.handoff.slot().key,
                                   "text": String(sessions.current?.messages.last?.text.prefix(160) ?? "")])
        if let w = mainWindow() { await capture(w, "chat-upgraded") }
        if evil {
            mark("evil line", ["line": sessions.composer.evilUnavailableLine?.string ?? "nil", "notice": sessions.composer.notice?.string ?? "nil"])
        }
        write(continueAt: continueAt)
    }

    static func mainWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "AntiChat" } }

    /// Step 4 rendered offscreen from the live model (the onboarding window is closed once Open chat ran).
    static func renderStep4(_ model: OnboardingModel, _ name: String) {
        let size = CGSize(width: 1280, height: 800)
        let host = NSHostingView(rootView: OnboardingFlow(model: model).frame(width: size.width, height: size.height))
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        offscreen(w, "\(name)-dark")
    }

    static func write(continueAt: ContinuousClock.Instant) {
        var out: [String: Any] = ["timeline": timeline, "liveCapture": shots]
        if let f = SetupLaunch.firstTokenAt { out["nfr.M5.continueToFirstToken.s"] = s(f - continueAt) }
        if let r = SetupLaunch.starterReadyAt { out["continueToStarterReady.s"] = s(r - continueAt) }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("probe.json"))
        }
    }
}
#endif
