// M7.T06 AT-081 c2/c3 at the turn level (journey 12 with the scripted MCP fixture; the XCUITest legs
// ConnectionsUITests / ToolApprovalUITests are pending Q-015): a connected server's tools are offered as
// `team_chat_*`; a write call (`send_message`, destructiveHint) shows the ApprovalCard and waits with no timeout
// auto-approve; Block removes the tool's schema from the rendered prompt (`-DumpPrompts`, PromptDump); the per-chat
// toggle (marker `conn.off:<server>` in `chat.tools_json`) hides the server's tools in that chat only; Offline only
// (`.mcp` off) hides them everywhere; results are untrusted.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct MCPTurnTests {
    static let fixtures: URL = {
        if let e = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !e.isEmpty { return URL(fileURLWithPath: e) }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("fixtures")
    }()
    static let jsonl = (try? String(contentsOf: fixtures.appendingPathComponent("web/mcp/scripted-server.jsonl"), encoding: .utf8)) ?? ""

    static let sendScript = """
        {"t":"toolCallDone","id":"call_1","name":"team_chat_send_message","args":"{\\"channel\\":\\"general\\",\\"text\\":\\"hi\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Done.","delayMs":1}
        """

    struct Env {
        let database: AppDatabase
        let chatID: String
        let registry: ToolRegistry
        let controller: TurnController
        let log: UpdateLog
        let host: MCPHost
        let server: MCPServerRecord
        let policy: NetworkPolicyStore

        init(script: String, block: Bool = false, chatOff: Bool = false) async throws {
            database = try AppDatabase.inMemory()
            policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
            host = MCPHost(database: database, secrets: MemorySecrets(), makeTransport: MCPHost.scriptedFactory(jsonl: MCPTurnTests.jsonl),
                           policy: policy)
            server = try await host.add(name: "Team Chat", url: URL(string: "https://chat.example/mcp")!, auth: .none)
            registry = ToolRegistry([ScriptedTools.getTime()])
            let permissions = ToolPermissionStore(database)
            if block { try permissions.set(.block, toolKey: MCPToolRecord.permissionKey(server: server.id, tool: "send_message")) }
            let set = MCPTools.install(into: registry, database: database, host: host, tier: { "T1" }, resume: false).tools
            var runtime = ToolRuntime(registry: registry, permissions: permissions, policy: .forTier(.t1), selection: .off,
                                      tier: { .t1 })
            runtime.chatFilter = MCPTools.filter(set, permissions: permissions, policy: policy)
            chatID = try ChatRepository(database).create().id
            if chatOff { _ = try ChatRepository(database).setToolsJSON(chatID, #"["\#(MCPTools.offMarker(server.id))"]"#) }
            controller = TurnController(chatID: chatID, database: database, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                        tools: runtime) { .scripted("inline") }
            log = UpdateLog(controller)
        }

        func send() async -> String {
            let a = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: "Tell the team hi.", parentID: nil), assistantID: a)
            return a
        }

        func pendingApproval(_ id: String) -> ToolApprovalRequest? {
            var last: ToolApprovalRequest?
            for u in log.all where u.assistantID == id { if case .approval(let r) = u.kind { last = r } }
            return last
        }
    }

    static func dump(_ id: String, in dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("\(id).txt"), encoding: .utf8)) ?? ""
    }

    @Test func writeCallShowsTheCardAndWaitsWithoutTimeout() async throws {
        let e = try await Env(script: Self.sendScript)
        #expect(e.registry.tool(named: "team_chat_send_message")?.sideEffect == .write)
        #expect(e.registry.tool(named: "team_chat_search_messages")?.defaultPolicy == .ask, "not curated: Ask")
        let a = await e.send()
        try await e.log.wait { _ in e.pendingApproval(a) != nil }
        let card = try #require(e.pendingApproval(a))
        #expect(card.tool == "team_chat_send_message" && card.sideEffect == .write)
        // No timeout auto-approve: the card is still pending after a wait (the turn would otherwise have finished).
        try await Task.sleep(for: .milliseconds(1500))
        #expect(e.pendingApproval(a) != nil && e.registry.invocations(of: "team_chat_send_message") == 0)
        await e.controller.answerApproval(callID: card.id, .allowOnce)
        let r = try await e.log.waitFinished(a)
        #expect(r.text == "Done.")
        let result = try MessageRepository(e.database).parts(of: a).first { $0.kind == .toolResult }?.body ?? ""
        #expect(result.contains("Sent to #general.") && result.contains(#"untrusted=\"true\""#))
    }

    @Test func blockedToolHasNoSchemaInThePrompt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("at081-\(UUID().uuidString)")
        PromptDump.directory = dir.path
        defer { PromptDump.directory = nil }
        let open = try await Env(script: #"{"t":"textDelta","v":"Ok.","delayMs":1}"#)
        let a1 = await open.send()
        _ = try await open.log.waitFinished(a1)
        #expect(Self.dump(a1, in: dir).contains("team_chat_send_message"))
        let blocked = try await Env(script: #"{"t":"textDelta","v":"Ok.","delayMs":1}"#, block: true)
        let a2 = await blocked.send()
        _ = try await blocked.log.waitFinished(a2)
        let text = Self.dump(a2, in: dir)
        #expect(!text.contains("team_chat_send_message") && text.contains("team_chat_search_messages"))
        // AT-081 c2 evidence (build/at/AT-081/prompt-block.txt) when the repo's build dir is reachable.
        if let out = ProcessInfo.processInfo.environment["AT081_OUT"] {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: URL(fileURLWithPath: out).appendingPathComponent("prompt-block.txt"))
        }
    }

    @Test func perChatToggleHidesTheServerInThatChatOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("at081c3-\(UUID().uuidString)")
        PromptDump.directory = dir.path
        defer { PromptDump.directory = nil }
        let off = try await Env(script: #"{"t":"textDelta","v":"Ok.","delayMs":1}"#, chatOff: true)
        let a = await off.send()
        _ = try await off.log.waitFinished(a)
        #expect(!Self.dump(a, in: dir).contains("team_chat_"))
        let on = try await Env(script: #"{"t":"textDelta","v":"Ok.","delayMs":1}"#)
        let b = await on.send()
        _ = try await on.log.waitFinished(b)
        #expect(Self.dump(b, in: dir).contains("team_chat_search_messages"))
    }

    @Test func offlineOnlyHidesEveryConnectionTool() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("at081off-\(UUID().uuidString)")
        PromptDump.directory = dir.path
        defer { PromptDump.directory = nil }
        let e = try await Env(script: #"{"t":"textDelta","v":"Ok.","delayMs":1}"#)
        e.policy.offlineOnly = true
        let a = await e.send()
        let r = try await e.log.waitFinished(a)
        #expect(r.text == "Ok." && !Self.dump(a, in: dir).contains("team_chat_"))
    }
}
