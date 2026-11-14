// M5.T14 review fixes (helper side), one regression test per finding. No model, no sd-server, no detectors
// (the gate fails closed without them, which these tests use as the "the gate was asked" signal). Gradients only.
//   P1-3 EngineRuntime I2V: the sd-server context goes with the job also when the run throws (`runReleasing`).
//   P1-4 a cancel that arrives after the engine's `end` (frames pull) still ends the job cancelled, nothing checked or
//        written (the after-gate / after-encode legs need an allow verdict: VideoGateTests, forced build).
//   P1-5 SDVideoEngine: a cancel sd-server never honours is cut off after the grace (sd-server stopped), and a cancelled
//        task does not spin on the socket.
//   P2   VideoEngine drops early previews itself (SSE fixture → VideoEngine.consume); MJPG AVI chunks are bounded by
//        their LIST; a 64-bit MP4 box size cannot overflow MediaProvenanceWriter.xmpBox.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite struct EngineRuntimeI2VReleaseTests {
    struct Boom: Error {}

    @Test func releaseRunsWhenTheRunThrows() async throws {
        let released = Mutex(0)
        await #expect(throws: Boom.self) {
            _ = try await EngineRuntime.runReleasing { () async throws -> Int in throw Boom() } release: { released.withLock { $0 += 1 } }
        }
        #expect(released.withLock { $0 } == 1, "sd-server is stopped on the throwing path too")
        let v = try await EngineRuntime.runReleasing { 7 } release: { released.withLock { $0 += 1 } }
        #expect(v == 7 && released.withLock { $0 } == 2)
    }
}

@Suite(.serialized) struct VideoCancelAfterEndTests {
    static func frames(_ n: Int, w: Int = 32, h: Int = 16) -> [Data] { (0..<n).map { Data(repeating: UInt8($0 & 0xff), count: w * h * 4) } }

    @Test func cancelBeforeTheFinalFramesEndsCancelledWithNothingChecked() async throws {
        let dir = RunnerHarness.temp("vcancel-end")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out/video.mp4")
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let cancel = EngineRuntime.CancelFlag()
        let thrown = Mutex<String?>(nil)
        let terminal = await runner.run(job: "j1", safety: nil, previewDir: dir.appendingPathComponent("xfer").path, outputPath: out.path,
                                        isCancelled: { cancel.isCancelled }, emit: { _ in }) { outputs in
            // The runtime sent `end`; the frames were pulled; the user's cancel lands now.
            cancel.cancel()
            do {
                _ = try await outputs.videoResult(frames: Self.frames(17), width: 32, height: 16, fps: 16,
                                                  info: MP4Encoder.Info(prompt: "p", model: "vid-5b", seed: 1, steps: 3))
            } catch {
                thrown.withLock { $0 = (error as? AntiChatError)?.code }
                throw error
            }
            return .completed
        }
        #expect(terminal == .jobCancelled(job: "j1"))
        #expect(thrown.withLock { $0 } == "cancelled")
        #expect(await runner.gateCalls(.video) == 0, "a cancelled clip is not even checked")
        #expect(RunnerHarness.files(dir).isEmpty, "nothing written")
    }

    @Test func engineThatCompletesWithoutAResultAfterACancelIsCancelled() async {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let cancel = EngineRuntime.CancelFlag()
        let terminal = await runner.run(job: "j2", safety: nil, previewDir: nil, outputPath: "/nonexistent/x.mp4",
                                        isCancelled: { cancel.isCancelled }, emit: { _ in }) { _ in
            cancel.cancel()
            return .completed
        }
        #expect(terminal == .jobCancelled(job: "j2"))
    }
}

@Suite(.serialized) struct SDVideoEngineCancelGraceTests {
    static func request() -> VideoRequest { SDVideoEngineTests.request() }

    /// sd-server ignores the cancel (always `generating`): after the grace the server is stopped and the job ends
    /// cancelled. The run's task is itself cancelled, so `Task.sleep` would return at once: the poll still waits.
    @Test func ignoredCancelIsCutOffAfterTheGraceWithoutSpinning() async throws {
        let polls = Mutex(0)
        let cancels = Mutex(0)
        let client = SDServerClient { method, path, _ in
            if method == "POST", path == "/sdcpp/v1/vid_gen" {
                return (202, try JSONSerialization.data(withJSONObject: ["id": "j", "kind": "vid_gen", "status": "queued"]))
            }
            if path.hasSuffix("/cancel") { cancels.withLock { $0 += 1 }; return (200, Data("{}".utf8)) }
            polls.withLock { $0 += 1 }
            return (200, try JSONSerialization.data(withJSONObject: ["id": "j", "status": "generating"]))
        }
        let stopped = Mutex(0)
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let req = Self.request()
        let ended = Mutex<MediaJobRunner.EngineEnd?>(nil)
        let t0 = ContinuousClock.now
        let job = Task {
            await runner.run(job: "sd1", safety: nil, previewDir: nil, outputPath: "/nonexistent/v.mp4", emit: { _ in }) { outputs in
                withUnsafeCurrentTask { $0?.cancel() }  // the job's task is cancelled (helper stream torn down)
                let e = try await SDVideoEngine.run(req, client: client, isCancelled: { true }, outputs: outputs, emit: { _ in },
                                                    poll: .milliseconds(20), cancelGrace: .milliseconds(300),
                                                    stopServer: { stopped.withLock { $0 += 1 } })
                ended.withLock { $0 = e }
                return e
            }
        }
        let terminal = await job.value
        let took = ContinuousClock.now - t0
        #expect(ended.withLock { $0 } == .cancelled && terminal == .jobCancelled(job: "sd1"))
        #expect(stopped.withLock { $0 } == 1, "sd-server stopped after the grace")
        #expect(cancels.withLock { $0 } == 1)
        #expect(took < .seconds(5))
        // 300 ms grace / 20 ms poll ≈ 15 polls; a spinning loop makes thousands.
        #expect(polls.withLock { $0 } <= 40, "polls: \(polls.withLock { $0 })")
    }

    /// M5 review P2-4: the grace leaves room for the stop within NFR-VID3's 2 s (the runtime's 500 ms soft cancel).
    @Test func defaultGraceFitsTheCancelBudget() { #expect(SDVideoEngine.cancelGrace == .milliseconds(500)) }
}

@Suite(.serialized) struct VideoEngineSSEPreviewTests {
    /// Splits an SSE text into `(event, data)` pairs and parses them like the client does.
    static func events(_ sse: String) -> [VideoRuntimeClient.Event] {
        sse.components(separatedBy: "\n\n").compactMap { block in
            var event = "message", data: [String] = []
            for line in block.split(separator: "\n") {
                if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("data:") { data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            }
            return data.isEmpty ? nil : VideoRuntimeClient.parse(event: event, data: data.joined(separator: "\n"))
        }
    }

    static func fixture(previewSteps: [Int], total: Int = 3) -> String {
        let jpeg = ScriptedVideoEngine.gradientJPEG(width: 64, height: 40, phase: 3).base64EncodedString()
        var s = ""
        var id = 0
        func add(_ event: String, _ data: String) { id += 1; s += "id: \(id)\nevent: \(event)\ndata: \(data)\n\n" }
        for step in 1...total {
            add("progress", #"{"stage":"denoise","step":\#(step),"total":\#(total)}"#)
            if previewSteps.contains(step) {
                add("preview", #"{"frame_index":0,"frames":1,"width":64,"height":40,"jpeg_b64":"\#(jpeg)","step":\#(step),"total":\#(total)}"#)
            }
        }
        add("end", #"{"status":"completed","metrics":{}}"#)
        return s
    }

    static func consume(_ evs: [VideoRuntimeClient.Event], runner: MediaJobRunner) async -> (VideoEngine.EventOutcome?, Int) {
        let stops = Mutex(0)
        let outcome = Mutex<VideoEngine.EventOutcome?>(nil)
        _ = await runner.run(job: "sse", safety: nil, previewDir: nil, outputPath: "/nonexistent/v.mp4", emit: { _ in }) { outputs in
            let stream = AsyncThrowingStream<VideoRuntimeClient.Event, Error> { c in evs.forEach { c.yield($0) }; c.finish() }
            var metrics: [String: Double] = [:]
            let o = try await VideoEngine.consume(stream, isCancelled: { false }, cancelled: CancelState(), outputs: outputs,
                                                  emit: { _ in }, governor: nil, metrics: &metrics, pid: 0, now: { 0 },
                                                  stop: { stops.withLock { $0 += 1 } })
            outcome.withLock { $0 = o }
            return .completed
        }
        return (outcome.withLock { $0 }, stops.withLock { $0 })
    }

    /// A-M9-T05-VID2: `VideoPreviewPolicy.minDenoiseFraction` is 2/3, so step 1 of 3 is below it (dropped, unchecked,
    /// unseen) and step 2 of 3 is shown, so it goes to the gate like step 3.
    @Test func earlyPreviewsNeverReachTheGate() async throws {
        let evs = Self.events(Self.fixture(previewSteps: [1]))
        #expect(evs.filter { if case .preview = $0 { true } else { false } }.count == 1, "the fixture parses")
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let (o, stops) = await Self.consume(evs, runner: runner)
        #expect(await runner.gateCalls(.preview) == 0, "step 1 of 3 is dropped in VideoEngine, unchecked and unseen")
        #expect(o?.withheld == false && o?.endStatus == "completed" && stops == 0)
    }

    @Test func stepTwoOfThreeGoesToTheGate() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let (o, stops) = await Self.consume(Self.events(Self.fixture(previewSteps: [1, 2])), runner: runner)
        #expect(await runner.gateCalls(.preview) == 1, "step 2 of 3 is checked (A-M9-T05-VID2), step 1 is not")
        #expect(o?.withheld == true && stops == 1, "no detectors: the shown preview fails closed and the job stops")
    }

    @Test func aShownPreviewGoesToTheGate() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let (o, stops) = await Self.consume(Self.events(Self.fixture(previewSteps: [1, 3])), runner: runner)
        #expect(await runner.gateCalls(.preview) == 1, "only step 3 is checked")
        #expect(o?.withheld == true && stops == 1, "no detectors: the shown preview fails closed and the job stops")
    }
}

@Suite struct MP4BoxBoundsTests {
    static func box(_ type: String, size64: UInt64) -> Data {
        var d = Data([0, 0, 0, 1]) + Data(type.utf8)
        withUnsafeBytes(of: size64.bigEndian) { d.append(contentsOf: $0) }
        return d + Data(count: 16)
    }

    @Test func hugeLargesizeIsRejectedNotOverflowed() throws {
        let dir = RunnerHarness.temp("xmp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for size in [UInt64.max, UInt64(Int.max), UInt64(Int.max) - 4] {
            let url = dir.appendingPathComponent("big-\(size).mp4")
            try Self.box("free", size64: size).write(to: url)
            #expect(try MP4Encoder.readXMP(url) == nil)
        }
    }

    @Test func aviChunkMustFitItsList() {
        func le(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        let jpeg = SDVideoEngineTests.jpeg(8, 8, phase: 0)
        // LIST movi claims 4 + 8 bytes, but its 00dc chunk claims the JPEG's size (past the LIST end, inside the buffer).
        let chunk = Data("00dc".utf8) + le(jpeg.count) + jpeg
        let movi = Data("LIST".utf8) + le(4 + 8) + Data("movi".utf8) + chunk
        let body = Data("AVI ".utf8) + movi
        let avi = Data("RIFF".utf8) + le(body.count) + body
        #expect(throws: (any Error).self) { try MJPGAVI.frames(avi) }
    }
}
