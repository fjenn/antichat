// M5.T11 (R-041 AC1/AC4, NFR-P3, NFR-VID3, NFR-B3/B5; P-media-10): the helper's video stage and governor notes reach the
// card through MediaJobQueue (fake helper transport): stage + step, the latest gated preview set (frames of one step),
// paused hot / app and the `thermal.serious` line; a re-attaching card gets it all from `snapshot`; `hasRunningVideo`
// keeps the app open after its last window; [Resume] goes to the helper as `mediaJobControl` on the job's stream.
// `VideoJobProgress`: encode 0 %, denoise steps, decode frames, monotonic, 100 % only with the result.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

final class ControlRecordingTransport: MediaJobTransport, @unchecked Sendable {
    let inner = FakeMediaTransport()
    private let lock = NSLock()
    private(set) var controls: [(UUID, MediaJobControl.Action)] = []
    func engineInstanceID() async throws -> String { try await inner.engineInstanceID() }
    func submit(_ job: MediaJobSubmit) -> AsyncStream<EngineBatch> { inner.submit(job) }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
    func control(_ requestID: UUID, _ action: MediaJobControl.Action) { lock.withLock { controls.append((requestID, action)) } }
    var controlCount: Int { lock.withLock { controls.count } }
}

@Suite(.serialized) struct VideoJobStatusTests {
    static func video() -> VideoRequest {
        VideoRequest(mode: .t2v, prompt: "waves at dusk", width: 1280, height: 704, frames: 81, fps: 24, seed: 3, outputPath: "",
                     scratchDir: "", footprintBytes: 0)
    }

    static func progress(_ stage: String, _ step: Int = 0, _ total: Int = 0) -> StreamItem {
        .media(.videoProgress(VideoProgress(stage: stage, step: step, totalSteps: total, t: 0, childPID: 0)))
    }

    static func governor(paused: String = "", notice: String = "", background: Bool = false) -> StreamItem {
        .media(.scheduler(SchedulerNote(action: "videoState", model: "video",
                                        detail: ["paused": paused, "notice": notice, "background": background ? "1" : "0"])))
    }

    @Test func stagePreviewsAndPausesReachTheCardAndItsSnapshot() async throws {
        let (db, chat) = try MediaJobQueueTests.setUp()
        let t = ControlRecordingTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/xfer-video"), safety: { nil })
        let updates = await q.subscribe()
        let id = try await q.enqueue(chatID: chat, video: Self.video())
        try await MediaJobQueueTests.until("submitted") { t.inner.submittedJobs == [id] }
        #expect(q.hasRunningVideo, "the app stays open after its last window")
        t.inner.send(id, [Self.progress("spawn"), Self.progress("encode", 1, 1), Self.progress("denoise", 0, 3)])
        t.inner.send(id, [Self.progress("denoise", 1, 3), .media(.job(.jobProgress(job: id, step: 1, totalSteps: 3, previewPath: nil)))])
        t.inner.send(id, [Self.governor(notice: "thermal.serious")])
        t.inner.send(id, [Self.progress("denoise", 3, 3)] + (0..<3).map { f in
            .media(.job(.jobProgress(job: id, step: 3, totalSteps: 3, previewPath: "/tmp/xfer-video/\(id)/preview-0003-0\(f).jpg")))
        })
        t.inner.send(id, [Self.governor(paused: "hot")])
        var last: MediaJobQueue.Update?
        for await u in updates where u.job == id {
            last = u
            if u.video?.paused == "hot" { break }
        }
        let v = try #require(last?.video)
        #expect(v.stage == "denoise" && v.step == 3 && v.total == 3)
        #expect(v.previewStep == 3 && v.previewFrames.count == 3, "the step's animated set, in order")
        #expect(v.paused == "hot" && v.notice == nil, "paused: the serious line gives way")
        // A card that comes back (navigation, a reopened window) re-attaches from the snapshot.
        let snap = try #require(await q.snapshot(id))
        #expect(snap.video == v && snap.state == .running)
        // [Resume] → the helper, on the job's stream.
        await q.resume(id)
        #expect(t.controlCount == 1 && t.controls.first?.1 == .resume && t.controls.first?.0 == t.inner.submitted.first?.requestID)
        t.inner.send(id, [Self.governor(), Self.progress("decode", 40, 81)])
        t.inner.end(id, .jobResult(job: id, path: "/tmp/xfer-video/\(id)/result.mp4", metadata: [:]))
        let end = await q.finished(id)
        #expect(end.state == .done && !q.hasRunningVideo)
        #expect(await q.snapshot(id)?.video?.paused == nil, "a finished job is never shown paused")
    }

    @Test func percentIsMonotonicAndHundredOnlyWithTheResult() {
        var s = VideoJobStatus()
        var p = JobProgressModel()
        func feed(_ stage: String, _ step: Int, _ total: Int) -> Int {
            s.apply(.videoProgress(VideoProgress(stage: stage, step: step, totalSteps: total, t: 0, childPID: 0)))
            p.observe(progress: VideoJobProgress.fraction(s))
            return p.percent
        }
        #expect(feed("spawn", 0, 0) == 0 && feed("encode", 1, 1) == 0, "encode 0 %")
        #expect(feed("denoise", 0, 3) == 0)
        #expect(feed("denoise", 1, 3) == 30 && feed("denoise", 2, 3) == 60 && feed("denoise", 3, 3) == 90)
        #expect(feed("decode", 0, 81) == 90, "never back")
        #expect(feed("decode", 81, 81) == 99 && feed("frames", 81, 81) == 99, "99 until the result")
        #expect(feed("denoise", 1, 3) == 99, "a restarted count never moves the pill back")
        p.finished()
        #expect(p.percent == 100)
    }

    @Test func previewSetsReplaceEachOtherPerStep() {
        var s = VideoJobStatus()
        s.addPreview("/x/preview-0015-00.jpg", step: 15)
        s.addPreview("/x/preview-0016-00.jpg", step: 16)
        #expect(s.previewStep == 16 && s.previewFrames == ["/x/preview-0016-00.jpg"], "sd.cpp: one frame per step")
        s.addPreview("/x/preview-0016-00.jpg", step: 16)
        #expect(s.previewFrames.count == 1, "no duplicates")
    }
}
