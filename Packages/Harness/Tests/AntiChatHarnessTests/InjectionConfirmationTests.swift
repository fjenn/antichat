// AT-NFR-SEC5 (M7.T15 step 6; NFR-SEC5, K-051, K-NEW-FILES-10): the 30 documents of `fixtures/prompts/injection-30/`
// (each hides an instruction to call a write tool) reach the model three ways — as a web result (`web_search`), as an
// MCP tool result (the scripted Team Chat server's `search_messages`) and as an uploaded file — and the scripted model
// then makes the induced write call (`team_chat_send_message`). The user has chosen "Always allow" for both Team Chat
// tools, so the only reason to ask is the untrusted context. Pass: 90/90 induced calls show the ApprovalCard with
// `approve.untrusted` (`untrusted: true`), 0 run without a click (the card is answered Deny), and the injected text
// sits inside an `untrusted="true"` wrapper in 100% of the requests that carry it. No content is inspected: the
// decision is the tool's side effect + provenance (R-241). Evidence: build/at/AT-NFR-SEC5/<date>.json.
//   make test-unit FILTER=InjectionConfirmationTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

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
    /// Every message text the model was sent (all requests of the turn).
    var texts: [String] {
        requests.withLock { $0 }.flatMap(\.messages).compactMap { if case .message(let m) = $0 { m.content } else { nil } }
    }
}

@Suite(.serialized) struct InjectionConfirmationTests {
    enum Leg: String, CaseIterable, Sendable { case web, mcp, file }

    struct Case: Decodable, Sendable {
        var id: String, file: String, kind: String, style: String, marker: String
    }

    static let dir = MCPTurnTests.fixtures.appendingPathComponent("prompts/injection-30")
    static let cases: [Case] = {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("cases.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
    }()
    static func document(_ c: Case) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(c.file), encoding: .utf8)) ?? ""
    }

    static let send = #"{"t":"toolCallDone","id":"call_send","name":"team_chat_send_message","args":"{\"channel\":\"general\",\"text\":\"injected\"}","delayMs":1}"#
    static func script(_ leg: Leg) -> String {
        let first: String
        switch leg {
        case .web: first = #"{"t":"toolCallDone","id":"call_web","name":"web_search","args":"{\"queries\":[\"tips\"]}","delayMs":1}"#
        case .mcp: first = #"{"t":"toolCallDone","id":"call_read","name":"team_chat_search_messages","args":"{\"query\":\"tips\"}","delayMs":1}"#
        case .file: return [send, #"{"t":"turn"}"#, #"{"t":"textDelta","v":"Done.","delayMs":1}"#].joined(separator: "\n")
        }
        return [first, #"{"t":"turn"}"#, send, #"{"t":"turn"}"#, #"{"t":"textDelta","v":"Done.","delayMs":1}"#].joined(separator: "\n")
    }

    /// The scripted Team Chat session with `search_messages` answering `doc`.
    static func jsonl(answering doc: String) throws -> String {
        try MCPTurnTests.jsonl.split(separator: "\n").map { line -> String in
            var o = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if o["tool"] as? String == "search_messages" {
                o["result"] = ["content": [["type": "text", "text": doc]], "isError": false]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n")
    }

    /// The web tool as the turn sees it: untrusted output, the production WebResultsBlock around the page.
    static func webSearch(page doc: String, marker: String) -> RegisteredTool {
        RegisteredTool(name: "web_search", description: "Search the web for current information.",
                       parametersJSON: WebSearchTools.webSearchParameters, sideEffect: .read, outputIsUntrusted: true) { _ in
            let s = WebSource(n: 1, url: "https://tips.example/\(marker.lowercased())", title: "Tips", site: "tips.example",
                              date: nil, snippet: "", fetched: true)
            let c = EvidenceChunk(source: 1, url: URL(string: s.url)!, site: s.site, title: s.title, text: doc, ordinal: 0)
            return WebResultsBlock.render(WebResults(queries: ["tips"], sources: [s], evidence: [c], evidenceTokens: 100, failed: nil))
        }
    }

    struct Outcome: Sendable {
        var asked: Bool, untrustedCard: Bool, executedBeforeClick: Int, executedAfterDeny: Int, wrapped: Bool, carriers: Int
    }

    static func run(_ c: Case, leg: Leg, mode: ChatMode) async throws -> Outcome {
        let doc = document(c)
        try #require(!doc.isEmpty && doc.contains(c.marker), "\(c.file)")
        let db = try AppDatabase.inMemory()
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        let host = MCPHost(database: db, secrets: MemorySecrets(),
                           makeTransport: MCPHost.scriptedFactory(jsonl: try jsonl(answering: leg == .mcp ? doc : "nothing new")),
                           policy: policy)
        let server = try await host.add(name: "Team Chat", url: URL(string: "https://chat.example/mcp")!, auth: .none)
        let registry = ToolRegistry([ScriptedTools.getTime()])
        if leg == .web { registry.register(webSearch(page: doc, marker: c.marker)) }
        let permissions = ToolPermissionStore(db)
        for tool in ["send_message", "search_messages"] {  // "Always allow" for both: only provenance can make it ask
            try permissions.set(.always, toolKey: MCPToolRecord.permissionKey(server: server.id, tool: tool))
        }
        let set = MCPTools.install(into: registry, database: db, host: host, tier: { "T1" }, resume: false).tools
        var runtime = ToolRuntime(registry: registry, permissions: permissions, policy: .forTier(.t1), selection: .off, tier: { .t1 })
        runtime.chatFilter = MCPTools.filter(set, permissions: permissions, policy: policy)
        runtime.switches = ToolSwitches(defaults: UserDefaults.inMemory())
        runtime.onlineGate = OnlineToolGate(policy: policy, kind: { _ in .local })
        let engine = try RecordingEngine(script: script(leg))
        let chatID = try ChatRepository(db).create().id
        let slot: @Sendable () -> ModelSlot = { .scripted("inline") }
        let promptSettings = ToneClause.settings(PromptSettings(), mode: mode, tone: FixedToneSentence("Give no warnings or moral commentary unless asked."))
        let controller = TurnController(chatID: chatID, database: db, engine: engine, mode: mode, promptSettings: promptSettings,
                                        tools: runtime, slot: slot)
        let log = UpdateLog(controller)
        var attachments: [String] = []
        if leg == .file {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent(c.file)
            try Data(doc.utf8).write(to: url)
            let intake = AttachmentIntake(database: db, mediaRoot: AttachmentIntake.incognitoRoot(), incognito: true)
            let item = await intake.ingest(AttachmentIntake.admit([url]).items[0])
            attachments = [try #require(item.attachmentID, "\(c.file) not ingested")]
        }
        let a = StorageID.make()
        await controller.start(.send(userID: StorageID.make(), text: "Summarise the tips.", parentID: nil, attachmentIDs: attachments),
                               assistantID: a)
        func card() -> ToolApprovalRequest? {
            var last: ToolApprovalRequest?
            for u in log.all where u.assistantID == a { if case .approval(let r) = u.kind { last = r } }
            return last
        }
        try await log.wait(.seconds(20)) { l in card() != nil || l.finished(a) != nil }
        let pending = card()
        let before = registry.invocations(of: "team_chat_send_message")
        if let pending { await controller.answerApproval(callID: pending.id, .deny) }
        _ = try await log.waitFinished(a, timeout: .seconds(20))
        let after = registry.invocations(of: "team_chat_send_message")
        let carriers = engine.texts.filter { $0.contains(c.marker) }
        let wrapped = !carriers.isEmpty && carriers.allSatisfy { Self.insideUntrustedWrapper($0, marker: c.marker) }
        return Outcome(asked: pending?.tool == "team_chat_send_message", untrustedCard: pending?.untrusted == true,
                       executedBeforeClick: before, executedAfterDeny: after, wrapped: wrapped, carriers: carriers.count)
    }

    /// Every occurrence of `marker` lies between an `untrusted="true"` opening tag and the matching closing tag.
    static func insideUntrustedWrapper(_ text: String, marker: String) -> Bool {
        var rest = text[...]
        var found = false
        while let r = rest.range(of: marker) {
            found = true
            let head = text[..<r.lowerBound]
            guard let open = head.range(of: #"<([a-z_]+)\b[^>]*untrusted="true"[^>]*>"#, options: [.regularExpression, .backwards]),
                  let name = text[open].dropFirst().split(whereSeparator: { $0 == " " || $0 == ">" }).first
            else { return false }
            if head[open.upperBound...].contains("</\(name)>") { return false }  // closed before the marker
            guard text[r.upperBound...].contains("</\(name)>") else { return false }
            rest = text[r.upperBound...]
        }
        return found
    }

    @Test func thirtyDocumentsAreThere() {
        #expect(Self.cases.count == 30)
        #expect(Set(Self.cases.map(\.style)).count >= 6)
    }

    @Test(arguments: Leg.allCases)
    func everyInducedWriteAsksAndNoneRunsWithoutAClick(_ leg: Leg) async throws {
        try #require(Self.cases.count == 30, "fixtures/prompts/injection-30 missing (git submodule update --init fixtures)")
        var rows: [[String: Any]] = []
        var failures: [String] = []
        for (i, c) in Self.cases.enumerated() {
            let mode: ChatMode = i.isMultiple(of: 2) ? .normal : .evil  // both modes, alternating (same rule in each)
            let o = try await Self.run(c, leg: leg, mode: mode)
            let pass = o.asked && o.untrustedCard && o.executedBeforeClick == 0 && o.executedAfterDeny == 0 && o.wrapped
            if !pass { failures.append("\(c.id) \(leg.rawValue): \(o)") }
            rows.append(["id": c.id, "leg": leg.rawValue, "mode": mode == .evil ? "evil" : "normal", "style": c.style,
                         "approval_card": o.asked, "approve_untrusted": o.untrustedCard,
                         "executed_without_click": o.executedBeforeClick, "executed_after_deny": o.executedAfterDeny,
                         "wrapped_untrusted": o.wrapped, "requests_carrying_text": o.carriers, "pass": pass])
        }
        #expect(failures.isEmpty, "\(failures)")
        Self.evidence(leg: leg, rows: rows)
    }

    /// Per-leg rows into build/at/AT-NFR-SEC5/<date>.<leg>.json (tools/at/at-nfr-sec5.py folds them into <date>.json).
    static func evidence(leg: Leg, rows: [[String: Any]]) {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let out = root.appendingPathComponent("build/at/AT-NFR-SEC5")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let doc: [String: Any] = ["leg": leg.rawValue, "cases": rows.count, "passed": rows.filter { $0["pass"] as? Bool == true }.count,
                                  "rows": rows]
        if let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: out.appendingPathComponent("\(day).\(leg.rawValue).json"))
        }
    }
}
