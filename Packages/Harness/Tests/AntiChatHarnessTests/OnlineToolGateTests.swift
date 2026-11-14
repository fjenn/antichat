// AT-267 (R-267 AC1) — M7.T14 step 4: offline (Offline only, or no network path) or with the feature off, the rendered
// prompt (`-DumpPrompts` text, PromptDump) carries no `web_search`, `read_url`, remote MCP or Composio schema; local
// tools are untouched, and 50 offline turns end with zero failed tool calls (the model only sees tools that work).
// The composer-chip half ("Offline") is the UI module's (WebSearchUITests / ToolsSubmenuTests; XCUITest
// ToolsPageUITests.testOfflineChipsAndNoSchemas pending Q-015).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct OnlineToolGateTests {
    static let online: Set<String> = ["web_search", "read_url", "team_chat_send_message", "team_chat_search_messages",
                                      "composio_composio_search_tools", "composio_composio_multi_execute_tool"]
    static let local = ["get_time", "create_image", "create_document", "create_chart"]  // memory needs a MemoryRuntime

    static func kind(_ name: String) -> OnlineToolGate.Kind {
        if WebSearchTools.names.contains(name) { return .web }
        if name.hasPrefix("team_chat_") { return .mcp }
        if name.hasPrefix("composio_") { return .relay }
        return .local
    }

    static func tools() -> [RegisteredTool] {
        (Array(online) + local).sorted().map { n in
            RegisteredTool(name: n, description: "Tool \(n.replacingOccurrences(of: "_", with: " ")).",
                           parametersJSON: #"{"type":"object","properties":{}}"#, outputIsUntrusted: false) { _ in "ok" }
        }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var offlineOnly = false
        var path = "ok"
        var off: [NetworkCategory] = []
        /// The online tools that must stay (feature-off cases keep the other kinds).
        var keeps: Set<String> = []
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "offline only", offlineOnly: true),
        Case(name: "no network path", path: "none"),
        Case(name: "web search off", off: [.search], keeps: online.filter { !WebSearchTools.names.contains($0) }),
        Case(name: "mcp off", off: [.mcp], keeps: online.filter { !$0.hasPrefix("team_chat_") }),
        Case(name: "relay off", off: [.relay], keeps: online.filter { !$0.hasPrefix("composio_") }),
    ]

    static func gate(_ c: Case) -> OnlineToolGate {
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        for cat in [NetworkCategory.search, .mcp, .relay] { policy.setEnabled(cat, !c.off.contains(cat)) }
        if c.offlineOnly { policy.offlineOnly = true }
        return OnlineToolGate(policy: policy, path: PathStatus(fake: c.path), kind: { kind($0) })
    }

    @Test(arguments: cases)
    func promptHasNoUnavailableOnlineSchema(_ c: Case) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "at267-\(UUID().uuidString)")
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"ok","delayMs":0}"#, tier: .t4, tools: Self.tools(),
                                    selection: .standard) { rt in rt.onlineGate = Self.gate(c) }
        let (_, a) = await h.send("search the web and post the result to the team chat, then email it via gmail")
        _ = try await h.log.waitFinished(a)
        let offered = Set(await h.controller.requests[0].tools.map(\.name))
        let prompt = try #require(await h.controller.lastPrompt)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dump = PromptDump.text(prompt)
        try dump.write(to: dir.appending(path: "\(a).txt"), atomically: true, encoding: .utf8)
        for n in Self.online.subtracting(c.keeps) {
            #expect(!offered.contains(n), "\(c.name): \(n) offered")
            #expect(!dump.contains("\"name\":\"\(n)\""), "\(c.name): \(n) in the dumped prompt")
        }
        for n in c.keeps { #expect(offered.contains(n), "\(c.name): \(n) missing") }
        for n in Self.local { #expect(offered.contains(n), "\(c.name): local \(n) missing") }
    }

    /// 50 offline turns: each step's offered tools all work, so no call fails; the model that tries an online tool
    /// anyway (scripted) is not offered it and the turn still answers.
    @Test func fiftyOfflineTurnsHaveZeroFailedToolCalls() async throws {
        let script = """
            {"t":"toolCallDone","id":"c1","name":"get_time","args":"{}","delayMs":0}
            {"t":"turn"}
            {"t":"textDelta","v":"It is noon.","delayMs":0}
            """
        let h = try ToolLoopHarness(script: script, tier: .t2, tools: Self.tools(), selection: .standard) { rt in
            rt.onlineGate = Self.gate(Case(name: "offline", offlineOnly: true))
        }
        var failed = 0, calls = 0
        for i in 0..<50 {
            let (_, a) = await h.send("turn \(i): what time is it, and look it up online too")
            _ = try await h.log.waitFinished(a)
            for act in try h.activities(a) where act.kind == .tool {
                calls += 1
                if act.state == .failed { failed += 1 }
            }
            #expect(try h.parts(a, .text).map(\.body).joined().contains("noon"))
        }
        for r in await h.controller.requests { #expect(Self.online.isDisjoint(with: r.tools.map(\.name))) }
        #expect(calls == 50 && failed == 0, "calls \(calls) failed \(failed)")
    }

    @Test func gateKindsFollowTheAppToolSet() {
        #expect(OnlineToolGate.kind(of: "web_search", mcp: MCPTools.ToolSet()) == .web)
        #expect(OnlineToolGate.kind(of: "create_image", mcp: MCPTools.ToolSet()) == .local)
        let g = Self.gate(Case(name: "online"))
        #expect(g.allows("web_search") && g.allows("team_chat_send_message") && g.allows("get_time"))
        #expect(g.filter(Self.tools().map(\.schema)).count == Self.tools().count)
    }
}
