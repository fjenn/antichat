// M7.T03 steps 3, 5, 7, 9 (R-080 AC3/AC4, R-250, R-254): the Web search chip forces one `web_search` step; its
// "Searching the web" line exists from the send (the forced call takes the same activity id, then it is persisted);
// the reply's sources land in `provenance.sources` (pills survive a relaunch); offline the chip adds the
// `network.offlineForSearch` notice and no web tool is offered. Stub web tools: no network.
//   make test-unit FILTER=WebSearchTurnTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct WebSearchTurnTests {
    /// A `web_search` that records two sources (1 fetched, 2 snippet-only and not in evidence) for the turn.
    static func stubSearch(available: Bool = true) -> RegisteredTool {
        RegisteredTool(name: "web_search", description: "Search the web.", parametersJSON: WebSearchTools.webSearchParameters,
                       sideEffect: .read, availability: available ? .available : .unavailable(reason: "noNetwork"),
                       outputIsUntrusted: true) { args in
            let plan = SearchPlan.make(arguments: args, maxQueries: 2)
            let srcs = [WebSource(n: 1, url: "https://one.test/a", title: "One", site: "one.test", date: nil, snippet: "s1", fetched: true),
                        WebSource(n: 2, url: "https://two.test/b", title: "Two", site: "two.test", date: nil, snippet: "s2", fetched: false)]
            let r = WebResults(queries: plan?.queries ?? [], sources: srcs,
                               evidence: [EvidenceChunk(source: 1, url: URL(string: srcs[0].url)!, site: "one.test", title: "One", text: "macOS 27", ordinal: 0)],
                               evidenceTokens: 5, failed: nil)
            return WebResultsBlock.render(TurnWebSources.shared.record(r, turn: TurnContext.requestID ?? "-"))
        }
    }

    static let script = """
        {"t":"toolCallDone","id":"call_1","name":"web_search","args":"{\\"queries\\":[\\"latest macOS\\"]}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"It is macOS 27 [1]. Also [2] and [9].","delayMs":1}
        """

    @Test func chipForcesSearchLineFromSendAndSourcesArePersisted() async throws {
        let h = try ToolLoopHarness(script: Self.script, tier: .t2, tools: [Self.stubSearch()], selection: .standard)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.text.contains("macOS 27"))
        // The line shown at send (id web-<assistant>) is the one the forced call filled in and persisted.
        let first = h.log.all.compactMap { u -> ToolActivity? in
            if u.assistantID == a, case .activity(let act) = u.kind { act } else { nil }
        }.first
        #expect(first?.id == "web-\(a)" && first?.state == .running && first?.tool == "web_search")
        let acts = try h.activities(a)
        #expect(acts.count == 1 && acts[0].id == "web-\(a)" && acts[0].state == .done)
        // The forced first step asked for web_search.
        let reqs = await h.controller.requests
        #expect(reqs.first?.toolChoice == .function("web_search"))
        // provenance.sources: both sources, `fetched` kept; the citation validator only pills [1].
        let prov = try #require(try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance)
        let sources = try #require(prov.sources)
        #expect(sources.map(\.n) == [1, 2] && sources.map(\.fetched) == [true, false])
        let web = sources.map { WebSource(n: $0.n, url: $0.url, title: $0.title, site: $0.site, date: $0.date, snippet: $0.snippet, fetched: $0.fetched) }
        let v = CitationValidator.validate(r.text, sources: web)
        #expect(v.citations.map(\.sources) == [[1]] && v.dropped == 2)
        #expect(TurnWebSources.shared.sources(turn: a).isEmpty, "the turn's sources are released at finalize")
    }

    /// M7.T16 review #3: [Continue] on a web reply keeps its sources (pills and the Sources panel stay) and the
    /// earlier citations are not re-checked against evidence that is gone.
    @Test func continueKeepsTheReplysWebSources() async throws {
        let script = """
            {"t":"toolCallDone","id":"call_1","name":"web_search","args":"{\\"queries\\":[\\"latest macOS\\"]}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"It is macOS 27 [1].","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":" More soon.","delayMs":1}
            """
        let h = try ToolLoopHarness(script: script, tier: .t2, tools: [Self.stubSearch()], selection: .standard)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        await h.controller.setChips([])
        await h.controller.start(.continueTools(assistantID: a), assistantID: a)
        try await h.log.wait(.seconds(30)) { log in
            log.all.filter { if case .finished = $0.kind { $0.assistantID == a } else { false } }.count == 2
        }
        let rec = try #require(try h.database.read { try MessageRecord.fetchOne($0, key: a) })
        let sources = try #require(rec.provenance?.sources, "Continue must keep the reply's sources")
        #expect(sources.map(\.n) == [1, 2] && sources[0].url == "https://one.test/a")
        let text = try MessageRepository(h.database).parts(of: a).filter { $0.kind == .text }.map(\.body).joined()
        #expect(text.contains("macOS 27 [1]"), "the earlier citation stays: \(text)")
        #expect(TurnWebSources.shared.sources(turn: a).isEmpty)
    }

    /// R-080 (A-M7-T03c attempt 7): a model that ignores the forced `web_search` (writes an answer, no call) still
    /// gets the search: the harness calls `web_search` with the user's message, the memory answer is never shown or
    /// stored, and the reply comes from the results. The forced step is capped so such a model stops early.
    @Test func chipSearchesEvenWhenTheModelWritesNoCall() async throws {
        let engine = TextRepliesEngine(["From memory: macOS 26.", "It is macOS 27 [1]."])
        let h = try ToolLoopHarness(script: "", tier: .t2, tools: [Self.stubSearch()], selection: .standard, engine: engine)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.text == "It is macOS 27 [1].")
        let deltas = h.log.all.compactMap { u -> String? in
            if u.assistantID == a, case .textDelta(let s) = u.kind { s } else { nil }
        }.joined()
        #expect(!deltas.contains("From memory"), "the held-back memory answer is never shown")
        #expect(await h.controller.forcedSearchFallbacks == 1)
        let reqs = await h.controller.requests
        #expect(reqs.count == 2 && reqs[0].toolChoice == .function("web_search"))
        #expect(reqs[0].sampling.maxTokens <= 256 && reqs[1].sampling.maxTokens > 256)
        // the second step saw the harness's call and its result
        let call = try #require(reqs[1].flattenedMessages.first { !$0.toolCalls.isEmpty }?.toolCalls.first)
        #expect(call.name == "web_search" && call.argumentsJSON.contains("What's the latest macOS version?"))
        let acts = try h.activities(a)
        #expect(acts.count == 1 && acts[0].id == "web-\(a)" && acts[0].state == .done)
        let prov = try #require(try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance)
        #expect(prov.sources?.map(\.n) == [1, 2])
    }

    /// M7 bars (T1 search latency): on T0/T1 the chip's forced call is the harness's (the user's message as the
    /// query); the model is asked once, for the answer from the results.
    @Test func onT1TheChipSearchesWithoutAModelStep() async throws {
        let engine = TextRepliesEngine(["It is macOS 27 [1]."])
        let h = try ToolLoopHarness(script: "", tier: .t1, tools: [Self.stubSearch()], selection: .standard, engine: engine)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.text == "It is macOS 27 [1].")
        let reqs = await h.controller.requests
        #expect(reqs.count == 2, "the forced step is recorded but not sent; one engine request answers")
        let call = try #require(reqs[1].flattenedMessages.first { !$0.toolCalls.isEmpty }?.toolCalls.first)
        #expect(call.name == "web_search" && call.argumentsJSON.contains("What's the latest macOS version?"))
        let acts = try h.activities(a)
        #expect(acts.count == 1 && acts[0].id == "web-\(a)" && acts[0].state == .done)
        #expect(await h.controller.forcedSearchFallbacks == 0)
    }

    /// M9.T05 (AT-254 T3): T3 searches without a model step too; a multi-part question goes out with its rule-written
    /// sub-queries in the same call, and the model then answers (or searches again when the pages in time were thin).
    @Test func onT3TheChipSearchCarriesTheSubQueries() async throws {
        let engine = TextRepliesEngine(["Lyon has 520,000 people [1] and Marseille 870,000 [2]."])
        let h = try ToolLoopHarness(script: "", tier: .t3, tools: [Self.stubSearch()], selection: .standard, engine: engine)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("Compare the populations of Lyon and Marseille.")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        let reqs = await h.controller.requests
        #expect(reqs.count == 2, "the forced step is recorded but not sent; one engine request answers")
        let call = try #require(reqs[1].flattenedMessages.first { !$0.toolCalls.isEmpty }?.toolCalls.first)
        let queries = try #require(SearchPlan.make(arguments: call.argumentsJSON, maxQueries: 3)?.queries)
        #expect(queries == ["Compare the populations of Lyon and Marseille.", "Compare the populations of Lyon.",
                            "Compare the populations of Marseille."])
    }

    @Test func onT1TheChipSearchesTheMessageAlone() async throws {
        let engine = TextRepliesEngine(["Lyon has 520,000 people [1]."])
        let h = try ToolLoopHarness(script: "", tier: .t1, tools: [Self.stubSearch()], selection: .standard, engine: engine)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("Compare the populations of Lyon and Marseille.")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        let reqs = await h.controller.requests
        #expect(reqs.count == 2)
        let call = try #require(reqs[1].flattenedMessages.first { !$0.toolCalls.isEmpty }?.toolCalls.first)
        #expect(SearchPlan.make(arguments: call.argumentsJSON, maxQueries: 3)?.queries == ["Compare the populations of Lyon and Marseille."])
    }

    @Test func aModelThatCallsTheToolIsNotOverridden() async throws {
        let h = try ToolLoopHarness(script: Self.script, tier: .t2, tools: [Self.stubSearch()], selection: .standard)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(await h.controller.forcedSearchFallbacks == 0)
        let reqs = await h.controller.requests
        let call = reqs.last?.flattenedMessages.compactMap { $0.toolCalls.first }.first
        #expect(call?.argumentsJSON.contains("latest macOS") == true)
    }

    @Test func offlineChipAddsTheNoticeAndOffersNoWebTool() async throws {
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"From what I know: macOS 26.","delayMs":1}"#,
                                    tools: [Self.stubSearch(available: false), ScriptedTools.getTime()], selection: .standard)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What's the latest macOS version?")
        _ = try await h.log.waitFinished(a, timeout: .seconds(30))
        let acts = try h.activities(a)
        #expect(acts.contains { $0.kind == .notice && $0.tool == "network.offlineForSearch" })
        let reqs = await h.controller.requests
        #expect(!(reqs.first?.tools ?? []).contains { WebSearchTools.names.contains($0.name) })
        let prov = try h.database.read { try MessageRecord.fetchOne($0, key: a) }?.provenance
        #expect(prov?.sources == nil)
    }

    @Test func readURLChipForcesReadURL() {
        #expect(ChipOverride.toolName(forChip: "readUrl") == "read_url")
        let offered = [ToolSchema(name: "web_search", description: "", parametersJSON: "{}"),
                       ToolSchema(name: "read_url", description: "", parametersJSON: "{}")]
        #expect(ChipOverride.forcedTool(chips: ["readUrl", "web"], offered: offered) == "read_url")
    }

    @Test func menuRowFollowsTheSearchState() {
        func web(_ s: WebSearchAvailability.State?) -> ComposerMenuItem? {
            var c = ComposerMenuContext(activeModelKey: "chat-9b-q4")
            c.webSearch = s
            return SlashCommandRegistry.addItems(c).first { $0.id == "web" }
        }
        #expect(web(nil) == nil, "no web tool registered: no row (M1 behaviour)")
        #expect(web(.available)?.state == .enabled)
        #expect(web(.switchedOff)?.state == .needsConsent && web(.switchedOff)?.state.isPickable == true)
        #expect(web(.offlineOnly)?.state == .offline && web(.noNetwork)?.state == .offline)
        var starter = ComposerMenuContext(activeModelKey: "chat-0.8b")
        starter.webSearch = .available
        #expect(!SlashCommandRegistry.addItems(starter).contains { $0.id == "web" }, "D-023: none for the chat-only starter")
    }

    @Test func searchPlanNormalisesTheForcedCall() {
        #expect(SearchPlan.make(arguments: #"{"queries":[" a ","A","b","c"]}"#, maxQueries: 2)?.queries == ["a", "b"])
        #expect(SearchPlan.make(arguments: #"{"query":"one"}"#, maxQueries: 2)?.queries == ["one"])
        #expect(SearchPlan.make(arguments: #"{"queries":[]}"#, maxQueries: 2, fallback: "user words")?.queries == ["user words"])
        #expect(SearchPlan.make(arguments: "not json", maxQueries: 2) == nil)
        #expect(SearchPlan.make(arguments: #"{"queries":["x"],"freshness":"week","category":"sports"}"#, maxQueries: 1)
            == SearchPlan(queries: ["x"], freshness: "week", category: nil))
    }
}

/// A model that ignores `tool_choice`: request k answers with `replies[k]` as plain text, never a tool call.
final class TextRepliesEngine: EngineService, @unchecked Sendable {
    let replies: [String]
    private let lock = NSLock()
    private var n = 0
    init(_ replies: [String]) { self.replies = replies }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let k = lock.withLock { defer { n += 1 }; return n }
        let text = k < replies.count ? replies[k] : "…"
        return AsyncThrowingStream { c in
            c.yield(.textDelta(text))
            c.yield(.done(.stop))
            c.finish()
        }
    }
}
