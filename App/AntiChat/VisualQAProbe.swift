// M2.T26 in-process visual QA capture probe (AT-VQ-M2; `-VisualQAProbe <dir>`, DEBUG). XCUITest and computer use
// are unavailable here (Q-015, Q-021), so the app walks its own M2 screens and captures each WINDOW with
// `screencapture -l <CGWindowID>` under the system Light and Dark appearance (NSApp.appearance):
//   onboarding launch (`-ResetOnboarding YES`): steps 1–4 (step 2 default ticks / Voice unticked / disk short, step 3
//     Evil off / on + adult box / a Mac with less memory, step 4 shortly after Continue and ~20 s later), then quits;
//     `VQ_ONB=ready` (Chat already in the container): step 4 Chat ready, a failed row, then Back to step 2 and Chat
//     alone, all ready; `VQ_ONB=failed` (no files on the server): step 4 with Chat failed;
//   main launch (`-SkipOnboarding YES`): the empty chat, the install cards a picture and a video request get
//     (`-FakeHardware t1-m2-16`: Photo offered, Video not available), Settings → Capabilities (top, Advanced = the
//     model manager expanded), Evil Mode and Storage, then quits.
// Capture path: by default the probe writes `<dir>/want/<name>.<windowID>` and waits for `<dir>/got/<name>` — the
// runner (tools/visual/vq-m2.sh, in the Terminal that holds the Screen Recording grant) takes the shot. A
// screencapture spawned by the app itself is attributed to the app when it was started by `open`/LaunchServices, which
// has no grant: the shot comes out as the bare window frame with black/empty content (the cause recorded in
// tools/visual/vq-m2.sh). `VQ_INPROCESS_CAPTURE=1` captures in-process instead (works when launched from Terminal).
// Writes `<dir>/probe.json` (what was shown, per shot) and quits.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatPlatform
import AntiChatUI
import AppKit
import Defaults
import SwiftUI

@MainActor
enum VisualQAProbe {
    static var dir: URL!
    static var shots: [[String: Any]] = []
    static var notes: [String] = []
    private static var started = false

    static func setDir(_ out: String) {
        dir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("want"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("got"), withIntermediateDirectories: true)
    }

    static func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// M7.T16: one `screencapture` run with `args` (VisualQAM7's window and region captures); returns its exit status.
    static func screencapture(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func waitUntil(timeout: Double, _ cond: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while true {
            if cond() { return true }
            if PaletteProbe.seconds(ContinuousClock.now - start) > timeout { return false }
            await settle(50)
        }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("VisualQAProbe: \(s)\n".utf8)) }

    /// One window shot. External (default): hand the window id to the runner and wait for the file.
    static func shot(_ window: NSWindow?, _ name: String, _ meta: [String: Any] = [:]) async {
        guard let window else { notes.append("\(name): no window"); return }
        window.orderFrontRegardless()
        await settle(500)
        let url = dir.appendingPathComponent("\(name).png")
        var entry = meta
        entry["name"] = name
        entry["windowID"] = window.windowNumber
        entry["size"] = "\(Int(window.frame.width))x\(Int(window.frame.height))"
        if ProcessInfo.processInfo.environment["VQ_INPROCESS_CAPTURE"] == "1" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
            try? p.run()
            p.waitUntilExit()
            entry["capture"] = "in-process rc=\(p.terminationStatus)"
        } else {
            let got = dir.appendingPathComponent("got/\(name)")
            try? Data().write(to: dir.appendingPathComponent("want/\(name).\(window.windowNumber)"))
            let ok = await waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: got.path) }
            entry["capture"] = ok ? "runner" : "runner timeout"
        }
        if let img = NSImage(contentsOf: url) { entry["black"] = OnboardingProbe.isBlack(img) }
        shots.append(entry)
        log("shot \(name) \(entry)")
    }

    /// The looks every capture takes, in order.
    static let looks = ["light", "dark"]

    /// Puts the app in `look` ("light" / "dark"; nil = back to `restore`) through its own Settings › Appearance ›
    /// Color mode (`colorMode`) as well as `NSApp.appearance`. Setting only `NSApp.appearance` did not hold: every
    /// window root's AppearanceRoot re-applies the setting (`system` → `NSApp.appearance = nil`) when a window, sheet
    /// or panel appears, so a "dark" shot taken after one appeared came out light (M10 harness issue 3, also the
    /// `-AppleInterfaceStyle Dark` launch argument, which the app's own Color mode overrides).
    static func setLook(_ look: String?, restore: (mode: String, appearance: NSAppearance?)) {
        Defaults[.colorMode] = look ?? restore.mode
        NSApp.appearance = look.map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua)! } ?? restore.appearance
    }

    static var currentLook: (mode: String, appearance: NSAppearance?) { (Defaults[.colorMode], NSApp.appearance) }

    /// The same window under the Light and Dark appearance.
    static func both(_ window: () -> NSWindow?, _ name: String, _ meta: [String: Any] = [:]) async {
        let saved = currentLook
        for look in looks {
            setLook(look, restore: saved)
            await settle(700)
            await shot(window(), "\(name)-\(look)", meta)
        }
        setLook(nil, restore: saved)
    }

    static func finish() {
        let out: [String: Any] = ["shots": shots, "notes": notes]
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("probe.json"))
        }
        try? Data().write(to: dir.appendingPathComponent("done"))
        NSApp.terminate(nil)
    }

    // MARK: Onboarding (S-01…S-04)

    static func startOnboarding(_ c: OnboardingWindowController, out: String) {
        guard !started else { return }
        started = true
        setDir(out)
        Task { @MainActor in
            let m = c.model
            c.window.setFrame(CGRect(x: 80, y: 80, width: 1440, height: 900), display: true)
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            _ = await waitUntil(timeout: 15) { m.profile != nil }
            await settle(800)
            // M10 harness (round-64 flake "step 3 skipped (step preparing)"): a step-2/3 choice saved by an earlier
            // run made this launch resume at step 4. It lived in the app domain, which every probe run and worktree
            // shares; it now lives in the run's -DefaultsSuite and -ResetOnboarding ignores it. A run that still opens
            // elsewhere says so.
            if m.step != .welcome { notes.append("onboarding opened at step \(m.step), not step 1") }
            switch ProcessInfo.processInfo.environment["VQ_ONB"] ?? "flow" {
            case "ready": await onboardingReadyLeg(c)
            case "failed": await onboardingFailedLeg(c)
            default: await onboardingFlowLeg(c)
            }
            finish()
        }
    }

    /// Runs `action` and waits until the model shows `step` (the probe must not shoot a half-faded crossfade, nor
    /// move on when Continue was refused).
    private static func advance(_ m: OnboardingModel, to step: OnboardingModel.Step, _ action: () -> Void) async -> Bool {
        action()
        let ok = await waitUntil(timeout: 5) { m.step == step }
        if !ok {
            let blocked = m.continueBlocked?.string ?? m.evilContinueBlocked?.string ?? "-"
            notes.append("expected step \(step), still at \(m.step) (blocked: \(blocked))")
        }
        await settle(600)
        return ok
    }

    private static func rowState(_ group: String) -> SetupProgress.RowState? {
        SetupLaunch.status.progress.rows.first { $0.group == group }?.state
    }

    /// The default leg (fresh container, slow loopback downloads): S-01; S-02 default, Voice unticked, disk short;
    /// S-03 off, on, ticked, a Mac with less memory; S-04 shortly after Continue and ~20 s later.
    private static func onboardingFlowLeg(_ c: OnboardingWindowController) async {
        let m = c.model
        let w = { c.window as NSWindow? }
        await both(w, "onb-step1", ["tier": m.profile?.tierKey ?? "?"])
        guard await advance(m, to: .capabilities, { m.next() }) else { return }
        await both(w, "onb-step2-default", ["total": m.totalLine.string, "packs": m.chosenPacks.map(\.rawValue).sorted()])
        m.toggle(.voice)  // a choice of the user's own: Voice unticked
        await settle(400)
        await both(w, "onb-step2-custom", ["total": m.totalLine.string, "packs": m.chosenPacks.map(\.rawValue).sorted()])
        m.toggle(.voice)
        // Disk short (NFR-D2): free space 4 GB under the chosen total + the 10 GB reserve.
        let free = m.freeBytes
        m.freeBytes = max(0, m.totalBytes + 6_000_000_000)
        await settle(400)
        await both(w, "onb-step2-diskshort", ["free": m.freeBytes, "blocked": m.continueBlocked?.string ?? ""])
        m.freeBytes = free
        await settle(300)
        guard await advance(m, to: .evil, { m.next() }) else { return }  // Continue → the starter download starts
        await both(w, "onb-step3-off")
        m.evilOn = true
        await settle(500)
        await both(w, "onb-step3-on-unticked", ["continueBlocked": m.evilContinueBlocked?.string ?? ""])
        m.adultConfirmed = true
        await settle(500)
        await both(w, "onb-step3-on-ticked", ["cost": m.evilCostLine.string, "total": m.totalLine.string])
        await lessMemoryShot(c)
        guard await advance(m, to: .preparing, { m.next() }) else { return }
        await settle(1900)
        await both(w, "onb-step4-early", ["rows": OnboardingProbe.rowsDescription()])
        await settle(20000)
        await both(w, "onb-step4-later", ["rows": OnboardingProbe.rowsDescription()])
    }

    /// S-03 on a Mac with less memory (8 GB, T0): the same choice planned for that Mac — its hardware line, Evil's
    /// cost and the availability line the catalog gives there (under Q-009 a Evil is offered wherever Normal is, so
    /// it truthfully stays "available"; the capture shows no false "has less"). A fixture on which a chosen pack has
    /// no Evil is preferred when one exists. Then back to this run's Mac.
    private static func lessMemoryShot(_ c: OnboardingWindowController) async {
        let m = c.model
        guard let original = m.profile, let catalog = m.catalog else { notes.append("less-memory: no profile"); return }
        func profile(_ name: String) -> HardwareProfile? {
            guard let url = HardwareProbe.fixtureURL(name), let data = try? Data(contentsOf: url),
                  let facts = try? HardwareFacts(fixture: data) else { return nil }
            return HardwareProfile(facts: facts, classification: TierClassifier.classify(facts: facts), fixture: name)
        }
        var chosen: (String, HardwareProfile)?
        for name in ["t0-m1-8", "t0-a18pro-8"] {
            guard let p = profile(name) else { continue }
            if chosen == nil { chosen = (name, p) }
            m.update(profile: p, catalog: catalog)
            if let plan = m.evilPlan, !plan.unavailablePacks.isEmpty || !plan.isAvailable { chosen = (name, p); break }
        }
        if let (name, p) = chosen {
            m.update(profile: p, catalog: catalog)
            await settle(500)
            await both({ c.window as NSWindow? }, "onb-step3-lessmemory",
                       ["fixture": name, "availability": m.evilAvailabilityLine.string, "cost": m.evilCostLine.string,
                        "hardware": m.hardwareLine.string])
        } else {
            notes.append("less-memory: no T0 fixture (ANTICHAT_FIXTURES)")
        }
        m.update(profile: original, catalog: catalog)
        await settle(400)
    }

    /// `VQ_ONB=ready` (a container that already holds Chat; the loopback server has only Chat's files): S-04 with
    /// Chat ready, a row that didn't finish, then Back to step 2, Chat alone, and every row ready.
    private static func onboardingReadyLeg(_ c: OnboardingWindowController) async {
        let m = c.model
        let w = { c.window as NSWindow? }
        guard await advance(m, to: .capabilities, { m.next() }), await advance(m, to: .evil, { m.next() }),
              await advance(m, to: .preparing, { m.next() }) else { return }
        if await waitUntil(timeout: 90, { SetupLaunch.status.progress.starterReady }) {
            await settle(800)
            await both(w, "onb-step4-chatready", ["rows": OnboardingProbe.rowsDescription()])
        } else {
            notes.append("chat never ready: \(OnboardingProbe.rowsDescription())")
        }
        if await waitUntil(timeout: 120, { SetupLaunch.status.progress.rows.contains { $0.state == .failed } }) {
            await settle(800)
            await both(w, "onb-step4-rowfailed", ["rows": OnboardingProbe.rowsDescription()])
        } else {
            notes.append("no failed row: \(OnboardingProbe.rowsDescription())")
        }
        // Back (onboarding_page4) to step 2, Chat only, Continue twice: the dropped packs stop.
        guard await advance(m, to: .evil, { m.back() }), await advance(m, to: .capabilities, { m.back() }) else { return }
        for pack in m.chosenPacks where pack != .chat { m.toggle(pack) }
        guard await advance(m, to: .evil, { m.next() }), await advance(m, to: .preparing, { m.next() }) else { return }
        let allReady = await waitUntil(timeout: 60) {
            let rows = SetupLaunch.status.progress.rows
            return !rows.isEmpty && rows.allSatisfy { $0.state == .ready }
        }
        if allReady {
            await settle(800)
            await both(w, "onb-step4-allready", ["rows": OnboardingProbe.rowsDescription()])
        } else {
            notes.append("not all ready: \(OnboardingProbe.rowsDescription())")
        }
    }

    /// `VQ_ONB=failed` (fresh container, no files on the loopback server): Chat itself didn't finish — S-04's failed
    /// subtitle and the Retry action.
    private static func onboardingFailedLeg(_ c: OnboardingWindowController) async {
        let m = c.model
        guard await advance(m, to: .capabilities, { m.next() }), await advance(m, to: .evil, { m.next() }),
              await advance(m, to: .preparing, { m.next() }) else { return }
        if await waitUntil(timeout: 120, { rowState("chat") == .failed }) {
            await settle(800)
            await both({ c.window as NSWindow? }, "onb-step4-chatfailed", ["rows": OnboardingProbe.rowsDescription()])
        } else {
            notes.append("chat never failed: \(OnboardingProbe.rowsDescription())")
        }
    }

    // MARK: Main window, install cards, Settings (S-08, S-21)

    static func startMain(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started, !OnboardingGate.shouldShow() else { return }  // the onboarding leg runs from AppDelegate
        started = true
        setDir(out)
        Task { @MainActor in
            await settle(2000)
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }) else {
                notes.append("no main window")
                return finish()
            }
            main.setFrame(CGRect(x: 60, y: 60, width: 1440, height: 900), display: true)
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
            await settle(800)
            let mw = { NSApp.windows.first { $0.isVisible && $0.title == "AntiChat" } }
            if let i = CommandLine.arguments.firstIndex(of: "-VisualQAImageLeg"), i + 1 < CommandLine.arguments.count {
                return await imageLeg(CommandLine.arguments[i + 1], sessions: sessions, mw: mw)  // M4.T16 AT-VQ-M4
            }
            if ProcessInfo.processInfo.environment["VQ_LEG"] == "voice" { return await voiceLeg(mw, state: state, sessions: sessions) }
            if ProcessInfo.processInfo.environment["VQ_LEG"] == "m9" { return await m9Leg(mw, main: main, state: state, sessions: sessions) }
            if ProcessInfo.processInfo.environment["VQ_LEG"] == "m9-crash" { return await m9CrashLeg(mw, state: state, sessions: sessions) }
            if ProcessInfo.processInfo.environment["VQ_LEG"] == "m9-edit" { return await m9EditLeg(mw, main: main, state: state, sessions: sessions) }
            if ProcessInfo.processInfo.environment["VQ_LEG"] == "m9-mac" { return await m9MacLeg(main: main) }
            if ProcessInfo.processInfo.environment["VQ_LEG"] == "m10" { return await m10Leg(mw, main: main) }
            await both(mw, "chat-empty")
            // The router must have its prototype vectors before a media request can be carded before the model.
            notes.append("router ready=\(await prepareRouter(sessions))")
            for (name, text) in [("installcard-photo", "Make me a picture of a lighthouse in a thunderstorm, oil painting style"),
                                 ("installcard-video", "Make a short video of a red kite flying over a wheat field")] {
                // Typing starts the router's prototype preparation on a fresh container (RouteScorer.prefetch);
                // retype once it had time so the send finds the draft's vector cached, as after normal typing.
                sessions.composer.text = text
                await settle(1500)
                sessions.composer.text = ""
                await settle(300)
                sessions.composer.text = text
                await settle(1500)
                let sent = sessions.composer.send()
                _ = await waitUntil(timeout: 90) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
                await settle(1500)
                await both(mw, name, ["sent": sent, "turn": await sessions.current?.debugTurnState() ?? "no chat",
                                           "slot": ChatModels.shared.handoff.slot().key,
                                           "embed": ChatModels.shared.searchSlot("embed")?.key ?? "nil"])
                state.newChat()
                await settle(800)
            }
            // Settings → Capabilities, Advanced (model manager), Evil Mode, Storage.
            SettingsProbe.main = main
            notes.append("settings opened via \(await SettingsProbe.openSettingsWithCommandComma())")
            let sw = { SettingsProbe.settingsWindow }
            sw()?.setFrameOrigin(CGPoint(x: 200, y: 120))
            let model = SettingsModel.shared
            model.open(.capabilities)
            await settle(1200)
            await both(sw, "settings-capabilities")
            model.advancedExpanded = true
            model.open(.capabilities, row: "capabilities.advanced")
            await settle(1200)
            await both(sw, "settings-capabilities-advanced")
            model.advancedExpanded = false
            for s in [SettingsSection.evil, .storage] {
                model.open(s)
                await settle(1000)
                // VQ (S-21 Storage): the page's numbers, not the first second of a scan.
                if s == .storage { notes.append("storage settled=\(await waitUntil(timeout: 30) { StorageProbeStatus.settled })") }
                await both(sw, "settings-\(s.rawValue)")
            }
            // VQ (S-21 Capabilities): a pack downloading (Voice, from the loopback mirror) and the disk-short refusal
            // (Photo with the free space pretended to 2 GB), then both undone.
            let packs = PackManagementModel.shared
            model.open(.capabilities)
            await settle(800)
            packs.enable(.voice)
            let downloading = await waitUntil(timeout: 20) {
                if case .downloading = packs.state(.voice) { return true } else { return false }
            }
            await settle(2500)
            await both(sw, "settings-capabilities-downloading", ["downloading": downloading])
            packs.debugFreeBytes(2_000_000_000)
            packs.enable(.photo)
            await settle(800)
            await both(sw, "settings-capabilities-diskshort", ["diskShort": packs.diskShort[.photo] ?? -1])
            packs.debugFreeBytes(nil)
            packs.diskShort[.photo] = nil
            packs.disable(.voice, remove: true)
            await settle(800)
            finish()
        }
    }

    /// Prepares the tool router's prototype vectors (≤ 60 s); "true after n s", "false after n s" or "no router".
    static func prepareRouter(_ sessions: ChatSessions) async -> String {
        guard let scorer = sessions.environment(for: nil).tools?.router?.scorer else { return "no router" }
        let t0 = ContinuousClock.now
        Task.detached { await scorer.prepare() }
        var ready = await scorer.isReady
        for _ in 0..<240 where !ready { await settle(250); ready = await scorer.isReady }
        return "\(ready) after \(PaletteProbe.seconds(ContinuousClock.now - t0)) s"
    }

    // MARK: Photo (M4.T16 AT-VQ-M4, journey 5 scripted: ScriptedImageEngine in the helper, real gate + dev detectors)

    /// `variant`: `main` (create → done card → viewer → edit by text → new version + rail → Erase → Remove background),
    /// `missing` (no detectors: the safety-missing card), `install` (Photo absent: the install card).
    /// Cap on one image turn: 300 s scripted; `-VisualQAImageWait <s>` for real models on a loaded host (the wait
    /// ends as soon as the picture is there).
    static var imageWait: Double { Double(UserDefaults.standard.string(forKey: "VisualQAImageWait") ?? "") ?? 300 }

    static func imageLeg(_ variant: String, sessions: ChatSessions, mw: @escaping () -> NSWindow?) async {
        func sendText(_ text: String) async -> Bool {
            sessions.composer.text = text
            await settle(800)
            return sessions.composer.send()
        }
        func waitIdle(_ s: Double = 180) async -> Bool {
            await settle(500)
            return await waitUntil(timeout: s) { !(sessions.current?.isGenerating ?? true) }
        }
        // M10 harness issue 2: a fresh container's router has no prototype vectors yet, so the first turn went out
        // unscored (`skipped=notReady`): create_image was never offered, the scripted call hit "no tool named
        // create_image" and both the main and the safety-missing legs showed a generic failure. Prepare it first,
        // as the main leg does (a user's first request after typing finds it ready the same way).
        notes.append("router ready=\(await prepareRouter(sessions))")
        let sent = await sendText("Draw me a lighthouse at dusk")
        switch variant {
        case "missing", "install":
            _ = await waitIdle()
            await settle(2000)
            let results = sessions.current?.messages.flatMap { $0.activities.map { "\($0.tool): \($0.result ?? "-")" } } ?? []
            await both(mw, variant == "missing" ? "image-safety-missing" : "image-install-card",
                       ["sent": sent, "turn": await sessions.current?.debugTurnState() ?? "no chat", "results": results])
            return finish()
        default: break
        }
        _ = await waitUntil(timeout: Self.imageWait) { sessions.current?.debugLatestImage() != nil && !(sessions.current?.isGenerating ?? true) }
        await settle(2500)
        guard let chat = sessions.current, let first = chat.debugLatestImage() else {
            notes.append("no picture after the create turn: \(await sessions.current?.debugTurnState() ?? "no chat")")
            await both(mw, "image-done-missing")
            return finish()
        }
        await both(mw, "image-done", ["artifact": first.artifactID])
        // Viewer (one version: no rail yet), Describe the change focused, editor toolbar.
        chat.openImageViewer(ImageViewerTarget(paths: [first.path], selected: 0, artifactID: first.artifactID, current: first.path,
                                               focusDescribe: true))
        await settle(1500)
        await both(mw, "image-viewer")
        // Edit by text from the viewer → a turn with edit_image on this picture → version 2.
        let edited = chat.editImage(ImageEditRequest(sourceID: first.artifactID, instruction: "Make the sky purple"))
        _ = await waitUntil(timeout: Self.imageWait) { (chat.debugLatestImage()?.versions ?? 0) >= 2 && !chat.isGenerating }
        await settle(2500)
        await both(mw, "image-edit-done", ["edited": edited, "versions": chat.debugLatestImage()?.versions ?? 0,
                                                 "results": chat.messages.flatMap { $0.activities.map { "\($0.tool) \($0.state.rawValue): \($0.result ?? "-")" } }])
        func openNewest() async {
            guard let l = chat.debugLatestImage() else { return }
            chat.openImageViewer(ImageViewerTarget(paths: [l.path], selected: 0, artifactID: l.artifactID, current: l.path))
            await settle(1500)
        }
        await openNewest()
        await both(mw, "image-viewer-versions", ["versions": chat.imageViewer?.versions.count ?? 0])
        // Erase: a brush stroke across the middle → local job (LaMa when ANTICHAT_ERASE_MODEL is set) → version 3.
        if let l = chat.debugLatestImage(), let size = ImageEditFlow.pixelSize(l.path),
           let mask = MaskBrush.png([MaskStroke(points: [CGPoint(x: 0.35, y: 0.45), CGPoint(x: 0.65, y: 0.55)], radius: 0.06)],
                                    width: size.width, height: size.height) {
            let r = await chat.localEdit(LocalEditRequest(sourceID: l.artifactID, operation: .erase, mask: mask))
            notes.append("erase: \(r)")
            await openNewest()
            await both(mw, "image-erase", ["versions": chat.imageViewer?.versions.count ?? 0])
            let rb = await chat.localEdit(LocalEditRequest(sourceID: l.artifactID, operation: .removeBackground))
            notes.append("remove background: \(rb)")
            await openNewest()
            await both(mw, "image-remove-background", ["outcome": "\(rb)", "versions": chat.imageViewer?.versions.count ?? 0])
        }
        chat.imageViewer = nil
        await settle(800)
        await both(mw, "image-viewer-closed")
        finish()
    }

    // MARK: M9.T08 full walk (AT-VQ-M9: the screens no earlier leg captures)

    /// `VQ_LEG=m9` (tools/visual/vq-m9.sh, scripted engine `vq-chat.jsonl`): S-05 empty, S-08 streaming + done with a
    /// populated sidebar, S-06 Evil empty, S-07 incognito empty, S-18 ⌘K, S-19 Library, S-20 Projects, the chats
    /// list, the 1180×820 repeat, and every S-21 section. Light and Dark.
    static func m9Leg(_ mw: @escaping () -> NSWindow?, main: NSWindow, state: WindowState, sessions: ChatSessions) async {
        func ask(_ text: String) async {
            sessions.composer.text = text
            await settle(400)
            _ = sessions.composer.send()
            _ = await waitUntil(timeout: 60) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
            await settle(1500)
        }
        await both(mw, "s05-chat-empty")
        sessions.composer.text = "Plan a relaxed weekend in a small harbour town"
        await settle(600)
        await both(mw, "s05-chat-typed")  // VQ round 65: the typed state (send enabled)
        _ = sessions.composer.send()
        await settle(350)
        await shot(mw(), "s08-streaming-system")
        _ = await waitUntil(timeout: 60) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
        await settle(3500)
        await both(mw, "s08-conversation-done")
        let firstChat = state.currentChatID
        for q in ["What should I pack for the coast in April?", "Suggest three seafood dishes to try"] {
            state.newRegularChat()
            await settle(600)
            await ask(q)
        }
        await both(mw, "s08-sidebar-populated")
        state.newRegularChat()
        await settle(800)
        await both(mw, "s05-chat-empty-sidebar")
        if let evil = EvilModeModel.shared {
            if !evil.isOn { try? evil.enable(adultSelfDeclared: true) }
            await settle(600)
            state.newEvilChat()
            if !(await waitUntil(timeout: 3) { sessions.composer.mode == .evil }) {
                sessions.composer.mode = .evil
                sessions.modeChanged(.evil)
            }
            await settle(1200)
            await both(mw, "s06-evil-empty", ["evilOn": evil.isOn])
            evil.disable()
            await settle(400)
        } else {
            notes.append("no EvilModeModel")
        }
        state.newRegularChat()
        await settle(600)
        state.newIncognitoChat()
        await settle(1200)
        await both(mw, "s07-incognito-empty")
        state.newRegularChat()
        await settle(800)
        if let palette = PaletteController.lastAttached {
            palette.present()
            await settle(1200)
            await both(mw, "s18-palette")
            // VQ round 65: a typed query (chat, action and settings matches) and a query with no results, typed into
            // the field with real key events (PaletteProbe).
            PaletteProbe.window = main
            for (q, name) in [("weekend", "s18-palette-typed"), ("qwxzvbnm", "s18-palette-noresults")] {
                await PaletteProbe.clear(palette.query.count)
                await PaletteProbe.type(q)
                let typed = await waitUntil(timeout: 3) { palette.query == q && !palette.isSearching }
                await settle(800)
                await both(mw, name, ["query": palette.query, "typed": typed, "rows": palette.items.count])
            }
            palette.dismiss()
            await settle(600)
        } else {
            notes.append("no palette")
        }
        for (route, name) in [(WindowRoute.library, "s19-library"), (.projects, "s20-projects"), (.chats, "chats-list")] {
            state.open(route)
            await settle(1200)
            await both(mw, name)
        }
        if let firstChat { state.open(.chat(firstChat)) }
        main.setFrame(CGRect(x: 60, y: 60, width: 1180, height: 820), display: true)
        await settle(1500)
        await both(mw, "s08-conversation-1180")
        main.setFrame(CGRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        await settle(800)
        // VQ round 65 (S-08): a reply stopped mid-stream (Stop in the composer), and a turn the engine fails
        // (`engine.stalled`: the error line with Retry). Both scripted in vq-chat.jsonl.
        state.newRegularChat()
        await settle(600)
        sessions.composer.text = "Plan a lighthouse walk for Saturday"
        await settle(400)
        _ = sessions.composer.send()
        await settle(2600)  // ~15 of the reply's 40 words (140 ms each) are on screen
        sessions.composer.stop()
        _ = await waitUntil(timeout: 20) { !(sessions.current?.isGenerating ?? false) }
        await settle(1500)
        await both(mw, "s08-stopped", ["turn": await sessions.current?.debugTurnState() ?? "no chat",
                                       "status": "\(sessions.current?.messages.last?.status.rawValue ?? "nil")"])
        state.newRegularChat()
        await settle(600)
        await ask("What are the tide times today?")
        await both(mw, "s08-error-retry", ["turn": await sessions.current?.debugTurnState() ?? "no chat",
                                           "status": "\(sessions.current?.messages.last?.status.rawValue ?? "nil")",
                                           "error": sessions.current?.messages.last?.errorCode ?? "nil"])
        SettingsProbe.main = main
        notes.append("settings opened via \(await SettingsProbe.openSettingsWithCommandComma())")
        let sw = { SettingsProbe.settingsWindow }
        sw()?.setFrameOrigin(CGPoint(x: 200, y: 120))
        for s in SettingsSection.allCases {
            SettingsModel.shared.open(s)
            await settle(1100)
            // VQ (S-21 Storage): the page's numbers, not the first second of a scan.
            if s == .storage { notes.append("storage settled=\(await waitUntil(timeout: 30) { StorageProbeStatus.settled })") }
            await both(sw, "s21-\(s.rawValue)")
        }
        // VQ (S-21 Privacy): Offline only on, with one network-activity category opened (its event rows).
        SettingsModel.shared.open(.privacy, row: "networkActivity")
        await settle(900)
        NetworkPolicyStore.shared.offlineOnly = true
        await settle(400)
        notes.append("privacy row opened: \(SettingsProbe.click("networkActivity.row.catalog", at: 0.3, tracking: false))")
        SettingsModel.shared.highlightedRow = nil  // the reveal wash would show in one look only
        await settle(900)
        await both(sw, "s21-privacy-offline-expanded")
        NetworkPolicyStore.shared.offlineOnly = false
        await settle(300)
        finish()
    }

    /// `VQ_LEG=m9-crash` (scripted engine `vq-failures.jsonl`, one reply per prompt by `when`): the S-25 failure
    /// states — not enough memory, a stalled engine, a damaged model (Re-download), then the engine restart last
    /// (a helper crash restarts the script). Each in a new chat so one failure is on screen at a time.
    static func m9CrashLeg(_ mw: @escaping () -> NSWindow?, state: WindowState, sessions: ChatSessions) async {
        for (name, prompt) in [("s25-not-enough-memory", "Summarise the Iliad in one page"),
                               ("s25-engine-stalled", "Plan a three-day trip to Lisbon"),
                               ("s25-model-corrupt", "Explain how the tides work")] {
            sessions.composer.text = prompt
            await settle(400)
            let sent = sessions.composer.send()
            _ = await waitUntil(timeout: 60) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
            await settle(2000)
            await both(mw, name, ["sent": sent, "turn": await sessions.current?.debugTurnState() ?? "no chat"])
            state.newChat()
            await settle(800)
        }
        sessions.composer.text = "Describe a quiet harbour town at dawn"
        await settle(400)
        _ = sessions.composer.send()
        _ = await waitUntil(timeout: 60) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
        await settle(3000)
        await both(mw, "s25-engine-crash", ["turn": await sessions.current?.debugTurnState() ?? "no chat"])
        finish()
    }

    // MARK: M9.T08 R1: S-09, S-22, S-23 (region shots, open menus)

    /// A screen region shot (top-left origin, points) for what is not one window: popovers and sheets with their
    /// window, open menus, the quick panel over another app. The runner takes `want/<name>.R<x>,<y>,<w>,<h>` with
    /// `screencapture -R`.
    static func regionShot(_ name: String, _ rect: CGRect, _ meta: [String: Any] = [:]) async {
        let screen = NSScreen.screens.first?.frame ?? .zero
        let r = rect.intersection(screen).integral
        guard r.width > 0, r.height > 0 else { notes.append("\(name): empty region"); return }
        let top = screen.height - r.maxY
        let spec = "R\(Int(r.minX)),\(Int(top)),\(Int(r.width)),\(Int(r.height))"
        var entry = meta
        entry["name"] = name
        entry["region"] = spec
        let got = dir.appendingPathComponent("got/\(name)")
        try? Data().write(to: dir.appendingPathComponent("want/\(name).\(spec)"))
        let ok = await waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: got.path) }
        entry["capture"] = ok ? "runner" : "runner timeout"
        if let img = NSImage(contentsOf: dir.appendingPathComponent("\(name).png")) { entry["black"] = OnboardingProbe.isBlack(img) }
        shots.append(entry)
        log("shot \(name) \(entry)")
    }

    /// `rect()` under the system Light and Dark appearance.
    static func bothRegion(_ name: String, _ rect: () -> CGRect?, _ meta: [String: Any] = [:]) async {
        let saved = currentLook
        for look in looks {
            setLook(look, restore: saved)
            await settle(700)
            if let r = rect() { await regionShot("\(name)-\(look)", r, meta) } else { notes.append("\(name)-\(look): no region") }
        }
        setLook(nil, restore: saved)
    }

    @MainActor final class MenuBox { var menu: NSMenu? }

    /// The frames of the menus on screen now (AppKit's menu windows), for a region around an open menu.
    static func menuFrames() -> [CGRect] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Menu") }.map(\.frame)
    }

    /// Opens a menu with `open` — run from the run loop, not from this task's main-queue job, so the task keeps running
    /// while AppKit tracks the menu — takes `name` of `around` ∪ the menu, then closes the menu. Light and Dark.
    static func menuShot(_ name: String, around: @escaping () -> CGRect?, open: @escaping @MainActor () -> Void) async -> Bool {
        let box = MenuBox()
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { n in
            nonisolated(unsafe) let menu = n.object as? NSMenu
            MainActor.assumeIsolated { box.menu = menu }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        let saved = currentLook
        var opened = true
        for look in looks {
            setLook(look, restore: saved)
            await settle(500)
            box.menu = nil
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { open() } }
            guard await waitUntil(timeout: 5, { box.menu != nil }) else {
                notes.append("\(name)-\(look): the menu did not open")
                opened = false
                continue
            }
            await settle(700)
            let rect = menuFrames().reduce(around() ?? .null) { $0.union($1) }
            if !rect.isNull { await regionShot("\(name)-\(look)", rect.insetBy(dx: -24, dy: -24)) }
            box.menu?.cancelTracking()
            await settle(600)
        }
        setLook(nil, restore: saved)
        return opened
    }

    /// The accessibility press of the element `id` in `window` (any role: a SwiftUI Menu is a pop-up button).
    static func axPress(_ id: String, in window: NSWindow) -> Bool {
        axPress(in: window) { $0.accessibilityIdentifier() == id }
    }

    /// The accessibility press of the first element in `window` that `match` accepts.
    static func axPress(in window: NSWindow, where match: (NSAccessibilityProtocol) -> Bool) -> Bool {
        func find(_ e: Any, depth: Int) -> NSAccessibilityProtocol? {
            guard depth < 60, let el = e as? NSAccessibilityProtocol else { return nil }
            if match(el) { return el }
            for c in el.accessibilityChildren() ?? [] { if let f = find(c, depth: depth + 1) { return f } }
            return nil
        }
        guard let v = window.contentView, let el = find(v, depth: 0) else { return false }
        return el.accessibilityPerformPress()
    }

    /// The element `id` is somewhere in `window`'s accessibility tree.
    static func axHas(_ id: String, in window: NSWindow) -> Bool {
        func find(_ e: Any, depth: Int) -> Bool {
            guard depth < 60, let el = e as? NSAccessibilityProtocol else { return false }
            if el.accessibilityIdentifier() == id { return true }
            return (el.accessibilityChildren() ?? []).contains { find($0, depth: depth + 1) }
        }
        return window.contentView.map { find($0, depth: 0) } ?? false
    }

    /// `VQ_LEG=m10` (tools/visual/vq-m9.sh m10, `-SimulateUpdatedFrom 0.0.0`): the What's new sheet over the main
    /// window, then (Continue) the first-run tour card on the empty chat. Light and Dark through the app's own Color
    /// mode (`setLook`); the scratch M10 leg's `-AppleInterfaceStyle Dark` never reached the app (harness issue 3).
    static func m10Leg(_ mw: @escaping () -> NSWindow?, main: NSWindow) async {
        // The What's new sheet is its own window (a SwiftUI sheet: `isSheet`, not always main's `attachedSheet`).
        let sheet = { NSApp.windows.first { $0.isVisible && $0 !== main && ($0.isSheet || main.frame.contains($0.frame) || axHas("whatsNew", in: $0)) } }
        let sheetUp = await waitUntil(timeout: 15) { sheet() != nil }
        await settle(800)
        notes.append("whatsNew=\(sheetUp)")
        await bothRegion("m10-whatsnew", { mw()?.frame })
        if let w = sheet() {
            let pressed = axPress(in: w) { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? "") == CopyText(CopyKey("whatsnew.continue")).string }
            if !pressed { MacIntegrationProbe.windowKey(w, "\r", code: 36) }  // Continue is the default button
            notes.append("continue pressed=\(pressed)")
        }
        let closed = await waitUntil(timeout: 10) { sheet() == nil }
        await settle(1200)
        notes.append("sheet closed=\(closed) tourTip=\(axHas("tourTip", in: main))")
        await both(mw, "m10-tour")
        // VQ round 65: the dismissed state (× = Got it, gone for good).
        let dismissed = SettingsProbe.click("tour.dismiss", tracking: false, in: main) || axPress("tour.dismiss", in: main)
        let gone = await waitUntil(timeout: 5) { UIProbeRegistry.frame("tour.dismiss", in: main) == nil }
        await settle(800)
        await both(mw, "m10-tour-dismissed", ["pressed": dismissed, "gone": gone])
        finish()
    }

    /// `VQ_LEG=m9-edit` (scripted engine `vq-chat.jsonl`): S-09 — the inline editor on a sent message (`edit.keepsVersions`),
    /// the edited turn with its version switcher (2/2), the Regenerate popover ("Ask to change response"), the
    /// Versions viewer, the reply's ⋯ menu with Branch in new chat, and the branched chat. Light and Dark.
    static func m9EditLeg(_ mw: @escaping () -> NSWindow?, main: NSWindow, state: WindowState, sessions: ChatSessions) async {
        func idle() async {
            _ = await waitUntil(timeout: 60) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
            await settle(1500)
        }
        let frame = { mw()?.frame }
        sessions.composer.text = "Plan a relaxed weekend in a small harbour town"
        await settle(400)
        _ = sessions.composer.send()
        await idle()
        guard let convo = sessions.current, let user = convo.messages.first(where: { $0.role == .user }) else {
            notes.append("no conversation")
            return finish()
        }
        convo.beginEdit(user.id)
        await settle(900)
        notes.append("editing=\(convo.editingID == user.id)")
        await both(mw, "s09-edit-inline", ["editing": convo.editingID == user.id])
        convo.editText = "Plan a relaxed weekend in a small fishing village"
        convo.submitEdit()
        await idle()
        let edited = convo.messages.first { $0.role == .user }
        notes.append("versions user=\(edited?.version ?? 0)/\(edited?.versionCount ?? 0)")
        await both(mw, "s09-versions", ["userVersion": "\(edited?.version ?? 0)/\(edited?.versionCount ?? 0)"])
        // Regenerate → the popover with "Ask to change response" (a popover window: a region of the main window).
        let pressed = SettingsProbe.click("action.regenerate", tracking: false, in: main) || axPress("action.regenerate", in: main)
        await settle(1000)
        notes.append("regenerate pressed=\(pressed) popover=\(NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") })")
        await bothRegion("s09-regenerate-popover", frame)
        if let pw = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            MacIntegrationProbe.windowKey(pw, "\u{1b}", code: 53)
        }
        await settle(600)
        if let reply = convo.messages.last(where: { $0.role == .assistant }) {
            convo.openVersions(edited?.id ?? user.id)
            await settle(1000)
            notes.append("versionsViewer=\(convo.versionsTarget != nil)")
            await bothRegion("s09-versions-viewer", frame)
            convo.versionsTarget = nil
            await settle(600)
            // The reply's ⋯ menu (Branch in new chat), then the branch itself.
            let menu = await menuShot("s09-more-menu", around: frame) { if let w = mw(), !SettingsProbe.click("action.more", tracking: true, in: w) { _ = axPress("action.more", in: w) } }
            notes.append("more menu=\(menu)")
            let before = state.currentChatID
            let branched = convo.branch(from: reply.id)
            _ = await waitUntil(timeout: 5) { state.currentChatID != before }
            await settle(1200)
            notes.append("branch=\(branched ?? "nil") open=\(state.currentChatID == branched)")
            await both(mw, "s09-branch-new-chat", ["branched": branched ?? ""])
        }
        finish()
    }

    /// `VQ_LEG=m9-mac` (scripted engine `vq-chat.jsonl`): S-22 and S-23 with another app (Finder) in front and the main
    /// window ordered out: the quick panel open (empty), typed, streaming and done (the collapse is a probe note); the menu bar item's menu
    /// idle and with a download progress row. Light and Dark (the app's appearance: panel and menu; the desktop and
    /// the menu bar follow the system).
    static func m9MacLeg(main: NSWindow) async {
        main.orderOut(nil)
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            finder.activate()
        }
        await settle(1500)
        notes.append("front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        let qp = QuickPanelController.shared
        _ = await waitUntil(timeout: 5) { qp.window != nil }
        let now = { ProcessInfo.processInfo.systemUptime }
        let around = { qp.window.map { $0.frame.insetBy(dx: -80, dy: -60) } }
        qp.show(.posted(at: now()))
        await settle(900)
        notes.append("panel visible=\(qp.isVisible) appActive=\(NSApp.isActive)")
        await bothRegion("s22-quickpanel-open", around)
        qp.model.text = "What's 2+2?"
        await settle(300)
        // M10 harness issue: the old `collapsed` shot (Esc on a finished reply) is by design the same empty compact
        // panel as `open` (QuickPanelViewModel.collapse), so the two shots were byte-identical. The question typed
        // before Return is the state that was missing; the collapse is recorded in probe.json instead of shot twice.
        await bothRegion("s22-quickpanel-typed", around, ["text": qp.model.text])
        if let p = qp.window { MacIntegrationProbe.windowKey(p, "\r", code: 36) }
        _ = await waitUntil(timeout: 20) { qp.model.reply.text.count > 40 }
        if let r = around() { await regionShot("s22-quickpanel-streaming-system", r, ["phase": qp.model.phase.rawValue]) }
        _ = await waitUntil(timeout: 60) { qp.model.phase != .streaming }
        await settle(800)
        await bothRegion("s22-quickpanel-done", around, ["phase": qp.model.phase.rawValue])
        if let p = qp.window { MacIntegrationProbe.windowKey(p, "\u{1b}", code: 53) }
        await settle(800)
        notes.append("collapsed after Esc: phase=\(qp.model.phase.rawValue) visible=\(qp.isVisible) size=\(qp.model.size) (= s22-quickpanel-open by design)")
        qp.hide()
        await settle(600)
        // S-23: the status item's menu, idle, then with a download row.
        let mb = MenuBarController.shared
        notes.append("menuBarItem inserted=\(mb.isInserted) titles=\(mb.renderedMenu().map(\.title))")
        let item = { mb.button?.window?.frame.insetBy(dx: -40, dy: -8) }
        if mb.isInserted {
            notes.append("menu idle=\(await menuShot("s23-menubar-menu", around: item) { mb.button?.performClick(nil) })")
            DownloadsLaunch.menuBar.update([PackProgress(pack: "photo", bytesDone: 42, bytesTotal: 100, bytesPerSecond: 1,
                                                         etaSeconds: 58, state: .downloading, errorKey: nil)])
            await settle(600)
            notes.append("menu progress=\(await menuShot("s23-menubar-progress", around: item) { mb.button?.performClick(nil) })")
            DownloadsLaunch.menuBar.update([])
        }
        main.makeKeyAndOrderFront(nil)
        finish()
    }

    // MARK: Voice (M3.T14: S-16 overlay states, the half-duplex hint, S-17 dictation, Settings › Voice)

    /// `VQ_LEG=voice` (tools/visual/vq-m3.sh): a short chat (scripted engine), then each conversation state of the
    /// overlay (`VoiceSessionController.debugPresent`: the overlay as the session drives it, without a helper
    /// session), and Settings › Voice. Light and Dark, 1440×900.
    /// VQ-M10 round 65 (S-16): one real spoken turn in the same chat — the launch's `-UseScriptedVoice` script (a
    /// pre-recorded WAV, vq-m3.sh) through the helper's VAD / smart-turn / Parakeet, the scripted chat reply, Kokoro
    /// TTS — so the capture shows the spoken question and its answer landing in the transcript as normal turns (the
    /// faked states above never send anything: the M10 panel read that as "spoken turns never reach the
    /// transcript"). Each live phase is shot once as it happens (`voice-live-<phase>`); the transcript after the
    /// turn in both looks (`voice-transcript`). Skipped (noted) without a scripted voice script.
    static func voiceLiveTurn(_ mw: @escaping () -> NSWindow?, sessions: ChatSessions, voice: VoiceSessionController) async {
        guard LaunchOptions.current.scriptedVoiceScript != nil else {
            notes.append("live voice turn: skipped (no -UseScriptedVoice)")
            return
        }
        guard let start = sessions.composer.onStartVoice else {
            notes.append("live voice turn: no voice start")
            return
        }
        let before = sessions.current?.messages.count ?? 0
        start()
        var shotPhases: Set<String> = []
        var phases: [String] = []
        var ok = false
        let t0 = ContinuousClock.now
        while PaletteProbe.seconds(ContinuousClock.now - t0) < 120 {
            let p = "\(voice.phase)"
            if phases.last != p { phases.append(p) }
            if voice.phase.isError { break }
            // The conversation is real: each phase is shot once, when it shows (the current look only).
            if ["userSpeaking", "thinking", "speaking"].contains(p), !shotPhases.contains(p) {
                shotPhases.insert(p)
                await shot(mw(), "voice-live-\(p)", ["phase": p])
            }
            if let m = sessions.current, m.messages.count >= before + 2, !m.isGenerating,
               !(m.messages.last?.text.isEmpty ?? true), voice.phase != .thinking {
                ok = true
                if voice.phase == .speaking || shotPhases.contains("speaking") { break }
            }
            await settle(50)
        }
        await settle(300)
        _ = await waitUntil(timeout: 60) { voice.phase == .listening || voice.phase.isError }
        await settle(1200)
        let messages = sessions.current?.messages ?? []
        notes.append("live voice turn ok=\(ok) phases=\(phases) messages \(before)→\(messages.count) "
                     + "user=\"\(messages.dropLast().last?.text ?? "")\" error=\(voice.lastError ?? "-")")
        await both(mw, "voice-transcript", ["phases": phases, "messages": messages.count])
        voice.end()
        _ = await waitUntil(timeout: 20) { voice.phase == .idle || voice.phase.isError }
        await settle(600)
    }

    static func voiceLeg(_ mw: @escaping () -> NSWindow?, state: WindowState, sessions: ChatSessions) async {
        await both(mw, "voice-chat-empty")
        sessions.composer.text = "What should I pack for a spring weekend in Lisbon?"
        await settle(400)
        let sent = sessions.composer.send()
        _ = await waitUntil(timeout: 60) { !(sessions.current?.isGenerating ?? false) && sessions.current?.messages.count ?? 0 >= 2 }
        await settle(1200)
        notes.append("chat sent=\(sent) messages=\(sessions.current?.messages.count ?? 0)")
        guard let voice = sessions.voice else {
            notes.append("no voice controller")
            return finish()
        }
        let states: [(String, VoiceSessionController.Phase, String, Bool, Float)] = [
            ("voice-connecting", .connecting, "", false, -120),
            ("voice-listening", .listening, "", false, -38),
            ("voice-user-speaking", .userSpeaking, "And what about shoes for the hills", false, -18),
            ("voice-thinking", .thinking, "", false, -60),
            ("voice-speaking", .speaking, "Comfortable walking shoes with good grip — Lisbon's hills and cobbles are steep.", false, -60),
            ("voice-halfduplex-hint", .listening, "", true, -40),
            ("voice-error-nodevice", .error("voice.noDevice"), "", false, -120),
        ]
        for (name, phase, caption, half, level) in states {
            voice.debugPresent(phase, caption: caption, halfDuplex: half, level: level)
            await settle(900)
            await both(mw, name, ["phase": "\(phase)", "halfDuplex": half])
        }
        voice.debugPresent(.idle)
        await settle(600)
        await voiceLiveTurn(mw, sessions: sessions, voice: voice)
        SettingsProbe.main = NSApp.windows.first { $0.isVisible && $0.title == "AntiChat" }
        notes.append("settings opened via \(await SettingsProbe.openSettingsWithCommandComma())")
        let sw = { SettingsProbe.settingsWindow }
        sw()?.setFrameOrigin(CGPoint(x: 200, y: 120))
        SettingsModel.shared.open(.voice)
        await settle(1500)
        await both(sw, "settings-voice")
        finish()
    }
}
#endif
