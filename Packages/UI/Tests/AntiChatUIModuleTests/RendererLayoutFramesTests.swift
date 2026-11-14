// AT-008 leg 4, layout-jump half (M1.T09): the screen recording of the live window is not usable on this shared
// desktop (other apps' windows overlap the crop, and the transcript is free to scroll), so the renderer is filmed
// in isolation: `mixed-3k.jsonl` is replayed into a reply at its own token timing, the reveal clock runs at 30 Hz,
// and every 3rd clock frame the reply view (fixed width, top-anchored, fixed height) is captured to
// build/at/AT-008/frames/NNNN.png. `tools/visual/layout-jump.py build/at/AT-008/frames` then measures how far any
// already-rendered row moved between frames (pass: 0 jumps > 4 px). Opt-in (≈ 40 s): AT008_FRAMES=1.
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AT008_FRAMES"] == "1"), .isolatedSettings)
struct RendererLayoutFramesTests {
    static func script() throws -> [(text: String, delayMs: Int)] {
        var url = RendererRig.repoRoot.appendingPathComponent("fixtures/scripts/mixed-3k.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            url = RendererRig.repoRoot.appendingPathComponent("tools/fixtures/scripts/mixed-3k.jsonl")
        }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{"), let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                d["t"] as? String == "textDelta", let v = d["v"] as? String
            else { return nil }
            return (v, d["delayMs"] as? Int ?? 0)
        }
    }

    @Test func captureStreamingFrames() async throws {
        let deltas = try Self.script()
        let full = deltas.map(\.text).joined()
        let out = RendererRig.repoRoot.appendingPathComponent("build/at/AT-008/frames")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Final height first, so every frame has the same size (ffmpeg needs one size).
        let done = RendererRig.Host(MessageMarkdownView(text: full, streaming: false), look: .light)
        await done.settle(min: 1)
        let height = done.host.frame.height + 40

        let binder = StreamingMarkdownBinder(text: "", streaming: true)
        let view = MessageMarkdownView(binder: binder).frame(height: height - 32, alignment: .top)
        let h = RendererRig.Host(view, look: .light)
        var clock = 0.0  // virtual stream time (s)
        var next = 0
        var arrived = ""
        var frame = 0
        var tick = 0
        let dt = 1.0 / 30
        var due = 0.0
        while next < deltas.count || binder.reveal.backlog > 1 {
            clock += dt
            while next < deltas.count, due + Double(deltas[next].delayMs) / 1000 <= clock {
                due += Double(deltas[next].delayMs) / 1000
                arrived += deltas[next].text
                next += 1
            }
            binder.update(text: arrived, streaming: next < deltas.count, interrupted: false)
            binder.tick(now: clock)
            try? await Task.sleep(for: .milliseconds(Int(dt * 1000)))
            h.layout()
            tick += 1
            if tick % 3 == 0 {
                frame += 1
                let rep = h.host.bitmapImageRepForCachingDisplay(in: h.host.bounds)!
                h.host.cacheDisplay(in: h.host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: out.appendingPathComponent(String(format: "%04d.png", frame)))
            }
            if tick > 4000 { break }
        }
        print("RendererLayoutFramesTests: \(frame) frames, \(tick) ticks, height \(height)")
        #expect(frame > 50)
        #expect(binder.reveal.shownText == full.trimmingCharacters(in: .whitespacesAndNewlines) || binder.reveal.backlog <= 1)
    }
}
}  // extension WindowSuites
