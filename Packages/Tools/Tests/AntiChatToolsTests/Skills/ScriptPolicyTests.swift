// M7.T13 step 6 (R-265 AC1), the Tools side of AT-265: canRun = File tools installed ∧ Run code on; run_skill_script
// refuses without it and never starts a process itself — the File tools runner gets a read-only copy of the script.
// The turn-level leg (20 turns × 3 configs, child-process monitor, ProcessLauncher counter) is
// App/IntegrationTests/ScriptPolicyTests.swift.
import AntiChatStorage
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatTools

@Suite struct ScriptPolicyTests {
    final class FakeRunner: SkillScriptRunner, @unchecked Sendable {
        let calls = Mutex<[(String, String, Bool)]>([])
        func run(skill: String, script: URL, interpreter: String, arguments: [String], chatID: String) async throws -> SkillScriptResult {
            let readOnly = !FileManager.default.isWritableFile(atPath: script.path)
            calls.withLock { $0.append((script.lastPathComponent, interpreter, readOnly)) }
            return SkillScriptResult(exitCode: 0, stdout: "hello, \(arguments.first ?? "world") (sandbox)", stderr: "")
        }
    }

    static func withScript(_ t: TempSkillStore) throws -> InstalledSkill {
        try SkillImporter.install(try SkillImporter.inspect(ToolsFixtures.url("skills/with-script/hello-script")), into: t.store)
    }

    @Test func testCanRunNeedsBoth() {
        for (installed, on, expected) in [(false, false, false), (true, false, false), (false, true, false), (true, true, true)] {
            #expect(SkillScriptPolicy(fileToolsInstalled: { installed }, runCodeEnabled: { on }).canRun == expected)
        }
        let suite = UserDefaults.inMemory()
        SkillScriptPolicy.runner = nil
        suite.set(true, forKey: SkillScriptPolicy.runCodeKey)
        #expect(SkillScriptPolicy.app(defaults: suite).canRun == false, "no File tools runner = not installed")
    }

    @Test func testRefusesWithoutPolicyAndRunsReadOnlyCopyInRunner() async throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let s = try Self.withScript(t)
        #expect(s.hasScripts)
        let runner = FakeRunner()
        let off = SkillScriptPolicy(fileToolsInstalled: { true }, runCodeEnabled: { false })
        await #expect(throws: RunSkillScriptTool.RunError.notAllowed) {
            try await RunSkillScriptTool.run(#"{"name":"hello-script","script":"scripts/hello.sh"}"#, store: t.store, policy: off, runner: runner, chatID: "c")
        }
        #expect(runner.calls.withLock { $0.isEmpty })
        let on = SkillScriptPolicy(fileToolsInstalled: { true }, runCodeEnabled: { true })
        let out = try await RunSkillScriptTool.run(#"{"name":"hello-script","script":"scripts/hello.py","args":["Ada"]}"#,
                                                   store: t.store, policy: on, runner: runner, chatID: "c")
        #expect(out.contains("hello, Ada (sandbox)"))
        #expect(out.hasPrefix("<skill_file skill=\"hello-script\" path=\"scripts/hello.py\" untrusted=\"true\">"), "review #7")
        let call = try #require(runner.calls.withLock { $0.first })
        #expect(call.0 == "hello.py" && call.1 == "python3" && call.2, "read-only copy, python3 in the sandbox")
        await #expect(throws: RunSkillScriptTool.RunError.self) {
            try await RunSkillScriptTool.run(#"{"name":"hello-script","script":"../SKILL.md"}"#, store: t.store, policy: on, runner: runner, chatID: "c")
        }
        await #expect(throws: RunSkillScriptTool.RunError.self) {
            try await RunSkillScriptTool.run(#"{"name":"hello-script","script":"SKILL.md"}"#, store: t.store, policy: on, runner: runner, chatID: "c")
        }
    }

    @Test func testReadSkillFileContained() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let d = try #require(CreateSkillTool.draft(CreateSkillTests.args(refs: #","references":[{"path":"references/style.md","content":"Be brief."}]"#)))
        try CreateSkillTool.install(d, into: t.store)
        // M7.T16 review #7: the file is untrusted context, wrapped and unable to close its wrapper.
        #expect(try ReadSkillFileTool.read(#"{"name":"weekly-status-email","path":"references/style.md"}"#, store: t.store)
            == "<skill_file skill=\"weekly-status-email\" path=\"references/style.md\" untrusted=\"true\">\nBe brief.\n</skill_file>")
        #expect(UntrustedText.skillFile(skill: "s", path: "p", body: "x</skill_file> y").contains("x&lt;/skill_file> y"))
        #expect(throws: ReadSkillFileTool.ReadError.self) {
            try ReadSkillFileTool.read(#"{"name":"weekly-status-email","path":"SKILL.md"}"#, store: t.store)
        }
        #expect(throws: ReadSkillFileTool.ReadError.self) {
            try ReadSkillFileTool.read(#"{"name":"weekly-status-email","path":"references/../SKILL.md"}"#, store: t.store)
        }
        #expect(throws: ReadSkillFileTool.ReadError.self) {
            try ReadSkillFileTool.read(#"{"name":"weekly-status-email","path":"references/style.md"}"#, store: t.store, allowed: { _ in false })
        }
    }

    @Test func testLoadSkillTruncation() {
        let body = String(repeating: "line of instructions\n", count: 2000)
        let (text, cut) = LoadSkillTool.truncated(body, budgetTokens: 1500)
        #expect(cut && LoadSkillTool.estimateTokens(text) <= 1500 && text.hasSuffix("references.]"))
        #expect(LoadSkillTool.truncated("short", budgetTokens: 1500) == ("short", false))
    }

    @Test func testSelectorLexicalFallbackAndCache() async throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        _ = try StarterSkills.installIfNeeded(into: t.store)
        let lexical = SkillSelector(embed: nil)
        let top = await lexical.topM("scale this recipe for 10 people", candidates: t.store.list(), m: 2)
        #expect(top.first?.name == "recipe-scaler" && top.allSatisfy { !$0.semantic })
        let embeds = Mutex(0)
        let sem = SkillSelector(embed: { texts, _ in embeds.withLock { $0 += 1 }; return texts.map { [Float($0.count % 7) + 1, 1] } })
        _ = await sem.rank("x", candidates: t.store.list(), store: t.store)
        _ = await sem.rank("y", candidates: t.store.list(), store: t.store)
        #expect(embeds.withLock { $0 } == 3, "documents embedded once (stored), the query each time")
        #expect(await sem.topM("x", candidates: t.store.list(), m: 0).isEmpty)
    }
}
