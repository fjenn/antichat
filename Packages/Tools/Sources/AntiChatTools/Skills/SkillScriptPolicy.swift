// No silent scripts (M7.T13 step 6; R-265 AC1; P-files-tools-09 approval path). A skill's `scripts/` can run only when
//   canRun = File tools installed ∧ Run code on (Settings → Tools, M6's `runCodeEnabled`).
// When false, `run_skill_script` is not registered at all (the model never sees it, AT-265 configs 1–2) and no skill code
// path reaches a process launcher. When true, the script is copied read-only into the chat's File tools jail and runs
// only inside AntiChatFileTools.xpc (App Sandbox, no network: M6.T17) through `runner` — after the user's
// `skills.scriptApproval` [Allow once] / [Always allow] / [Deny] (the tool's side effect is `.write`, so PermissionGate
// asks). The app process itself never spawns for a skill; `tools/ci/no-raw-process.py` keeps it that way.
//
// `runner` is `FileToolsSkillRunner` over the File tools client (M6.T17/T19 `FileToolsClient.runScript`, the network-off
// service, the chat's jail); `ToolRuntime.app` sets it. File tools count as installed when a runner is set and the
// filetools runtime is present. The runtime is Python, so `.py` scripts run; a `.sh` script is refused there.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

/// Runs one skill script inside the File tools sandbox (never in the app process).
public protocol SkillScriptRunner: Sendable {
    /// `script` is a read-only copy (mode 0444) in a fresh folder; `interpreter` is "python3" or "sh".
    func run(skill: String, script: URL, interpreter: String, arguments: [String], chatID: String) async throws -> SkillScriptResult
}

/// The real runner: the script crosses into the chat's File tools jail as a read-only input and runs inside
/// AntiChatFileTools.xpc (App Sandbox, network-off variant), never in the app process.
public struct FileToolsSkillRunner: SkillScriptRunner {
    let client: FileToolsClient
    let runtimePath: @Sendable () -> String?

    public init(client: FileToolsClient = FileToolsClient(network: false),
                runtimePath: @escaping @Sendable () -> String? = { RunPythonTool.installedRuntimePath() }) {
        self.client = client
        self.runtimePath = runtimePath
    }

    public func run(skill: String, script: URL, interpreter: String, arguments: [String], chatID: String) async throws -> SkillScriptResult {
        guard interpreter == "python3" else { throw RunSkillScriptTool.RunError.unsupported(script.lastPathComponent + " (the File tools sandbox runs Python)") }
        guard let runtime = runtimePath() else { throw RunSkillScriptTool.RunError.notAllowed }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("skill-script-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        // The tool asked first (side effect .write → PermissionGate → skills.scriptApproval), so the call is approved.
        let (r, _) = try await client.runScript(skillID: skill, scriptPath: script, args: [script.lastPathComponent] + arguments,
                                                chatID: chatID, runtimePath: runtime, approved: true, outputDirectory: out)
        if let e = r.serviceError { throw RunSkillScriptTool.RunError.service(e) }
        var err = r.stderr
        if let e = r.error { err += (err.isEmpty ? "" : "\n") + (e.traceback ?? "\(e.type): \(e.message)") }
        return SkillScriptResult(exitCode: r.error == nil && r.killedReason == nil ? 0 : 1, stdout: r.stdout, stderr: err)
    }
}

public struct SkillScriptResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) { self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr }
}

public struct SkillScriptPolicy: Sendable {
    /// M6's Settings key for Run code (`ToolDefaults.runCodeEnabled`, default off).
    public static let runCodeKey = ToolDefaults.runCodeEnabled

    public var fileToolsInstalled: @Sendable () -> Bool
    public var runCodeEnabled: @Sendable () -> Bool

    public init(fileToolsInstalled: @escaping @Sendable () -> Bool, runCodeEnabled: @escaping @Sendable () -> Bool) {
        self.fileToolsInstalled = fileToolsInstalled
        self.runCodeEnabled = runCodeEnabled
    }

    public var canRun: Bool { fileToolsInstalled() && runCodeEnabled() }

    /// The File tools runner of this process (nil = File tools not installed / not linked here).
    nonisolated(unsafe) public static var runner: (any SkillScriptRunner)?

    /// The app's policy: installed = a File tools runner is set and the filetools runtime is present; Run code = M6's
    /// switch (`ToolDefaults.store`, the same store Settings writes).
    public static func app(defaults: UserDefaults = ToolDefaults.store,
                           runtimeInstalled: @escaping @Sendable () -> Bool = { RunPythonTool.installedRuntimePath() != nil }) -> SkillScriptPolicy {
        nonisolated(unsafe) let d = defaults
        return SkillScriptPolicy(fileToolsInstalled: { runner != nil && runtimeInstalled() }, runCodeEnabled: { d.bool(forKey: runCodeKey) })
    }
}

public enum RunSkillScriptTool {
    public static let name = "run_skill_script"
    public static let description = "Run one script from a skill's scripts/ folder in the File tools sandbox (no network). The user approves each run."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","description":"The skill name"},"script":{"type":"string","description":"e.g. scripts/hello.py"},"args":{"type":"array","items":{"type":"string"}}},"required":["name","script"]}"#

    struct Args: Decodable { var name: String; var script: String; var args: [String]? }

    public enum RunError: Error, Equatable, CustomStringConvertible {
        case malformed, notAllowed, noSkill(String), noScript(String), unsupported(String), service(String)
        public var description: String {
            switch self {
            case .malformed: "run_skill_script needs {\"name\": …, \"script\": \"scripts/…\"}."
            case .notAllowed: "Scripts can't run: File tools aren't installed or Run code is off."
            case .noSkill(let n): "No skill named \(n) is installed and on."
            case .noScript(let p): "The skill has no script \(p)."
            case .unsupported(let p): "\(p): only .py and .sh scripts run."
            case .service(let m): "File tools: \(m)"
            }
        }
    }

    /// Checks the call, copies the script read-only into a fresh folder and hands it to the File tools runner.
    public static func run(_ argumentsJSON: String, store: SkillStore, policy: SkillScriptPolicy,
                           runner: (any SkillScriptRunner)?, chatID: String) async throws -> String {
        guard policy.canRun, let runner else { throw RunError.notAllowed }
        guard let a = try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8)) else { throw RunError.malformed }
        guard let skill = store.skill(named: a.name), skill.isValid else { throw RunError.noSkill(a.name) }
        let rel = a.script.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.first == "scripts", parts.count >= 2, !parts.contains(".."), skill.files.contains(where: { $0.relativePath == rel })
        else { throw RunError.noScript(a.script) }
        let interpreter: String
        switch (rel as NSString).pathExtension.lowercased() {
        case "py": interpreter = "python3"
        case "sh": interpreter = "sh"
        default: throw RunError.unsupported(rel)
        }
        let fm = FileManager.default
        let jail = fm.temporaryDirectory.appendingPathComponent("antichat-skill-script-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: jail) }
        try fm.createDirectory(at: jail, withIntermediateDirectories: true)
        let copy = jail.appendingPathComponent(parts.last!)
        try fm.copyItem(at: store.directory(for: skill.record.path).appendingPathComponent(rel), to: copy)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
        let r = try await runner.run(skill: skill.name, script: copy, interpreter: interpreter, arguments: a.args ?? [], chatID: chatID)
        var lines = ["exit \(r.exitCode)"]
        if !r.stdout.isEmpty { lines.append(r.stdout) }
        if !r.stderr.isEmpty { lines.append("stderr: " + r.stderr) }
        // M7.T16 review #7: the script's output is untrusted context (a third-party script could imitate app markup).
        return UntrustedText.skillFile(skill: skill.name, path: rel, body: lines.joined(separator: "\n"))
    }
}
