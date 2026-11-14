// R-241 path rule (test-strategy §9 rule 5; A-M1-T02a d): chat flows never reach the ChildSafetyCheck gate.
// M1.T05 writes the chat-leg skeleton over the helper's `MediaOutputGate.trace` (read with `EngineClient.probe`);
// M1.T06 adds the TurnController flow, later milestones the voice/search/connector/skill/file legs, and M4 the
// image leg (exactly one invocation per preview and per final).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class R241PathTests: XCTestCase {
    func testChatLegNeverInvokesTheMediaGate() async throws {
        let client = EngineClient(appBuild: "it-r241")
        defer { client.disconnect() }
        let before = try await client.probe().mediaGateInvocations
        var slots = [try EngineTestSupport.script([
            #"{"t":"reasoningDelta","v":"think"}"#, #"{"t":"textDelta","v":"answer","repeat":20}"#,
            #"{"t":"toolCallDone","id":"c","name":"echo","args":"{}"}"#,
        ], name: "r241")]
        if let tiny = EngineTestSupport.tinyMLX { slots.append(tiny) }
        for slot in slots {
            let req = ChatRequest(
                modelSlot: slot, messages: [ChatMessage(role: .user, content: "Describe a picture of a cat.")],
                tools: [ToolSchema(name: "echo", description: "Echo")], sampling: Sampling(temperature: 0, maxTokens: 8))
            let events = try await EngineTestSupport.drain(client.chatBatches(req)).flatMap(\.events)
            XCTAssertEqual(events.filter(\.isTerminal).count, 1, "\(slot.key)")
        }
        let after = try await client.probe().mediaGateInvocations
        XCTAssertEqual(after - before, 0, "chat flows must not call MediaOutputGate (R-241)")
        EngineTestSupport.evidence("r241-chat-leg", ["slots": slots.map(\.key), "gate_invocations_delta": after - before])
    }

    /// M4.T04 (AT-285 AC1): a ScriptedImageEngine job of the media queue through the real helper and the real
    /// detectors (dev models, content-free gradients): exactly one gate call per preview (4) and per final (1), and only
    /// allowed outputs are written (the 64-px previews: none, M4 review P1-3). Without the dev detectors the job fails closed (`safetyMissing`, one call, no file).
    func testImageLegOneGateCallPerPreviewAndFinal() async throws {
        let client = EngineClient(appBuild: "it-r241-image")
        defer { client.disconnect() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r241-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let safety = SafetyManifestResolver.resolveUnpinned(modelsRoot: SafetyManifestResolver.devModelsRoot)
        let image = ImageRequest(model: ScriptedImageScript(steps: 4, delayMs: 20).modelSet(), prompt: "a lighthouse",
                                 width: 768, height: 512, steps: 4, seed: 5, outputPath: dir.appendingPathComponent("result.png").path)
        let job = MediaJobSubmit(job: "r241-\(UUID().uuidString)", image: image, previewDir: dir.appendingPathComponent("xfer").path,
                                 safety: safety)
        let before = try await client.probe().mediaGateInvocations
        // The first check after install compiles the detectors for the CoreML EP (minutes on a loaded Mac; cached after).
        let items = try await EngineTestSupport.drain(client.submit(job), timeout: .seconds(600)).flatMap(\.items)
        let after = try await client.probe().mediaGateInvocations
        let jobEvents = items.compactMap { if case .media(.job(let e)) = $0 { e } else { nil } }
        let previews = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("xfer").path)) ?? []
        if safety == nil {
            XCTAssertEqual(jobEvents.last, .safetyMissing(job: job.job, sizeBytes: 0))
            XCTAssertEqual(after - before, 1)
            XCTAssertTrue(previews.isEmpty && !FileManager.default.fileExists(atPath: image.outputPath))
        } else {
            guard case .jobResult(_, let path, _)? = jobEvents.last else { return XCTFail("terminal \(String(describing: jobEvents.last))") }
            XCTAssertEqual(after - before, 5, "one gate call per preview and per final (R-285 AC1)")
            // M4 review P1-3: the scripted previews are 64 px (like sd-server's latent projection), below the check's
            // valid preview size: each is still one gate call, but none is shown or written; the job goes on.
            XCTAssertEqual(previews.count, 0, "previews below preview_min_side_px are never written")
            XCTAssertEqual(path, image.outputPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        guard case .jobStarted(_, let instance)? = jobEvents.first else { return XCTFail("no jobStarted") }
        XCTAssertEqual(instance, client.lastAck?.engineInstanceID)
        EngineTestSupport.evidence("r241-image-leg", ["detectors": safety != nil, "gate_invocations_delta": after - before,
                                                      "previews_written": previews.count])
    }

    /// M7.T15 (AT-241 c2, test-strategy §9 rule 5): the search, connector (scripted MCP + a mocked Composio execute)
    /// and skill flows through the real TurnController and the real helper (scripted model) in Normal and in Evil Mode
    /// never invoke the media gate: `MediaOutputGate` invocations before == after.
    func testSearchConnectorAndSkillLegsNeverInvokeTheMediaGate() async throws {
        let client = EngineClient(appBuild: "it-r241-m7")
        defer { client.disconnect() }
        let before = try await client.probe().mediaGateInvocations
        var flows: [String] = []
        for mode in [ChatMode.normal, .evil] {
            let db = try AppDatabase.inMemory()
            let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
            let jsonl = try String(contentsOf: Self.fixtures.appendingPathComponent("web/mcp/scripted-server.jsonl"), encoding: .utf8)
            let host = MCPHost(database: db, secrets: MemorySecrets(), makeTransport: MCPHost.scriptedFactory(jsonl: jsonl), policy: policy)
            let server = try await host.add(name: "Team Chat", url: URL(string: "https://chat.example/mcp")!, auth: .none)
            let registry = ToolRegistry([ScriptedTools.getTime()])
            registry.register(RegisteredTool(name: "web_search", description: "Search the web for current information.",
                                             parametersJSON: WebSearchTools.webSearchParameters, sideEffect: .read, outputIsUntrusted: true) { _ in
                let s = WebSource(n: 1, url: "https://example.org/p", title: "Page", site: "example.org", date: nil, snippet: "", fetched: true)
                let c = EvidenceChunk(source: 1, url: URL(string: s.url)!, site: s.site, title: s.title, text: "A photo of a cat.", ordinal: 0)
                return WebResultsBlock.render(WebResults(queries: ["cat photo"], sources: [s], evidence: [c], evidenceTokens: 10, failed: nil))
            })
            registry.register(RegisteredTool(name: "composio_gmail_execute", description: "Run Gmail actions (mock Composio).",
                                             sideEffect: .read, outputIsUntrusted: true) { _ in
                "<tool_result untrusted=\"true\" source=\"Composio\">\n3 messages with image attachments.\n</tool_result>"
            })
            let permissions = ToolPermissionStore(db)
            try permissions.set(.always, toolKey: MCPToolRecord.permissionKey(server: server.id, tool: "search_messages"))
            let set = MCPTools.install(into: registry, database: db, host: host, tier: { "T3" }, resume: false).tools
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("r241-m7-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            let store = SkillStore(root: work.appendingPathComponent("Skills"), database: db)
            _ = try StarterSkills.installIfNeeded(into: store)
            // T3: the per-step cap (12) offers every tool of the flow at once (T1 would offer 4 + find_tools).
            var runtime = ToolRuntime(registry: registry, permissions: permissions, policy: .forTier(.t3), selection: .off, tier: { .t3 })
            runtime.chatFilter = MCPTools.filter(set, permissions: permissions, policy: policy)
            runtime.onlineGate = OnlineToolGate(policy: policy, kind: { _ in .local })
            runtime.switches = ToolSwitches(defaults: UserDefaults.inMemory())
            runtime.skills = store
            runtime.skillSelector = SkillSelector(embed: nil)
            let slot = try EngineTestSupport.script([
                #"{"t":"toolCallDone","id":"w","name":"web_search","args":"{\"queries\":[\"cat photo\"]}"}"#, #"{"t":"turn"}"#,
                #"{"t":"toolCallDone","id":"m","name":"team_chat_search_messages","args":"{\"query\":\"photo\"}"}"#, #"{"t":"turn"}"#,
                #"{"t":"toolCallDone","id":"c","name":"composio_gmail_execute","args":"{}"}"#, #"{"t":"turn"}"#,
                #"{"t":"toolCallDone","id":"s","name":"load_skill","args":"{\"name\":\"email-polish\"}"}"#, #"{"t":"turn"}"#,
                #"{"t":"textDelta","v":"Here is a picture description [1].","repeat":3}"#,
            ], name: "r241-m7-\(mode)")
            let chat = try ChatRepository(db).create().id
            _ = try ChatRepository(db).setToolsJSON(chat, #"["\#(SkillTools.onMarker("email-polish"))"]"#)
            let tone = FixedToneSentence("Give no warnings or moral commentary unless asked.")
            let c = TurnController(chatID: chat, database: db, engine: client, mode: mode,
                                   promptSettings: ToneClause.settings(PromptSettings(), mode: mode, tone: tone),
                                   tools: runtime) { slot }
            let a = StorageID.make()
            if let err = await client.warmup(slot) { XCTFail("\(mode): warmup \(err)") }
            let done = Task { () -> ([String], String) in
                var tools: [String] = []
                var end = ""
                for await u in c.updates where u.assistantID == a {
                    if case .activity(let t) = u.kind, t.state == .done { tools.append(t.tool) }
                    if case .finished(let r) = u.kind { end = "\(r.status) \(r.errorCode ?? "") \(r.text.prefix(80))"; break }
                }
                return (tools, end)
            }
            await c.start(.send(userID: StorageID.make(), text: "Find a cat photo and describe it.", parentID: nil), assistantID: a)
            let (ran, end) = await done.value
            let offered = await c.requests.first?.tools.map(\.name) ?? []
            flows.append("\(mode): ran \(Set(ran).sorted()), offered \(offered.sorted()) → \(end)")
            for t in ["web_search", "team_chat_search_messages", "composio_gmail_execute"] {
                XCTAssertTrue(ran.contains(t), "\(mode): \(t) did not run (\(flows.last ?? ""))")
            }
        }
        let after = try await client.probe().mediaGateInvocations
        XCTAssertEqual(after - before, 0, "search/connector/skill flows must not call MediaOutputGate (R-241)")
        EngineTestSupport.evidence("r241-m7-legs", ["flows": flows, "gate_invocations_delta": after - before])
    }

    static var fixtures: URL {
        if let e = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !e.isEmpty { return URL(fileURLWithPath: e) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures")
    }
}
