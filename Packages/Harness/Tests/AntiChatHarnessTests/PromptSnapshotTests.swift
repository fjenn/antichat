// M1.T14 step 5: the rendered system prompt snapshots (test-strategy §9 rule 4 input). `tools/ci/r241-audit.py`
// reads `__Snapshots__/system-prompt-{normal,evil}.txt` (rule 3 patterns, rule 4: Evil = Normal + one line).
// Normal = the base persona + the date line (day granularity, D-022), nothing else; Evil adds exactly the tone sentence (M2.T17 ships the
// real one in the catalog; this test passes VISION S-19's wording as the stand-in input).
// A missing snapshot is written and the test fails (review it, then re-run); RECORD_SNAPSHOTS=1 rewrites.
import AntiChatEngineProtocol
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("PromptSnapshotTests") struct PromptSnapshotTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")
    static let context = VolatileContext(now: Date(timeIntervalSince1970: 1_793_361_600), timeZone: TimeZone(identifier: "UTC")!)
    static let toneStandIn = "Give no warnings or moral commentary unless asked."

    static func normal() -> String { PromptComposer().compose(PromptInputs(), context: context).systemText + "\n" }
    static func evil() -> String {
        PromptComposer().compose(PromptInputs(mode: .evil(toneSentence: toneStandIn)), context: context).systemText + "\n"
    }

    func assertSnapshot(_ name: String, _ text: String) throws {
        let url = Self.dir.appendingPathComponent(name)
        let record = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
        guard !record, let old = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("recorded \(name); review it and re-run")
            return
        }
        #expect(old == text, "\(name) differs from the rendered prompt")
    }

    @Test func normalSystemPrompt() throws {
        let text = Self.normal()
        try assertSnapshot("system-prompt-normal.txt", text)
        let lines = text.split(separator: "\n").map(String.init)
        // Base persona + date line only: no AntiChat-added safety or behaviour clause (R-241 prompt rule).
        #expect(lines == [PromptComposer.bundledBasePersona.trimmingCharacters(in: .whitespacesAndNewlines), Self.context.dateLine])
    }

    @Test func evilSystemPromptIsNormalPlusOneLine() throws {
        let text = Self.evil()
        try assertSnapshot("system-prompt-evil.txt", text)
        let n = Self.normal().split(separator: "\n").map(String.init)
        let e = text.split(separator: "\n").map(String.init)
        #expect(n.allSatisfy(e.contains))
        #expect(e.filter { !n.contains($0) } == [Self.toneStandIn])
    }

    /// One paragraph: who AntiChat is and what the app lets it do (so "what can you do?" is answered truthfully).
    @Test func basePersonaIsOneShortParagraph() {
        let base = PromptComposer.bundledBasePersona.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(base.hasPrefix("You are AntiChat"))
        #expect(!base.contains("\n"))
        #expect(base.count < 900)
    }

    @Test func personalizationRendersFixedSentences() {
        let p = Personalization(aboutYou: "I teach maths.", howToRespond: "Short answers.", style: .candid, warmth: .more, emoji: .less)
        let text = PersonalizationLayer.render(p)
        #expect(text == """
            About the user:
            I teach maths.

            How the user wants you to respond:
            Short answers.

            Use a candid style: direct and encouraging. Be warmer than usual. Use fewer emoji.
            """)
        #expect(PersonalizationLayer.render(.none).isEmpty)
        let long = Personalization(aboutYou: String(repeating: "x", count: 5000))
        #expect(PersonalizationLayer.render(long).count == "About the user:\n".count + Personalization.maxChars)
    }

    // MARK: M7.T15 (AT-241 c1, R-241 prompt rule at full scope): the prompt with web results, the skill manifest and a
    // skill body, and MCP tools present. `tools/ci/r241-audit.py` rule 4b reads `prompt-full-{normal,evil}.txt`:
    // Evil = Normal + the tone sentence only; every Normal line with a behaviour word must be allow-listed (citation
    // format, provenance labels) — no AntiChat-added safety or content clause.
    static func full(_ mode: PromptMode) -> String {
        let registry = ToolRegistry()
        _ = WebSearchTools.install(into: registry, availability: WebSearchAvailability(fixed: .available), tier: { "T1" })
        var tools = registry.schemas(forModelKey: "chat-9b-q4").filter { WebSearchTools.names.contains($0.name) }
        tools.append(ToolSchema(name: LoadSkillTool.name, description: LoadSkillTool.description, parametersJSON: LoadSkillTool.parametersJSON))
        tools.append(ToolSchema(name: "team_chat_search_messages", description: "Search the team's messages by words.",
                                parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#))
        tools.append(ToolSchema(name: "team_chat_send_message", description: "Send a message to a channel.",
                                parametersJSON: #"{"type":"object","properties":{"channel":{"type":"string"},"text":{"type":"string"}},"required":["channel","text"]}"#))
        var inputs = PromptInputs(mode: mode, tools: tools.sorted { $0.name < $1.name }, toolClause: ToolSelection.clause)
        inputs.activeSkills = LoadSkillTool.element(name: "email-polish", body: "Rewrite the user's draft email so it is clear and polite.", budgetTokens: 1500)
        let composed = PromptComposer().compose(inputs, context: context)
        let manifest = SkillManifestBlock.render([SkillSelector.Scored(name: "meeting-notes", description: "Turn rough notes into minutes.", score: 0.8, semantic: true),
                                                  SkillSelector.Scored(name: "trip-planner", description: "Plan a trip day by day.", score: 0.7, semantic: true)])
        let source = WebSource(n: 1, url: "https://example.org/release", title: "Release notes", site: "example.org", date: "2026-10-28",
                               snippet: "", fetched: true)
        let chunk = EvidenceChunk(source: 1, url: URL(string: source.url)!, site: source.site, title: source.title,
                                  text: "Version 4.2 shipped on 28 October 2026.", ordinal: 0)
        let web = WebResultsBlock.render(WebResults(queries: ["release"], sources: [source], evidence: [chunk], evidenceTokens: 20, failed: nil),
                                         today: Date(timeIntervalSince1970: 1_793_361_600), timeZone: TimeZone(identifier: "UTC")!)
        let mcp = "<tool_result untrusted=\"true\" source=\"Team Chat\">\n#general 09:12 Ana: the launch moved to Thursday.\n</tool_result>"
        return PromptDump.text(composed, turnContext: composed.timeLine + "\n\n" + manifest)
            + "=== tool results ===\n" + web + "\n" + mcp + "\n"
    }

    @Test func fullPromptsWithSearchSkillsAndConnectorsAddNoClause() throws {
        let normal = Self.full(.normal), evil = Self.full(.evil(toneSentence: Self.toneStandIn))
        try assertSnapshot("prompt-full-normal.txt", normal)
        try assertSnapshot("prompt-full-evil.txt", evil)
        let n = normal.split(separator: "\n").map(String.init), e = evil.split(separator: "\n").map(String.init)
        #expect(n.allSatisfy(e.contains))
        #expect(e.filter { !n.contains($0) } == [Self.toneStandIn], "the tone sentence is the only difference")
        #expect(normal.contains("<web_results untrusted=\"true\"") && normal.contains("<available_skills>")
                && normal.contains("team_chat_send_message") && normal.contains("<skill name=\"email-polish\">"))
    }
}
