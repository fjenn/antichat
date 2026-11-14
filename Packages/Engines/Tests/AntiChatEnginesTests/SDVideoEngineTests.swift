// M5.T04 task checks (recorded; no sd-server, no model): the I2V request builder, the sd-server launch arguments of a
// video set, the `vid_gen` job-result parsing, the MJPG AVI frame decoder, and a whole recorded job through
// MediaJobRunner (early previews stay progress only; later previews and the final frames go through the gate).
// Content-free gradients only.
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import AntiChatEngines

@Suite(.serialized) struct SDVideoEngineTests {
    static func request(source: String? = nil, steps: Int = 20) -> VideoRequest {
        VideoRequest(mode: .i2v, prompt: "the lighthouse beam sweeps slowly", width: 320, height: 192, frames: 17, fps: 16, seed: 9,
                     taehv: "/m/vid-taehv/taew2_2.safetensors", diffusionModel: "/m/vid-i2v/Wan2.2-TI2V-5B-Q8_0.gguf",
                     vae: "/m/vid-i2v/VAE/Wan2.2_VAE.safetensors", t5xxl: "/m/vid-te/umt5-xxl-encoder-Q8_0.gguf", initImage: source,
                     steps: steps, cfgScale: 6, flowShift: 3, outputPath: "/tmp/never/video.mp4", scratchDir: "", footprintBytes: 1 << 30)
    }

    static func jpeg(_ w: Int, _ h: Int, phase: Int) -> Data {
        ScriptedVideoEngine.gradientJPEG(width: w, height: h, phase: phase)
    }

    /// A minimal MJPG AVI in the layout of sd.cpp's `create_mjpg_avi_from_sd_images_to_vector` (hdrl list + movi list).
    static func avi(_ jpegs: [Data]) -> Data {
        func le(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func chunk(_ id: String, _ body: Data) -> Data {
            var d = Data(id.utf8) + le(body.count) + body
            if body.count & 1 == 1 { d.append(0) }
            return d
        }
        func list(_ type: String, _ body: Data) -> Data { chunk("LIST", Data(type.utf8) + body) }
        let hdrl = list("hdrl", chunk("avih", Data(count: 56)))
        let movi = list("movi", jpegs.reduce(Data()) { $0 + chunk("00dc", $1) })
        let idx = chunk("idx1", Data(count: 16 * jpegs.count))
        let body = Data("AVI ".utf8) + hdrl + movi + idx
        return Data("RIFF".utf8) + le(body.count) + body
    }

    @Test func requestBody() throws {
        let b = SDVideoEngine.body(Self.request(), initImage: Data([1, 2, 3]))
        #expect(b["video_frames"] as? Int == 17 && b["fps"] as? Int == 16 && b["seed"] as? Int64 == 9)
        #expect(b["output_format"] as? String == "avi" && b["preview"] as? String == "tae")
        #expect(b["init_image"] as? String == Data([1, 2, 3]).base64EncodedString())
        let sp = try #require(b["sample_params"] as? [String: Any])
        #expect(sp["sample_steps"] as? Int == 20 && sp["sample_method"] as? String == "euler" && sp["flow_shift"] as? Double == 3)
        #expect((b["negative_prompt"] as? String)?.isEmpty == false)
        #expect(b["batch_count"] == nil, "vid_gen has no batch_count")
    }

    @Test func launchArgumentsOfTheVideoSet() {
        let set = SDVideoEngine.modelSet(Self.request())
        let a = SDServerSupervisor.arguments(set, socket: "/tmp/s/sd.sock", modelDir: "/tmp/empty")
        #expect(!a.contains("--llm"))
        #expect(a.contains("--t5xxl") && a[a.firstIndex(of: "--t5xxl")! + 1].hasSuffix("umt5-xxl-encoder-Q8_0.gguf"))
        #expect(a.contains("--taesd") && a.contains("--vae") && a.contains("--diffusion-model"))
        #expect(a.prefix(2) == ["--listen-ip", "unix:/tmp/s/sd.sock"])
        #expect(set.key == "vid-i2v")
    }

    @Test func mjpgAVIRoundTrip() throws {
        let jpegs = (0..<5).map { Self.jpeg(64, 40, phase: $0 * 10) }
        let got = try MJPGAVI.frames(Self.avi(jpegs))
        #expect(got == jpegs)
        let (rgba, w, h) = try MJPGAVI.rgba(got)
        #expect(w == 64 && h == 40 && rgba.count == 5 && rgba.allSatisfy { $0.count == 64 * 40 * 4 })
        #expect(throws: (any Error).self) { try MJPGAVI.frames(Data("RIFF....WAVE".utf8)) }
        #expect(throws: (any Error).self) { try MJPGAVI.frames(Self.avi([])) }
    }

    @Test func jobResultParsing() async throws {
        let video = Self.avi([Self.jpeg(32, 32, phase: 0)])
        let client = SDServerClient { _, _, _ in
            let obj: [String: Any] = ["id": "j", "kind": "vid_gen", "status": "completed",
                                      "result": ["output_format": "avi", "mime_type": "video/x-msvideo", "fps": 16, "frame_count": 1,
                                                 "b64_json": video.base64EncodedString()]]
            return (200, try JSONSerialization.data(withJSONObject: obj))
        }
        let st = try await client.job("j")
        #expect(st.status == "completed" && st.video == video && st.frameCount == 1 && st.fps == 16 && st.imagePNG == nil)
    }

    @Test func sourceIsFittedToTheClipSize() throws {
        let src = ScriptedImageEngine.gradientPNG(width: 100, height: 100, phase: 0)
        let fit = try #require(SDVideoEngine.fitSource(src, width: 320, height: 192))
        let img = try #require(CGImageSourceCreateWithData(fit as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(img.width == 320 && img.height == 192)
    }

    /// A recorded job (20 steps, previews at 2, 10 and 20, then the AVI) through MediaJobRunner. Step 2's preview is
    /// progress only (never checked, never written); with the real detectors (`CSC_REAL_DETECTORS=1`) steps 10 and 20
    /// are checked and written, the final frames are checked once and the MP4 is written; without detectors the first
    /// shown preview (step 15) fails closed (`safetyMissing`) and nothing is written. The source is never checked.
    @Test func recordedJobThroughTheRunner() async throws {
        let safety = RealDetectors.manifest
        let dir = RunnerHarness.temp("sdvid")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("source.png")
        try ScriptedImageEngine.gradientPNG(width: 200, height: 120, phase: 3).write(to: source)
        var r = Self.request(source: source.path)
        r.outputPath = dir.appendingPathComponent("out/video.mp4").path
        let req = r
        let preview = ScriptedImageEngine.gradientPNG(width: 160, height: 96, phase: 5)
        let video = Self.avi((0..<17).map { Self.jpeg(320, 192, phase: $0 * 3) })
        let polls = Mutex(0)
        let cancelled = Mutex(false)
        let submitted = Mutex<[String: Any]?>(nil)
        let client = SDServerClient { method, path, body in
            if method == "POST", path == "/sdcpp/v1/vid_gen" {
                submitted.withLock { $0 = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
                return (202, try JSONSerialization.data(withJSONObject: ["id": "job1", "kind": "vid_gen", "status": "queued"]))
            }
            if path.hasSuffix("/cancel") {
                cancelled.withLock { $0 = true }
                return (200, Data("{}".utf8))
            }
            let n = polls.withLock { $0 += 1; return $0 }
            let step = [0, 2, 2, 15, 20, 20][min(n, 5)]
            let stop = cancelled.withLock { $0 }
            var obj: [String: Any] = ["id": "job1", "status": stop ? "cancelled" : n >= 6 ? "completed" : "generating"]
            if step > 0 { obj["preview"] = ["pass": 1, "step": step, "total_steps": 20, "b64_json": preview.base64EncodedString()] }
            if n >= 6, !stop { obj["result"] = ["fps": 16, "frame_count": 17, "b64_json": video.base64EncodedString()] }
            return (200, try JSONSerialization.data(withJSONObject: obj))
        }
        let runner = RealDetectors.runner()
        let events = EventLog()
        let terminal = await runner.run(job: req.requestID.uuidString, safety: safety, previewDir: dir.appendingPathComponent("xfer").path,
                                        outputPath: req.outputPath, emit: { events.append($0) }) { outputs in
            try await SDVideoEngine.run(req, client: client, isCancelled: { false }, outputs: outputs, emit: { _ in }, poll: .milliseconds(1))
        }
        let steps = events.all.compactMap { e -> (Int, Bool)? in
            if case .jobProgress(_, let s, _, let p) = e { return (s, p != nil) } else { return nil }
        }
        #expect(await runner.gateCalls(.result) == 0, "the source image is never checked")
        let body = try #require(submitted.withLock { $0 })
        let sent = try #require((body["init_image"] as? String).flatMap { Data(base64Encoded: $0) })
        let img = try #require(CGImageSourceCreateWithData(sent as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(img.width == 320 && img.height == 192)
        guard safety != nil else {
            #expect(terminal == .safetyMissing(job: req.requestID.uuidString, sizeBytes: 0))
            #expect(await runner.gateCalls(.preview) == 1, "step 2 is not checked; step 15 fails closed")
            #expect(steps.map(\.0) == [2] && steps.map(\.1) == [false])
            #expect(cancelled.withLock { $0 }, "the withheld job is cancelled on the server")
            #expect(RunnerHarness.files(dir) == ["source.png"])
            return
        }
        guard case .jobResult(_, let path, let meta) = terminal else { Issue.record("terminal \(terminal)"); return }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(meta["model"] == "vid-i2v" && meta["operation"] == "animate" && meta["frames"] == "17")
        #expect(await runner.gateCalls(.preview) == 2, "steps 15 and 20 only")
        #expect(await runner.gateCalls(.video) == 1)
        #expect(steps.map(\.0) == [2, 15, 20] && steps.map(\.1) == [false, true, true])
    }
}
