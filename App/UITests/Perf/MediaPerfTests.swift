// M9.T05 XCUITest perf legs for media jobs, each writing its timings to build/at/<AT>/perf-uitest.json:
//   ImageProgressPerfTests (NFR-P3, AT-NFR-P3; ImageJobCardTests/testNeverStaleThreeSeconds as a measurement): the job
//     card's on-screen progress never stays unchanged > 3 s while the job runs (ScriptedImageEngine, 4 s per step: the
//     hardest case for the card's own elapsed/indeterminate cues). Samples the card every 250 ms (label + pixels).
//   VideoPausedPerfTests (NFR-B5, AT-NFR-B5; VideoJobCardTests/testPausedForOtherApp as a measurement): a running video
//     job (ScriptedVideoEngine) with `build/tools/gpu-burn --seconds 30` started beside it → "Paused for another app"
//     within 12 s of the other app's GPU load, and the job resumes after the load stops.
// The bars are asserted here (no perf-log interval exists for them) and the JSON is the T05 record.
import AppKit
import XCTest

enum MediaPerfApp {
    static func file(_ name: String, _ body: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? Data(body.utf8).write(to: url)
        return url.path
    }

    static let createImageTurn = #"{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1}"#

    @MainActor
    static func image(_ imageScript: String, log: URL? = nil) -> XCUIApplication {
        PerfUI.launch(container: PerfUI.tempContainer("p3"), log: log, [
            "-SkipOnboarding", "YES", "-UseScriptedEngine", file("create-image.jsonl", createImageTurn + "\n"),
            "-UseScriptedImageEngine", file("image.json", imageScript), "-FakePackState", "photo=ready",
            // A tool-capable chat slot (a fresh container's chat-only starter is offered no tools, D-023 a).
            "-ChatModel", "chat-9b-q4"])
    }

    @MainActor
    static func video(steps: Int, delayMs: Int, log: URL? = nil) -> XCUIApplication {
        let script = file("video.json", #"{"steps":\#(steps),"delayMs":\#(delayMs),"frames":48,"fps":16,"previewFrames":6}"#)
        return PerfUI.launch(container: PerfUI.tempContainer("b5"), log: log, [
            // The scripted chat calls `create_video` (a tool-capable chat slot) → the plan card → Start → the job.
            "-SkipOnboarding", "YES", "-UseScriptedEngine", PerfUI.script("voice-create-video.jsonl"), "-ChatModel", "chat-9b-q4",
            "-UseScriptedVideoEngine", script, "-FakeHardware", "T3",
            "-FakePower", "ac", "-FakeInstalledPacks", "chat,photo,video"])
    }
}

final class ImageProgressPerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testProgressNeverStaleThreeSeconds() throws {
        let app = MediaPerfApp.image(#"{"steps":4,"delayMs":4000}"#)
        PerfUI.send(app, "Draw me a lighthouse at dusk")
        let card = PerfUI.element(app, "imageJobCard")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "image job card")
        let result = PerfUI.element(app, "imageJobCard.result")
        let progress = PerfUI.element(app, "imageJobCard.progress")
        // Pixels of the card's area from a window capture (the card itself may be replaced by the result between an
        // existence check and its own screenshot, which fails the test).
        let window = PerfUI.mainWindow(app)
        let area = card.frame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        func cardPixels() -> Data {
            let img = window.screenshot().image
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Data() }
            let s = CGFloat(cg.width) / max(1, img.size.width)
            let r = CGRect(x: area.minX * s, y: area.minY * s, width: area.width * s, height: area.height * s)
            guard let c = cg.cropping(to: r), let d = c.dataProvider?.data else { return Data() }
            return d as Data
        }
        var last = cardPixels(), lastLabel = progress.exists ? progress.label : ""
        var lastChange = Date(), lastLabelChange = Date(), maxStale = 0.0, maxLabelStale = 0.0, samples = 0, changes = 0
        let t0 = Date()
        // Until the result shows or the running card is replaced by it (the job ended).
        while !result.exists, Date().timeIntervalSince(t0) < 60 {
            usleep(250_000)
            guard card.exists, progress.exists else { break }
            let label = progress.label, png = cardPixels()
            samples += 1
            let labelChanged = label != lastLabel
            if labelChanged { lastLabel = label; lastLabelChange = Date() }
            if png != last || labelChanged {
                changes += 1
                last = png
                lastChange = Date()
            }
            maxStale = max(maxStale, Date().timeIntervalSince(lastChange))
            maxLabelStale = max(maxLabelStale, Date().timeIntervalSince(lastLabelChange))
        }
        let jobS = Date().timeIntervalSince(t0)
        let done = result.exists || !progress.exists
        app.terminate()
        // Gate: what the user sees on the card (pixels or the progress text) changes at least every 3 s; the text alone is
        // reported too (`max_label_stale_s`: a card whose only motion is an animation would show up there).
        let out: [String: Any] = ["metric": "NFR-P3", "bar": "progress never stale > 3 s", "max_stale_s": maxStale,
                                  "max_label_stale_s": maxLabelStale, "samples": samples,
                                  "changes": changes, "job_s": jobS, "job_ended": done,
                                  "script": "ScriptedImageEngine 4 steps × 4000 ms", "load": PerfUI.loadAverage(), "date": PerfUI.utc()]
        PerfUI.writeJSON(out, to: PerfUI.atDir("AT-NFR-P3").appendingPathComponent("perf-uitest.json"))
        PerfUI.evidence("AT-NFR-P3", out)
        XCTAssertTrue(done, "the job ended within 60 s")
        XCTAssertGreaterThan(samples, 8)
        XCTAssertLessThanOrEqual(maxStale, 3.0, "NFR-P3: progress unchanged for \(maxStale) s")
    }
}

/// M9.T05 (NFR-P2, AT-NFR-P2 under A-M4-R1 / A-M4-R1b): the first visible preview. Previews below the check's valid
/// size (512 px; every T3+ sd-server step preview, ~128 px at 1024²) are withheld, and the card shows its visible
/// progress state instead — the dot matrix with the % pill. This leg measures what the user sees: the picture is
/// requested (the create_image call starts) → that state is on screen (`imageFirstVisible`, perf log), one fresh app per
/// run. The bar is the strictest class's (S4 ≤ 1 s): the state is drawn by the app before the generator's first step, so
/// no class may be slower than a frame budget here. The first REAL step (% > 0) is recorded by `-Bench image` as
/// `first_step_s` (sd-scale `m0.P2step1.*`, diagnostic: text encode + one full step).
final class ImageFirstVisiblePerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testFirstVisibleProgressState() throws {
        let runs = min(PerfUI.runs, 10)
        let log = PerfUI.perfLog("ImageFirstVisiblePerfTests")
        var seen = 0
        for _ in 0..<runs {
            let app = MediaPerfApp.image(#"{"steps":4,"delayMs":1500}"#, log: log)
            PerfUI.send(app, "Draw me a lighthouse at dusk")
            XCTAssertTrue(PerfUI.element(app, "imageJobCard").waitForExistence(timeout: 30), "image job card")
            let n = PerfUI.waitIntervals(log, "imageFirstVisible", atLeast: seen + 1, timeout: 10)
            XCTAssertGreaterThan(n, seen, "the card's first visible progress state was recorded")
            seen = n
            app.terminate()
        }
        let xs = PerfUI.intervals(log, "imageFirstVisible").compactMap { ($0["dur_ns"] as? NSNumber)?.doubleValue }.map { $0 / 1e9 }.sorted()
        func pct(_ p: Double) -> Double {
            guard !xs.isEmpty else { return -1 }
            let k = Double(xs.count - 1) * p
            let f = Int(k), c = min(f + 1, xs.count - 1)
            return xs[f] + (xs[c] - xs[f]) * (k - Double(f))
        }
        let out: [String: Any] = ["metric": "NFR-P2", "bar": "first visible progress state (A-M4-R1b) ≤ 1 s (S4; strictest class)",
                                  "definition": "create_image call starts (ToolActivity.startedAt) → job card's dot matrix + % pill on screen",
                                  "n": xs.count, "p50_s": pct(0.5), "p95_s": pct(0.95), "max_s": xs.last ?? -1, "values_s": xs,
                                  "script": "ScriptedImageEngine 4 steps × 1500 ms (the state is drawn before the engine's first step)",
                                  "log": log.path, "load": PerfUI.loadAverage(), "date": PerfUI.utc()]
        PerfUI.writeJSON(out, to: PerfUI.atDir("AT-NFR-P2").appendingPathComponent("perf-uitest.json"))
        PerfUI.evidence("AT-NFR-P2", out)
        XCTAssertEqual(xs.count, runs, "one imageFirstVisible per run")
        XCTAssertLessThanOrEqual(pct(0.5), 1.0, "NFR-P2: first visible progress state p50 \(pct(0.5)) s")
    }
}

final class VideoPausedPerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPausedForOtherApp() throws {
        let burn = PerfUI.repoRoot.appendingPathComponent("build/tools/gpu-burn")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: burn.path), "tools/perf/gpu-burn/build.sh first")
        // M9.T05: the app's perf log carries the helper's gpuYield / gpuYieldHold notes (busiest other process, share).
        let log = PerfUI.perfLog("B5")
        let helperLogs = Self.helperLogSizes()  // the helper's own log: the per-job summary (top GPU users) lands there
        let app = MediaPerfApp.video(steps: 20, delayMs: 2000, log: log)
        let input = PerfUI.element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("Make a short video of waves rolling onto a beach at dusk")
        input.typeKey(.return, modifierFlags: [])
        let start = PerfUI.element(app, "videoPlan.start")
        if !start.waitForExistence(timeout: 30) { add(XCTAttachment(screenshot: app.screenshot())) }
        XCTAssertTrue(start.exists, "plan card")
        start.click()
        XCTAssertTrue(PerfUI.element(app, "videoJobCard").waitForExistence(timeout: 30), "job card")
        sleep(3)  // the job is running before the other app starts
        let p = Process()
        p.executableURL = burn
        p.arguments = ["--seconds", "30"]
        try p.run()
        let tBurn = Date()
        defer { if p.isRunning { p.terminate() } }
        let paused = PerfUI.element(app, "videoJobPaused")
        let pausedSeen = PerfUI.wait(paused, timeout: 20)
        let pauseS = Date().timeIntervalSince(tBurn)
        p.waitUntilExit()
        let tStop = Date()
        let resumed = PerfUI.wait(paused, gone: true, timeout: 40)
        let resumeS = Date().timeIntervalSince(tStop)
        let cardStill = PerfUI.element(app, "videoJobCard").exists || PerfUI.element(app, "videoJobResult").exists
        app.terminate()
        let notes = Self.gpuYieldNotes(log)
        let helperLines = Self.helperGPUYieldLines(since: helperLogs)
        // Who held the job paused (gpuYieldHold samples per process): a miss names the process.
        let holders = Dictionary(grouping: notes.filter { $0["action"] == "gpuYieldHold" }.compactMap { $0["process"] }
            .filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        let out: [String: Any] = ["metric": "NFR-B5", "bar": "paused for another app ≤ 12 s after its GPU load; resumes after it stops",
                                  "paused": pausedSeen, "burn_to_paused_s": pausedSeen ? pauseS : -1, "resumed": resumed,
                                  "burn_end_to_resumed_s": resumed ? resumeS : -1, "job_alive": cardStill,
                                  "script": "ScriptedVideoEngine 20 steps × 2000 ms, -FakeHardware T3", "gpu_burn_s": 30,
                                  "load": PerfUI.loadAverage(), "date": PerfUI.utc(),
                                  "gpu_yield_notes": notes, "gpu_yield_last": notes.last ?? [:], "gpu_yield_holders": holders,
                                  "gpu_yield_busy": Dictionary(grouping: notes.filter { $0["action"] == "gpuYieldBusy" }
                                      .compactMap { $0["process"] }, by: { $0 }).mapValues(\.count),
                                  "helper_gpu_yield_log": helperLines, "perf_log": log.path]
        PerfUI.writeJSON(out, to: PerfUI.atDir("AT-NFR-B5").appendingPathComponent("perf-uitest.json"))
        PerfUI.evidence("AT-NFR-B5", out)
        XCTAssertTrue(pausedSeen, "\"Paused for another app\" shown")
        XCTAssertLessThanOrEqual(pauseS, 14, "paused within 12 s (+ UI)")
        XCTAssertTrue(resumed, "the job resumed after the other app's load stopped (last sampler note: \(notes.last ?? [:]))")
    }

    /// The helper's file log directory (Debug / perf-harness builds log under AntiChat-Dev).
    static var helperLogDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AntiChat-Dev/engine")
    }

    /// Byte size of each helper log now (lines appended after this are the run's).
    static func helperLogSizes() -> [String: Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: helperLogDir.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.filter { $0.hasSuffix(".log") }.map { n in
            (n, ((try? FileManager.default.attributesOfItem(atPath: helperLogDir.appendingPathComponent(n).path))?[.size] as? Int) ?? 0)
        })
    }

    /// The helper's `gpuYield…` lines appended since `sizes` (start, notes, the job summary with its top GPU users).
    static func helperGPUYieldLines(since sizes: [String: Int]) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: helperLogDir.path)) ?? []
        var out: [String] = []
        for n in names.sorted() where n.hasSuffix(".log") {
            guard let d = FileManager.default.contents(atPath: helperLogDir.appendingPathComponent(n).path) else { continue }
            let from = min(sizes[n] ?? 0, d.count)
            out += String(decoding: d[from...], as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.contains("gpuYield") }
        }
        return out
    }

    /// The `gpuYield` events of the app's perf log (meta: action, yielding, process, share, quiet_s, mode, job).
    static func gpuYieldNotes(_ log: URL) -> [[String: String]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["name"] as? String == "gpuYield", var meta = o["meta"] as? [String: String] else { return nil }
            meta["end_ns"] = (o["end_ns"] as? NSNumber)?.stringValue
            return meta
        }
    }
}
