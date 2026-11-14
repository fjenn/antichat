// M1.T14 AT-230 (1) (R-230 AC1) + AT-269 tool-block bytes: over a scripted 30-turn chat the stable-prefix bytes
// (SHA-256) are identical on every turn; editing instructions changes the hash exactly once, at the next turn; the
// time line on the newest user turn is the only difference between turn renders besides the conversation (D-022:
// the system turn carries the date only, so a new minute keeps prefix + history; only a new day changes the date
// line). Plus the composer's determinism rules (canonical tool order, compact schemas, NFC/CRLF normalisation,
// date/time line format).
// With ANTICHAT_EVIDENCE_DIR set, the 30-turn log goes to $ANTICHAT_EVIDENCE_DIR/stability.log.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Records every request; replies through the in-process ScriptedEngine.
private final class RecordingEngine: EngineService {
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
}

/// A clock the test advances: one minute per turn, so every turn has a new time line.
private final class TestClock: Sendable {
    let minutes = Mutex(0)
    let start: Date
    init(start: Date = Date(timeIntervalSince1970: 1_793_361_600)) { self.start = start }  // 2026-10-30 12:00:00 UTC
    var context: VolatileContext {
        VolatileContext(now: start.addingTimeInterval(Double(minutes.withLock { $0 }) * 60),
                        timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }
}

enum PromptFixtures {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The seven AntiChat tools (M1.T13's set), `tools/fixtures/prompt/antichat-tools-7.json`.
    static func tools() throws -> [ToolSchema] {
        let json = try String(contentsOf: repoRoot.appendingPathComponent("tools/fixtures/prompt/antichat-tools-7.json"), encoding: .utf8)
        let t = ToolSchema.fromOpenAI(json)
        precondition(t.count == 7, "antichat-tools-7.json must hold 7 tools")
        return t
    }
}

/// What a request's stable prefix is on the wire: the leading stable layers (the date line last) and the tool list
/// bytes; `volatile` = layers that are not stable or follow the conversation (none since D-022).
private func stableWire(_ r: ChatRequest) -> (
    text: String, tools: String, sha: String, date: [String], volatile: [String], conversation: [ChatMessage]
) {
    var stable: [String] = [], date: [String] = [], volatile: [String] = [], conv: [ChatMessage] = []
    var inHead = true
    for item in r.messages {
        switch item {
        case .layer(let l):
            if inHead, l.stable {
                stable.append(l.content)
                if l.id == PromptLayerID.date { date.append(l.content) }
            } else {
                inHead = false
                volatile.append(l.content)
            }
        case .message(let m):
            inHead = false
            conv.append(m)
        }
    }
    let tools = r.tools.map { ToolBlockRenderer.json($0.openAIObject) }.joined(separator: "\n")
    let text = stable.joined(separator: "\n\n")
    let sha = SHA256.hash(data: Data((text + "\u{0}" + tools).utf8)).map { String(format: "%02x", $0) }.joined()
    return (text, tools, sha, date, volatile, conv)
}

/// A ChatML-style render (what the Qwen templates produce, minus the generation prompt), to compare prompts as
/// text: the next turn's prompt must start with everything before this turn's ephemeral part.
private func chatML(_ messages: [ChatMessage]) -> String {
    messages.map { "<|im_start|>\($0.role.rawValue)\n\($0.content)<|im_end|>\n" }.joined()
}

/// The render of `r` up to its ephemeral part: its history view without the last `<|im_end|>\n`.
private func reusablePrefix(_ r: ChatRequest) -> String {
    String(chatML(r.flattenedHistory).dropLast("<|im_end|>\n".count))
}

@Suite("PromptStabilityTests") struct PromptStabilityTests {
    @Test func thirtyTurnChatKeepsTheStablePrefixUntilTheEdit() async throws {
        let db = try AppDatabase.inMemory()
        let engine = try RecordingEngine(script: words(3, delayMs: 0))
        let tools = try PromptFixtures.tools()
        let settings = PromptSettings(PromptInputs(
            personalization: Personalization(aboutYou: "I am a nurse in Lyon.", style: .efficient), tools: tools))
        let clock = TestClock()
        let chatID = StorageID.make()
        let controller = TurnController(
            chatID: chatID, database: db, engine: engine, promptSettings: settings,
            volatileContext: { clock.context }, slot: { .scripted("inline") })
        let log = UpdateLog(controller)
        let editAfterTurn = 15
        var parent: String?
        var assistants: [String] = []
        for turn in 1...30 {
            let u = StorageID.make(), a = StorageID.make()
            await controller.start(.send(userID: u, text: "Question \(turn)?", parentID: parent), assistantID: a)
            #expect(try await log.waitFinished(a).status == .done)
            parent = a
            assistants.append(a)
            clock.minutes.withLock { $0 += 1 }
            if turn == editAfterTurn {
                settings.update { $0.personalization.howToRespond = "Answer in French." }
            }
        }
        let reqs = engine.requests.withLock { $0 }
        #expect(reqs.count == 30)
        var lines: [String] = []
        var changes: [Int] = []
        for (i, r) in reqs.enumerated() {
            let w = stableWire(r)
            lines.append("turn \(i + 1) stable_sha256=\(w.sha) tools_sha256=\(sha(w.tools)) date=\"\(w.date.joined())\" "
                         + "time=\"\(r.turnContext ?? "")\" conversation=\(w.conversation.count) session=\(r.sessionID)")
            #expect(r.sessionID == reqs[0].sessionID, "one session id per chat")
            #expect(w.date.count == 1, "the date line is the last stable layer")
            #expect(w.volatile.isEmpty, "no volatile layer in the system turn (D-022)")
            #expect(r.turnContext?.hasPrefix("Current local time: ") == true)
            #expect(!w.conversation.contains { $0.content.contains("Current local time") }, "time line not in history")
            #expect(r.flattenedMessages.last?.content.hasSuffix("\n\n" + r.turnContext!) == true)
            #expect(w.tools == stableWire(reqs[0]).tools, "tool block bytes identical on every turn (AT-269)")
            guard i > 0 else { continue }
            let p = stableWire(reqs[i - 1])
            if w.sha != p.sha { changes.append(i + 1) }
            // The only differences to the previous render: the time line and the conversation (which extends);
            // the previous prompt up to its time line is a prefix of this one (prefix + history survive).
            #expect(r.turnContext != reqs[i - 1].turnContext)
            #expect(w.date == p.date)
            if i + 1 != editAfterTurn + 1 { #expect(chatML(r.flattenedMessages).hasPrefix(reusablePrefix(reqs[i - 1]))) }
            #expect(Array(w.conversation.prefix(p.conversation.count)) == p.conversation)
            #expect(w.conversation.count == p.conversation.count + 2)
            if i + 1 != editAfterTurn + 1 { #expect(w.text == p.text) }
        }
        #expect(changes == [editAfterTurn + 1], "the edit changes the hash exactly once, at the next turn")
        // provenance_json.promptHash per assistant message = the composer's manifest hash of that turn.
        let hashes = try assistants.map { id in try #require(try db.read { try MessageTree.message(id, db: $0) }.provenance?.promptPrefixHash) }
        #expect(Set(hashes[0..<editAfterTurn]).count == 1)
        #expect(Set(hashes[editAfterTurn...]).count == 1)
        #expect(hashes[0] != hashes[editAfterTurn])
        lines.append("hash changes at turns: \(changes) (edit after turn \(editAfterTurn)); promptHash before=\(hashes[0]) after=\(hashes[editAfterTurn])")
        lines.append("result: \(changes == [editAfterTurn + 1] ? "PASS" : "FAIL")")
        if let dir = ProcessInfo.processInfo.environment["ANTICHAT_EVIDENCE_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/stability.log", atomically: true, encoding: .utf8)
        }
    }

    @Test func canonicalToolOrderAndCompactSchemas() throws {
        let tools = try PromptFixtures.tools()
        let r = ToolBlockRenderer()
        let a = r.canonical(tools), b = r.canonical(tools.reversed()), c = r.canonical(tools.shuffled())
        #expect(a == b && b == c, "registration order does not change the block")
        #expect(a.map(\.name) == a.map(\.name).sorted())
        #expect(r.render(a) == r.render(b))
        let mem = try #require(a.first { $0.name == "memory_write" })
        // `description` annotations are dropped, a parameter literally named `description` is kept.
        let params = try #require(try JSONSerialization.jsonObject(with: Data(mem.parametersJSON.utf8)) as? [String: Any])
        let props = try #require(params["properties"] as? [String: Any])
        #expect(Set(props.keys) == ["fact", "description"])
        #expect((props["fact"] as? [String: Any])?["description"] == nil)
        #expect(mem.description == "Save a fact about the user for later chats.")
        // Sorted keys: the same schema built from differently ordered JSON renders the same bytes.
        let x = ToolSchema(name: "t", description: "d", parametersJSON: #"{"type":"object","required":["a"],"properties":{"b":{"type":"string"},"a":{"type":"integer"}}}"#)
        let y = ToolSchema(name: "t", description: "d", parametersJSON: #"{"properties":{"a":{"type":"integer"},"b":{"type":"string"}},"required":["a"],"type":"object"}"#)
        #expect(r.canonical([x]) == r.canonical([y]))
    }

    @Test func oneLineDescriptionRules() {
        #expect(ToolBlockRenderer.oneLineToolDescription("Read ~/.venv/x. Then more.") == "Read ~/.venv/x.")
        #expect(ToolBlockRenderer.oneLineToolDescription("Use e.g. this one. Second.") == "Use e.g. this one.")
        #expect(ToolBlockRenderer.oneLineToolDescription("   ") == nil)
        let long = String(repeating: "a", count: 300)
        #expect(ToolBlockRenderer.oneLineToolDescription(long)?.count == 180)
    }

    @Test func composerIsDeterministicAndNormalises() {
        let c = PromptComposer()
        let ctx = VolatileContext(now: Date(timeIntervalSince1970: 1_793_361_600), timeZone: TimeZone(identifier: "UTC")!)
        let p1 = c.compose(PromptInputs(personalization: Personalization(aboutYou: "Caf\u{65}\u{301}\r\nline  ")), context: ctx)
        let p2 = c.compose(PromptInputs(personalization: Personalization(aboutYou: "Caf\u{e9}\nline")), context: ctx)
        #expect(p1.stableSHA256 == p2.stableSHA256, "NFC + CRLF + trailing spaces normalised")
        #expect(p1.stableSHA256.count == 64)
        #expect(p1.promptHash == p1.manifest.prefixHash)
        // Defaults render no instructions/memory/tool layer at all.
        let plain = c.compose(PromptInputs(), context: ctx)
        #expect(plain.layers.map(\.id) == [PromptLayerID.base, PromptLayerID.date])
        #expect(plain.layers.allSatisfy { $0.stable })
        #expect(plain.stablePrefix.hasSuffix(plain.dateLine))
        // A later minute changes only the time line (turnContext); the system turn and its hash stay.
        let later = c.compose(PromptInputs(), context: VolatileContext(now: ctx.now.addingTimeInterval(60), timeZone: ctx.timeZone))
        #expect(later.stableSHA256 == plain.stableSHA256 && later.promptHash == plain.promptHash)
        #expect(later.systemText == plain.systemText)
        #expect(later.timeLine != plain.timeLine)
        // A later day changes the date line, hence the prefix.
        let tomorrow = c.compose(PromptInputs(), context: VolatileContext(now: ctx.now.addingTimeInterval(86_400), timeZone: ctx.timeZone))
        #expect(tomorrow.stableSHA256 != plain.stableSHA256)
        #expect(tomorrow.dateLine != plain.dateLine)
        // Tools: hashed into the stable prefix, sent as `tools` (template slot), not as system text.
        let withTools = c.compose(PromptInputs(tools: [ToolSchema(name: "get_time", description: "Get the time.")]), context: ctx)
        #expect(withTools.stableSHA256 != plain.stableSHA256)
        #expect(withTools.layers.map(\.id) == [PromptLayerID.base, PromptLayerID.date])
        #expect(withTools.tools.count == 1)
        let inLayer = c.compose(PromptInputs(tools: [ToolSchema(name: "get_time", description: "Get the time.")], toolPlacement: .systemLayer), context: ctx)
        #expect(inLayer.layers.map(\.id) == [PromptLayerID.base, PromptLayerID.tools, PromptLayerID.date])
        #expect(inLayer.stableSHA256 == withTools.stableSHA256)
    }

    @Test func dateAndTimeLineFormat() {
        let t = Date(timeIntervalSince1970: 1_793_361_600)  // 2026-10-30 12:00 UTC, a Friday
        let utc = VolatileContext(now: t, timeZone: TimeZone(identifier: "UTC")!)
        #expect(utc.dateLine == "Current date: 2026-10-30 (Friday), time zone GMT.")
        #expect(utc.timeLine == "Current local time: 12:00 (UTC+00:00).")
        let ny = VolatileContext(now: t.addingTimeInterval(59), timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(ny.dateLine == "Current date: 2026-10-30 (Friday), time zone America/New_York.")
        #expect(ny.timeLine == "Current local time: 08:00 (UTC-04:00).")
        let kol = VolatileContext(now: t, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        #expect(kol.dateLine == "Current date: 2026-10-30 (Friday), time zone Asia/Kolkata.")
        #expect(kol.timeLine == "Current local time: 17:30 (UTC+05:30).")
        // The day is the user's local day: 12:00 UTC is already Saturday in Kiritimati (UTC+14).
        #expect(VolatileContext(now: t, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!).dateLine
            == "Current date: 2026-10-31 (Saturday), time zone Pacific/Kiritimati.")
    }

    /// D-022: across a minute boundary the system turn and the whole history are reused (only the newest turn's
    /// time line and the new messages differ); across a day boundary only the date line changes in the system turn,
    /// and the history after it is unchanged.
    @Test func minuteAndDayBoundaries() async throws {
        let db = try AppDatabase.inMemory()
        let engine = try RecordingEngine(script: words(3, delayMs: 0))
        // 2026-10-30 23:58 in Berlin (UTC+01:00 after the 25 Oct DST end) = 22:58 UTC.
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_793_361_600 + 10 * 3600 + 58 * 60))
        let controller = TurnController(
            chatID: StorageID.make(), database: db, engine: engine,
            promptSettings: PromptSettings(PromptInputs(tools: try PromptFixtures.tools())),
            volatileContext: { clock.context }, slot: { .scripted("inline") })
        let log = UpdateLog(controller)
        var parent: String?
        for minute in [0, 1, 2] {  // 23:58, 23:59 (minute boundary), 00:00 next day (day boundary)
            clock.minutes.withLock { $0 = minute }
            let u = StorageID.make(), a = StorageID.make()
            await controller.start(.send(userID: u, text: "Question at +\(minute) min?", parentID: parent), assistantID: a)
            #expect(try await log.waitFinished(a).status == .done)
            parent = a
        }
        let r = engine.requests.withLock { $0 }
        try #require(r.count == 3)
        let w = r.map(stableWire)
        #expect(w[0].date == ["Current date: 2026-10-30 (Friday), time zone Europe/Berlin."])
        #expect(r[0].turnContext == "Current local time: 23:58 (UTC+01:00).")
        #expect(r[1].turnContext == "Current local time: 23:59 (UTC+01:00).")
        #expect(r[2].turnContext == "Current local time: 00:00 (UTC+01:00).")
        // Minute boundary: identical system turn, and turn 1's prompt up to its time line is a prefix of turn 2's.
        #expect(w[1].sha == w[0].sha && w[1].text == w[0].text)
        #expect(r[1].flattenedMessages.first == r[0].flattenedMessages.first)
        #expect(chatML(r[1].flattenedMessages).hasPrefix(reusablePrefix(r[0])))
        #expect(Array(r[1].flattenedMessages.prefix(r[0].flattenedHistory.count)) == r[0].flattenedHistory)
        // Day boundary: only the date line changes in the system turn; the history after it is unchanged.
        #expect(w[2].date == ["Current date: 2026-10-31 (Saturday), time zone Europe/Berlin."])
        #expect(w[2].sha != w[1].sha)
        #expect(w[2].text.replacingOccurrences(of: w[2].date[0], with: "") == w[1].text.replacingOccurrences(of: w[1].date[0], with: ""))
        #expect(Array(r[2].flattenedMessages.dropFirst().prefix(r[1].flattenedHistory.count - 1)) == Array(r[1].flattenedHistory.dropFirst()))
        #expect(!chatML(r[2].flattenedMessages).hasPrefix(reusablePrefix(r[1])), "a day change re-prefills from the date line")
    }

    @Test func sessionIDIsStablePerChat() {
        #expect(UUID.session(forChat: "abc") == UUID.session(forChat: "abc"))
        #expect(UUID.session(forChat: "abc") != UUID.session(forChat: "abd"))
    }
}

private func sha(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
