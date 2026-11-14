// AT-285 AC1 + AC5 runner legs (M4.T04, written for M4.T03): with the gate's forced verdict (the UI-testing seam,
// compiled only under ANTICHAT_UI_TESTING, which no Debug/Release configuration defines), a ScriptedImageEngine job
// through MediaJobRunner makes exactly one gate call per preview and one per final (4 + 1 = 5), and writes only what
// was allowed; a forced block writes nothing at all (no preview, no result), stops the job and reports `jobBlocked`
// with no reason; a block arriving at a later preview stops the job before any result. Content-free gradients only.
// Run: tools/at/at-285-runner.sh (its own scratch build with `-DANTICHAT_UI_TESTING`). In the ordinary unit run this
// file compiles to nothing; the zero-call legs for non-media flows are App/IntegrationTests/R241PathTests.
#if ANTICHAT_UI_TESTING
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct R241PathTraceTests {
    static func job(steps: Int = 4, dir: URL) -> ImageRequest {
        ImageRequest(model: ScriptedImageEngine.modelSet(footprint: 1 << 20, steps: steps, ms: 2), prompt: "a lighthouse",
                     width: 768, height: 512, steps: steps, seed: 3, outputPath: dir.appendingPathComponent("result.png").path)
    }

    @Test func onePerPreviewAndOnePerFinal() async throws {
        let dir = RunnerHarness.temp("trace")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
                let events = EventLog()
        let xfer = dir.appendingPathComponent("xfer")
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let r = try await RunnerHarness.run(Self.job(dir: dir), runner: runner, previewDir: xfer, events: events)
        #expect(r.status == "completed")
        #expect(await runner.gateCalls(.preview) == 4)
        #expect(await runner.gateCalls(.result) == 1)
        #expect(await runner.gateCalls(.video) == 0)
        #expect(RunnerHarness.files(xfer).count == 4 && FileManager.default.fileExists(atPath: r.path))
        let ev = events.all
        #expect(ev.filter { if case .jobProgress(_, _, _, let p) = $0 { p != nil } else { false } }.count == 4)
        if case .jobResult(_, let path, let meta) = ev.last { #expect(path == r.path && meta["seed"] == "3") } else {
            Issue.record("last event \(String(describing: ev.last))")
        }
    }

    @Test func blockedWritesNothingAndCarriesNoReason() async throws {
        let dir = RunnerHarness.temp("block")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .block
                let events = EventLog()
        let cancel = EngineRuntime.CancelFlag()
        let xfer = dir.appendingPathComponent("xfer")
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let r = try await RunnerHarness.run(Self.job(steps: 6, dir: dir), runner: runner, previewDir: xfer, cancel: cancel, events: events)
        #expect(r.status == "blocked" && r.path.isEmpty)
        #expect(cancel.isCancelled, "the remaining work stops")
        #expect(RunnerHarness.files(dir).filter { $0 != "xfer" }.isEmpty && RunnerHarness.files(xfer).isEmpty)
        #expect(await runner.gateCalls(.preview) == 1)
        #expect(await runner.gateCalls(.result) == 0)
        let ev = events.all
        #expect(ev.last == .jobBlocked(job: ev.last!.job))
        #expect(!ev.contains { if case .jobProgress = $0 { true } else { false } })
    }

    /// AT-033 AC1 (M4.T13): an edit job (kind `edit`, the source as a reference picture) passes the gate like any Photo
    /// output — one call per preview and one per final, through the same runner — and a block still writes nothing.
    @Test func testEditJobGateCalls() async throws {
        let dir = RunnerHarness.temp("edit")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("source.png")
        try ScriptedImageEngine.gradientPNG(width: 96, height: 64, phase: 0.3).write(to: source)
        var edit = Self.job(dir: dir)
        edit.refImagePaths = [source.path]
        let req = edit
        ForcedVerdictCheck.current = .allow
        let xfer = dir.appendingPathComponent("xfer")
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = ScriptedImageEngine()
        let events = EventLog()
        let terminal = await runner.run(MediaJobSubmit(job: "edit-1", kind: .edit, image: req, previewDir: xfer.path, safety: nil),
                                        emit: { events.append($0) }) { o in
            _ = try await engine.run(req, isCancelled: { false }, outputs: o, emit: { _ in })
            return .completed
        }
        guard case .jobResult(_, let path, _) = terminal else { Issue.record("\(terminal)"); return }
        let p1 = await runner.gateCalls(.preview), r1 = await runner.gateCalls(.result)
        #expect(p1 == 4 && r1 == 1)
        #expect(FileManager.default.fileExists(atPath: path) && RunnerHarness.files(xfer).count == 4)

        ForcedVerdictCheck.current = .block
        let out2 = dir.appendingPathComponent("blocked")
        var blockedReq = req
        blockedReq.outputPath = out2.appendingPathComponent("result.png").path
        let req2 = blockedReq
        let blocked = await runner.run(MediaJobSubmit(job: "edit-2", kind: .edit, image: req2, previewDir: out2.path, safety: nil),
                                       emit: { _ in }) { o in
            _ = try await engine.run(req2, isCancelled: { false }, outputs: o, emit: { _ in })
            return .completed
        }
        #expect(blocked == .jobBlocked(job: "edit-2") && RunnerHarness.files(out2).isEmpty)
        let p2 = await runner.gateCalls(.preview), r2 = await runner.gateCalls(.result)
        #expect(p2 == 5 && r2 == 1, "the block stopped it at its first preview")
    }

    /// AT-034 / R-034 step 6 (M4.T15): a `local` job (Remove background, Vision) is a Photo output too — exactly one
    /// gate call for its one result, none for previews; allowed → written; blocked → nothing written, `jobBlocked`.
    @Test func testLocalJobGateCalls() async throws {
        let dir = RunnerHarness.temp("local")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A content-free scene: a flat background with one solid disc (a clear subject for Vision).
        let side = 256
        var px = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side { for x in 0..<side {
            let i = (y * side + x) * 4, inDisc = (x - 128) * (x - 128) + (y - 128) * (y - 128) < 60 * 60
            px[i] = inDisc ? 220 : 40; px[i + 1] = inDisc ? 60 : 120; px[i + 2] = inDisc ? 40 : 200
        } }
        let src = dir.appendingPathComponent("src.png")
        try MaskCompositor.png(MaskCompositor.image(rgba: px, width: side, height: side)!)!.write(to: src)
        func request(_ out: String) -> ImageRequest {
            var r = ImageRequest(model: ImageModelSet(key: "apple-vision", diffusionModel: "", llm: "", vae: "", footprintBytes: 0),
                                 prompt: "", width: side, height: side, steps: 1, seed: 0, preview: "none",
                                 outputPath: dir.appendingPathComponent(out).appendingPathComponent("result.png").path)
            r.initImagePath = src.path
            r.localOperation = LocalImageJob.removeBackground
            return r
        }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        ForcedVerdictCheck.current = .allow
        let ok = request("allow")
        let t1 = await runner.run(MediaJobSubmit(job: "local-1", kind: .local, image: ok, safety: nil), emit: { _ in }) { o in
            try await LocalImageJob.run(ok, outputs: o, eraser: { _ in nil }, isCancelled: { false })
        }
        if case .jobResult(_, let path, _) = t1 { #expect(FileManager.default.fileExists(atPath: path)) } else { Issue.record("\(t1)") }
        let p1 = await runner.gateCalls(.preview), r1 = await runner.gateCalls(.result)
        #expect(p1 == 0 && r1 == 1)

        ForcedVerdictCheck.current = .block
        let no = request("block")
        let t2 = await runner.run(MediaJobSubmit(job: "local-2", kind: .local, image: no, safety: nil), emit: { _ in }) { o in
            try await LocalImageJob.run(no, outputs: o, eraser: { _ in nil }, isCancelled: { false })
        }
        #expect(t2 == .jobBlocked(job: "local-2") && !FileManager.default.fileExists(atPath: no.outputPath))
        let r2 = await runner.gateCalls(.result)
        #expect(r2 == 2)
    }

    /// A later preview blocked (earlier ones allowed): no result is checked or written after it.
    @Test func blockAtALaterPreviewStopsBeforeTheResult() async throws {
        let dir = RunnerHarness.temp("late")
        defer { try? FileManager.default.removeItem(at: dir); ForcedVerdictCheck.current = nil }
        ForcedVerdictCheck.current = .allow
                let events = EventLog()
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let req = Self.job(steps: 4, dir: dir)
        let png = ScriptedImageEngine.gradientPNG(width: 64, height: 43, phase: 0)
        let terminal = await runner.run(MediaJobSubmit(job: "late", image: req, previewDir: dir.path, safety: nil),
                                        emit: { e in events.append(e) }) { o in
            #expect(await o.preview(png, step: 1, totalSteps: 3))
            ForcedVerdictCheck.current = .block
            #expect(await !o.preview(png, step: 2, totalSteps: 3))
            #expect(await o.result(png) == nil)
            return .completed
        }
        #expect(terminal == .jobBlocked(job: "late"))
        #expect(RunnerHarness.files(dir) == ["preview-0001.png"] && !FileManager.default.fileExists(atPath: req.outputPath))
        #expect(await runner.gateCalls(.preview) == 2)
        #expect(await runner.gateCalls(.result) == 0)
    }
}
#endif
