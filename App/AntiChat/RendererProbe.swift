// AT-008 leg 4 in-process renderer probe (M1.T09). XCUITest is blocked on this Mac (Q-015), so — like WindowProbe —
// the app measures itself: it sends one prompt through the real window (composer path → TurnController → the
// `-UseScriptedEngine` script, normally `mixed-3k.jsonl`), and while the reply streams records
//   - every reveal apply (`rendererApply`: time, words) and every parse-result commit,
//   - every display frame (CADisplayLink) and whether a word was mid-fade in it,
//   - main-thread passes > 33 ms (`RendererCPUThrottle`, with `-RendererCPUScale 0.25` = the S1 stand-in),
// then writes `<dir>/renderer.json` (+ window captures) and quits. `tools/at/at-008-probe.sh` runs it beside a
// display-rate screen recording for frametime.py / layout-jump.py. DEBUG only (`-RendererProbe <dir>`).
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
enum RendererProbe {
    private static var started = false
    static let prompt = "Walk me through a market day in numbers, with code and a table."

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        FileHandle.standardError.write(Data("RendererProbe: start → \(out)\n".utf8))
        Task { @MainActor in
            await run(state, sessions: sessions, dir: URL(fileURLWithPath: out, isDirectory: true))
            NSApp.terminate(nil)
        }
    }

    /// Display-frame sampler: one callback per screen refresh of the window's display (main run loop).
    @MainActor
    final class FrameSampler: NSObject {
        var frames: [Double] = []
        var fadeFrames = 0
        var link: CADisplayLink?
        let probe: MarkdownProbe

        init(view: NSView, probe: MarkdownProbe) {
            self.probe = probe
            super.init()
            link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }

        @objc func tick(_ link: CADisplayLink) {
            frames.append(link.timestamp)
            probe.sampleFade()
        }

        func stop() { link?.invalidate() }
    }

    static func stats(_ xs: [Double]) -> [String: Double] {
        guard !xs.isEmpty else { return [:] }
        let s = xs.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        return ["n": Double(s.count), "min": s.first!, "median": q(0.5), "p95": q(0.95), "max": s.last!,
                "mean": s.reduce(0, +) / Double(s.count)]
    }

    static func intervalsMs(_ ts: [Double]) -> [Double] { zip(ts, ts.dropFirst()).map { ($1 - $0) * 1000 } }

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // M9.T05 prep: wait for the main window like A11yProbe (state.window); the title lookup alone found nothing
        // in a background run (BackgroundRun since 8e40f7a01), so U5 wrote only {"error": "no AntiChat window"}.
        _ = await SettingsProbe.waitUntil(timeout: 20) { state.window != nil }
        try? await Task.sleep(for: .milliseconds(500))
        guard let window = state.window ?? NSApp.windows.first(where: { $0.isVisible && $0.title == "AntiChat" }),
            let content = window.contentView
        else {
            write(["error": "no AntiChat window"], dir: dir)
            return
        }
        window.setFrame(CGRect(x: 80, y: 80, width: 1180, height: 820), display: true)
        BackgroundRun.makeKeyAndOrderFront(window)
        BackgroundRun.activate()
        try? await Task.sleep(for: .milliseconds(800))
        // fix/u5-renderer long-chat variant: `-RendererProbeChat <chat id>` streams the reply into an existing chat
        // (tools/at/at-008-longchat.sh seeds one with 60+ finished Markdown replies) instead of a new one.
        var seededRows = 0
        if let i = CommandLine.arguments.firstIndex(of: "-RendererProbeChat"), i + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[i + 1]
            state.open(.chat(id))
            _ = await SettingsProbe.waitUntil(timeout: 20) {
                state.currentChatID == id && !sessions.model(for: id).messages.isEmpty
            }
            seededRows = sessions.model(for: id).messages.count
            FileHandle.standardError.write(Data("RendererProbe: chat \(id) with \(seededRows) rows\n".utf8))
            try? await Task.sleep(for: .seconds(2))  // the transcript opens and settles before the send
        }

        let probe = MarkdownProbe()
        MarkdownProbe.current = probe
        RendererCPUThrottle.shared.reset()
        let sampler = FrameSampler(view: content, probe: probe)
        let t0 = CACurrentMediaTime()
        FileHandle.standardError.write(Data("RendererProbe: send at \(t0)\n".utf8))
        state.send(prompt, turn: sessions.slots.startTurn)

        // Wait for the reply to finish (status leaves pending/streaming) and the reveal + fade to settle.
        var finishedAt: Double?
        while CACurrentMediaTime() - t0 < 180 {
            try? await Task.sleep(for: .milliseconds(50))
            guard let m = state.currentChatID.map { sessions.model(for: $0) }?.messages.last, m.role == .assistant else { continue }
            if m.status != .pending, m.status != .streaming, finishedAt == nil { finishedAt = CACurrentMediaTime() }
            if let f = finishedAt, CACurrentMediaTime() - f > 1.5 { break }
        }
        sampler.stop()
        let message = state.currentChatID.map { sessions.model(for: $0) }?.messages.last
        let applies = probe.applies
        let firstApply = applies.first?.time ?? t0
        let lastApply = applies.last?.time ?? t0
        // Display frames while text was being revealed (first → last apply).
        let streamFrames = sampler.frames.filter { $0 >= firstApply && $0 <= lastApply }
        let applyIntervals = intervalsMs(applies.map(\.time))
        let commitIntervals = intervalsMs(probe.commits.filter { $0 >= firstApply && $0 <= lastApply + 0.1 })
        let frameIntervals = intervalsMs(streamFrames)
        let words = applies.reduce(0) { $0 + $1.words }
        let revealSeconds = lastApply - firstApply
        let throttle = RendererCPUThrottle.shared
        let cadenceMedian = stats(applyIntervals)["median"] ?? 0
        let cadenceOK = cadenceMedian >= 16.0 && cadenceMedian <= 33.4
        let hitchesOK = throttle.hitches == 0
        let shot = dir.appendingPathComponent("final.png")
        WindowProbe.capture(window, to: shot)

        let screenFrame = window.frame
        let scale = window.screen?.backingScaleFactor ?? 2
        let screenHeight = window.screen?.frame.height ?? 0
        let result: [String: Any] = [
            "pass": cadenceOK && hitchesOK && probe.fadeFrames > 0,
            "label": LaunchOptions.current.rendererCPUScale.map { "S1 stand-in -RendererCPUScale \($0) [ASSUMPTION]" }
                ?? "S4 (this Mac)",
            "script": LaunchOptions.current.scriptedEngineScript ?? "real engine",
            "status": message.map { "\($0.status)" } ?? "none",
            "replyChars": message?.text.count ?? 0,
            "chatRowsBeforeSend": seededRows,
            "revealedWords": words,
            "revealSeconds": revealSeconds,
            "applies": applies.count,
            "applyIntervalMs": stats(applyIntervals),
            "applyHz": revealSeconds > 0 ? Double(applies.count - 1) / revealSeconds : 0,
            "parseCommitIntervalMs": stats(commitIntervals),
            "displayFrameIntervalMs": stats(frameIntervals),
            "framesWithFadingWords": probe.fadeFrames,
            // fix/u5-renderer: frames with any fading draw (header labels included: the old counter's view), and
            // the renderer's draw counts (bodyDraws 0 = the fade renderer never drew the reply text).
            "framesWithAnyFadingText": probe.anyFadeFrames,
            "fadeDraws": ["draws": probe.fadeDraws.draws, "fading": probe.fadeDraws.fading,
                          "bodyDraws": probe.fadeDraws.body, "bodyFading": probe.fadeDraws.bodyFading],
            "liveBlocksSelectable": ProcessInfo.processInfo.arguments.contains("-RendererLiveSelectable"),
            "displayFramesWhileRevealing": streamFrames.count,
            "mainThread": ["passes": throttle.passes, "hitchesOver33ms": throttle.hitches,
                           "longestPassMs": throttle.longestPassMs,
                           "cpuScale": LaunchOptions.current.rendererCPUScale ?? 1],
            "legs": [
                "cadence 30–60 Hz (median apply interval 16.7–33.3 ms)": ["pass": cadenceOK, "medianMs": cadenceMedian],
                "0 main-thread frames > 33 ms": ["pass": hitchesOK, "hitches": throttle.hitches],
                "per-word fade active": ["pass": probe.fadeFrames > 0, "frames": probe.fadeFrames],
            ],
            // For tools/at/at-008-probe.sh: crop the screen recording to this window (pixels, origin top-left).
            "windowPixels": [
                "x": Int(screenFrame.minX * scale), "y": Int((screenHeight - screenFrame.maxY) * scale),
                "w": Int(screenFrame.width * scale), "h": Int(screenFrame.height * scale), "scale": scale,
            ],
            "t0": t0, "firstApply": firstApply, "lastApply": lastApply,
            // fix/u5-renderer-2: passes > 100 ms, seconds relative to the first apply (negative = before the reveal,
            // after lastApply - firstApply = the finish / settle).
            "longPasses": throttle.longPasses.map { ["at": $0.end - firstApply, "ms": $0.ms] },
            // fix/u5-renderer-4: every pass > 33 ms, with the reveal position (bytes, blocks) of the last apply
            // before it ended.
            "hitchPasses": throttle.hitchPasses.map { h -> [String: Any] in
                let last = applies.last { $0.time <= h.end }
                return ["at": h.end - firstApply, "ms": h.ms, "bytes": last?.bytes ?? 0, "blocks": last?.blocks ?? 0]
            },
            "finishedAt": finishedAt.map { $0 - firstApply } ?? -1,
        ]
        write(result, dir: dir)
        MarkdownProbe.current = nil
    }

    static func write(_ obj: [String: Any], dir: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: dir.appendingPathComponent("renderer.json"))
    }
}
#endif
