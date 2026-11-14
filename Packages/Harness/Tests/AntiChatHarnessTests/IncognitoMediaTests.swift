// M5.T14 review P1-1 (R-090, cross-task contract 5): media jobs of an incognito chat run on the session's OWN queue,
// with the production wiring (`ToolRuntime.installMedia` as ChatEnvironment.open calls it, then IncognitoSession). The
// app database gets no `media_job` row (the old wiring hit the chat FK, or stored the prompt in spec_json), the helper
// writes into the session's temp dir (never the app's xfer root), the clip / picture is stored there with no history or
// Library row, and the job's xfer files go once stored. A store with no session queue fails closed (`unavailable`).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct IncognitoMediaTests {
    struct App {
        var root: URL
        var db: AppDatabase
        var transport: FakeMediaTransport
        var queue: MediaJobQueue
        var env: ChatEnvironment
    }

    static func app() throws -> App {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incognito-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: root.appendingPathComponent("antichat.sqlite"))
        FileOutTools.Stores.shared.install(ArtifactStore(database: db, mediaRoot: root.appendingPathComponent("Media"), incognito: false), for: db)
        let t = FakeMediaTransport()
        let broker = VideoPlanBroker()
        var tools = ToolRuntime(registry: .m1(scriptedTools: false), permissions: ToolPermissionStore(db))
        let queue = tools.installMedia(database: db, transport: t, xferRoot: root.appendingPathComponent("xfer"), photo: FakePhoto(),
                                       video: FakeVideoModels(), broker: broker)
        Task { await broker.setAutoAnswer { r in VideoToolsTests.job(r).map(VideoPlanAnswer.start) } }
        let engine = InProcessScriptedEngine(script: try EngineScript(text: words(3, delayMs: 1)))
        let env = ChatEnvironment(database: db, engine: engine, tools: tools, slot: { .scripted("inline") })
        return App(root: root, db: db, transport: t, queue: queue, env: env)
    }

    /// Invokes a registered tool as the turn loop does (chat, call id and the chat's store as task locals).
    static func invoke(_ s: IncognitoSession, _ tool: String, _ args: String, chat: String, call: String) -> Task<String, Error> {
        let registry = s.environment.tools!.registry
        let store = s.store
        return Task {
            try await TurnContext.$chatID.withValue(chat) {
                try await TurnContext.$toolCallID.withValue(call) {
                    try await ToolCallStore.$database.withValue(store) { try await registry.invoke(tool, argumentsJSON: args) }
                }
            }
        }
    }

    static func count(_ db: AppDatabase, _ table: String) throws -> Int {
        try db.read { d in try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    @Test func incognitoVideoRunsOnTheSessionQueueAndPersistsNothing() async throws {
        let a = try Self.app()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let s = try IncognitoSession(app: a.env, tempRoot: a.root.appendingPathComponent("tmp"))
        let chat = try s.createChat()
        let sq = try #require(s.mediaQueue)
        #expect(sq !== a.queue)
        let task = Self.invoke(s, CreateVideoTool.name, #"{"prompt":"waves rolling onto a beach at dusk"}"#, chat: chat, call: "inc-v")
        try await MediaJobQueueTests.until("submitted") { !a.transport.submittedJobs.isEmpty }
        let submit = try #require(a.transport.submitted.first)
        let out = try #require(submit.video?.outputPath)
        #expect(out.hasPrefix(s.tempDirectory.path), "the helper writes into the session's temp dir: \(out)")
        #expect(submit.previewDir?.hasPrefix(s.tempDirectory.path) == true)
        #expect(try Self.count(a.db, "media_job") == 0, "no row (and no prompt) in the app database")
        #expect(try Self.count(s.store, "media_job") == 1)
        #expect(await MediaJobQueue.job(forCall: "inc-v")?.queue === sq, "the card finds the session's queue")
        // The helper's gated output, then the result.
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mp4".utf8).write(to: url)
        try Data("jpg".utf8).write(to: URL(fileURLWithPath: VideoTurnPolicy.posterPath(forClip: out)))
        a.transport.end(submit.job, .jobResult(job: submit.job, path: out, metadata: [:]))
        let outcome = try #require(VideoTurnPolicy.Outcome.parse(try await task.value))
        guard case .done(_, let path?, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(path.hasPrefix(s.tempDirectory.path), "stored in the session's temp dir")
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "xfer copy removed")
        #expect(try Self.count(a.db, "artifact") == 0)
        #expect(try Self.count(a.db, "video_run_history") == 0)
        #expect(try Self.count(s.store, "video_run_history") == 0, "no history for incognito")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: a.root.appendingPathComponent("xfer").path)) ?? []).isEmpty,
                "nothing in the app's xfer root")
        s.discard()
        #expect(!FileManager.default.fileExists(atPath: s.tempDirectory.path))
        #expect(MediaJobQueue.serving(s.store, app: a.queue) == nil, "the session queue is gone with the session")
    }

    @Test func incognitoImageRunsOnTheSessionQueue() async throws {
        let a = try Self.app()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let s = try IncognitoSession(app: a.env, tempRoot: a.root.appendingPathComponent("tmp"))
        defer { s.discard() }
        let chat = try s.createChat()
        let task = Self.invoke(s, CreateImageTool.name, #"{"prompt":"a lighthouse at dusk"}"#, chat: chat, call: "inc-i")
        try await MediaJobQueueTests.until("submitted") { !a.transport.submittedJobs.isEmpty }
        let submit = try #require(a.transport.submitted.first)
        #expect(submit.image.outputPath.hasPrefix(s.tempDirectory.path))
        #expect(try Self.count(a.db, "media_job") == 0)
        #expect(try Self.count(s.store, "media_job") == 1)
        let url = URL(fileURLWithPath: submit.image.outputPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        a.transport.end(submit.job, .jobResult(job: submit.job, path: url.path, metadata: [:]))
        let outcome = try #require(ImageTurnPolicy.Outcome.parse(try await task.value))
        guard case .done(_, _, _, let path?) = outcome else { Issue.record("\(outcome)"); return }
        #expect(path.hasPrefix(s.tempDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), "xfer copy removed")
        #expect(try Self.count(a.db, "artifact") == 0)
    }

    /// Incognito is the session's, not the store's being in memory: a Normal chat on an in-memory store uses the app's
    /// queue; an incognito session's store without a session queue fails closed.
    @Test func anIncognitoStoreWithoutASessionQueueFailsClosed() async throws {
        let a = try Self.app()
        defer { try? FileManager.default.removeItem(at: a.root) }
        let normal = try AppDatabase.inMemory()
        #expect(MediaJobQueue.serving(normal, app: a.queue) === a.queue, "an in-memory Normal store is not incognito")
        let mem = try AppDatabase.inMemory()
        MediaJobQueue.markIncognito(mem)
        let chat = ChatRecord(mode: .normal)
        try mem.write { try chat.insert($0) }
        #expect(MediaJobQueue.serving(mem, app: a.queue) == nil)
        #expect(MediaJobQueue.serving(a.db, app: a.queue) === a.queue)
        let broker = VideoPlanBroker()
        await broker.setAutoAnswer { r in VideoToolsTests.job(r).map(VideoPlanAnswer.start) }
        let outcome = try await VideoTools.run(#"{"prompt":"waves"}"#, queue: a.queue, video: FakeVideoModels(), broker: broker,
                                               chatID: chat.id, callID: "mem", facts: nil, database: mem)
        #expect(outcome == .unavailable)
        #expect(a.transport.submittedJobs.isEmpty)
        #expect(try Self.count(a.db, "media_job") == 0)
    }
}
