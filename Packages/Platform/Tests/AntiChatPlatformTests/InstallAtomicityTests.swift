// AT-293 (R-293 AC2) — M2.T10: `kill -9` of `antichat-cli models install` at a random point leaves the model either
// absent or ready (`models list --json`), never half-installed, and `installs/` never holds a `.tmp`.
// 50 iterations (ANTICHAT_DL_FULL=1 or ANTICHAT_AT_LOG=1), 12 in the plain unit run.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite(.serialized) struct InstallAtomicityTests {
    func cli(_ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = CLI.url
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        try ChildExit.waitBlocking(p, "antichat-cli \(args.prefix(2).joined(separator: " "))", limit: .seconds(300))
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func killNineLeavesAbsentOrReady() async throws {
        let f = try StoreFixture("atomic", sizesMB: ["tokenizer.json": 2, "model.safetensors": 8, "config.json": 1, "evil.gguf": 1],
                                 serverArgs: ["--slow", "20000"])
        let n = DL.full || ProcessInfo.processInfo.environment["ANTICHAT_AT_LOG"] == "1" ? 50 : 12
        let base = ["--models", f.models.root.path, "--catalog", f.catalogURL.path]
        // t_install of one clean run.
        let t0 = Date()
        #expect(try cli(["models", "install", "--id", "norm"] + base).0 == 0)
        let tInstall = Date().timeIntervalSince(t0)
        var absent = 0, ready = 0
        for i in 0..<n {
            try? FileManager.default.removeItem(at: f.models.root)
            let p = try CLI.spawn(["models", "install", "--id", "norm"] + base)
            let at = Double.random(in: 0...tInstall)
            try await Task.sleep(for: .seconds(at))
            kill(p.processIdentifier, SIGKILL)
            // Not `waitUntilExit()`: it can miss the exit (see ChildExit).
            try await ChildExit.wait(p, "SIGKILLed antichat-cli models install (iteration \(i))", limit: .seconds(60))
            let (rc, out) = try cli(["models", "list", "--json"] + base)
            #expect(rc == 0)
            let rows = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] ?? []
            let installs = (try? FileManager.default.contentsOfDirectory(atPath: f.models.installs.path)) ?? []
            #expect(!installs.contains { $0.hasSuffix(".tmp") || $0.hasSuffix(".old") }, "iteration \(i): \(installs)")
            if rows.isEmpty { absent += 1; #expect(installs.isEmpty, "iteration \(i): view without manifest \(installs)") } else {
                ready += 1
                #expect(rows.map { $0["id"] as? String } == ["norm"])
                #expect(Repair.check("norm", models: f.models, full: true).isEmpty, "iteration \(i): listed but not complete")
            }
        }
        #expect(absent + ready == n)
        ATLog.write("AT-293", "atomicity.log", String(format: "kill -9 × %d at random points in [0, %.2f s]: absent %d, ready %d, half-installed 0, .tmp in installs/ 0", n, tInstall, absent, ready))
    }
}
