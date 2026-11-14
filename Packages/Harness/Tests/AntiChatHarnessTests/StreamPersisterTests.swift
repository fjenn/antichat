// AT-NFR-S2 (unit leg, M1.T06): streamed text is persisted every ≤ 1 s or 50 tokens. Virtual clock: each test
// replays a stream with explicit timestamps and calls `tick` at every deadline the persister asks for (what the
// TurnController's flush timer does), then checks the bounds over the whole stream.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("StreamPersisterTests") struct StreamPersisterTests {
    typealias Instant = ContinuousClock.Instant

    final class Recorder {
        var writes: [(at: Instant, parts: [(idx: Int, part: PartContent)])] = []
        var failNext = 0
        var now: Instant
        init(_ now: Instant) { self.now = now }
    }

    struct Delta {
        var at: Duration
        var text: String
        var tokens: Int?
    }

    /// Replays `deltas` (sorted by time); between deltas, fires every due deadline. Returns the persister and
    /// the max age any delta stayed unwritten (arrival → the write that contained it).
    static func replay(_ deltas: [Delta], policy: StreamFlushPolicy = .standard)
        -> (StreamPersister, Recorder, maxAge: Duration, maxTokensPerFlush: Int)
    {
        let t0 = ContinuousClock.now
        let rec = Recorder(t0)
        var p = StreamPersister(policy: policy) { parts in
            if rec.failNext > 0 {
                rec.failNext -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            rec.writes.append((rec.now, parts))
        }
        var pending: [Instant] = []  // arrival times of unwritten deltas
        var maxAge: Duration = .zero
        func noteFlush(_ at: Instant) {
            for a in pending { maxAge = max(maxAge, at - a) }
            pending.removeAll()
        }
        for d in deltas {
            let at = t0 + d.at
            while let deadline = p.deadline, deadline <= at {
                rec.now = deadline
                if p.tick(at: deadline) { noteFlush(deadline) }
            }
            rec.now = at
            pending.append(at)
            if p.appendText(d.text, tokens: d.tokens, at: at) { noteFlush(at) }
        }
        while let deadline = p.deadline {
            rec.now = deadline
            if p.tick(at: deadline) { noteFlush(deadline) } else { break }
        }
        let maxTokens = p.flushes.map(\.tokens).max() ?? 0
        return (p, rec, maxAge, maxTokens)
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `fixtures/scripts/stream-600w.jsonl` (fixtures repo) or the staging copy in `tools/fixtures/scripts`.
    static func fixtureScript(_ name: String) throws -> EngineScript {
        let fixtures = repoRoot.appendingPathComponent("fixtures/scripts/\(name)")
        let staged = repoRoot.appendingPathComponent("tools/fixtures/scripts/\(name)")
        let url = FileManager.default.fileExists(atPath: fixtures.path) ? fixtures : staged
        return try EngineScript(contentsOf: url)
    }

    /// The whole `stream-600w.jsonl` stream (600 words, 25 ms apart): every write ≤ 1 s apart, ≤ 50 tokens.
    @Test func stream600wMeetsNFRS2() throws {
        let script = try Self.fixtureScript("stream-600w.jsonl")
        var t: Duration = .zero
        var deltas: [Delta] = []
        for step in script.segments[0] {
            guard case .text(let s, let k) = step.kind else { continue }
            for _ in 0..<step.repeatCount {
                t += .milliseconds(step.delayMs)
                deltas.append(Delta(at: t, text: s, tokens: k))
            }
        }
        #expect(deltas.count == 600)
        let (p, rec, maxAge, maxTokens) = Self.replay(deltas)
        let gaps = zip(rec.writes, rec.writes.dropFirst()).map { $1.at - $0.at }
        #expect((gaps.max() ?? .zero) <= .milliseconds(1000), "max gap \(gaps.max() ?? .zero)")
        #expect((gaps.max() ?? .zero) <= .milliseconds(500))
        #expect(maxAge <= .milliseconds(500), "a delta waited \(maxAge)")
        #expect(maxTokens <= 50)
        #expect(p.text == deltas.map(\.text).joined())
        // The last write holds the whole text.
        #expect(rec.writes.last?.parts.first?.part.body == p.text)
        #expect(!p.isDirty)
    }

    /// 200 tok/s, one token per delta: the 50-token bound triggers before the 500 ms one.
    @Test func fastStreamFlushesEvery50Tokens() {
        let deltas = (1...1000).map { Delta(at: .milliseconds(5 * $0), text: " t", tokens: 1) }
        let (p, _, maxAge, maxTokens) = Self.replay(deltas)
        #expect(maxTokens == 50)
        #expect(maxAge <= .milliseconds(250))
        #expect(p.flushes.count == 20)
    }

    /// Estimated tokens (no count from the engine) also respect the bound.
    @Test func estimatedTokensRespectTheBound() {
        let deltas = (1...500).map { Delta(at: .milliseconds(4 * $0), text: " harbour", tokens: nil) }
        let (_, _, _, maxTokens) = Self.replay(deltas)
        #expect(maxTokens <= 50 + TokenEstimate.count(" harbour"))
        #expect(TokenEstimate.count(" harbour") == 3)
        #expect(TokenEstimate.count("") == 1)
    }

    /// One delta every 900 ms: each is written by its 500 ms deadline, never waiting for the next delta.
    @Test func slowStreamFlushesByDeadline() {
        let deltas = (1...10).map { Delta(at: .milliseconds(900 * $0), text: " slow", tokens: 1) }
        let (p, rec, maxAge, _) = Self.replay(deltas)
        #expect(maxAge == .milliseconds(500))
        #expect(rec.writes.count == 10)
        #expect(p.flushes.allSatisfy { $0.tokens == 1 })
    }

    @Test func failedWriteStaysDirtyAndRetries() {
        let t0 = ContinuousClock.now
        let rec = Recorder(t0)
        rec.failNext = 1
        var p = StreamPersister { parts in
            if rec.failNext > 0 {
                rec.failNext -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            rec.writes.append((rec.now, parts))
        }
        p.appendText("a", tokens: 1, at: t0)
        let first = p.tick(at: t0 + .milliseconds(500))
        #expect(!first)
        #expect(p.lastError != nil && p.isDirty)
        let second = p.tick(at: t0 + .milliseconds(510))
        #expect(second)
        #expect(rec.writes.count == 1 && !p.isDirty)
    }

    @Test func partsKeepArrivalOrderAndOnlyChangedPartsAreWritten() {
        let t0 = ContinuousClock.now
        let rec = Recorder(t0)
        var p = StreamPersister { parts in rec.writes.append((rec.now, parts)) }
        p.appendReasoning("think", tokens: 1, at: t0)
        p.flush(at: t0)
        p.appendText("answer", tokens: 1, at: t0)
        p.appendToolCall(id: "c1", name: "echo", argsJSON: #"{"text":"hi"}"#, at: t0)
        p.flush(at: t0)
        #expect(p.parts.map(\.kind) == [.reasoning, .text, .toolCall])
        #expect(rec.writes.map { $0.parts.map(\.idx) } == [[0], [1, 2]])
        #expect(p.reasoning == "think" && p.text == "answer" && p.hasContent)
        #expect(p.allParts.count == 3)
        let wrote = p.flush(at: t0)
        #expect(!wrote, "clean persister writes nothing")
    }

    /// The real sink: flushes land in `message_part` with status `streaming`; the row is readable mid-stream.
    @Test func flushesReachTheDatabase() throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create()
        let tree = MessageTree(db)
        let u = try tree.append(chatID: chat.id, parentID: nil, role: .user, parts: [.text("q")])
        let a = try tree.append(chatID: chat.id, parentID: u.id, role: .assistant, status: .pending)
        var p = StreamPersister { parts in try MessageRepository(db).flush(a.id, parts: parts, status: .streaming) }
        let t0 = ContinuousClock.now
        for i in 0..<120 { p.appendText(" w\(i)", tokens: 1, at: t0 + .milliseconds(10 * i)) }
        let row = try #require(try MessageRepository(db).message(a.id))
        #expect(row.status == .streaming)
        let stored = try MessageRepository(db).parts(of: a.id).map(\.body).joined()
        #expect(!stored.isEmpty && p.text.hasPrefix(stored))
        #expect(p.text.count - stored.count < 50 * 4)
    }
}
