// M9 review H8: an incognito chat follows the user's tool decisions exactly like a normal chat. A Blocked MCP tool is
// not offered (and a call to it is refused), a disabled server's tools are absent, and a stored Ask still asks — also
// for a curated read-only tool whose default is Always. The decisions are read from the app's store; answering
// "Always allow" in incognito writes nothing there.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct IncognitoToolPermissionTests {
    static let serverURL = "https://chat.example/mcp"

    struct Env {
        let appDB: AppDatabase
        let host: MCPHost
        let server: MCPServerRecord
        let registry: ToolRegistry
        let session: IncognitoSession
        let root: URL

        init(script: String, curated: Bool = false, setUp: (ToolPermissionStore, MCPServerRecord) throws -> Void = { _, _ in }) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("incognito-h8-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            appDB = try AppDatabase.inMemory()
            let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
            host = MCPHost(database: appDB, secrets: MemorySecrets(), makeTransport: MCPHost.scriptedFactory(jsonl: MCPTurnTests.jsonl),
                           policy: policy)
            let store = MCPCurated.Store()
            if curated {
                let entry = MCPCuratedEntry(id: "team-chat", name: "Team Chat", url: IncognitoToolPermissionTests.serverURL,
                                            auth: "none", category: "Work", tagline: "", icon: "")
                store.apply(catalogJSON: try JSONSerialization.data(withJSONObject: [
                    "schema": 2, "mcp_curated": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))]]))
            }
            server = try await host.add(name: "Team Chat", url: URL(string: IncognitoToolPermissionTests.serverURL)!, auth: .none,
                                        curatedID: curated ? "team-chat" : nil)
            registry = ToolRegistry([ScriptedTools.getTime()])
            let permissions = ToolPermissionStore(appDB)
            try setUp(permissions, server)
            let set = MCPTools.install(into: registry, database: appDB, host: host, tier: { "T1" }, curated: store, resume: false).tools
            var runtime = ToolRuntime(registry: registry, permissions: permissions, policy: .forTier(.t1), selection: .off, tier: { .t1 })
            runtime.chatFilter = MCPTools.filter(set, permissions: permissions, policy: policy)
            let engine = InProcessScriptedEngine(script: try EngineScript(text: script))
            let app = ChatEnvironment(database: appDB, engine: engine, tools: runtime, slot: { .scripted("inline") })
            session = try IncognitoSession(app: app, tempRoot: root)
        }

        func close() {
            session.discard()
            try? FileManager.default.removeItem(at: root)
        }

        func key(_ tool: String) -> String { MCPToolRecord.permissionKey(server: server.id, tool: tool) }
    }

    struct Turn {
        let controller: TurnController
        let log: UpdateLog
        let assistantID: String

        static func send(_ e: Env) async throws -> Turn {
            let controller = e.session.environment.controller(chatID: try e.session.createChat())
            let log = UpdateLog(controller)
            let a = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: "Tell the team hi.", parentID: nil), assistantID: a)
            return Turn(controller: controller, log: log, assistantID: a)
        }

        var approval: ToolApprovalRequest? {
            var last: ToolApprovalRequest?
            for u in log.all where u.assistantID == assistantID { if case .approval(let r) = u.kind { last = r } }
            return last
        }

        func offered() async -> [String] { await controller.lastPrompt?.tools.map(\.name) ?? [] }
    }

    static let reply = #"{"t":"textDelta","v":"Ok.","delayMs":1}"#

    @Test func blockedToolIsNotOfferedOrRunInIncognito() async throws {
        let e = try await Env(script: """
            {"t":"toolCallDone","id":"call_1","name":"team_chat_send_message","args":"{\\"channel\\":\\"general\\",\\"text\\":\\"hi\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Done.","delayMs":1}
            """) { p, s in try p.set(.block, toolKey: MCPToolRecord.permissionKey(server: s.id, tool: "send_message")) }
        defer { e.close() }
        #expect(e.session.environment.tools?.chatFilter != nil)
        let t = try await Turn.send(e)
        _ = try await t.log.waitFinished(t.assistantID)
        let offered = await t.offered()
        #expect(!offered.contains("team_chat_send_message"), "Blocked: no schema in the incognito prompt")
        #expect(offered.contains("team_chat_search_messages"))
        #expect(t.approval == nil && e.registry.invocations(of: "team_chat_send_message") == 0, "a forced call is refused, not run")
        let result = try MessageRepository(e.session.store).parts(of: t.assistantID).first { $0.kind == .toolResult }?.body ?? ""
        #expect(!result.contains("Sent to"), "the un-offered call takes the unknown-tool path, never the server")
        // The permission layer refuses it too (Block read through from the app's store).
        let layered = try #require(e.session.environment.tools?.permissions)
        #expect(try layered.policy(toolKey: e.key("send_message"), chatID: nil) == .block)
    }

    @Test func disabledServerToolsAreAbsentInIncognito() async throws {
        let e = try await Env(script: Self.reply)
        defer { e.close() }
        await e.host.setEnabled(e.server.id, false)
        let t = try await Turn.send(e)
        _ = try await t.log.waitFinished(t.assistantID)
        let offered = await t.offered()
        #expect(!offered.contains { $0.hasPrefix("team_chat_") })
        #expect(offered.contains("get_time"), "the other tools are still offered")
    }

    @Test func storedAskStillAsksInIncognitoForACuratedReadTool() async throws {
        let e = try await Env(script: """
            {"t":"toolCallDone","id":"call_1","name":"team_chat_search_messages","args":"{\\"query\\":\\"launch\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Thursday.","delayMs":1}
            """, curated: true) { p, s in try p.set(.ask, toolKey: MCPToolRecord.permissionKey(server: s.id, tool: "search_messages")) }
        defer { e.close() }
        #expect(e.registry.tool(named: "team_chat_search_messages")?.defaultPolicy == .always, "curated read-only: Always by default")
        let t = try await Turn.send(e)
        try await t.log.wait { _ in t.approval != nil }
        let card = try #require(t.approval)
        #expect(card.tool == "team_chat_search_messages")
        #expect(e.registry.invocations(of: "team_chat_search_messages") == 0, "nothing runs before the answer")
        await t.controller.answerApproval(callID: card.id, .always)
        let r = try await t.log.waitFinished(t.assistantID)
        #expect(r.text == "Thursday.")
        // "Always allow" in incognito lives in the session's memory only: the app's row is still Ask.
        let key = e.key("search_messages")
        #expect(try ToolPermissionStore(e.appDB).policy(toolKey: key, chatID: nil) == .ask)
        #expect(try ToolPermissionStore(e.session.store).policy(toolKey: key, chatID: nil) == .always)
    }

    @Test func layeredStoreReadsThroughAndWritesOnlyTheSession() throws {
        let app = try AppDatabase.inMemory(), session = try AppDatabase.inMemory()
        try ToolPermissionStore(app).set(.block, toolKey: "k")
        let layered = ToolPermissionStore(session, readThrough: app)
        #expect(try layered.policy(toolKey: "k", chatID: "c") == .block)
        #expect(try layered.policy(toolKey: "other", chatID: nil) == nil)
        try layered.set(.always, toolKey: "other")
        #expect(try layered.policy(toolKey: "other", chatID: nil) == .always)
        #expect(try ToolPermissionStore(app).policy(toolKey: "other", chatID: nil) == nil)
    }
}
