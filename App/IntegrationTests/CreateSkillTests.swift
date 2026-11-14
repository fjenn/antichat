// AT-264 (R-264 AC1; M7.T13 step 5), real model: "Build me a skill that turns my notes into a weekly status email" on
// T1 (chat-9b-q4) through the app's turn path. Pass: the reply carries a SkillInstallCard (`create_skill` call) whose
// SKILL.md passes SkillValidator; [Install] (CreateSkillTool.install, on for the chat); the next turn's prompt dump lists
// the skill in `<available_skills>` and `load_skill` succeeds. The installed folder is copied to
// build/at/AT-264/real/<name>/ for tools/ci/skills-ref-validate.sh.
// Run: make test-integration-real TIER=T1 FILTER=CreateSkillTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class CreateSkillTests: XCTestCase {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCreateByChatRealModel() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else {
            throw XCTSkip("ANTICHAT_TIER must be T1 (make test-integration-real TIER=T1)")
        }
        let dir = PrefixReuseTests.view("chat-9b-q4")
        guard FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("chat-9b-q4 not fetched") }
        let slot = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: dir.path)
        let client = EngineClient(appBuild: "it-create-skill")
        defer { client.disconnect() }
        try await client.ensureConnected()
        try await client.setPolicy(SetPolicy(budgetB: UInt64(9.5e9)))
        if let err = await client.warmup(slot) { throw err }

        let db = try AppDatabase.inMemory()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("create-skill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = SkillStore(root: work.appendingPathComponent("Skills"), database: db)
        _ = try StarterSkills.installIfNeeded(into: store)
        let dumps = work.appendingPathComponent("prompts")
        PromptDump.directory = dumps.path
        defer { PromptDump.directory = nil }
        let chat = try ChatRepository(db).create().id
        func controller() -> TurnController {
            var runtime = ToolRuntime(registry: ToolRegistry([ScriptedTools.getTime()]), policy: .forTier(.t1), selection: .standard, tier: { .t1 })
            runtime.skills = store
            runtime.skillSelector = SkillSelector(embed: nil)
            runtime.skillScripts = SkillScriptPolicy(fileToolsInstalled: { false }, runCodeEnabled: { false })
            return TurnController(chatID: chat, database: db, engine: client,
                                  sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: 1500, seed: 7),
                                  contextPolicy: ContextPolicy(windowOverride: 16_384), tools: runtime) { slot }
        }
        var log = ["AT-264 CreateSkillTests (real, T1 chat-9b-q4) \(Date())"]
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        defer {  // written on failure too (diagnostics)
            let path = Self.repoRoot.appendingPathComponent("build/at/AT-264/\(day)-real.log")
            try? (log.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        }
        func send(_ c: TurnController, _ text: String) async -> (String, [ToolActivity]) {
            let a = StorageID.make()
            let done = Task { () -> ([ToolActivity], String) in
                var acts: [String: ToolActivity] = [:]
                var reply = ""
                for await u in c.updates where u.assistantID == a {
                    if case .activity(let t) = u.kind { acts[t.id] = t }
                    if case .textDelta(let d) = u.kind { reply += d }
                    if case .finished = u.kind { break }
                }
                return (Array(acts.values), reply)
            }
            await c.start(.send(userID: StorageID.make(), text: text, parentID: nil), assistantID: a)
            let (acts, reply) = await done.value
            log.append("reply \(a): \(reply.prefix(1200))")
            return (a, acts)
        }

        let c1 = controller()
        let (a1, acts1) = await send(c1, "Build me a skill that turns my notes into a weekly status email")
        let offered = (await c1.requests.first?.tools ?? []).map(\.name)
        log.append("turn 1 offered tools: \(offered.sorted())")
        log.append("turn 1 activities: \(acts1.map { "\($0.kind.rawValue):\($0.tool):\($0.state.rawValue)" }.sorted())")
        let card = try XCTUnwrap(acts1.first { $0.kind == .skillCard && $0.state == .done }, "no SkillInstallCard (create_skill call)")
        let draft = try XCTUnwrap(CreateSkillTool.draft(card.argumentsJSON))
        XCTAssertTrue(CreateSkillTool.problems(card.argumentsJSON).isEmpty, "SkillValidator findings")
        log.append("draft SKILL.md:\n\(draft.markdown)")
        let installed = try CreateSkillTool.install(draft, into: store)
        _ = try ChatRepository(db).setToolsJSON(chat, #"["\#(SkillTools.onMarker(installed.name))"]"#)
        XCTAssertTrue(installed.isValid)
        let out = Self.repoRoot.appendingPathComponent("build/at/AT-264/real/\(installed.name)")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.directory(for: installed.name), to: out)

        let c2 = controller()
        let (a2, acts2) = await send(c2, "Here are my notes for this week: shipped the login fix, started the billing page, blocked on API keys. Turn them into my weekly status email.")
        let dump = try String(contentsOf: dumps.appendingPathComponent("\(a2).txt"), encoding: .utf8)
        let listed = SkillManifestBlock.names(in: dump)
        log.append("turn 2 manifest: \(listed)")
        let loadedByModel = acts2.contains { $0.kind == .skill && $0.tool == installed.name }
        log.append("turn 2 activities: \(acts2.map { "\($0.kind.rawValue):\($0.tool):\($0.state.rawValue)" }.sorted())")
        XCTAssertTrue(listed.contains(installed.name) || loadedByModel, "the new skill is offered on the next turn")
        // load_skill succeeds for it (the model's own call, else the tool directly in a turn ledger).
        var loadOK = loadedByModel
        if !loadOK {
            let plan = await c2.lastSkillPlan
            if let plan {
                SkillTools.begin(turn: "direct", plan: plan, store: store)
                let r = try? await TurnContext.$requestID.withValue("direct") {
                    try await SkillTools.loadTool().run(#"{"name":"\#(installed.name)"}"#)
                }
                SkillTools.end(turn: "direct")
                loadOK = r?.hasPrefix("<skill name=\"\(installed.name)\">") ?? false
            }
        }
        XCTAssertTrue(loadOK)
        log.append("load_skill: \(loadOK ? (loadedByModel ? "called by the model" : "direct call succeeded (model answered without it)") : "FAILED")")
        log.append("reply ids: \(a1), \(a2)")
        log.append("PASS")
    }
}
