// ProcessLauncher (M7.T13, D-026 note 6; R-265; architecture §1.2): the one way new code in AntiChat starts a child
// process. It wraps swift-subprocess 1.0.2 (the M1 pattern of `LlamaServerSupervisor`), counts every spawn
// (`spawnCount`, read by AT-265's ScriptPolicyTests) and logs the executable. `tools/ci/no-raw-process.py` (in `make
// audit`) fails on any `Process(`, `posix_spawn`, `Subprocess.run` or `NSTask` outside this file and the launch sites
// listed in `tools/ci/no-raw-process-allow.txt`, each with its reason.
//
// Skill scripts never come here: they run only inside AntiChatFileTools.xpc after approval (`SkillScriptPolicy`); with
// File tools absent or Run code off, no skill code path calls `ProcessLauncher` (AT-265 configs 1–2: spawnCount stays 0).
import AntiChatFoundation
import Foundation
import Subprocess
import Synchronization
#if canImport(System)
import System
#else
import SystemPackage
#endif

public enum ProcessLauncher {
    /// What a finished child left: its exit status (nil = killed by a signal) and up to `outputLimit` bytes of output.
    public struct Result: Sendable, Hashable {
        public var exitCode: Int32?
        public var signal: Int32?
        public var stdout: String
        public var stderr: String
        public var succeeded: Bool { exitCode == 0 }
    }

    public struct LaunchError: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    private static let counter = Mutex<Int>(0)

    /// How many children this process has started through the launcher (tests: AT-265).
    public static var spawnCount: Int { counter.withLock { $0 } }

    /// Runs `executable` with `arguments` to the end and returns its collected output (stdin /dev/null).
    /// `environment` nil = inherit; otherwise exactly these variables.
    public static func run(_ executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                           workingDirectory: String? = nil, outputLimit: Int = 1 << 20) async throws -> Result {
        counter.withLock { $0 += 1 }
        AppLog.log(.tools, .info, "ProcessLauncher: \(URL(fileURLWithPath: executable).lastPathComponent) (\(arguments.count) args)")
        let env: Environment = environment.map { dict in
            .custom(Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Environment.Key(rawValue: k).map { ($0, v) } }))
        } ?? .inherit
        do {
            let r = try await Subprocess.run(
                .path(FilePath(executable)), arguments: Arguments(arguments), environment: env,
                workingDirectory: workingDirectory.map { FilePath($0) },
                output: .string(limit: outputLimit), error: .string(limit: outputLimit))
            var out = Result(exitCode: nil, signal: nil, stdout: r.standardOutput, stderr: r.standardError)
            switch r.terminationStatus {
            case .exited(let c): out.exitCode = c
            case .signaled(let s): out.signal = s
            }
            return out
        } catch {
            throw LaunchError(description: "\(executable): \(error)")
        }
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Tests only: back to zero before a measured run.
    public static func resetSpawnCountForTests() { counter.withLock { $0 = 0 } }
    #endif
}
