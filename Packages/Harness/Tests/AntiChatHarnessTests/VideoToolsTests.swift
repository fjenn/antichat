// M5.T10 step 4–5 (R-040 AC1/AC2, R-043 AC1/AC2; cross-task contracts 4–5): `create_video` end to end on the app side
// against a fake helper transport — the plan card's answer (VideoPlanBroker) decides whether a job is written; [Start]
// queues ONE video job in the same durable queue as images (kind `video`, the `VideoRequest` on the submit); the
// result becomes a `video` artifact + poster, a history row (never for incognito) and one completion event; Cancel
// writes nothing; a blocked clip is `not_shown` with no event; Animate's picture reaches the request as is (never
// checked); Evil never asks for Sound. Plus the plan's lead rule: only presets within VideoEligibility's offer.
//   make test-unit FILTER=VideoToolsTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

final class FakeVideoModels: VideoModelProviding, @unchecked Sendable {
    let lock = NSLock()
    var available = true
    private(set) var requests: [(job: VideoPlanJob, source: String?, isEvil: Bool)] = []
    private(set) var completed: [(chat: String, job: String)] = []

    func isAvailable() async -> Bool { lock.withLock { available } }
    func speedClass() async -> String { "S4" }
    func jobCompleted(chatID: String, jobID: String) async { lock.withLock { completed.append((chatID, jobID)) } }
    func request(for job: VideoPlanJob, sourceImagePath: String?, seed: Int64, isEvil: Bool) async -> VideoRequest? {
        lock.withLock { requests.append((job, sourceImagePath, isEvil)) }
        return VideoRequest(mode: job.mode == .i2v ? .i2v : .t2v, prompt: job.prompt, width: job.spec.width, height: job.spec.height,
                            frames: job.spec.frames, fps: job.spec.fps, seed: seed, initImage: sourceImagePath, steps: job.spec.steps,
                            outputPath: "", scratchDir: "", footprintBytes: 0, generator: ScriptedVideoScript().generator)
    }
    var requestCount: Int { lock.withLock { requests.count } }
    var completedCount: Int { lock.withLock { completed.count } }
}

@Suite(.serialized) struct VideoToolsTests {
    struct Env {
        var db: AppDatabase
        var chat: String
        var transport: FakeMediaTransport
        var queue: MediaJobQueue
        var models: FakeVideoModels
        var broker: VideoPlanBroker
        var dir: URL
    }

    static func env(onDisk: Bool = true) throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = onDisk ? try AppDatabase.onDisk(at: dir.appendingPathComponent("db.sqlite")) : try AppDatabase.inMemory()
        FileOutTools.Stores.shared.install(ArtifactStore(database: db, mediaRoot: dir.appendingPathComponent("Media"), incognito: !onDisk),
                                           for: db)  // never the dev container
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: dir.appendingPathComponent("xfer"), safety: { nil })
        if !onDisk { MediaJobQueue.register(q, for: db) }  // an incognito store has its session's own queue (M5.T14 P1-1)
        return Env(db: db, chat: chat.id, transport: t, queue: q, models: FakeVideoModels(), broker: VideoPlanBroker(), dir: dir)
    }

    /// The plan job a card on T3-S4 would hand over (VideoPlan, bundled presets).
    static func job(_ r: VideoPlanRequest) -> VideoPlanJob? {
        let models = [VideoSound.Model(key: "vid-5b", capabilities: []), VideoSound.Model(key: "vid-i2v", capabilities: []),
                      VideoSound.Model(key: "vid-ltx", capabilities: ["audio"])]
        let input = VideoPlanInput(prompt: r.prompt, intent: r.intent, sourceImageID: r.sourceImageID, isEvil: r.isEvil, tier: "T3",
                                   speedClass: "S4", budgetGB: 48, models: models, length: r.length, shape: r.shape, sound: r.sound)
        return VideoPlan.make(input).job
    }

    static func run(_ e: Env, args: String = #"{"prompt":"waves rolling onto a beach at dusk"}"#, facts: VideoTurnContext.Facts? = nil,
                    callID: String = "call-1") -> Task<VideoTurnPolicy.Outcome, Error> {
        Task {
            try await VideoTools.run(args, queue: e.queue, video: e.models, broker: e.broker, chatID: e.chat, callID: callID,
                                     facts: facts, database: e.db)
        }
    }

    /// Writes what the helper writes after the gate allowed a clip (MP4 + poster) and ends the job with `jobResult`.
    static func finish(_ e: Env, job: String) throws {
        let out = e.dir.appendingPathComponent("xfer/\(job)/result.mp4")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: out)
        try Data("jpg".utf8).write(to: URL(fileURLWithPath: VideoTurnPolicy.posterPath(forClip: out.path)))
        e.transport.end(job, .jobResult(job: job, path: out.path, metadata: [:]))
    }

    @Test func startQueuesOneVideoJobAndPostsCompletion() async throws {
        let e = try Self.env()
        await e.broker.setAutoAnswer { r in Self.job(r).map(VideoPlanAnswer.start) }
        let task = Self.run(e, facts: VideoTurnContext.Facts(route: VideoRoute.Facts(chips: ["video"], userText: "waves"), isEvil: false))
        try await MediaJobQueueTests.until("submitted") { !e.transport.submittedJobs.isEmpty }
        let submit = try #require(e.transport.submitted.first)
        #expect(submit.kind == .video && submit.video != nil && submit.requestID == submit.video?.requestID)
        #expect(submit.video?.mode == .t2v && submit.video?.outputPath.hasSuffix("/\(submit.job)/result.mp4") == true)
        #expect(submit.video?.generator?.hasPrefix(ScriptedVideoScript.scheme) == true)
        #expect(try await e.queue.row(submit.job)?.kind == "video")
        #expect(await e.broker.answer(forCall: "call-1") != nil)
        try Self.finish(e, job: submit.job)
        let outcome = try await task.value
        guard case .done(let id, let path?, let poster?) = outcome else { Issue.record("\(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: path) && FileManager.default.fileExists(atPath: poster))
        #expect(path.hasPrefix(e.dir.appendingPathComponent("Media").path), "a video artifact of the chat")
        #expect(!FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("xfer/\(submit.job)").path),
                "M5.T14 P1-2: the xfer copy goes once stored")
        let kind = try e.db.read { db in try String.fetchOne(db, sql: "SELECT kind FROM artifact WHERE id = ?", arguments: [id]) }
        #expect(kind == "video")
        #expect(e.models.completed.map(\.chat) == [e.chat] && e.models.completed.map(\.job) == [submit.job], "one MediaJobCompleted")
        let runs = try e.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM video_run_history") }
        #expect(runs == 1, "history row for a Normal chat")
        #expect(VideoTurnPolicy.Outcome.parse(outcome.resultJSON) == outcome)
    }

    @Test func cancelOnThePlanCardWritesNoJob() async throws {
        let e = try Self.env()
        await e.broker.setAutoAnswer { _ in .cancel }
        let outcome = try await Self.run(e).value
        #expect(outcome == .notStarted && outcome.resultJSON == #"{"status":"not_started"}"#)
        #expect(e.transport.submittedJobs.isEmpty && e.models.requestCount == 0)
        #expect(try e.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_job") } == 0)
    }

    @Test func theCardAnswersAWaitingCall() async throws {
        let e = try Self.env()
        let task = Self.run(e, callID: "call-wait")
        try await MediaJobQueueTests.until("plan published") { await e.broker.request(forCall: "call-wait") != nil }
        let r = try #require(await e.broker.request(forCall: "call-wait"))
        #expect(r.prompt == "waves rolling onto a beach at dusk" && r.intent == .inferred && r.chatID == e.chat)
        await e.broker.answer(callID: "call-wait", .cancel)
        #expect(try await task.value == .notStarted)
        #expect(await e.broker.request(forCall: "call-wait") == nil)
    }

    @Test func blockedClipIsNotShownAndNotAnnounced() async throws {
        let e = try Self.env()
        await e.broker.setAutoAnswer { r in Self.job(r).map(VideoPlanAnswer.start) }
        let task = Self.run(e)
        try await MediaJobQueueTests.until("submitted") { !e.transport.submittedJobs.isEmpty }
        let job = try #require(e.transport.submittedJobs.first)
        e.transport.end(job, .jobBlocked(job: job))
        #expect(try await task.value == .notShown)
        #expect(e.models.completedCount == 0)
        #expect(try e.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artifact") } == 0)
    }

    @Test func animateSourceReachesTheRequestUnchecked() async throws {
        let e = try Self.env()
        let store = FileOutTools.Stores.shared.store(for: e.db)
        let png = try store.save(chatID: e.chat, kind: "image", filename: "image.png", data: Data([0x89, 0x50, 0x4E, 0x47]),
                                 specJSON: nil, messageID: nil)
        await e.broker.setAutoAnswer { r in Self.job(r).map(VideoPlanAnswer.start) }
        let facts = VideoTurnContext.Facts(route: VideoRoute.Facts(chips: ["video", VideoRoute.animateChip(png.artifactID)],
                                                                   userText: "Animate"), isEvil: false)
        let task = Self.run(e, facts: facts)
        try await MediaJobQueueTests.until("submitted") { !e.transport.submittedJobs.isEmpty }
        let submit = try #require(e.transport.submitted.first)
        #expect(submit.video?.mode == .i2v && submit.video?.initImage == png.path, "the stored picture, as is (D-005)")
        let req = try #require(e.models.requests.first)
        #expect(req.job.mode == .i2v && req.job.sourceImageID == png.artifactID && req.source == png.path)
        #expect(req.job.spec.model == "vid-i2v")
        e.transport.end(submit.job, .jobCancelled(job: submit.job))
        #expect(try await task.value == .failed(code: "cancelled"))
    }

    @Test func theLastImageOfTheChatIsTheSource() async throws {
        let e = try Self.env()
        let store = FileOutTools.Stores.shared.store(for: e.db)
        _ = try store.save(chatID: e.chat, kind: "image", filename: "image.png", data: Data([1, 2, 3]), specJSON: nil, messageID: nil,
                           now: Date(timeIntervalSinceNow: -60))
        let newest = try store.save(chatID: e.chat, kind: "image", filename: "image.png", data: Data([4, 5, 6]), specJSON: nil, messageID: nil)
        #expect(store.lastImageRef(chatID: e.chat) == newest.artifactID)
        await e.broker.setAutoAnswer { r in Self.job(r).map(VideoPlanAnswer.start) }
        let facts = VideoTurnContext.Facts(route: VideoRoute.Facts(routeTop: .videoFromImage, userText: "animate the last image"),
                                           isEvil: false)
        let task = Self.run(e, facts: facts)
        try await MediaJobQueueTests.until("submitted") { !e.transport.submittedJobs.isEmpty }
        let submit = try #require(e.transport.submitted.first)
        #expect(submit.video?.mode == .i2v && submit.video?.initImage == newest.path)
        e.transport.end(submit.job, .jobCancelled(job: submit.job))
        _ = try await task.value
    }

    @Test func unknownSourceFailsBeforeAnyCard() async throws {
        let e = try Self.env()
        let outcome = try await Self.run(e, args: #"{"prompt":"x","source_image_id":"nope"}"#).value
        #expect(outcome == .failed(code: "unknownSourceImage"))
        #expect(await e.broker.request(forCall: "call-1") == nil && e.transport.submittedJobs.isEmpty)
    }

    @Test func incognitoKeepsNoHistoryAndWritesToTheTempStore() async throws {
        let e = try Self.env(onDisk: false)
        await e.broker.setAutoAnswer { r in Self.job(r).map(VideoPlanAnswer.start) }
        let task = Self.run(e)
        try await MediaJobQueueTests.until("submitted") { !e.transport.submittedJobs.isEmpty }
        let job = try #require(e.transport.submittedJobs.first)
        try Self.finish(e, job: job)
        guard case .done(_, let path?, _) = try await task.value else { Issue.record("not done"); return }
        #expect(path.hasPrefix(e.dir.appendingPathComponent("Media").path), "the incognito store's temp dir")
        #expect(try e.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM video_run_history") } == 0, "no history row")
    }

    @Test func evilNeverAsksForSound() async throws {
        let e = try Self.env()
        let seen = Mutex<VideoPlanRequest?>(nil)
        await e.broker.setAutoAnswer { r in seen.withLock { $0 = r }; return .cancel }
        let facts = VideoTurnContext.Facts(route: VideoRoute.Facts(chips: ["video"]), isEvil: true)
        _ = try await Self.run(e, args: #"{"prompt":"a storm","sound":true}"#, facts: facts, callID: "evil").value
        let r = try #require(seen.withLock { $0 })
        #expect(r.isEvil && r.sound == false && r.intent == .createVideoChip, "Evil plans never carry Sound (K-014)")
        // …and the plan runs the Normal silent model with no Sound chip.
        let models = [VideoSound.Model(key: "vid-5b", capabilities: []), VideoSound.Model(key: "vid-ltx", capabilities: ["audio"])]
        let plan = VideoPlan.make(VideoPlanInput(prompt: r.prompt, intent: r.intent, isEvil: true, tier: "T3", speedClass: "S4",
                                                 budgetGB: 48, models: models, sound: true))
        #expect(!plan.soundChip && plan.spec?.sound == false && plan.spec?.model == "vid-5b")
    }

    @Test func unavailableVideoAnswersUnavailable() async throws {
        let e = try Self.env()
        e.models.lock.withLock { e.models.available = false }
        #expect(try await Self.run(e).value == .unavailable)
    }

    @Test func restartKeepsAVideoJobAVideoJob() async throws {
        let e = try Self.env()
        let req = VideoRequest(mode: .t2v, prompt: "a koala", width: 320, height: 192, frames: 33, seed: 1, outputPath: "", scratchDir: "",
                               footprintBytes: 0, generator: ScriptedVideoScript().generator)
        let id = try await e.queue.enqueue(chatID: e.chat, video: req)
        try await MediaJobQueueTests.until("submitted") { e.transport.submittedJobs == [id] }
        e.transport.end(id, .jobFailed(job: id, code: "x"))
        try await MediaJobQueueTests.until("failed") { try await MediaJobQueueTests.state(e.queue, id) == .failed }
        let again = try await e.queue.restart(id)
        try await MediaJobQueueTests.until("resubmitted") { e.transport.submittedJobs.count == 2 }
        let s = try #require(e.transport.submitted.last)
        #expect(s.job == again && s.kind == .video && s.video?.prompt == "a koala" && s.video?.requestID != req.requestID)
        e.transport.end(again, .jobCancelled(job: again))
    }

    // MARK: lead decision: the plan offers only what VideoEligibility offers

    @Test func planStaysWithinTheEligibilityOffer() throws {
        let models = [VideoSound.Model(key: "vid-5b", capabilities: []), VideoSound.Model(key: "vid-ltx", capabilities: ["audio"])]
        func input(_ offered: [String]?, sound: Bool? = nil) -> VideoPlanInput {
            VideoPlanInput(prompt: "p", intent: .createVideoChip, tier: "T3", speedClass: "S4", budgetGB: 48, models: models,
                           sound: sound, offeredPresets: offered)
        }
        // Unrestricted: 720p default.
        #expect(VideoPlan.make(input(nil)).spec?.resolution == "720p")
        // 720p not offered (memory) → the largest offered resolution, the picker shows it.
        let low = VideoPlan.make(input(["t2v-480p-short", "t2v-ltx-512p-short"]))
        #expect(low.spec?.resolution == "480p" && low.historyKey == "t2v-480p-short" && low.options?.resolution == "480p")
        // Sound on but the LTX preset not offered → silent model, no chip.
        let silent = VideoPlan.make(input(["t2v-480p-short", "t2v-720p-short"], sound: true))
        #expect(silent.spec?.sound == false && silent.spec?.model == "vid-5b" && !silent.soundChip)
        // Sound chip only when a Sound-on clip is within the offer.
        #expect(VideoPlan.make(input(["t2v-720p-short", "t2v-ltx-512p-short"])).soundChip)
        let on = VideoPlan.make(input(["t2v-720p-short", "t2v-ltx-512p-short"], sound: true))
        #expect(on.spec?.model == "vid-ltx" && on.spec?.sound == true && on.historyKey == "t2v-ltx-512p-short")
        // Nothing offered → not offered (no job can come out of the card).
        let none = VideoPlan.make(input([]))
        #expect(!none.isOffered && none.job == nil && !none.soundChip)
    }

    @Test func ltxRowIsMeasuredOnS4AndScaledBelow() throws {
        let t = VideoSpeedTable.bundled
        let p = try #require(t.preset("t2v-ltx-512p-short"))
        #expect(p.model == "vid-ltx" && p.width == 768 && p.height == 512 && p.frames == 97 && p.steps == 11)
        let s4 = try #require(t.row(speedClass: "S4", preset: p.key))
        #expect(s4.source == "measured" && s4.n == 3)  // M9.T05 round 66: runtime 0.3.5, 3 runs
        let total = s4.encodeS + Double(p.steps) * s4.tStepS + Double(p.frames) * s4.decodeSPerFrame
        #expect(abs(total - 78.2) < 0.5, "measured total 78.2 s, got \(total)")
        #expect(abs(s4.peakGB - 28.87) < 0.05, "peak 28.87 GB")
        for c in ["S1", "S2", "S3"] { #expect(t.row(speedClass: c, preset: p.key)?.source == "scaled", "\(c)") }
        #expect(Set(t.presets.map(\.model)) == ["vid-5b", "vid-i2v", "vid-ltx"], "every assigned video model has a row")
    }
}
