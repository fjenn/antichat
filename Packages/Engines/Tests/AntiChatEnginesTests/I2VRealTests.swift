// M5.T04 real leg (R-043 engine part; @realModels, GPU: ~/AntiChat-tools/gpu-run.sh shared, free memory ≥ vid-i2v +
// vid-te + 20 GB):  ANTICHAT_REAL_VIDEO=1 ANTICHAT_I2V=1 make test-unit FILTER=I2VRealTests
// A CC0 photo with no people (fixtures/images/photos-cc0/019.jpg, "Lake Superior in early April"; Q-012) → sd-server
// (`vid_gen`, Wan2.2-TI2V-5B Q8_0 + vid-te + TAEHV) → SDVideoEngine → MediaJobRunner with the real detectors → MP4.
// Checks: a 2.6 s clip at 16 fps; its first frame (decoded from the gated MP4) is close to the source (SSIM ≥ 0.5 at
// 256 px); sd-server opens no file for writing in its cwd or $TMPDIR during the job (lsof); the TE check (M5.T04
// step 1: does sd-server load vid-5b's own T5?) is logged. Log → build/at/M5.T04/<date>.log.
import AntiChatEngineProtocol
import AntiChatFoundation
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_I2V"] == "1"))
struct I2VRealTests {
    static let repo = VideoRuntimeProcessTests.repo
    static let models = SafetyPrepareTests.devModels

    static func request(out: URL, t5: String) -> VideoRequest {
        VideoRequest(mode: .i2v, prompt: "gentle waves move across the lake, clouds drift slowly", width: 832, height: 480, frames: 41, fps: 16,
                     seed: 1, taehv: models.appending(path: "vid-taehv/taew2_2.safetensors").path,
                     diffusionModel: models.appending(path: "vid-i2v/Wan2.2-TI2V-5B-Q8_0.gguf").path,
                     vae: models.appending(path: "vid-i2v/VAE/Wan2.2_VAE.safetensors").path, t5xxl: t5,
                     initImage: repo.appending(path: "fixtures/images/photos-cc0/019.jpg").path, steps: 20, cfgScale: 6, flowShift: 3,
                     outputPath: out.path, scratchDir: "", footprintBytes: 16 << 30)
    }

    /// Grey 256-px-wide image (aspect kept) as Float luminance.
    static func luma(_ img: CGImage, width: Int = 256) -> ([Float], Int, Int) {
        let h = max(1, Int((Double(img.height) * Double(width) / Double(img.width)).rounded()))
        var px = [UInt8](repeating: 0, count: width * h)
        let ctx = CGContext(data: &px, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return (px.map(Float.init), width, h)
    }

    /// Mean SSIM over 8×8 windows (stride 4), luminance, C1/C2 for 8-bit.
    static func ssim(_ a: [Float], _ b: [Float], _ w: Int, _ h: Int) -> Double {
        let c1: Float = 6.5025, c2: Float = 58.5225
        var total = 0.0, n = 0
        for y in stride(from: 0, through: h - 8, by: 4) {
            for x in stride(from: 0, through: w - 8, by: 4) {
                var ma: Float = 0, mb: Float = 0
                for j in 0..<8 { for i in 0..<8 { ma += a[(y + j) * w + x + i]; mb += b[(y + j) * w + x + i] } }
                ma /= 64; mb /= 64
                var va: Float = 0, vb: Float = 0, cov: Float = 0
                for j in 0..<8 {
                    for i in 0..<8 {
                        let da = a[(y + j) * w + x + i] - ma, db = b[(y + j) * w + x + i] - mb
                        va += da * da; vb += db * db; cov += da * db
                    }
                }
                va /= 63; vb /= 63; cov /= 63
                total += Double(((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2)))
                n += 1
            }
        }
        return n == 0 ? 0 : total / Double(n)
    }

    /// Paths sd-server holds open for writing under `dirs` (lsof `-a -p`, write/read-write fds).
    static func writtenFiles(_ pid: Int32, under dirs: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-n", "-P", "-a", "-p", "\(pid)", "-F", "an"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var mode = "", hits: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("a") { mode = String(line.dropFirst()) }
            if line.hasPrefix("n"), mode == "w" || mode == "u" {
                let path = String(line.dropFirst())
                if dirs.contains(where: { path.hasPrefix($0) }), !path.hasSuffix(".sock") { hits.append(path) }
            }
        }
        return hits
    }

    @Test func cc0PhotoToClip() async throws {
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let logDir = Self.repo.appending(path: "build/at/M5.T04")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        var log: [String] = ["M5.T04 I2VRealTests \(date) load \(ProcessInfo.processInfo.loadAverage)"]
        defer { try? (log.joined(separator: "\n") + "\n").write(to: logDir.appending(path: "\(date).log"), atomically: true, encoding: .utf8) }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "i2v-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let modelDir = tmp.appending(path: "sd-models").path
        let sdLog = tmp.appending(path: "sd-server.log").path
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sd = SDServerSupervisor(config: .init(binary: Self.repo.appending(path: "build/binaries/sd-server").path, logFile: sdLog, modelDir: modelDir))

        // Step 1, TE check: vid-5b's own T5 is a 3-shard HF folder (`text_encoder/model-0000{1,2,3}-of-00003.safetensors`);
        // sd-server's `--t5xxl` takes one file. Try shard 1 (a partial encoder): it must not reach a usable context.
        let shard = Self.models.appending(path: "vid-5b/text_encoder/model-00001-of-00003.safetensors").path
        var teShared = "not loadable"
        do {
            let s = try await sd.start(SDVideoEngine.modelSet(Self.request(out: tmp, t5: shard)), timeout: .seconds(240))
            teShared = "context ready in \(String(format: "%.1f", s)) s with shard 1 only (partial weights; not usable)"
        } catch {
            teShared = "not loadable (\(error))"
        }
        await sd.stop()
        let missing = (try? String(contentsOfFile: sdLog, encoding: .utf8))?.split(separator: "\n")
            .filter { $0.localizedCaseInsensitiveContains("missing") || $0.localizedCaseInsensitiveContains("error") }.prefix(3) ?? []
        log.append("TE check: vid-5b text_encoder via --t5xxl → \(teShared); log: \(missing.joined(separator: " | "))")
        log.append("TE used: vid-te (city96/umt5-xxl-encoder-gguf@b535255 umt5-xxl-encoder-Q8_0.gguf, D-016)")

        // Step 2: the real clip with vid-te.
        let out = tmp.appending(path: "out/video.mp4")
        let req = Self.request(out: out, t5: Self.models.appending(path: "vid-te/umt5-xxl-encoder-Q8_0.gguf").path)
        let load = try await sd.start(SDVideoEngine.modelSet(req), timeout: .seconds(600))
        let pid = await sd.pid
        log.append("sd-server ready in \(String(format: "%.1f", load)) s (pid \(pid)); args: \((await sd.lastArgs).joined(separator: " "))")
        let watch = [FileManager.default.currentDirectoryPath, NSTemporaryDirectory(), modelDir]
        let written = Locked<[String]>([])
        let stop = Locked<Bool>(false)
        let watcher = Task.detached {
            while !stop.get() {
                let w = Self.writtenFiles(pid, under: watch)
                if !w.isEmpty { written.set(Array(Set(written.get() + w))) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        let safety = try SafetyPrepareTests.devManifest()
        let runner = RealDetectors.runner()
        let t0 = ContinuousClock.now
        let client = await sd.client
        let terminal = await runner.run(job: req.requestID.uuidString, safety: safety, previewDir: tmp.appending(path: "xfer").path,
                                        outputPath: req.outputPath, emit: { _ in }) { o in
            try await SDVideoEngine.run(req, client: client, isCancelled: { false }, outputs: o, emit: { _ in }, pid: pid)
        }
        stop.set(true)
        _ = await watcher.value
        await sd.stop()
        let secs = VideoChild.secs(ContinuousClock.now - t0)
        log.append("job: \(terminal) in \(String(format: "%.1f", secs)) s")
        log.append("sd-server files opened for writing under cwd/$TMPDIR/model-dir during the job: \(written.get())")
        #expect(written.get().isEmpty)
        guard case .jobResult(_, let path, let meta) = terminal else { Issue.record("terminal \(terminal)"); return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let dur = try await asset.load(.duration).seconds
        log.append("mp4 \(meta["width"] ?? "?")x\(meta["height"] ?? "?") frames \(meta["frames"] ?? "?") fps \(meta["fps"] ?? "?") duration \(String(format: "%.2f", dur)) s")
        #expect(dur >= 2.0 && dur <= 3.0)
        // First frame of the gated MP4 vs the source (both aspect-filled to the clip size, then 256 px wide).
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let first = try await gen.image(at: .zero).image
        let srcData = try Data(contentsOf: URL(fileURLWithPath: req.initImage!))
        let fit = try #require(SDVideoEngine.fitSource(srcData, width: req.width, height: req.height))
        let src = try #require(CGImageSourceCreateWithData(fit as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let (a, w, h) = Self.luma(first), (b, _, _) = Self.luma(src)
        let s = Self.ssim(a, b, w, h)
        log.append("SSIM(first frame, source) at 256 px = \(String(format: "%.3f", s))")
        #expect(s >= 0.5)
    }

    /// M5 review P2-4 (AT-NFR-VID3, I2V leg; timing run: `~/AntiChat-tools/gpu-run.sh timing --`
    /// `env ANTICHAT_REAL_VIDEO=1 ANTICHAT_I2V=1 ANTICHAT_I2V_CANCEL=1 make test-unit FILTER=I2VRealTests/cancel`): a real
    /// Animate job cancelled mid-denoise (step 2 and step 4). The engine stops sd-server after its soft-cancel grace
    /// (as EngineRuntime's `runReleasing` does after any I2V job); measured: cancel → terminal and cancel → sd-server
    /// gone (its memory back). Budget 2 s. Rows → build/perf/raw/video-i2v-cancel.jsonl, summary build/at/AT-NFR-VID3/cancel-i2v-T3.json.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_I2V_CANCEL"] == "1"))
    func cancelMidDenoiseFreesTheServerWithinTwoSeconds() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "i2v-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sd = SDServerSupervisor(config: .init(binary: Self.repo.appending(path: "build/binaries/sd-server").path,
                                                  logFile: tmp.appending(path: "sd-server.log").path, modelDir: tmp.appending(path: "sd-models").path))
        let safety = try SafetyPrepareTests.devManifest()
        let runner = RealDetectors.runner()
        var rows: [[String: Any]] = []
        for (i, atStep) in [2, 4].enumerated() {
            let req = Self.request(out: tmp.appending(path: "out-\(i)/video.mp4"),
                                   t5: Self.models.appending(path: "vid-te/umt5-xxl-encoder-Q8_0.gguf").path)
            _ = try await sd.start(SDVideoEngine.modelSet(req), timeout: .seconds(600))
            let pid = await sd.pid
            let client = await sd.client
            let cancel = EngineRuntime.CancelFlag()
            let emit: VideoEngine.Emit = { ev in
                if case .videoProgress(let p) = ev, p.stage == "denoise", p.step >= atStep { cancel.cancel() }
            }
            let terminal = await runner.run(job: req.requestID.uuidString, safety: safety, previewDir: tmp.appending(path: "xfer-\(i)").path,
                                            outputPath: req.outputPath, isCancelled: { cancel.isCancelled }, emit: { _ in }) { o in
                try await EngineRuntime.runReleasing {
                    try await SDVideoEngine.run(req, client: client, isCancelled: { cancel.isCancelled }, outputs: o, emit: emit, pid: pid,
                                                stopServer: { _ = await sd.stop() })
                } release: { _ = await sd.stop() }
            }
            let toEnd = cancel.at.map { VideoChild.secs(ContinuousClock.now - $0) } ?? -1
            var gone = -1.0
            let t0 = ContinuousClock.now
            while VideoChild.secs(ContinuousClock.now - t0) < 15 {
                if kill(pid, 0) != 0 { gone = cancel.at.map { VideoChild.secs(ContinuousClock.now - $0) } ?? -1; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            rows.append(["step": atStep, "terminal": "\(terminal)", "cancel_to_end_s": toEnd, "cancel_to_freed_s": gone,
                         "load": ProcessInfo.processInfo.loadAverage])
            if case .jobBlocked = terminal { continue }  // the gate withheld a preview before the cancel point
            #expect(terminal == .jobCancelled(job: req.requestID.uuidString), "step \(atStep): \(terminal)")
            #expect(gone >= 0 && gone <= 2.0, "step \(atStep): cancel → sd-server gone \(gone) s")
        }
        await sd.stop()
        let raw = Self.repo.appending(path: "build/perf/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let lines = rows.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: raw.appending(path: "video-i2v-cancel.jsonl"), atomically: true, encoding: .utf8)
        let at = Self.repo.appending(path: "build/at/AT-NFR-VID3")
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        let freed = rows.compactMap { $0["cancel_to_freed_s"] as? Double }
        let summary: [String: Any] = ["metric": "VID3_CANCEL_I2V", "tier": "T3", "n": rows.count, "max_cancel_to_freed_s": freed.max() ?? -1,
                                      "rows": rows, "load": ProcessInfo.processInfo.loadAverage]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: at.appending(path: "cancel-i2v-T3.json"))
        print("VID3_CANCEL_I2V", summary)
    }
}
