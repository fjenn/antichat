// AT-270 checks 1–2 (prompt side; M6.T02 steps 2–4): a document that fits goes inline as
// `<document … untrusted="true">` before the user's text (excerpt_policy whole, provenance files mode whole); one that
// does not is chunked with page refs, its top-k excerpts go in as `<excerpt … page untrusted="true">`, `retrieval` rows
// are written and the reply's `provenance_json.files` lists the pages; a follow-up re-sends the same blocks (stable
// position, M6.T03). `[Read whole file]` forces inline when the context allows.
//   make test-unit FILTER=DocumentContextAssemblerTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatHarness

private final class CapturingEngine: EngineService {
    let inner: InProcessScriptedEngine
    let requests = Mutex<[ChatRequest]>([])
    init(script: String) throws { inner = InProcessScriptedEngine(script: try EngineScript(text: script)) }
    func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        await inner.warmup(slot, onLifecycle: onLifecycle)
    }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        return inner.chat(request, onLifecycle: onLifecycle)
    }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
    var lastUser: String? {
        guard case .message(let m)? = requests.withLock({ $0.last })?.messages.last(where: {
            if case .message(let m) = $0 { return m.role == .user } else { return false }
        }) else { return nil }
        return m.content
    }
}

@Suite struct DocumentContextAssemblerTests {
    static var fixtures: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }

    private func rig(window: Int) async throws -> (ChatEnvironment, CapturingEngine, String) {
        let db = try AppDatabase.inMemory()
        let engine = try CapturingEngine(script: #"{"t":"prefill","ms":20,"steps":4}"# + "\n" + #"{"t":"textDelta","v":"ok (p. 3)","delayMs":1}"#)
        let env = ChatEnvironment(database: db, engine: engine, contextPolicy: ContextPolicy(windowOverride: window),
                                  slot: { .scripted("inline") })
        let root = VisionInputTests.mediaRoot()
        let intake = AttachmentIntake(database: db, mediaRoot: root, incognito: true)
        let item = await intake.ingest(AttachmentIntake.admit([Self.fixtures.appendingPathComponent("docs/pdf/text-10p.pdf")]).items[0])
        return (env, engine, try #require(item.attachmentID))
    }

    @Test func aDocumentThatFitsGoesInlineBeforeTheText() async throws {
        let (env, engine, att) = try await rig(window: 131_072)
        let c = env.controller(chatID: StorageID.make())
        let log = UpdateLog(c)
        let u = StorageID.make(), a = StorageID.make()
        await c.start(.send(userID: u, text: "Summarise it", parentID: nil, attachmentIDs: [att]), assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        let content = try #require(engine.lastUser)
        #expect(content.contains("<document name=\"text-10p.pdf\" pages=\"10\" untrusted=\"true\">"))
        #expect(content.hasSuffix("</document>\n\n" + DocumentContextAssembler.citeInstruction + "\n\nSummarise it"), "document before the user text")
        let row = try #require(try env.database.read { try AttachmentRecord.fetchOne($0, key: att) })
        #expect(row.excerptPolicy == .whole && row.messageID == u && (row.tokenCount ?? 0) > 0)
        let p = try #require(try MessageRepository(env.database).message(a)?.provenance)
        #expect(p.files == [.init(attachmentID: att, mode: "whole", pages: [], name: "text-10p.pdf", pageCount: 10, pdf: true)])
        // NFR-C5 (step 6): the whole document's prefill reports `status.reading` with the real percent, rising.
        let reading = log.all.filter { $0.assistantID == a }.compactMap { u -> Int? in
            if case .reading(let f, let pc) = u.kind, f == "text-10p.pdf" { pc } else { nil }
        }
        #expect(!reading.isEmpty && reading == reading.sorted())
    }

    @Test func aDocumentThatDoesNotFitUsesExcerptsWithPages() async throws {
        let (env, engine, att) = try await rig(window: 4096)
        let c = env.controller(chatID: StorageID.make())
        let log = UpdateLog(c)
        let u = StorageID.make(), a = StorageID.make()
        await c.start(.send(userID: u, text: "What does it say about the harbour lantern?", parentID: nil, attachmentIDs: [att]),
                      assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        let content = try #require(engine.lastUser)
        #expect(!content.contains("<document "))
        #expect(content.contains("<excerpt source=\"text-10p.pdf\" page=\""))
        #expect(content.contains("untrusted=\"true\">"))
        #expect(content.hasSuffix("What does it say about the harbour lantern?"))
        let k = TierBudgets.shared.topK(tier: "T1")
        let retrieved = try env.database.read { try Row.fetchAll($0, sql: "SELECT page_ref FROM retrieval WHERE message_id = ?", arguments: [u]) }
        #expect(retrieved.count == k)
        let row = try #require(try env.database.read { try AttachmentRecord.fetchOne($0, key: att) })
        #expect(row.excerptPolicy == .excerpt)
        let p = try #require(try MessageRepository(env.database).message(a)?.provenance?.files?.first)
        #expect(p.mode == "excerpt" && !p.pages.isEmpty && p.keywordOnly == true)
        #expect(p.pages.allSatisfy { Int($0).map { (1...10).contains($0) } ?? false })
        #expect(p.pages == DocumentContextAssembler.sortedPages(p.pages))
        // A follow-up re-sends the same excerpts at the same place.
        let u2 = StorageID.make(), a2 = StorageID.make()
        await c.start(.send(userID: u2, text: "And then?", parentID: a), assistantID: a2)
        #expect(try await log.waitFinished(a2).status == .done)
        let req = try #require(engine.requests.withLock { $0.last })
        let users = req.messages.compactMap { m -> String? in if case .message(let x) = m, x.role == .user { return x.content } else { return nil } }
        #expect(users.first == content)
    }

    @Test func readWholeFileForcesInlineWhenTheContextAllows() async throws {
        // 131072 context but a slow model: fits the context, not the time → excerpts unless forced.
        let (env, engine, att) = try await rig(window: 131_072)
        let c = env.controller(chatID: StorageID.make())
        let log = UpdateLog(c)
        let tokens = try #require(await env.engine.countTokens(["x"], slot: .scripted("inline")).first)
        #expect(tokens == 1)
        let plan = await DocumentContextAssembler(database: env.database, embedder: nil).plan(
            attachmentIDs: [att], userText: "q", model: .init(contextTokens: 131_072, prefillTPS: 10),
            chat: .init(fixedTokens: 500, historyTokens: 0), countTokens: { $0.map(CountTokensRequest.estimate) })
        #expect(plan.files.first?.decision.offersReadWhole == true)
        #expect(plan.files.first?.decision.mode == .excerpts)
        await c.setReadWhole()
        let u = StorageID.make(), a = StorageID.make()
        await c.start(.send(userID: u, text: "All of it", parentID: nil, attachmentIDs: [att]), assistantID: a)
        _ = try await log.waitFinished(a)
        #expect(engine.lastUser?.contains("<document ") == true)
    }

    /// AT-270 check 3 (menu leg, M6.T02 step 7): `files.summariseWhole` on an excerpt-mode reply makes a new version
    /// of it that is the map-reduce summary: every section goes in untrusted, `.summarising` progress only rises to
    /// 100 %, and the reply text is the reduce output.
    @Test func summariseWholeRunsMapReduceAsANewVersion() async throws {
        let (env, engine, att) = try await rig(window: 4096)
        let c = env.controller(chatID: StorageID.make())
        let log = UpdateLog(c)
        let u = StorageID.make(), a = StorageID.make()
        await c.start(.send(userID: u, text: "What is on page 3?", parentID: nil, attachmentIDs: [att]), assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        let before = engine.requests.withLock { $0.count }
        await c.setSummariseWhole(att)
        let a2 = StorageID.make()
        await c.start(.retry(assistantID: a), assistantID: a2)
        let r = try await log.waitFinished(a2)
        #expect(r.status == .done && r.version == 2 && r.text == "ok (p. 3)")
        let progress = log.all.filter { $0.assistantID == a2 }.compactMap { u -> MapReduceSummariser.Progress? in
            if case .summarising(let p) = u.kind { p } else { nil }
        }
        #expect(progress.first?.n == 0 && progress.last?.percent == 100)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.n <= $1.n && $0.percent <= $1.percent })
        let calls = engine.requests.withLock { Array($0.dropFirst(before)) }
        #expect(calls.count >= 3, "several sections + a reduce at a 4k window")
        #expect(calls.count == progress.last?.total)
        let firstBody = calls.first?.messages.compactMap { m -> String? in if case .message(let x) = m { x.content } else { nil } }.last
        #expect(firstBody?.hasPrefix("<document name=\"text-10p.pdf\" untrusted=\"true\">\n[p. 1]") == true)
        #expect(await c.summariseNextTurn == nil, "one-shot")
        let row = try #require(try MessageRepository(env.database).message(a2))
        #expect(row.status == .done)
    }

    /// AT-271 check 2 (R-271 AC2; M6.T04 steps 4–5), in-process: a 60-page scan's tile counts "page n of 60" up from 0,
    /// a turn sent at page 3 is accepted while OCR runs, uses the pages read so far and records `files.stillReading`
    /// (page 3); the image of an attachment goes in as untrusted "Text found in image".
    @Test func aScanCanBeSentBeforeOCRFinishes() async throws {
        let db = try AppDatabase.inMemory()
        let engine = try CapturingEngine(script: #"{"t":"textDelta","v":"ok","delayMs":1}"#)
        let env = ChatEnvironment(database: db, engine: engine, contextPolicy: ContextPolicy(windowOverride: 131_072),
                                  slot: { .scripted("inline") })
        let pause = OCRPause()
        let intake = AttachmentIntake(database: db, mediaRoot: VisionInputTests.mediaRoot(), incognito: true,
                                      ocrQueue: OCRQueue(pause: pause))
        let admitted = AttachmentIntake.admit([Self.fixtures.appendingPathComponent("docs/pdf/scan-60p-contract.pdf")]).items[0]
        let seen = Mutex<[(Int, Int)]>([])
        let rowID = Mutex<String?>(nil)
        let ingest = Task {
            await intake.ingest(admitted) { item in
                guard case .scanning(let page, let pages) = item.state else { return }
                seen.withLock { $0.append((page, pages)) }
                rowID.withLock { $0 = item.attachmentID }
                if page >= 3 { pause.set(true) }
            }
        }
        defer { ingest.cancel() }
        // Progress, not a wall budget: wait for page 3 however slowly a loaded host runs Vision OCR (a 120 s total cap
        // ran out at load 170 with OCR still advancing); fail only when no page has advanced for 120 s (a stall).
        var lastPage = -1
        var lastAdvance = ContinuousClock.now
        while true {
            let page = seen.withLock { $0.last?.0 ?? -1 }
            if page >= 3 { break }
            if page != lastPage { lastPage = page; lastAdvance = ContinuousClock.now }
            if ContinuousClock.now - lastAdvance > .seconds(120) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let progress = seen.withLock { $0 }
        #expect(progress.first?.0 == 0 && progress.allSatisfy { $0.1 == 60 })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.0 <= $1.0 }, "monotonic")
        let att = try #require(rowID.withLock { $0 })
        #expect(try db.read { try AttachmentRecord.fetchOne($0, key: att) }?.ocrState == .pending)
        let c = env.controller(chatID: StorageID.make())
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "What does clause 2 say?", parentID: nil, attachmentIDs: [att]),
                      assistantID: a)
        #expect(try await log.waitFinished(a).status == .done)
        let use = try #require(try MessageRepository(db).message(a)?.provenance?.files?.first)
        let page = try #require(use.stillReadingPage)
        #expect(page >= 3 && page < 60, "\(page)")
        let content = try #require(engine.lastUser)
        #expect(content.contains("Clause 2") && !content.contains("Clause 59"))
    }

    @Test func imageOCRTextGoesInAsUntrustedContext() throws {
        let block = DocumentContextAssembler.imageTextBlock(name: "r\"x.png", text: "TOTAL 12.50")
        #expect(block == "<image_text name=\"r&quot;x.png\" untrusted=\"true\">\nText found in image: TOTAL 12.50\n</image_text>")
    }

    @Test func chunksKeepPagesAndNeverSplitATableRow() {
        let table = (0..<200).map { "| row \($0) | value \($0) | more text here |" }.joined(separator: "\n")
        let pieces = DocumentIndexer.pieces(table)
        #expect(pieces.count > 1)
        for p in pieces { for line in p.split(separator: "\n") { #expect(line.hasPrefix("| row ") && line.hasSuffix(" |")) } }
        #expect(pieces.allSatisfy { $0.count <= DocumentIndexer.chunkChars })
        #expect(DocumentIndexer.pageRef(.init(kind: .page, index: 7, start: 0, end: 1)) == "7")
        #expect(DocumentIndexer.pageRef(.init(kind: .slide, index: 2, start: 0, end: 1)) == "Slide 2")
        #expect(DocumentIndexer.pageRef(.init(kind: .sheet, index: 1, label: "Budget", start: 0, end: 1)) == "Budget")
    }
}
