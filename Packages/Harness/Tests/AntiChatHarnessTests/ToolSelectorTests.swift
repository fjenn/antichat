// AT-266 (R-266 AC1) — M7.T14: "Load tools when needed". With the 40 tools of fixtures/tools/forty-tools.json enabled,
// 200 turns (fixtures/prompts/tool-select-200.jsonl) × T0–T4 through the TurnController: every request — and the
// rendered prompt's tool block (what `-DumpPrompts` writes) — carries at most the tier's `tools.max_per_step`
// (tier-budgets.json, read, never retyped) and fits `tools.schema_token_cap`; `find_tools` is offered when tools were
// left out and brings a found tool in on the next step; forced chips are never cut; "Always offer all" offers every
// eligible tool within the schema cap; the tool block is byte-stable for the same set (R-269). The accuracy leg (c2)
// is `antichat-bench tool-select` (real embed model, build/at/AT-266/).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct ToolSelectorTests {
    static let fixtures: URL = {
        if let e = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !e.isEmpty { return URL(fileURLWithPath: e) }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("fixtures")
    }()

    struct FixtureTool: Decodable {
        var name: String
        var description: String
        var parameters: AnyJSONText
    }

    struct AnyJSONText: Decodable {
        var text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            text = String(decoding: try JSONEncoder().encode(try c.decode(JSONNode.self)), as: UTF8.self)
        }
    }

    indirect enum JSONNode: Codable {
        case null, bool(Bool), num(Double), str(String), arr([JSONNode]), obj([String: JSONNode])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let d = try? c.decode(Double.self) { self = .num(d) }
            else if let s = try? c.decode(String.self) { self = .str(s) }
            else if let a = try? c.decode([JSONNode].self) { self = .arr(a) }
            else { self = .obj(try c.decode([String: JSONNode].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .num(let d): if d == d.rounded() { try c.encode(Int(d)) } else { try c.encode(d) }
            case .str(let s): try c.encode(s)
            case .arr(let a): try c.encode(a)
            case .obj(let o): try c.encode(o)
            }
        }
    }

    struct Row: Decodable { var id: String; var prompt: String; var gold: String; var also: [String] }

    static func fortyTools() throws -> [RegisteredTool] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("tools/forty-tools.json"))
        return try JSONDecoder().decode([FixtureTool].self, from: data).map { t in
            RegisteredTool(name: t.name, description: t.description, parametersJSON: t.parameters.text, outputIsUntrusted: false) { _ in "ok" }
        }
    }

    static func rows() throws -> [Row] {
        try String(contentsOf: fixtures.appendingPathComponent("prompts/tool-select-200.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    }

    /// The tools in a rendered prompt's tool block (one function object per line).
    static func dumpedToolCount(_ p: ComposedPrompt) -> Int {
        let text = PromptDump.text(p)
        guard let a = text.range(of: "=== tools ===\n"), let b = text.range(of: "\n=== volatile ===") else { return -1 }
        return text[a.upperBound..<b.lowerBound].split(separator: "\n").filter { $0.hasPrefix("{") }.count
    }

    @Test func fixtureHasFortyToolsAndTwoHundredLabelledPrompts() throws {
        let tools = try Self.fortyTools(), rows = try Self.rows()
        #expect(tools.count == 40 && Set(tools.map(\.name)).count == 40)
        #expect(rows.count == 200)
        let names = Set(tools.map(\.name))
        for r in rows { #expect(r.gold == "none" || names.contains(r.gold), "\(r.id)") }
    }

    /// AT-266 c1: 200 turns × T0–T4, 40 tools enabled.
    @Test(arguments: DeviceTier.allCases)
    func perStepToolCountNeverExceedsTierCap(tier: DeviceTier) async throws {
        let tools = try Self.fortyTools(), rows = try Self.rows()
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"ok","delayMs":0}"#, tier: tier, tools: tools,
                                    selection: .standard, router: try await RouterStubs.router())
        let budget = ToolSelector.Budget.forTier(tier)
        var maxSeen = 0
        for r in rows {
            let (_, a) = await h.send(r.prompt)
            _ = try await h.log.waitFinished(a)
            let reqs = await h.controller.requests  // this turn's steps (reset per turn)
            let prompt = try #require(await h.controller.lastPrompt)
            #expect(!reqs.isEmpty, "\(r.id): \(r.prompt)")
            for req in reqs {
                #expect(req.tools.count <= budget.maxPerStep, "\(tier) \(r.id): \(req.tools.map(\.name))")
                #expect(SchemaCompactor.tokens(req.tools) <= budget.schemaTokenCap || req.tools.count <= 1, "\(r.id)")
                maxSeen = max(maxSeen, req.tools.count)
            }
            #expect(Self.dumpedToolCount(prompt) <= budget.maxPerStep, "\(r.id)")
        }
        #expect(maxSeen > 0 && maxSeen <= ToolSelector.cap(tier, budget: budget))
    }

    @Test func forcedFirstFindToolsLastAndCapsHold() {
        let eligible = (0..<20).map { ToolSchema(name: String(format: "t%02d", $0), description: "Tool \($0).", parametersJSON: #"{"type":"object"}"#) }
        let hits = ["t05", "t06", "t07", "t08"].map { ToolIndex.Hit(name: $0, fusedScore: 0.03, relevant: true) }
        for tier in DeviceTier.allCases {
            let b = ToolSelector.Budget.forTier(tier)
            let s = ToolSelector.select(eligible: eligible, forced: ["t19"], routed: ["t03"], hits: hits, tier: tier, budget: b)
            #expect(s.tools.count <= b.maxPerStep && s.tools.count <= ToolSelector.cap(tier, budget: b))
            #expect(s.tools.first?.name == "t19" && s.tools.last?.name == FindToolsTool.name)
            #expect(s.reasons["t19"] == .forced && s.reasons["t03"] == .routed && s.top == "t19")
            #expect(!s.leftOut.isEmpty)
        }
        // Everything fits: all offered, no find_tools.
        let few = Array(eligible.prefix(2))
        let s = ToolSelector.select(eligible: few, tier: .t0, budget: .forTier(.t0))
        #expect(s.tools.map(\.name) == ["t00", "t01"] && !s.offersFindTools && s.top == nil)
        // "Always offer all": every eligible tool within the schema token cap.
        let all = ToolSelector.select(eligible: eligible, access: .all, tier: .t4, budget: .forTier(.t4))
        #expect(all.tools.count == 20 && !all.offersFindTools)
        let tiny = ToolSelector.select(eligible: eligible, forced: ["t10"], access: .all, tier: .t0,
                                       budget: .init(maxPerStep: 3, schemaTokenCap: 60))
        #expect(tiny.tools.first?.name == "t10" && tiny.offersFindTools && tiny.tools.count < 21)
    }

    @Test func noRelevantToolMeansNoPickAndOnlyAlwaysOnPlusFindTools() {
        let eligible = ["create_image", "get_time", "web_search", "a", "b", "c", "d"].map {
            ToolSchema(name: $0, description: "x", parametersJSON: #"{"type":"object"}"#)
        }
        let s = ToolSelector.select(eligible: eligible, hits: [ToolIndex.Hit(name: "a", fusedScore: 0.01, relevant: false)],
                                    tier: .t1, budget: .forTier(.t1))
        #expect(s.top == nil)
        #expect(s.tools.map(\.name) == ["get_time", FindToolsTool.name])
    }

    @Test func toolIndexRanksLexicallyWithoutVectorsAndFusesWithThem() async {
        let tools = [ToolSchema(name: "github_create_issue", description: "Open a new issue in a GitHub repository.", parametersJSON: "{}"),
                     ToolSchema(name: "calendar_list_events", description: "List the events on the user's calendar.", parametersJSON: "{}"),
                     ToolSchema(name: "create_image", description: "Create a picture from a text description.", parametersJSON: "{}")]
        let lexical = ToolIndex(embedding: nil)
        let hits = await lexical.search(query: "open an issue on github about the crash", queryVector: nil, among: tools, minEmbedCosine: 0.5)
        #expect(hits.first?.name == "github_create_issue" && hits.first?.relevant == true)
        #expect(await lexical.search(query: "hello there", queryVector: nil, among: tools, minEmbedCosine: 0.5).isEmpty)
        let emb = TrigramEmbedding()
        let semantic = ToolIndex(embedding: emb)
        #expect(await semantic.prepare(tools))
        #expect(await semantic.isReady(tools))
        let q = await semantic.queryVector("what is on my calendar")
        let h2 = await semantic.search(query: "what is on my calendar", queryVector: q, among: tools, minEmbedCosine: 0)
        #expect(h2.first?.name == "calendar_list_events")
    }

    /// find_tools brings a left-out tool in for the next step (still within the cap), and the model can call it.
    @Test func findToolsOffersTheFoundToolOnTheNextStep() async throws {
        let script = """
            {"t":"toolCallDone","id":"c1","name":"find_tools","args":"{\\"query\\":\\"stripe invoice for a customer\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"c2","name":"stripe_create_invoice","args":"{\\"customer_email\\":\\"a@example.com\\",\\"amount\\":\\"5\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Done.","delayMs":1}
            """
        let tools = try Self.fortyTools()
        let h = try ToolLoopHarness(script: script, tier: .t1, tools: tools, selection: .standard,
                                    router: try await RouterStubs.router()) { rt in rt.permissions = nil }
        let (_, a) = await h.send("please handle the paperwork from yesterday")
        _ = try await h.log.waitFinished(a)
        let reqs = await h.controller.requests
        #expect(reqs.count >= 2)
        #expect(reqs[0].tools.contains { $0.name == FindToolsTool.name })
        #expect(!reqs[0].tools.contains { $0.name == "stripe_create_invoice" })
        #expect(reqs[1].tools.contains { $0.name == "stripe_create_invoice" }, "\(reqs[1].tools.map(\.name))")
        #expect(reqs[1].tools.count <= ToolSelector.Budget.forTier(.t1).maxPerStep)
        let results = try h.parts(a, .toolResult).map(\.body)
        #expect(results.contains { $0.contains("stripe_create_invoice") })
    }

    /// R-269: the tool block depends on the set, not on the selection order.
    @Test func toolBlockIsOrderStable() {
        let a = [ToolSchema(name: "b", description: "B.", parametersJSON: "{}"), ToolSchema(name: "a", description: "A.", parametersJSON: "{}")]
        let c = PromptComposer()
        #expect(c.compose(PromptInputs(tools: a)).stableSHA256 == c.compose(PromptInputs(tools: a.reversed())).stableSHA256)
    }

    /// R-268 AC2: a per-chat switch-off hides that group's tools in that chat only and never touches the global store.
    @Test func perChatSwitchOverridesGlobalWithoutWritingIt() throws {
        let d = UserDefaults.inMemory()
        let s = ToolSwitches(defaults: d)
        #expect(s.isOn(.image) && !s.isOn(.code) && s.access == .whenNeeded)
        #expect(!s.allows("create_image", chatToolIDs: [ToolGroup.image.offMarker]))
        #expect(s.allows("create_image", chatToolIDs: []))
        #expect(s.allows("run_python", chatToolIDs: [ToolGroup.code.onMarker]) && !s.allows("run_python", chatToolIDs: []))
        #expect(d.object(forKey: "toolImage") == nil && d.object(forKey: "runCodeEnabled") == nil)
        s.setOn(.memory, false)
        #expect(!s.allows("memory", chatToolIDs: []) && s.allows("memory", chatToolIDs: [ToolGroup.memory.onMarker]))
        #expect(s.allows("team_chat_send_message", chatToolIDs: []))
    }
}
