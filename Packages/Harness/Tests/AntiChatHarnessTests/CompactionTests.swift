// M1.T18 AT-233 leg (1) + AT-009 leg (2) harness half: non-destructive compaction.
//   make test-unit FILTER=CompactionTests
// The boundary rules ported from Osaurus (`compactionCutIndex`, `summaryIsValid`), then TurnController against a
// test engine that answers chat requests with long replies and compaction requests (the `compaction` layer) with
// a short summary: idle compaction at ≥ 75 % writes a summary node and leaves every original row unchanged (hash of
// bodies before/after), the originals stay on the visible path and in FTS, the next prompt carries the summary in
// place of the covered turns; a send above 85 % compacts synchronously first (counted, `compacting` events); a
// truncated summary (`done(length)`) writes nothing; regenerate after a compaction still uses the summary; the
// system turn stays byte-identical across a compaction and the summarised history is a stable prefix (D-022).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB
import OsaurusVendored
import Synchronization
import Testing
@testable import AntiChatHarness

/// Answers chat requests with `replyWords` distinct words (`w<turn>x<i>`) and compaction requests with a summary.
final class CompactionTestEngine: EngineService {
    let requests = Mutex<[ChatRequest]>([])
    let replyWords: Int
    let summaryFinish: FinishReason
    let summaryDelay: Duration

    init(replyWords: Int = 300, summaryFinish: FinishReason = .stop, summaryDelay: Duration = .zero) {
        self.replyWords = replyWords
        self.summaryFinish = summaryFinish
        self.summaryDelay = summaryDelay
    }

    static func isCompaction(_ r: ChatRequest) -> Bool {
        if case .layer(let l) = r.messages.first, l.id == "compaction" { return true }
        return false
    }

    var chatRequests: [ChatRequest] { requests.withLock { $0.filter { !Self.isCompaction($0) } } }
    var compactionRequests: [ChatRequest] { requests.withLock { $0.filter(Self.isCompaction) } }

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}

    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        let compaction = Self.isCompaction(request)
        let turn = request.messages.reduce(0) { n, i in if case .message(let m) = i, m.role == .assistant { n + 1 } else { n } }
        let words = replyWords, finish = summaryFinish, delay = summaryDelay
        let n = requests.withLock { $0.filter(Self.isCompaction).count }
        return AsyncThrowingStream { c in
            Task {
                if compaction {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    c.yield(.textDelta("SUMMARY\(n): the user and the assistant talked about numbered words."))
                    c.yield(.done(finish))
                } else {
                    c.yield(.textDelta((0..<words).map { "w\(turn)x\($0)" }.joined(separator: " ")))
                    c.yield(.done(.stop))
                }
                c.finish()
            }
        }
    }
}

struct CompactionHarness {
    let database: AppDatabase
    let chatID = StorageID.make()
    let controller: TurnController
    let engine: CompactionTestEngine
    let log: UpdateLog

    init(window: Int = 4096, idleDelay: Duration = .milliseconds(50), engine: CompactionTestEngine = CompactionTestEngine()) throws {
        database = try AppDatabase.inMemory()
        self.engine = engine
        let policy = ContextPolicy(idleDelay: idleDelay, reservedOutput: 512, windowOverride: window)
        controller = TurnController(chatID: chatID, database: database, engine: engine, contextPolicy: policy) {
            .scripted("inline")
        }
        log = UpdateLog(controller)
    }

    /// One turn: send under the visible leaf, wait for the reply. Returns (userID, assistantID).
    @discardableResult
    func turn(_ text: String) async throws -> (String, String) {
        let leaf = try database.read { db in
            try MessageTree.visiblePath(chatID, db: db).last { $0.role != .systemNote }?.id
        }
        let u = StorageID.make(), a = StorageID.make()
        await controller.start(.send(userID: u, text: text, parentID: leaf), assistantID: a)
        _ = try await log.waitFinished(a)
        return (u, a)
    }

    /// sha256 over every user/assistant row (id, role, status) and its parts, in id order.
    func originalsHash() throws -> String {
        try database.read { db in
            var h = SHA256()
            let rows = try MessageRecord.filter(Column("role") != MessageRole.systemNote.rawValue).order(Column("id")).fetchAll(db)
            for r in rows {
                h.update(data: Data("\(r.id)|\(r.role.rawValue)|\(r.parentID ?? "-")|".utf8))
                for p in try MessageRepository.parts(of: r.id, db: db) { h.update(data: Data("\(p.kind.rawValue):\(p.body)|".utf8)) }
            }
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    func summaries() throws -> [SummaryNode] {
        try database.read { try ChatMessageAdapter.summaryNodes(chatID: chatID, db: $0) }
    }

    func waitForSummary(count: Int = 1, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while try summaries().count < count {
            if ContinuousClock.now > deadline { throw UpdateLog.TimeoutError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The row lands inside the run; the scheduler clears its in-flight run a moment later. A turn sent in that gap
        // waits on it (`waitedTurns` 1, seen under `make test-unit --parallel` load), so settle before returning.
        while await controller.compaction.idleRunInFlight {
            if ContinuousClock.now > deadline { throw UpdateLog.TimeoutError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func usageFraction() async -> Double { await controller.contextUsage().fraction }
}

private func turn(_ id: String, _ role: ChatMessage.Role, _ words: Int = 10) -> ContextTurn {
    ContextTurn(id: id, role: role, content: String(repeating: "word ", count: words))
}

@Suite("CompactionTests") struct CompactionTests {
    // MARK: Boundary (ported upstream rules)

    @Test func cutKeepsTheCurrentAndOnePriorExchange() {
        let ids = (0..<8).map { _ in StorageID.make() }
        let turns = ids.enumerated().map { turn($1, $0 % 2 == 0 ? .user : .assistant) }
        // u0 a1 u2 a3 u4 a5 u6 a7 → cut at the second-from-last user turn (index 4): 4 turns covered.
        #expect(ContextCompactionService.compactionCutIndex(turns: turns, existingSummary: nil) == 4)
        // An existing summary covering 4 turns: nothing new to cover (the cut must grow).
        let s = ConversationSummary(summaryText: "s", coveredTurnIds: ids.prefix(4).compactMap(UUID.init(uuidString:)),
                                    modelIdentifier: "m", savedTokensEstimate: 0)
        #expect(ContextCompactionService.compactionCutIndex(turns: turns, existingSummary: s) == nil)
    }

    @Test func sizeGateAndWholeTranscriptLastResort() {
        let ids = (0..<4).map { _ in StorageID.make() }
        // u a u a with tiny content: preferred cut 2 < 4 turns and < gate tokens → nil.
        let small = ids.enumerated().map { turn($1, $0 % 2 == 0 ? .user : .assistant, 5) }
        #expect(ContextCompactionService.compactionCutIndex(turns: small, existingSummary: nil, minimumCoveredTokens: 800) == nil)
        // A heavy first exchange passes the token gate.
        var heavy = small
        heavy[1].content = String(repeating: "word ", count: 1000)  // ≈ 1250 tokens
        #expect(ContextCompactionService.compactionCutIndex(turns: heavy, existingSummary: nil, minimumCoveredTokens: 800) == 2)
        // One huge exchange: the whole transcript (ending in a reply) is coverable.
        let one = [turn(ids[0], .user, 2000), turn(ids[1], .assistant, 10)]
        #expect(ContextCompactionService.compactionCutIndex(turns: one, existingSummary: nil, minimumCoveredTokens: 800) == 2)
    }

    @Test func summaryValidityIsAnExactPrefix() {
        #expect(ChatMessageAdapter.isValid(["a", "b"], for: ["a", "b", "c"]))
        #expect(ChatMessageAdapter.isValid(["a", "b", "c"], for: ["a", "b", "c"]))
        #expect(!ChatMessageAdapter.isValid(["a", "x"], for: ["a", "b", "c"]))
        #expect(!ChatMessageAdapter.isValid(["b"], for: ["a", "b"]))
        #expect(!ChatMessageAdapter.isValid([], for: ["a"]))
        #expect(!ChatMessageAdapter.isValid(["a", "b"], for: ["a"]))
    }

    @Test func summaryLeadsTheFirstKeptUserTurn() {
        let ids = (0..<4).map { _ in StorageID.make() }
        let turns = [ContextTurn(id: ids[0], role: .user, content: "old q"), ContextTurn(id: ids[1], role: .assistant, content: "old a"),
                     ContextTurn(id: ids[2], role: .user, content: "new q"), ContextTurn(id: ids[3], role: .assistant, content: "new a")]
        let s = ConversationSummary(summaryText: "S", coveredTurnIds: ids.prefix(2).compactMap(UUID.init(uuidString:)),
                                    modelIdentifier: "m", savedTokensEstimate: 0)
        let out = ChatMessageAdapter.messages(turns, summary: s)
        #expect(out.count == 2)
        #expect(out[0].role == .user && out[0].content == s.contextMessageText + "\n\nnew q")
        #expect(out[1].content == "new a")
    }

    @Test func windowScaledGatesAndCap() {
        #expect(ContextCompactionService.minimumCoveredTokens(window: 4096) == 819)
        #expect(ContextCompactionService.minimumCoveredTokens(window: 65_536) == 4000)
        #expect(ContextCompactionService.summaryTokenCap(window: 4096) == 512)
        #expect(ContextCompactionService.summaryTokenCap(window: 16_384) == 1024)
        #expect(ContextPolicy(windowOverride: 4096).window(for: .scripted("x")) == 4096)
        #expect(ContextPolicy().window(for: ModelSlot(engine: .mlx, key: "chat-9b-q4", path: "/")) == 16_384)
        #expect(ContextPolicy().window(for: ModelSlot(engine: .llama, key: "evil-9b", path: "/", contextTokens: 8192)) == 8192)
    }

    // MARK: Turn flow

    /// AT-233 (1): idle compaction keeps every original row unchanged, visible and searchable.
    @Test func idleCompactionIsNonDestructive() async throws {
        let h = try CompactionHarness()
        var users: [String] = []
        // 300-word replies ≈ 525 tokens each; the 4K window passes 75 % after the 6th reply.
        for i in 0..<10 {
            let before = await h.usageFraction()
            let (u, _) = try await h.turn("Question number \(i) about kestrel\(i)")
            users.append(u)
            if try h.summaries().isEmpty { #expect(await h.usageFraction() > before) }  // rises as messages are added
            if await h.usageFraction() >= 0.75 { break }
        }
        let hashBefore = try h.originalsHash()
        try await h.waitForSummary()
        #expect(try h.originalsHash() == hashBefore)  // originals unchanged (bodies, roles, tree edges)
        let node = try #require(try h.summaries().first)
        #expect(node.record.role == .systemNote)
        #expect(node.coveredIDs.first == users.first)
        // The covered rows are still on the visible path, in order, and FTS finds them.
        let path = try h.database.read { try MessageTree.visiblePath(h.chatID, db: $0) }
        #expect(node.coveredIDs.allSatisfy { id in path.contains { $0.id == id } })
        let hits = try FTSSearch(h.database).search("kestrel0")
        #expect(hits.first?.messageID == users.first)
        // The idle run is logged (≥ 75 % at start) and the usage drops.
        let runs = await h.controller.compaction.runs
        #expect(runs.first?.trigger == .idle && runs.first?.ok == true && (runs.first?.fractionBefore ?? 0) >= 0.75)
        #expect((runs.first?.fractionAfter ?? 1) < (runs.first?.fractionBefore ?? 0))

        // The next request carries the summary in place of the covered turns; the reply records it.
        let (u, a) = try await h.turn("And one more about osprey")
        let req = try #require(h.engine.chatRequests.last)
        let convo = req.flattenedHistory.dropFirst()  // after the system turn
        #expect(convo.first?.content.hasPrefix("[Conversation summary") == true)
        #expect(!convo.contains { $0.content.contains("kestrel0") })
        #expect(convo.last?.content.contains("osprey") == true)
        #expect(try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance?.summaryID == node.id)
        // The new user message hangs below the summary node (on the active path).
        #expect(try h.database.read { try MessageRecord.fetchOne($0, key: u) }?.parentID == node.id)
        #expect(await h.controller.compaction.waitedTurns == 0)
    }

    /// R-009 AC2 / step 4: a send above 85 % with no covering summary compacts synchronously first.
    @Test func syncFallbackAbove85Percent() async throws {
        let h = try CompactionHarness(idleDelay: .seconds(3600))  // never idle
        var sent = 0
        while try h.summaries().isEmpty, sent < 12 {
            try await h.turn("Question \(sent)")
            sent += 1
        }
        let node = try #require(try h.summaries().first)
        let runs = await h.controller.compaction.runs
        #expect(runs.filter(\.ok).first?.trigger == .sync)
        #expect((runs.first?.fractionBefore ?? 0) > 0.85)
        #expect(await h.controller.compaction.waitedTurns == 1)
        // `compacting` true → false around it, before the reply that used the summary.
        let events = h.log.all.compactMap { u -> Bool? in if case .context(.compacting(let b)) = u.kind { b } else { nil } }
        #expect(events == [true, false])
        let last = try #require(h.engine.chatRequests.last)
        #expect(last.flattenedHistory.dropFirst().first?.content.hasPrefix("[Conversation summary") == true)
        let reply = try h.database.read { db in try MessageTree.visiblePath(h.chatID, db: db).last { $0.role == .assistant } }
        #expect(reply?.provenance?.summaryID == node.id)
    }

    /// Step 6: a summary that hit the output limit is never applied; the originals stay in the prompt.
    @Test func truncatedSummaryWritesNothing() async throws {
        let h = try CompactionHarness(idleDelay: .seconds(3600), engine: CompactionTestEngine(summaryFinish: .length))
        for i in 0..<10 { try await h.turn("Question \(i)") }
        #expect(try h.summaries().isEmpty)
        let runs = await h.controller.compaction.runs
        #expect(!runs.isEmpty && runs.allSatisfy { !$0.ok })
        #expect(runs.contains { $0.error?.contains("truncatedSummary") == true })
        let last = try #require(h.engine.chatRequests.last)
        #expect(last.flattenedHistory.contains { $0.content.contains("Question 0") })
    }

    /// Regenerating the reply after an idle compaction: the summary hangs off the old version, but it covers a
    /// prefix of the new path, so the retry still uses it.
    @Test func regenerateAfterCompactionUsesTheSummary() async throws {
        let h = try CompactionHarness()
        var last = ""
        for i in 0..<10 {
            (_, last) = try await h.turn("Question \(i)")
            if await h.usageFraction() >= 0.75 { break }
        }
        try await h.waitForSummary()
        let node = try #require(try h.summaries().first)
        let a2 = StorageID.make()
        await h.controller.start(.retry(assistantID: last), assistantID: a2)
        _ = try await h.log.waitFinished(a2)
        #expect(h.engine.chatRequests.last?.flattenedHistory.dropFirst().first?.content.hasPrefix("[Conversation summary") == true)
        #expect(try h.database.read { try MessageRecord.fetchOne($0, key: a2) }?.provenance?.summaryID == node.id)
    }

    /// D-022: a compaction never touches the system turn, and between compactions each turn's history (without
    /// the time line) is a prefix of the next prompt, so the prefix cache keeps working.
    @Test func compactionKeepsTheCacheLayout() async throws {
        let h = try CompactionHarness(window: 16_384, engine: CompactionTestEngine(replyWords: 600))
        func summaryText(_ r: ChatRequest) -> String? {
            r.flattenedHistory.dropFirst().first.flatMap { $0.content.hasPrefix("[Conversation summary") ? $0.content : nil }
        }
        var prompts: [ChatRequest] = []
        for i in 0..<20 {
            try await h.turn("Question \(i)")
            prompts.append(try #require(h.engine.chatRequests.last))
            if prompts.suffix(3).count == 3, prompts.suffix(3).allSatisfy({ summaryText($0) != nil }) { break }
            try await Task.sleep(for: .milliseconds(150))  // let the idle compaction run
        }
        #expect(try !h.summaries().isEmpty)
        // The system turn is byte-identical in every prompt, before and after the compaction.
        #expect(Set(prompts.map { $0.flattenedHistory.first?.content ?? "" }).count == 1)
        // Consecutive prompts under the same summary (or none): the earlier prompt's history (no time line) is an
        // exact prefix of the next prompt.
        var checked = 0
        for (p, q) in zip(prompts, prompts.dropFirst()) where summaryText(p) == summaryText(q) {
            let ph = p.flattenedHistory, qh = q.flattenedMessages
            #expect(ph.count < qh.count)
            #expect(Array(qh.prefix(ph.count)) == ph)
            checked += 1
        }
        #expect(checked >= 4)
        #expect(prompts.contains { summaryText($0) != nil })
    }
}
