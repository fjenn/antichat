// AT-237 (R-237 AC1/AC2; M6.T06): an image sent to a text-only model is described once by the helper VLM (stored as
// `caption_text`), the prompt carries `<image_description source="helper" untrusted="true">` with the caption and the
// OCR text, the reply records `vision: helper` (the img.describedByHelper label); follow-ups and a forced compaction
// reuse the stored caption and the helper runs 0 more times. T0 (captions not allowed): OCR only, no label; no helper
// installed: img.needsLargerModel.
//   make test-unit FILTER='HelperCaptionerTests|CompactionImageTests'
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatHarness

final class CaptionEngine: EngineService {
    static let caption = "A shop receipt on white paper listing groceries and a total."
    let requests = Mutex<[ChatRequest]>([])
    let replyWords: Int
    init(replyWords: Int = 5) { self.replyWords = replyWords }

    static func isCaption(_ r: ChatRequest) -> Bool { r.flattenedMessages.last?.content == HelperCaptioner.prompt }
    var captionCalls: Int { requests.withLock { $0.filter(Self.isCaption).count } }
    var chatRequests: [ChatRequest] {
        requests.withLock { $0.filter { !Self.isCaption($0) && !CompactionTestEngine.isCompaction($0) } }
    }
    var compactionRequests: [ChatRequest] { requests.withLock { $0.filter(CompactionTestEngine.isCompaction) } }

    func capabilities() async -> EngineCapabilities? { nil }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        let text: String
        if Self.isCaption(request) { text = Self.caption }
        else if CompactionTestEngine.isCompaction(request) { text = "SUMMARY: the user asked about a receipt." }
        else { text = (0..<replyWords).map { "w\($0)" }.joined(separator: " ") }
        return AsyncThrowingStream { c in
            c.yield(.textDelta(text))
            c.yield(.done(.stop))
            c.finish()
        }
    }
}

struct CaptionRig {
    let db: AppDatabase
    let engine: CaptionEngine
    let controller: TurnController
    let log: UpdateLog
    let chatID = StorageID.make()
    let xfer: URL

    init(helper: Bool = true, allowed: Bool = true, window: Int = 32_768, replyWords: Int = 5,
         idleDelay: Duration = .seconds(3600)) throws {
        db = try AppDatabase.inMemory()
        engine = CaptionEngine(replyWords: replyWords)
        let xfer = FileManager.default.temporaryDirectory.appendingPathComponent("caption-\(UUID().uuidString)")
        self.xfer = xfer
        let routing = VisionRouting(preparer: { _ in ImageInputPreparer(directory: xfer) },
                                    helperSlot: { helper ? ModelSlot(engine: .scripted, key: "chat-0.8b+vision", path: "", vision: true) : nil },
                                    captionsAllowed: { allowed })
        controller = TurnController(chatID: chatID, database: db, engine: engine,
                                    contextPolicy: ContextPolicy(idleDelay: idleDelay, reservedOutput: 512, windowOverride: window),
                                    vision: routing) { ModelSlot(engine: .scripted, key: "chat-lfm3", path: "") }
        log = UpdateLog(controller)
    }

    static var fixtures: URL { VisionInputTests.fixtures }

    func attach(_ rel: String) async throws -> String {
        let intake = AttachmentIntake(database: db, mediaRoot: VisionInputTests.mediaRoot(), incognito: true)
        let item = await intake.ingest(AttachmentIntake.admit([Self.fixtures.appendingPathComponent(rel)]).items[0])
        return try #require(item.attachmentID)
    }

    @discardableResult
    func send(_ text: String, attachments: [String] = []) async throws -> String {
        let leaf = try db.read { db in try MessageTree.visiblePath(chatID, db: db).last { $0.role != .systemNote }?.id }
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: text, parentID: leaf, attachmentIDs: attachments), assistantID: a)
        _ = try await log.waitFinished(a)
        return a
    }

    func use(_ reply: String, _ att: String) throws -> MessageProvenance.FileUse? {
        try MessageRepository(db).message(reply)?.provenance?.files?.first { $0.attachmentID == att }
    }
}

@Suite struct HelperCaptionerTests {
    @Test func aTextOnlyModelGetsTheHelperCaptionOnce() async throws {
        let rig = try CaptionRig()
        defer { try? FileManager.default.removeItem(at: rig.xfer) }
        let att = try await rig.attach("images/ocr/receipt-00.png")
        let a = try await rig.send("What is the total?", attachments: [att])
        #expect(rig.engine.captionCalls == 1)
        let captionReq = try #require(rig.engine.requests.withLock { $0.first(where: CaptionEngine.isCaption) })
        #expect(captionReq.modelSlot.key == "chat-0.8b+vision" && captionReq.sampling.temperature == 0
                && captionReq.sampling.maxTokens == 256 && captionReq.flattenedMessages.last?.imagePaths.count == 1)
        let row = try #require(try rig.db.read { try AttachmentRecord.fetchOne($0, key: att) })
        #expect(row.captionText == CaptionEngine.caption)
        let user = try #require(rig.engine.chatRequests.last?.flattenedMessages.last { $0.role == .user })
        #expect(user.imagePaths.isEmpty)
        #expect(user.content.contains("<image_description source=\"helper\" untrusted=\"true\">" + CaptionEngine.caption + "\nText found in image: "))
        let use = try rig.use(a, att)
        #expect(use?.vision == "helper")
        // A follow-up reuses the stored caption: no new helper call, the description is still in the history.
        _ = try await rig.send("And the shop?")
        let calls = await rig.controller.helperCaptionCalls
        #expect(rig.engine.captionCalls == 1 && calls == 1)
        let history = try #require(rig.engine.chatRequests.last).flattenedMessages.filter { $0.role == .user }
        #expect(history.first?.content.contains(CaptionEngine.caption) == true)
    }

    @Test func onT0OnlyOCRTextAndNoLabel() async throws {
        let rig = try CaptionRig(allowed: false)
        defer { try? FileManager.default.removeItem(at: rig.xfer) }
        let att = try await rig.attach("images/ocr/receipt-00.png")
        let a = try await rig.send("What is the total?", attachments: [att])
        #expect(rig.engine.captionCalls == 0)
        let user = try #require(rig.engine.chatRequests.last?.flattenedMessages.last { $0.role == .user })
        #expect(user.content.contains("Text found in image:") && !user.content.contains("<image_description"))
        let use = try rig.use(a, att)
        #expect(use?.vision == "ocr")
    }

    @Test func noHelperMeansNeedsLargerModel() async throws {
        let rig = try CaptionRig(helper: false)
        defer { try? FileManager.default.removeItem(at: rig.xfer) }
        let att = try await rig.attach("images/ocr/receipt-00.png")
        let a = try await rig.send("What is the total?", attachments: [att])
        let use = try rig.use(a, att)
        #expect(rig.engine.captionCalls == 0 && use?.vision == "unavailable")
    }
}

@Suite struct CompactionImageTests {
    /// AT-237 check 2: after forced compaction the summary request carries the stored caption, and the helper VLM
    /// ran 0 additional times.
    @Test func compactionReusesTheStoredCaption() async throws {
        let rig = try CaptionRig(window: 4096, replyWords: 300, idleDelay: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: rig.xfer) }
        let att = try await rig.attach("images/ocr/receipt-00.png")
        try await rig.send("What is the total on this receipt?", attachments: [att])
        #expect(rig.engine.captionCalls == 1)
        let deadline = ContinuousClock.now + .seconds(30)
        var i = 0
        while rig.engine.compactionRequests.isEmpty, ContinuousClock.now < deadline, i < 12 {
            try await rig.send("Question number \(i) about the receipt")
            i += 1
            try await Task.sleep(for: .milliseconds(120))
        }
        let summary = try #require(rig.engine.compactionRequests.first)
        let body = summary.flattenedMessages.map(\.content).joined(separator: "\n")
        #expect(body.contains(CaptionEngine.caption), "the summary input reads the stored caption")
        let calls = await rig.controller.helperCaptionCalls
        #expect(rig.engine.captionCalls == 1 && calls == 1, "helper ran 0 more times")
    }
}
