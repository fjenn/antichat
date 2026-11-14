// M5.T10 (R-040 AC1, R-043 AC2; D-006): a queued video job travels the SAME helper path as an image job — the app's
// MediaJobQueue sends `ClientMessage.mediaJob(MediaJobSubmit{kind: video, video: VideoRequest})` over XPC; the helper's
// EngineCore.runMediaJob hands it to the video lane under the QUEUE's job id → MediaJobRunner (one heavy job at a time,
// the gate) → EngineRuntime.runVideo → ScriptedVideoEngine (no runtime, no model). Without detector files the gate
// fails closed: terminal `safetyMissing` for that job id and nothing written (no MP4, no poster). The allowed path
// (jobResult → MP4 + poster) is VideoGateRealDetectorTests (real detectors) and the forced-verdict suites of
// tools/at/at-285-runner.sh (UI-testing build only).
//   make test-unit FILTER=VideoQueueRoundTripTests
import AntiChatEngineProtocol
import AntiChatEngines
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngineHost

@Suite(.serialized) struct VideoQueueRoundTripTests {
    static func temp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("video-rt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func core(_ dir: URL) -> EngineCore {
        EngineCore(paths: EngineListener.Paths(
            llamaServer: "/nonexistent/llama-server", sdServer: "/nonexistent/sd-server", sdLog: nil,
            sdModelDir: dir.path, kvDir: dir.appendingPathComponent("kv").path, llamaLog: nil, selfExecutable: "/usr/bin/true",
            watchdogTool: nil, videoLog: nil, logDir: nil))
    }

    static func request(_ dir: URL, mode: VideoRequest.Mode) -> VideoRequest {
        VideoRequest(mode: mode, prompt: "a lighthouse on a cliff", width: 64, height: 32, frames: 9, fps: 8, seed: 3,
                     initImage: mode == .i2v ? dir.appendingPathComponent("source.png").path : nil,
                     outputPath: dir.appendingPathComponent("xfer/job/result.mp4").path, scratchDir: dir.path, footprintBytes: 0,
                     generator: ScriptedVideoScript(steps: 2, delayMs: 1, frames: 9, fps: 8, previewFrames: 0).generator)
    }

    @Test func submitSurvivesTheWireWithItsVideoRequest() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let submit = MediaJobSubmit(job: "queue-job-1", video: Self.request(dir, mode: .t2v), previewDir: dir.path, safety: nil)
        #expect(submit.kind == .video && submit.requestID == submit.video?.requestID && submit.image.requestID == submit.requestID)
        let back = try JSONDecoder().decode(MediaJobSubmit.self, from: JSONEncoder().encode(submit))
        #expect(back == submit && back.video?.generator == submit.video?.generator)
        // An image submit from before M5.T10 (no `video` key) still decodes.
        var old = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(submit)) as? [String: Any])
        old["video"] = nil
        old["kind"] = "image"
        let image = try JSONDecoder().decode(MediaJobSubmit.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(image.video == nil && image.kind == .image)
    }

    @Test(arguments: [VideoRequest.Mode.t2v, .i2v])
    func queuedVideoRunsTheVideoLaneUnderTheQueueJobID(mode: VideoRequest.Mode) async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = Self.core(dir)
        let req = Self.request(dir, mode: mode)
        let submit = MediaJobSubmit(job: "queue-job-\(mode.rawValue)", video: req, previewDir: dir.appendingPathComponent("xfer/job").path,
                                    safety: nil)
        let items = Mutex<[StreamItem]>([])
        await core.runMediaJob(submit, cancel: EngineRuntime.CancelFlag(), emit: { batch, _ in items.withLock { $0 += batch } })
        let all = items.withLock { $0 }
        let jobs = all.compactMap { if case .media(.job(let e)) = $0 { e } else { nil } }
        #expect(jobs.first == .jobStarted(job: submit.job, engineInstanceID: core.mediaJobs.engineInstanceID))
        guard case .safetyMissing(let job, _)? = jobs.last else { Issue.record("terminal \(String(describing: jobs.last))"); return }
        #expect(job == submit.job, "the queue's job id, not the request id")
        #expect(jobs.allSatisfy { $0.job == submit.job })
        // The video lane ran (scripted stages up to the final frames handed to the gate), not the image lane.
        #expect(all.contains { if case .media(.videoProgress(let p)) = $0 { p.stage == "decode" } else { false } })
        #expect(!all.contains { if case .media(.imageResult) = $0 { true } else { false } })
        #expect(!FileManager.default.fileExists(atPath: req.outputPath), "nothing unchecked is written")
        #expect(!FileManager.default.fileExists(atPath: (req.outputPath as NSString).deletingPathExtension + ".poster.jpg"))
    }
}
