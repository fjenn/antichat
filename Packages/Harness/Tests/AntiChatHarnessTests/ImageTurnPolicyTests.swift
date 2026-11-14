// AT-236 AC1 (R-236; M4.T06 step 4) at the turn controller: on T1 an image tool call ends the turn with the templated
// `img.done.caption` — exactly one engine request (no text step, so no chat reload before the next user message); a
// withheld picture gets no text; on T3 the model writes its sentence (a second, text-only step). Plus the queue-backed
// tool: a call becomes one media job and its terminal maps to the outcome the model sees.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite struct ImageTurnPolicyTests {
    static let script = """
        {"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\\"prompt\\":\\"a lighthouse\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"A lighthouse at dusk, as asked.","delayMs":1}
        """

    func run(tier: DeviceTier, result: String) async throws -> (TurnResult, Int) {
        let (res, engine) = try await runEngine(tier: tier, result: result)
        return (res, engine.count.withLock { $0 })
    }

    func runEngine(tier: DeviceTier, result: String) async throws -> (TurnResult, CountingEngine) {
        let db = try AppDatabase.inMemory()
        let image = RegisteredTool(name: "create_image", description: "Create a picture.",
                                   parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]}"#,
                                   outputIsUntrusted: false) { _ in result }
        var rt = ToolRuntime(registry: ToolRegistry([image]), permissions: ToolPermissionStore(db), policy: .forTier(tier),
                             router: try await RouterStubs.router(enabled: false), tier: { tier })
        rt.imageCaption = "Here's your picture."
        let engine = CountingEngine(InProcessScriptedEngine(script: try EngineScript(text: Self.script)))
        let c = TurnController(chatID: StorageID.make(), database: db, engine: engine, tools: rt,
                               packs: FakePacks([.photo: .installed])) { .scripted("inline") }
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "draw a lighthouse", parentID: nil), assistantID: a)
        let res = try await log.waitFinished(a)
        return (res, engine)
    }

    /// M4.T16 (Release run at T4): the model, sent the stored picture's path, wrote it into the reply as a Markdown image
    /// (`![…](/…/Library/Application Support/…)`). The model's copy of the result carries the id only; the stored
    /// result (the card's picture) keeps the path.
    @Test func t3ModelNeverSeesThePicturePath() async throws {
        let path = "/Users/someone/Library/Application Support/AntiChat/Artifacts/p.png"
        let (res, engine) = try await runEngine(tier: .t3, result: ImageTurnPolicy.Outcome.done(imageID: "j1", width: 1024, height: 1024,
                                                                                                path: path).resultJSON)
        let sent = engine.sent.withLock { $0 }
        #expect(sent.count == 2 && res.text.contains("A lighthouse at dusk"))
        #expect(sent[1].contains("j1") && !sent[1].contains("Application Support") && !sent[1].contains("p.png"))
    }

    /// M4.T16 (Release run at T4): local models call `call_1` in every reply, so the job key is reply id + call id —
    /// an edit's card no longer attaches to the previous reply's finished create job.
    @Test func mediaJobKeyIsPerReply() async throws {
        let seen = Mutex<[String]>([])
        let db = try AppDatabase.inMemory()
        let image = RegisteredTool(name: "create_image", description: "Create a picture.",
                                   parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]}"#,
                                   outputIsUntrusted: false) { _ in
            seen.withLock { $0.append(TurnContext.toolCallID ?? "nil") }
            return ImageTurnPolicy.Outcome.done(imageID: "j1", width: 768, height: 768).resultJSON
        }
        var rt = ToolRuntime(registry: ToolRegistry([image]), permissions: ToolPermissionStore(db), policy: .forTier(.t1),
                             router: try await RouterStubs.router(enabled: false), tier: { .t1 })
        rt.imageCaption = "Here's your picture."
        let chat = StorageID.make()
        var keys: [String] = []
        for _ in 0..<2 {
            let c = TurnController(chatID: chat, database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: Self.script)),
                                   tools: rt, packs: FakePacks([.photo: .installed])) { .scripted("inline") }
            let log = UpdateLog(c)
            let a = StorageID.make()
            await c.start(.send(userID: StorageID.make(), text: "draw a lighthouse", parentID: nil), assistantID: a)
            _ = try await log.waitFinished(a)
            keys.append(MediaCallKey.make(messageID: a, callID: "call_1"))
        }
        #expect(seen.withLock { $0 } == keys && keys[0] != keys[1])
        #expect(MediaCallKey.make(messageID: nil, callID: "call_1") == "call_1")
    }

    @Test func modelViewOfMediaResults() {
        let done = ImageTurnPolicy.Outcome.done(imageID: "a1", width: 768, height: 512, path: "/x/a.png").resultJSON
        #expect(MediaToolResult.forModel(name: "create_image", result: done) == ImageTurnPolicy.Outcome.done(imageID: "a1", width: 768, height: 512).resultJSON)
        #expect(MediaToolResult.forModel(name: "edit_image", result: done).contains("a1"))
        let video = #"{"path":"/x/v.mp4","poster":"/x/v.jpg","status":"done","video_id":"v1"}"#
        #expect(MediaToolResult.forModel(name: "create_video", result: video) == #"{"status":"done","video_id":"v1"}"#)
        #expect(MediaToolResult.forModel(name: "create_document", result: #"{"path":"/x/d.docx"}"#) == #"{"path":"/x/d.docx"}"#)
        #expect(MediaToolResult.forModel(name: "create_image", result: "not json") == "not json")
        // A later turn rebuilds the history from the stored parts: the same view.
        let parts = [PartContent(kind: .toolCall, body: #"{"id":"c1","name":"create_image","arguments":"{}"}"#),
                     PartContent(kind: .toolResult, body: Self.json(["id": "c1", "name": "create_image", "result": done]))]
        let history = ToolLoopHistory.messages(from: parts)
        #expect(history.count == 2 && !history[1].content.contains("/x/a.png") && history[1].content.contains("a1"))
    }

    static func json(_ o: [String: String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func t1EndsWithTheTemplatedCaptionAndNoSecondStep() async throws {
        let (res, requests) = try await run(tier: .t1, result: ImageTurnPolicy.Outcome.done(imageID: "j1", width: 768, height: 768).resultJSON)
        #expect(res.status == .done && res.text == "Here's your picture.")
        #expect(requests == 1, "no LLM step after the image job on T1–T2")
    }

    @Test func withheldPictureHasNoText() async throws {
        let (res, requests) = try await run(tier: .t2, result: ImageTurnPolicy.Outcome.notShown.resultJSON)
        #expect(res.text.isEmpty && requests == 1)
    }

    @Test func t3LetsTheResidentModelSpeak() async throws {
        let (res, requests) = try await run(tier: .t3, result: ImageTurnPolicy.Outcome.done(imageID: "j1", width: 1024, height: 1024).resultJSON)
        #expect(requests == 2 && res.text.contains("A lighthouse at dusk"))
    }

    @Test func outcomeJSONRoundTrips() {
        for o: ImageTurnPolicy.Outcome in [.done(imageID: "a", width: 768, height: 512), .notShown, .unavailable, .safetyMissing(sizeBytes: 9),
                                           .failed(code: "x")] {
            #expect(ImageTurnPolicy.Outcome.parse(o.resultJSON) == o)
        }
        #expect(ImageTurnPolicy.Outcome.notShown.resultJSON == #"{"status":"not_shown"}"#, "no reason, no detail (D-006)")
        #expect(ImageTurnPolicy.endsTurnWithTemplate(tier: .t1) && !ImageTurnPolicy.endsTurnWithTemplate(tier: .t3))
    }

    /// The registered tool → MediaJobQueue: one job with the builder's request; terminals map to outcomes.
    @Test func toolRunsOneQueueJob() async throws {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/x"), safety: { nil })
        let photo = FakePhoto()
        let task = Task {
            try await TurnContext.$chatID.withValue(chat.id) {
                try await ImageTools.run("create_image", #"{"prompt":"a lighthouse","aspect":"16:9","seed":42}"#, queue: q, photo: photo)
            }
        }
        try await MediaJobQueueTests.until("submitted") { t.submittedJobs.count == 1 }
        let sub = t.submitted[0]
        #expect(sub.image.width == 1344 && sub.image.height == 768 && sub.image.seed == 42 && sub.image.negativePrompt == nil)
        t.end(sub.job, .jobResult(job: sub.job, path: "/tmp/x/r.png", metadata: [:]))
        // No chat store here, so nothing can be stored: a failure, never the job id as an image id (M4 review).
        #expect(try await task.value == .failed(code: "save"))

        let blocked = Task {
            try await TurnContext.$chatID.withValue(chat.id) { try await ImageTools.run("create_image", #"{"prompt":"x"}"#, queue: q, photo: photo) }
        }
        try await MediaJobQueueTests.until("second") { t.submittedJobs.count == 2 }
        t.end(t.submitted[1].job, .jobBlocked(job: t.submitted[1].job))
        #expect(try await blocked.value == .notShown)
        #expect(try await ImageTools.run("create_image", #"{"prompt":"x"}"#, queue: q, photo: FakePhoto(installed: false), chatID: chat.id) == .unavailable)
    }

    /// R-285 AC6 / D-006 (Q-015 r5, AT SafetyMissing): absent detector files (or no manifest at all) answer
    /// `safety_missing` with the repair size and submit NO job; present files submit as before.
    @Test func missingDetectorsSubmitNoJob() async throws {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: URL(fileURLWithPath: "/tmp/x"), safety: { nil })
        let o = try await ImageTools.run("create_image", #"{"prompt":"a lighthouse"}"#, queue: q, photo: FakePhoto(detectors: false), chatID: chat.id)
        #expect(o == .safetyMissing(sizeBytes: 123))
        #expect(t.submittedJobs.isEmpty, "no job is submitted")
        #expect(SafetyStatus.preflight(nil) == .missing(sizeBytes: 0))
        #expect(SafetyStatus.preflight(FakeSafety.installed) == .available)
        var oneGone = FakeSafety.installed
        oneGone.ageBinsPath = "/nonexistent/bins"
        #expect(SafetyStatus.preflight(oneGone) == .missing(sizeBytes: 1))
    }
}

struct FakePhoto: PhotoModelProviding {
    var installed = true
    var stepDown = false
    func mediaStepDown() async -> Bool { stepDown }
    func modelSet(for tool: String) async -> ImageModelSet? {
        installed ? ImageModelSet(key: "img-klein-q8", diffusionModel: "/m/d.gguf", llm: "/m/te.gguf", vae: "/m/vae.safetensors", footprintBytes: 6_000_000_000) : nil
    }
    func speedClass() async -> ImageSpeedClass { .s4 }
    var detectors = true
    func safetyManifest() async -> SafetyManifest? { detectors ? FakeSafety.installed : FakeSafety.absent }
    func imagePath(_ id: String) async -> String? { nil }
}
/// Detector files as the app-side preflight sees them (Q-015 r5): present (empty files in a temp dir; the helper's
/// sha256 gate is not part of these tests) or absent (the repair size kept).
enum FakeSafety {
    static let installed: SafetyManifest = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-safety-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = ["n", "a", "b"].map { dir.appendingPathComponent($0).path }
        for f in p { FileManager.default.createFile(atPath: f, contents: Data()) }
        return SafetyManifest(nudityPath: p[0], agePath: p[1], ageBinsPath: p[2], sha256: [:], sizeBytes: 1)
    }()
    static let absent = SafetyManifest(nudityPath: "/nonexistent/n", agePath: "/nonexistent/a", ageBinsPath: "/nonexistent/b",
                                       sha256: [:], sizeBytes: 123)
}
