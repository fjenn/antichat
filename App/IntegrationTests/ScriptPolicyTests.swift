// AT-265 (R-265 AC1; M7.T13 step 6): no silent scripts. Imports fixtures/skills/with-script/hello-script (scripts/hello.sh,
// scripts/hello.py) and runs 20 turns per config whose model asks to run the script:
//   1. File tools absent, 2. File tools installed + Run code off  → `run_skill_script` is not in the request's tools or
//      the prompt dump, zero child processes of the app (proc_listchildpids sampled every 50 ms) and zero
//      ProcessLauncher calls;
//   3. installed + Run code on → the script runs only through the File tools runner after [Allow once], still zero
//      app children and zero ProcessLauncher calls: 3a with a recording runner (the policy path), 3b with the real
//      FileToolsSkillRunner — scripts/hello.py inside AntiChatFileTools.xpc (child of launchd, network-off service)
//      over the installed filetools runtime (skipped when no runtime is installed).
// Run: make test-integration-stub FILTER=ScriptPolicyTests FIXTURES=$PWD/fixtures
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools
import Darwin
import Foundation
import Synchronization
import XCTest

final class ScriptPolicyTests: XCTestCase {
    final class Runner: SkillScriptRunner, @unchecked Sendable {
        let calls = Mutex(0)
        let outputs = Mutex<[String]>([])
        let real: FileToolsSkillRunner?
        init(real: FileToolsSkillRunner? = nil) { self.real = real }
        func run(skill: String, script: URL, interpreter: String, arguments: [String], chatID: String) async throws -> SkillScriptResult {
            calls.withLock { $0 += 1 }
            let r = try await real?.run(skill: skill, script: script, interpreter: interpreter, arguments: arguments, chatID: chatID)
                ?? SkillScriptResult(exitCode: 0, stdout: "hello, \(arguments.first ?? "world") (\(interpreter), File tools)", stderr: "")
            outputs.withLock { $0.append(r.stdout + r.stderr) }
            return r
        }
    }

    /// Child pids of this process, sampled every 50 ms while `body` runs; returns the new ones.
    static func children() -> Set<pid_t> {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(getpid(), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return Set(buf.prefix(max(0, Int(n))).filter { $0 > 0 })
    }

    static func script(_ file: String) -> String {
        """
        {"t":"toolCallDone","id":"call_1","name":"run_skill_script","args":"{\\"name\\":\\"hello-script\\",\\"script\\":\\"scripts/\(file)\\",\\"args\\":[\\"Ada\\"]}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Done.","delayMs":1}
        """
    }

    struct Outcome { var newChildren: Set<pid_t>; var launcherCalls: Int; var offered: Int; var dumped: Int; var runs: Int; var approvals: Int
        var outputs: [String] = [] }

    func runConfig(_ name: String, installed: Bool, runCode: Bool, turns: Int = 20, real: FileToolsSkillRunner? = nil) async throws -> Outcome {
        guard let fx = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] else {
            throw XCTSkip("ANTICHAT_FIXTURES not set (make test-integration-stub FIXTURES=…)")
        }
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(root: root.appendingPathComponent("Skills"), database: db)
        try SkillImporter.install(try SkillImporter.inspect(URL(fileURLWithPath: fx).appendingPathComponent("skills/with-script/hello-script")), into: store)
        let runner = Runner(real: real)
        SkillScriptPolicy.runner = installed ? runner : nil
        defer { SkillScriptPolicy.runner = nil }
        let dumpDir = root.appendingPathComponent("prompts")
        PromptDump.directory = dumpDir.path
        defer { PromptDump.directory = nil }

        let baseline = Self.children()
        let launcherBefore = ProcessLauncher.spawnCount
        let seen = Mutex(Set<pid_t>())
        let sampling = Task.detached {
            while !Task.isCancelled {
                let now = ScriptPolicyTests.children().subtracting(baseline)
                seen.withLock { $0.formUnion(now) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        var offered = 0, dumped = 0, approvals = 0
        for _ in 0..<turns {
            var runtime = ToolRuntime(registry: ToolRegistry([ScriptedTools.getTime()]), policy: .forTier(.t1), selection: .off, tier: { .t1 })
            runtime.skills = store
            runtime.skillSelector = SkillSelector(embed: nil)
            runtime.skillScripts = SkillScriptPolicy(fileToolsInstalled: { installed && SkillScriptPolicy.runner != nil }, runCodeEnabled: { runCode })
            let chat = try ChatRepository(db).create().id
            let c = TurnController(chatID: chat, database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: Self.script(real == nil ? "hello.sh" : "hello.py"))),
                                   tools: runtime) { .scripted("inline") }
            let a = StorageID.make()
            let watcher = Task { () -> Int in
                var asked = 0
                for await u in c.updates where u.assistantID == a {
                    if case .approval(let req?) = u.kind { asked += 1; await c.answerApproval(callID: req.id, .allowOnce) }
                    if case .finished = u.kind { break }
                }
                return asked
            }
            await c.start(.send(userID: StorageID.make(), text: "Please run the hello script of the hello-script skill for Ada.", parentID: nil),
                          assistantID: a)
            approvals += await watcher.value
            if (await c.requests.first?.tools ?? []).contains(where: { $0.name == RunSkillScriptTool.name }) { offered += 1 }
            if let d = try? String(contentsOf: dumpDir.appendingPathComponent("\(a).txt"), encoding: .utf8), d.contains(RunSkillScriptTool.name) { dumped += 1 }
        }
        try await Task.sleep(for: .milliseconds(120))
        sampling.cancel()
        return Outcome(newChildren: seen.withLock { $0 }, launcherCalls: ProcessLauncher.spawnCount - launcherBefore, offered: offered,
                       dumped: dumped, runs: runner.calls.withLock { $0 }, approvals: approvals, outputs: runner.outputs.withLock { $0 })
    }

    func testScriptsNeverSpawnWithoutPolicyAndRunOnlyInFileTools() async throws {
        func line(_ n: String, _ o: Outcome) -> String {
            "config \(n): turns=20 offered=\(o.offered) in_dump=\(o.dumped) approvals=\(o.approvals) runner_runs=\(o.runs) app_children=\(o.newChildren.count) process_launcher_calls=\(o.launcherCalls)"
        }
        let absent = try await runConfig("absent", installed: false, runCode: true)
        let off = try await runConfig("installed-off", installed: true, runCode: false)
        let on = try await runConfig("installed-on", installed: true, runCode: true)
        for (n, o) in [("1 absent", absent), ("2 installed+off", off)] {
            XCTAssertTrue(o.newChildren.isEmpty, "\(n): child processes \(o.newChildren)")
            XCTAssertEqual(o.launcherCalls, 0, n)
            XCTAssertEqual(o.offered, 0, "\(n): run_skill_script offered")
            XCTAssertEqual(o.dumped, 0, "\(n): run_skill_script in the prompt dump")
            XCTAssertEqual(o.runs, 0, n)
        }
        XCTAssertEqual(on.offered, 20)
        XCTAssertEqual(on.approvals, 20, "every run asks first")
        XCTAssertEqual(on.runs, 20, "runs only through the File tools runner after Allow once")
        XCTAssertTrue(on.newChildren.isEmpty, "3: the app itself spawns nothing (\(on.newChildren))")
        XCTAssertEqual(on.launcherCalls, 0)
        // 3b: the real File tools XPC.
        var realLine = "config 3b real AntiChatFileTools.xpc: skipped (no filetools runtime installed)"
        if let rt = RunPythonTool.installedRuntimePath() {
            let real = try await runConfig("installed-on-real", installed: true, runCode: true, real: FileToolsSkillRunner(runtimePath: { rt }))
            XCTAssertEqual(real.offered, 20)
            XCTAssertEqual(real.approvals, 20, "every real run asks first")
            XCTAssertEqual(real.runs, 20)
            XCTAssertEqual(real.outputs.filter { $0.contains("hello, Ada (py)") }.count, 20, "outputs without the greeting: \(real.outputs.filter { !$0.contains("hello, Ada (py)") }.map { String($0.prefix(2000)) })")
            XCTAssertTrue(real.newChildren.isEmpty, "3b: the app itself spawns nothing (\(real.newChildren))")
            XCTAssertEqual(real.launcherCalls, 0)
            realLine = line("3b installed+run-code-on REAL AntiChatFileTools.xpc (\(URL(fileURLWithPath: rt).lastPathComponent), hello.py)", real)
                + " outputs_ok=\(real.outputs.filter { $0.contains("hello, Ada (py)") }.count)/20"
        }

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let log = root.appendingPathComponent("build/at/AT-265/\(day).log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ([
            "AT-265 ScriptPolicyTests (R-265 AC1) \(Date())",
            line("1 file-tools-absent", absent), line("2 installed+run-code-off", off), line("3a installed+run-code-on (recording runner)", on),
            realLine,
            testRun?.failureCount == 0 ? "PASS" : "FAIL (\(testRun?.failureCount ?? -1) assertion failures)",
        ].joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    }
}
