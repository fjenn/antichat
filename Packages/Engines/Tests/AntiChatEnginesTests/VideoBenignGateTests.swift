// A-M5-07 "after" leg: the benign false-block rate of the PRODUCT path (MediaJobRunner → VideoEngine → the signed
// runtime, real ChildSafetyCheck detectors on every shown preview and on the final frames, VideoPreviewPolicy applied)
// on the same benign prompts and seeds as VideoPreviewTraceTests (lawful proxies only, Q-012).
// @realModels, GPU (~/AntiChat-tools/gpu-run.sh shared; free memory ≥ vid-5b + TE + 20 GB):
//   ANTICHAT_REAL_VIDEO=1 ANTICHAT_VIDEO_BENIGN=1 [ANTICHAT_TRACE_N=60] make test-unit FILTER=VideoBenignGateTests
// Allowed MP4s go to a temp dir and are deleted; rows (terminal per prompt, no image) → build/at/AT-M5-preview-fp/.
import AntiChatEngineProtocol
import AntiChatFoundation
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VIDEO_BENIGN"] == "1"))
struct VideoBenignGateTests {
    @Test func benignPromptsAreNotBlocked() async throws {
        let env = ProcessInfo.processInfo.environment
        let n = min(VideoPreviewTraceTests.prompts.count, Int(env["ANTICHAT_TRACE_N"] ?? "60") ?? 60)
        let models = SafetyPrepareTests.devModels
        let safety = try SafetyPrepareTests.devManifest()
        let runner = RealDetectors.runner()
        let engine = VideoEngine()
        let tmp = FileManager.default.temporaryDirectory.appending(path: "benign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var rows: [[String: Any]] = []
        var at287: [String] = []
        for i in 0..<n {
            let seed = Int64(i % 7 + 1)
            let out = tmp.appending(path: "\(i)/video.mp4")
            let req = VideoRequest(mode: .t2v, prompt: VideoPreviewTraceTests.prompts[i], width: 832, height: 480, frames: 73, fps: 24, seed: seed,
                                   runtimeDir: VideoRuntimeProcessTests.runtime.path, modelDir: models.appending(path: "vid-5b").path,
                                   taehv: models.appending(path: "vid-taehv/taew2_2.safetensors").path, outputPath: out.path,
                                   scratchDir: "", footprintBytes: 0, memoryLimitBytes: 36_000_000_000, safety: safety,
                                   previewDir: tmp.appending(path: "\(i)/xfer").path, generator: "wan22")
            let previews = Locked<Int>(0)
            let t0 = ContinuousClock.now
            let terminal = await runner.run(job: req.requestID.uuidString, safety: safety, previewDir: req.previewDir, outputPath: req.outputPath,
                                            emit: { e in if case .jobProgress(_, _, _, let p) = e, p != nil { previews.set(previews.get() + 1) } }) { o in
                try await engine.run(req, isCancelled: { false }, outputs: o, emit: { _ in })
            }
            let kind: String = switch terminal {
            case .jobResult: "result"
            case .jobBlocked: "blocked"
            case .safetyMissing: "safetyMissing"
            case .jobFailed(_, let code): "failed:\(code)"
            default: "\(terminal)"
            }
            if case .jobResult(_, let path, let meta) = terminal, at287.isEmpty {
                at287 = try await Self.at287(path: path, meta: meta, prompt: req.prompt)
            }
            rows.append(["prompt": i, "seed": seed, "terminal": kind, "previews_shown": previews.get(),
                         "s": VideoChild.secs(ContinuousClock.now - t0)])
            print("benign job \(i + 1)/\(n): \(kind)")
            try? FileManager.default.removeItem(at: tmp.appending(path: "\(i)"))
        }
        await engine.shutdown()
        let blocked = rows.filter { $0["terminal"] as? String == "blocked" }.count
        let results = rows.filter { $0["terminal"] as? String == "result" }.count
        let dir = VideoRuntimeProcessTests.repo.appending(path: "build/at/AT-M5-preview-fp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summary: [String: Any] = ["n": rows.count, "results": results, "blocked": blocked,
                                      "benign_false_block_rate": Double(blocked) / Double(max(1, rows.count)),
                                      "min_denoise_fraction": VideoPreviewPolicy.minDenoiseFraction,
                                      "load": ProcessInfo.processInfo.loadAverage, "rows": rows]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appending(path: "after.json"))
        if !at287.isEmpty {
            let d = VideoRuntimeProcessTests.repo.appending(path: "build/at/AT-287")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            try (at287.joined(separator: "\n") + "\n").write(to: d.appending(path: "\(date)-video.log"), atomically: true, encoding: .utf8)
        }
        print("BENIGN_AFTER n=\(rows.count) results=\(results) blocked=\(blocked)")
        #expect(results + blocked == rows.count, "every job ends with a result or a block")
    }

    /// AT-287 AC3 on a real FastMetal clip (the first allowed job): playable, the XMP mark and generation fields, the
    /// Get-Info description.
    static func at287(path: String, meta: [String: String], prompt: String) async throws -> [String] {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let dur = try await asset.load(.duration).seconds
        var desc = ""
        for item in try await asset.load(.metadata) where item.identifier == .commonIdentifierDescription || item.identifier?.rawValue == "uiso/dscp" {
            desc = try await item.load(.stringValue) ?? ""
        }
        var fields: [String: String] = [:]
        if let x = try MP4Encoder.readXMP(url), let m = CGImageMetadataCreateFromXMPData(x as CFData) {
            for tag in (CGImageMetadataCopyTags(m) as? [CGImageMetadataTag]) ?? [] {
                let k = "\(CGImageMetadataTagCopyPrefix(tag) ?? "" as CFString):\(CGImageMetadataTagCopyName(tag) ?? "" as CFString)"
                if let v = CGImageMetadataTagCopyValue(tag) as? String { fields[k] = v }
            }
        }
        let ok = playable && fields["Iptc4xmpExt:DigitalSourceType"] == MP4Encoder.digitalSourceType && fields["antichat:model"] == "vid-5b"
            && desc.hasPrefix(prompt)
        #expect(ok, "AT-287 AC3 on the real clip")
        return ["AT-287 AC3 (real FastMetal clip, M5.T05/T06) \(ok ? "PASS" : "FAIL")",
                "playable=\(playable) duration=\(String(format: "%.3f", dur)) s frames=\(meta["frames"] ?? "?") fps=\(meta["fps"] ?? "?") size=\(meta["width"] ?? "?")x\(meta["height"] ?? "?")",
                "uiso/dscp=\(desc)", "xmp=\(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"]
    }
}
