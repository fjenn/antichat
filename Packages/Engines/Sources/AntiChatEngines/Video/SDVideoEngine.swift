// M5.T04 (R-043 engine part, R-040 I2V start; P-media-11 source 3 + RL-005, P-media-07): image-to-video with
// Wan2.2-TI2V-5B (`vid-i2v` Q8_0 GGUF + Wan2.2 VAE, `vid-te` umT5-XXL Q8_0, D-016) through the helper's sd-server
// child (`POST /sdcpp/v1/vid_gen`, leejet/stable-diffusion.cpp@e239e4b examples/server/api.md:1416-1830), the same
// HTTP-over-unix-socket client as images. No C binding, no sd-cli, no file:
//   - sd-server returns the finished clip as ONE encoded container in the job result (`result.b64_json`, api.md
//     "Result Payload"); we ask for `avi` (MJPG, quality 95), whose frames are plain JPEGs, and decode them here in
//     memory (`MJPGAVI.frames`) into RGBA8. sd-server writes no file (UP-SD-002 is not needed).
//   - the job's latest step preview (`preview{step, b64_json}`, first frame of the step's prediction, TAEHV `tae` mode)
//     → `VideoPreviewPolicy` (previews before 2/3 of the schedule are progress only, never shown, A-M5-07, A-M9-T05-VID2) → `outputs.preview`
//     (the gate before anything is shown or written);
//   - the decoded frames → `outputs.videoResult` (M5.T06: the gate on the sampled frames, then the MP4).
// The source image is never checked (D-005, R-043 AC2); it is scaled (aspect fill, centre crop) to the clip size in
// memory before upload. Decode with TAEHV (`--taesd`): sd.cpp's full Wan2.2 VAE decode is unusable at e239e4b
// (S-10, A-M0-T07b). TE check (M5.T04 step 1): sd-server cannot load vid-5b's sharded HF `text_encoder/` (it takes a
// single file), so `vid-te` stays (D-016) — result recorded by I2VRealTests.
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SDVideoEngine {
    public static let modelKey = "vid-i2v"
    /// How long sd-server has to end a cancelled job before it is stopped (M5.T14 review P1-5). M5 review P2-4: the
    /// same soft-cancel window as the T2V runtime (`VideoEngine.Timing.cancelWait`, 500 ms) — sd-server only honours a
    /// cancel at the end of the current Wan step (seconds), and the I2V context is released after the job anyway, so
    /// stopping it then frees the memory within NFR-VID3's 2 s instead of up to 10 s.
    public static let cancelGrace: Duration = .milliseconds(500)

    /// Sleeps `d` even when the current task is cancelled.
    static func uncancellableSleep(_ d: Duration) async {
        let ns = UInt64(max(0, Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(ns))) { c.resume() }
        }
    }

    /// The sd-server context of an I2V request: diffusion GGUF, Wan2.2 VAE, umT5 (`--t5xxl`), TAEHV (`--taesd`).
    public static func modelSet(_ req: VideoRequest) -> ImageModelSet {
        var extra = ["--t5xxl", req.t5xxl]
        if !req.taehv.isEmpty { extra += ["--taesd", req.taehv] }
        return ImageModelSet(key: modelKey, diffusionModel: req.diffusionModel, llm: "", vae: req.vae,
                             footprintBytes: req.footprintBytes, extraArgs: extra)
    }

    /// The `vid_gen` body (api.md:1450-1560). Euler, the Wan default negative prompt, `flow_shift`, cfg; a step preview
    /// per step; the result as MJPG AVI.
    public static func body(_ req: VideoRequest, initImage: Data?) -> [String: Any] {
        var b: [String: Any] = [
            "prompt": req.prompt, "negative_prompt": VideoRuntimeSupervisor.wanNegativePrompt, "width": req.width, "height": req.height,
            "seed": req.seed, "video_frames": req.frames, "fps": req.fps,
            "sample_params": ["sample_method": "euler", "sample_steps": req.steps, "flow_shift": Double(req.flowShift),
                              "guidance": ["txt_cfg": Double(req.cfgScale)]],
            "preview": req.taehv.isEmpty ? "proj" : "tae", "preview_interval": 1,
            "output_format": "avi", "output_compression": 95,
        ]
        if let initImage { b["init_image"] = initImage.base64EncodedString() }
        return b
    }

    /// Scales the source to `width × height` (aspect fill, centre crop) as PNG, in memory. Not a check (D-005).
    public static func fitSource(_ data: Data, width: Int, height: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let s = max(Double(width) / Double(img.width), Double(height) / Double(img.height))
        let w = Double(img.width) * s, h = Double(img.height) * s
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let d = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, out, nil)
        return CGImageDestinationFinalize(dst) ? d as Data : nil
    }

    /// Runs one I2V job on a ready sd-server. `.cancelled` when the cancel flag stopped it.
    public static func run(_ req: VideoRequest, client: SDServerClient, isCancelled: @escaping @Sendable () -> Bool,
                           outputs: MediaJobOutputs, emit: @escaping VideoEngine.Emit, pid: Int32 = 0,
                           poll: Duration = .milliseconds(100), timeout: Duration = .seconds(3600),
                           governor: VideoJobGovernor? = nil, cancelGrace: Duration = cancelGrace,
                           stopServer: (@Sendable () async -> Void)? = nil) async throws -> MediaJobRunner.EngineEnd {
        let t0 = ContinuousClock.now
        func now() -> Double { VideoChild.secs(ContinuousClock.now - t0) }
        let source = try req.initImage.map { path -> Data in
            guard let raw = FileManager.default.contents(atPath: path), let fit = fitSource(raw, width: req.width, height: req.height) else {
                throw mediaError("video.badSource", path)
            }
            return fit
        }
        let job = try await client.submitVideo(body(req, initImage: source))
        // M5.T11: heat / other-app pauses are SIGSTOP / SIGCONT of sd-server, only between polls (a step boundary).
        await governor?.attach(pid > 0 ? SignalPauseTarget(pid: pid) : NoChildPauseTarget())
        await emit(.videoProgress(VideoProgress(stage: "denoise", step: 0, totalSteps: req.steps, t: now(), childPID: pid)))
        var lastStep = 0
        var cancelSent = false
        var withheld = false
        var final: SDServerClient.JobState?
        let deadline = ContinuousClock.now + timeout
        var cancelDeadline: ContinuousClock.Instant?
        while true {
            if (isCancelled() || withheld || Task.isCancelled), !cancelSent {
                cancelSent = true
                cancelDeadline = .now + cancelGrace
                try? await client.cancel(job)
            }
            // M5.T14 review P1-5: sd-server gets `cancelGrace` to honour the cancel; then it is stopped (the job's
            // memory comes back within the NFR-VID3 budget even when the server never answers `cancelled`).
            if let cd = cancelDeadline, ContinuousClock.now > cd {
                await stopServer?()
                await governor?.leftDenoise()
                return withheld && !isCancelled() ? .completed : .cancelled
            }
            if ContinuousClock.now > deadline { try? await client.cancel(job); throw mediaError("sdJobTimeout", job) }
            let st = try await client.job(job)
            if !cancelSent, let s = st.previewStep, s > lastStep {
                lastStep = s
                let total = st.previewTotal ?? req.steps
                await emit(.videoProgress(VideoProgress(stage: "denoise", step: s, totalSteps: total, t: now(), childPID: pid)))
                // Early, still-noisy steps are progress only (never shown, so nothing to check); later ones go to the gate.
                if let png = st.previewPNG, VideoPreviewPolicy.shows(step: s, of: total) {
                    if !(await outputs.preview(png, step: s, totalSteps: total, frame: 0)) { withheld = true }
                } else if !(await outputs.progress(step: s, totalSteps: total)) {
                    withheld = true
                }
                if !withheld { await governor?.checkpoint(step: s, total: total, isCancelled: isCancelled) }
            }
            if ["completed", "failed", "cancelled"].contains(st.status) { final = st; break }
            // A cancelled task's `Task.sleep` returns at once: wait the poll interval anyway (no busy loop on the socket).
            if Task.isCancelled { await uncancellableSleep(poll) } else { try? await Task.sleep(for: poll) }
        }
        await governor?.leftDenoise()
        if isCancelled() || final?.status == "cancelled" { return .cancelled }
        if withheld { return .completed }  // the runner reports its withheld verdict
        guard let f = final, f.status == "completed", let container = f.video else {
            throw mediaError("video.failed", final?.error ?? final?.status ?? "noResult")
        }
        await emit(.videoProgress(VideoProgress(stage: "decode", step: 0, totalSteps: f.frameCount ?? req.frames, t: now(), childPID: pid)))
        let jpegs = try MJPGAVI.frames(container)
        let (frames, w, h) = try MJPGAVI.rgba(jpegs)
        await emit(.videoProgress(VideoProgress(stage: "frames", step: frames.count, totalSteps: frames.count, t: now(), childPID: pid)))
        let info = MP4Encoder.Info(prompt: req.prompt, model: modelKey, seed: req.seed, steps: req.steps, operation: "animate")
        _ = try await outputs.videoResult(frames: frames, width: w, height: h, fps: Double(f.fps ?? req.fps), info: info)
        await outputs.noteGateTiming(emit: emit)  // M9.T05 F7_VIDEO: the gate's time for this job
        return .completed
    }
}

/// The MJPG AVI container sd-server returns for `output_format: avi` (examples/common/media_io.cpp
/// `create_mjpg_avi_from_sd_images_to_vector`): RIFF `AVI ` → LIST `movi` → one `00dc` chunk (a JPEG) per frame.
public enum MJPGAVI {
    /// The JPEG of every video chunk, in order. Throws on a malformed container.
    public static func frames(_ d: Data) throws -> [Data] {
        let b = [UInt8](d)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func tag(_ o: Int) -> String { String(decoding: b[o..<o + 4], as: UTF8.self) }
        guard b.count >= 12, tag(0) == "RIFF", tag(8) == "AVI " else { throw mediaError("video.badContainer", "not an AVI") }
        var out: [Data] = []
        // Walk chunks; descend into LIST chunks; collect `##dc` / `##db` video chunks.
        func walk(_ start: Int, _ end: Int) throws {
            var o = start
            while o + 8 <= end {
                let id = tag(o), size = u32(o + 4)
                let body = o + 8
                // M5.T14 review P2: a chunk must fit its parent (the LIST / RIFF end), not only the buffer.
                guard size <= end - body, body + size <= b.count else { throw mediaError("video.badContainer", "chunk past the end") }
                if id == "LIST", size >= 4 {
                    try walk(body + 4, body + size)
                } else if id.hasSuffix("dc") || id.hasSuffix("db"), size > 0 {
                    out.append(Data(b[body..<body + size]))
                }
                o = body + size + (size & 1)
            }
        }
        try walk(12, min(b.count, 8 + u32(4)))
        guard !out.isEmpty else { throw mediaError("video.badContainer", "no frames") }
        return out
    }

    /// JPEG frames → RGBA8 frames of one size (in memory).
    public static func rgba(_ jpegs: [Data]) throws -> ([Data], Int, Int) {
        var out: [Data] = []
        var size: (Int, Int)?
        for (i, j) in jpegs.enumerated() {
            guard let src = CGImageSourceCreateWithData(j as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw mediaError("video.badFrames", "frame \(i)")
            }
            let (w, h) = size ?? (img.width, img.height)
            guard img.width == w, img.height == h else { throw mediaError("video.badFrames", "frame \(i) size") }
            size = (w, h)
            var px = Data(count: w * h * 4)
            let ok = px.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { throw mediaError("video.badFrames", "frame \(i) draw") }
            out.append(px)
        }
        guard let (w, h) = size else { throw mediaError("video.badFrames", "none") }
        return (out, w, h)
    }
}
