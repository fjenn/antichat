// M5.T03 task check: the helper's client of the video runtime server — SSE parsing of a recorded event stream (the
// scripted generator's, captured from `antichat_video.server`), the length-prefixed frames format, the job body keys.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct VideoRuntimeClientTests {
    /// Recorded from `--generator scripted` (one preview frame kept, base64 shortened to a valid 1×1 JPEG).
    static let recorded: [(String, String)] = [
        ("progress", #"{"stage":"encode","step":0,"total":1}"#),
        ("progress", #"{"stage":"encode","step":1,"total":1}"#),
        ("progress", #"{"stage":"denoise","step":0,"total":3}"#),
        ("progress", #"{"stage":"denoise","step":1,"total":3}"#),
        ("preview", #"{"frame_index":0,"frames":6,"width":277,"height":160,"step":1,"total":3,"jpeg_b64":"/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="}"#),
        ("progress", #"{"stage":"decode","step":49,"total":49}"#),
        ("frames_ready", #"{"count":49,"width":832,"height":480,"fps":24}"#),
        ("end", #"{"status":"completed","metrics":{"total_s":0.31,"previews_failed":0}}"#),
        ("unknown", #"{"x":1}"#),
    ]

    @Test func parsesEveryRecordedEvent() throws {
        let evs = Self.recorded.compactMap { VideoRuntimeClient.parse(event: $0.0, data: $0.1) }
        #expect(evs.count == 8)  // the unknown kind is dropped
        #expect(evs[3] == .progress(stage: "denoise", step: 1, total: 3))
        guard case .preview(let fi, let n, let w, let h, let jpeg, let step, let total) = evs[4] else { Issue.record("preview"); return }
        #expect(fi == 0 && n == 6 && w == 277 && h == 160 && step == 1 && total == 3)
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(evs[6] == .framesReady(count: 49, width: 832, height: 480, fps: 24))
        #expect(evs[7] == .end(status: "completed", metrics: ["total_s": 0.31, "previews_failed": 0]))
    }

    @Test func badPreviewOrJSONIsDropped() {
        #expect(VideoRuntimeClient.parse(event: "preview", data: #"{"frame_index":0}"#) == nil)
        #expect(VideoRuntimeClient.parse(event: "progress", data: "not json") == nil)
        #expect(VideoRuntimeClient.parse(event: "error", data: #"{"code":"taehvMissing"}"#) == .error(code: "taehvMissing"))
    }

    @Test func splitsLengthPrefixedFramesAndRejectsBadSizes() throws {
        func frame(_ n: Int, _ v: UInt8) -> Data {
            var d = Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            d.append(Data(repeating: v, count: n))
            return d
        }
        let body = frame(16, 1) + frame(16, 2) + frame(16, 3)
        let fs = try VideoRuntimeClient.splitFrames(body, frameBytes: 16)
        #expect(fs.count == 3 && fs[2] == Data(repeating: 3, count: 16))
        #expect(throws: (any Error).self) { try VideoRuntimeClient.splitFrames(frame(12, 1), frameBytes: 16) }
        #expect(throws: (any Error).self) { try VideoRuntimeClient.splitFrames(body.dropLast(3), frameBytes: 16) }
    }

    @Test func jobBodyUsesTheServerKeys() throws {
        let j = VideoRuntimeClient.Job(jobID: "j1", modelDir: "/m", taehvPath: "/t", prompt: "waves", width: 832, height: 480,
                                       numFrames: 73, fps: 24, seed: 3, memoryLimitBytes: 36_000_000_000)
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as? [String: Any])
        for k in ["job_id", "model_dir", "taehv_path", "prompt", "width", "height", "num_frames", "fps", "steps", "seed",
                  "memory_limit_bytes", "preview"] { #expect(o[k] != nil, "\(k)") }
        // fix/t05-video: the preview size / step fields are sent only when set (an older runtime never sees them unset).
        #expect(o["preview_short_side"] == nil && o["preview_min_fraction"] == nil)
        var p = j
        p.previewShortSide = 512
        p.previewMinFraction = 0.75
        let q = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        #expect(q["preview_short_side"] as? Int == 512 && q["preview_min_fraction"] as? Double == 0.75)
    }
}
