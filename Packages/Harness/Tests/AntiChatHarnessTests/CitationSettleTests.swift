// AT-250 c2 (M7 bars, lead decision 2026-11-09): the citation checks run after the final write with no whole-answer
// bound. The turn finishes at once (composer free, `.finished` with `citationsChecking`), the stored reply carries
// `citations_checking` (pills show `cite.checking`), and the late verdict rewrites the stored text (markers removed,
// words kept) and clears the flag — also after the user has sent another turn (the verifier waits while that turn
// generates), after the reply was deleted (verdict dropped), and at the next launch (unfinished checks: uncited).
//   make test-unit FILTER=CitationSettleTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Opens once; every waiter (before or after) goes on.
actor OneShotGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Records verifier calls and answers each after the gate opens.
final class HeldVerifier: @unchecked Sendable {
    let gate = OneShotGate()
    private let lock = NSLock()
    private var calls: [String] = []
    let reply: String
    init(reply: String) { self.reply = reply }
    var count: Int { lock.withLock { calls.count } }
    var generator: CitationVerifier.Generator {
        { [self] prompt, _ in
            lock.withLock { calls.append(prompt) }
            await gate.wait()
            return reply
        }
    }
}

/// R2 review P2-2: a verifier whose answer takes a minute (cancellable); counts calls and cancellations.
final class SlowVerifier: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0, c = 0
    var calls: Int { lock.withLock { n } }
    var cancelled: Int { lock.withLock { c } }
    var generator: CitationVerifier.Generator {
        { [self] _, _ in
            lock.withLock { n += 1 }
            do { try await Task.sleep(for: .seconds(60)) } catch {
                lock.withLock { c += 1 }
                throw error
            }
            return "1: SUPPORTED"
        }
    }
}

@Suite(.serialized) struct CitationSettleTests {
    static let script = """
        {"t":"toolCallDone","id":"call_1","name":"web_search","args":"{\\"queries\\":[\\"latest macOS\\"]}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"It is macOS 27 [1].","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Second answer.","delayMs":1}
        """

    static func storedText(_ h: ToolLoopHarness, _ id: String) throws -> String {
        try h.parts(id, .text).map(\.body).joined()
    }

    static func settled(_ h: ToolLoopHarness, _ id: String) -> String?? {
        for u in h.log.all where u.assistantID == id { if case .citationsSettled(let t) = u.kind { return .some(t) } }
        return nil
    }

    @Test func theTurnFinishesFirstAndTheLateVerdictSettlesThePills() async throws {
        let h = try ToolLoopHarness(script: Self.script, tier: .t2, tools: [WebSearchTurnTests.stubSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: UNSUPPORTED: 27")
        await h.controller.useVerifier(v.generator)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        // finished while the verifier is still held: the text keeps its marker, the reply is marked checking
        #expect(r.citationsChecking && r.text == "It is macOS 27 [1].")
        let prov = try #require(try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance)
        #expect(prov.citationsChecking == true)
        #expect(Self.settled(h, a) == nil)
        await v.gate.release()
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(Self.settled(h, a) == .some("It is macOS 27."))
        #expect(try Self.storedText(h, a) == "It is macOS 27.", "the unsupported marker is removed, the words kept")
        let after = try #require(try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance)
        #expect(after.citationsChecking == nil && after.sources?.map(\.n) == [1, 2])
        #expect(await h.controller.lastVerification?.uncited == 1)
    }

    @Test func aSupportedVerdictKeepsTheMarkerAndClearsTheFlag() async throws {
        let h = try ToolLoopHarness(script: Self.script, tier: .t2, tools: [WebSearchTurnTests.stubSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: SUPPORTED")
        await h.controller.useVerifier(v.generator)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await v.gate.release()
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(try Self.storedText(h, a) == "It is macOS 27 [1].")
        #expect(try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance?.citationsChecking == nil)
    }

    /// The user moved on: a second turn starts while the first reply's verdict is pending. The verifier does not run
    /// while that turn generates; the late verdict still lands on the first reply only.
    @Test func aVerdictAfterTheNextTurnLandsOnItsOwnReply() async throws {
        let h = try ToolLoopHarness(script: Self.script, tier: .t2, tools: [WebSearchTurnTests.stubSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: UNSUPPORTED: 27")
        await h.controller.useVerifier(v.generator)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await h.controller.setChips([])
        let (_, b) = await h.send("And then?", parent: a)
        let rb = try await h.log.waitFinished(b, timeout: .seconds(30))
        #expect(!rb.citationsChecking, "the second reply has no web sources of its own: \(rb)")
        await v.gate.release()
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(try Self.storedText(h, a) == "It is macOS 27.")
        #expect(try Self.storedText(h, b) == rb.text, "the second reply is not touched")
        #expect(Self.settled(h, b) == nil)
    }

    /// R2 review P2-2: the chat's controller goes away (its window closed) while the verifier still runs. The checks
    /// stop at once (the verifier request in flight is cancelled, no further one is sent) and the reply gets the launch
    /// sweep's result right away: unverified markers removed, words kept, `citations_checking` cleared — no spinning
    /// pills until the next launch.
    @Test func closingTheChatMidCheckStopsTheChecksAndUncitesTheReplyAtOnce() async throws {
        let database = try AppDatabase.inMemory()
        let registry = ToolRegistry([WebSearchTurnTests.stubSearch()])
        let runtime = ToolLoopHarness.runtime(registry: registry, database: database, tier: .t2, selection: .standard)
        var controller: TurnController? = TurnController(
            chatID: StorageID.make(), database: database, engine: try InProcessScriptedEngine(script: try EngineScript(text: Self.script)),
            tools: runtime) { .scripted("inline") }
        let v = SlowVerifier()
        await controller?.useVerifier(v.generator)
        await controller?.setChips(["web"])
        // The window's update stream, without holding the controller (as the UI does not).
        let updates = controller!.updates
        let finished = Mutex<TurnResult?>(nil)
        let reader = Task { for await u in updates { if case .finished(let r) = u.kind { finished.withLock { $0 = r } } } }
        defer { reader.cancel() }
        let a = StorageID.make()
        await controller?.start(.send(userID: StorageID.make(), text: "What's the latest macOS version?", parentID: nil), assistantID: a)
        let deadline = ContinuousClock.now + .seconds(30)
        while (finished.withLock { $0 } == nil || v.calls == 0), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(finished.withLock { $0 }?.citationsChecking == true)
        #expect(v.calls == 1, "the verifier is running")
        #expect(try database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance?.citationsChecking == true)

        weak var gone = controller
        controller = nil  // the window closed: its ConversationModel and TurnController go
        while gone != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gone == nil, "the controller went away")
        let prov = try #require(try database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance)
        #expect(prov.citationsChecking == nil, "no checking pills after the window closed")
        #expect(try MessageRepository(database).parts(of: a).filter { $0.kind == .text }.map(\.body).joined() == "It is macOS 27.",
                "the unverified marker is removed, the words kept")
        while v.cancelled == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(v.cancelled == 1, "the verifier request in flight was cancelled")
        try await Task.sleep(for: .milliseconds(300))
        #expect(v.calls == 1, "no verifier request after the chat went away")
    }

    @Test func aVerdictForADeletedReplyIsDropped() async throws {
        let h = try ToolLoopHarness(script: Self.script, tier: .t2, tools: [WebSearchTurnTests.stubSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: UNSUPPORTED: 27")
        await h.controller.useVerifier(v.generator)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        try h.database.write { db in _ = try MessageRecord.deleteOne(db, key: a) }
        await v.gate.release()
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(Self.settled(h, a) == .some(nil))
    }

    @Test func settleKeepsAContinuedTailAndDropsAChangedText() throws {
        let db = try AppDatabase.inMemory()
        let repo = MessageRepository(db)
        let (chat, msg) = (StorageID.make(), StorageID.make())
        try db.write { d in
            try ChatRecord(id: chat, title: "t", createdAt: Date(), updatedAt: Date()).insert(d)
            var m = MessageRecord(id: msg, chatID: chat, parentID: nil, role: .assistant, status: .done, createdAt: Date())
            var p = MessageProvenance(); p.citationsChecking = true; m.provenance = p
            try m.insert(d)
            try MessageRepository.upsertPart(msg, idx: 0, PartContent(kind: .text, body: "A [1]. B [2]. Tail [3]."), db: d)
        }
        #expect(try repo.settleCitations(msg, checked: "A [1]. B [2].", settled: "A [1]. B.") == "A [1]. B. Tail [3].")
        #expect(try repo.message(msg)?.provenance?.citationsChecking == nil)
        #expect(try repo.settleCitations(msg, checked: "Something else", settled: "x") == nil)
        #expect(try repo.parts(of: msg).first?.body == "A [1]. B. Tail [3].")
    }

    @Test func theLaunchSweepUncitesRepliesWhoseChecksNeverFinished() throws {
        let db = try AppDatabase.inMemory()
        let (chat, msg, other) = (StorageID.make(), StorageID.make(), StorageID.make())
        try db.write { d in
            try ChatRecord(id: chat, title: "t", createdAt: Date(), updatedAt: Date()).insert(d)
            var m = MessageRecord(id: msg, chatID: chat, parentID: nil, role: .assistant, status: .done, createdAt: Date())
            var p = MessageProvenance(); p.citationsChecking = true; m.provenance = p
            try m.insert(d)
            try MessageRepository.upsertPart(msg, idx: 0, PartContent(kind: .text, body: "It is 27 [1]. Code `a[1]` stays."), db: d)
            try MessageRecord(id: other, chatID: chat, parentID: msg, role: .assistant, status: .done, createdAt: Date()).insert(d)
            try MessageRepository.upsertPart(other, idx: 0, PartContent(kind: .text, body: "Settled [1]."), db: d)
        }
        TurnController.launchSweep(db)
        let repo = MessageRepository(db)
        #expect(try repo.parts(of: msg).first?.body == "It is 27. Code `a[1]` stays.")
        #expect(try repo.message(msg)?.provenance?.citationsChecking == nil)
        #expect(try repo.parts(of: other).first?.body == "Settled [1].", "a settled reply is not touched")
    }

    // MARK: bars-3 (AT-248 c1): a source attached to an uncited factual sentence

    static func twoSourceSearch() -> RegisteredTool {
        RegisteredTool(name: "web_search", description: "Search the web.", parametersJSON: WebSearchTools.webSearchParameters,
                       sideEffect: .read, availability: .available, outputIsUntrusted: true) { args in
            let plan = SearchPlan.make(arguments: args, maxQueries: 2)
            let srcs = [WebSource(n: 1, url: "https://one.test/a", title: "One", site: "one.test", date: nil, snippet: "s1", fetched: true),
                        WebSource(n: 2, url: "https://two.test/b", title: "Two", site: "two.test", date: nil, snippet: "s2", fetched: true)]
            let r = WebResults(queries: plan?.queries ?? [], sources: srcs, evidence: [
                EvidenceChunk(source: 1, url: URL(string: srcs[0].url)!, site: "one.test", title: "One",
                              text: "Lyon is a city in France on the Rhône.", ordinal: 0),
                EvidenceChunk(source: 2, url: URL(string: srcs[1].url)!, site: "two.test", title: "Two",
                              text: "The city of Lyon had 519,127 residents in 2022, according to INSEE.", ordinal: 0),
            ], evidenceTokens: 20, failed: nil)
            return WebResultsBlock.render(TurnWebSources.shared.record(r, turn: TurnContext.requestID ?? "-"))
        }
    }
    static let uncitedScript = """
        {"t":"toolCallDone","id":"call_1","name":"web_search","args":"{\\"queries\\":[\\"Lyon population\\"]}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Lyon is a city in France [1]. The city of Lyon had 519,127 residents in 2022.","delayMs":1}
        """

    @Test func anUncitedSentenceGetsTheSourceThatPassesEveryCheck() async throws {
        let h = try ToolLoopHarness(script: Self.uncitedScript, tier: .t2, tools: [Self.twoSourceSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: SUPPORTED\n2: SUPPORTED")
        await v.gate.release()
        await h.controller.useVerifier(v.generator)
        await h.controller.useCiteCheck { pairs in pairs.map { _ in 0.95 } }
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What is the population of Lyon?")
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.text == "Lyon is a city in France [1]. The city of Lyon had 519,127 residents in 2022.", "attached after the checks")
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(await h.controller.lastAttached == 1)
        #expect(try Self.storedText(h, a) == "Lyon is a city in France [1]. The city of Lyon had 519,127 residents in 2022 [2].")
        #expect(v.count == 2, "the verifier ran on the answer's marker, then on the attached one alone")
    }

    @Test func anAttachedSourceIsRemovedWhenTheVerifierGivesNoVerdict() async throws {
        let h = try ToolLoopHarness(script: Self.uncitedScript, tier: .t2, tools: [Self.twoSourceSearch()], selection: .standard)
        let v = HeldVerifier(reply: "no idea")
        await v.gate.release()
        await h.controller.useVerifier(v.generator)
        await h.controller.useCiteCheck { pairs in pairs.map { _ in 0.95 } }
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What is the population of Lyon?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(try Self.storedText(h, a) == "Lyon is a city in France. The city of Lyon had 519,127 residents in 2022.",
                "no verdict (M7 verifier): the model's own marker goes too, and nothing is attached")
    }

    @Test func noSourceIsAttachedWithoutTheEntailmentCheck() async throws {
        let h = try ToolLoopHarness(script: Self.uncitedScript, tier: .t2, tools: [Self.twoSourceSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: SUPPORTED")
        await v.gate.release()
        await h.controller.useVerifier(v.generator)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What is the population of Lyon?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await h.controller.citationsSettled(a)
        #expect(await h.controller.lastAttached == 0)
        #expect(try Self.storedText(h, a) == "Lyon is a city in France [1]. The city of Lyon had 519,127 residents in 2022.")
    }

    @Test func anAttachedSourceTheVerifierRejectsIsNotKept() async throws {
        let h = try ToolLoopHarness(script: Self.uncitedScript, tier: .t2, tools: [Self.twoSourceSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: UNSUPPORTED: 519,127")
        await v.gate.release()
        await h.controller.useVerifier(v.generator)
        await h.controller.useCiteCheck { pairs in pairs.map { _ in 0.95 } }
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What is the population of Lyon?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(await h.controller.lastAttached == 0)
        #expect(try Self.storedText(h, a) == "Lyon is a city in France. The city of Lyon had 519,127 residents in 2022.")
    }

    /// M7 verifier: attach never proposes a (sentence, source) pair the checks removed from the answer: the verifier's
    /// verdict can differ between batches, and a second ask alone must not bring a rejected citation back (dev replay:
    /// h3 h037, h4 k077).
    @Test func attachNeverReturnsAPairTheChecksRemoved() async {
        let ev = [1: "One — one.test\nLyon is a city in France on the Rhône.",
                  2: "Two — two.test\nThe city of Lyon had 519,127 residents in 2022, according to INSEE."]
        let text = "Lyon is a city in France [1]. The city of Lyon had 519,127 residents in 2022."
        let yes: CitationVerifier.Generator = { _, _ in "1: SUPPORTED" }
        let fresh = await TurnController.attachChecked(text, evidence: ev, candidates: [1, 2], scorer: { $0.map { _ in 0.95 } },
                                                       verify: yes, gate: nil)
        #expect(fresh.attached == [CitationGrounding.Attached(claim: "The city of Lyon had 519,127 residents in 2022", source: 2)])
        let rejected: Set = [CitationGrounding.Attached(claim: "The city of Lyon had 519,127 residents in 2022", source: 2)]
        let again = await TurnController.attachChecked(text, evidence: ev, candidates: [1, 2], scorer: { $0.map { _ in 0.95 } },
                                                       verify: yes, gate: nil, rejected: rejected)
        #expect(again.attached.isEmpty && again.text == text)
        #expect(CitationGrounding.pairs("A fact [1, 2]. B [3].") == [.init(claim: "A fact", source: 1), .init(claim: "A fact", source: 2), .init(claim: "B", source: 3)])
    }

    @Test func aMarkerlessAnswerCanGetASourceAfterTheChecks() async throws {
        let script = Self.uncitedScript.replacingOccurrences(of: "Lyon is a city in France [1]. ", with: "")
        let h = try ToolLoopHarness(script: script, tier: .t2, tools: [Self.twoSourceSearch()], selection: .standard)
        let v = HeldVerifier(reply: "1: SUPPORTED")
        await v.gate.release()
        await h.controller.useVerifier(v.generator)
        await h.controller.useCiteCheck { pairs in pairs.map { _ in 0.95 } }
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What is the population of Lyon?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await h.controller.citationsSettled(a)
        try await h.log.wait(.seconds(30)) { _ in Self.settled(h, a) != nil }
        #expect(try Self.storedText(h, a) == "The city of Lyon had 519,127 residents in 2022 [2].")
    }
}
