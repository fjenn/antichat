// M4.T05 step 5 (D-013, test-strategy §7.6, NFR-S4): the signed, patched sd-server (build/binaries/sd-server, UP-SD-001)
// under SDServerSupervisor with the T1 photo set (klein Q4 + Qwen3-4B Q4_K_M + flux2 VAE, dev models):
//   * it listens on a unix socket only — `lsof -a -p <pid> -i` lists NO TCP/UDP socket — in a 0700 directory;
//   * readiness over the socket (`models/status` ready) and one 256² 2-step job round-trips (content-free prompt);
//   * `kill -9` → the supervisor sees it gone; the next start is ready again (relaunch time recorded vs NFR-S4).
// Opt-in real-model test: `ANTICHAT_REAL_SD=1` (memory checked by the caller: free ≥ ~6 GB + 20 GB). The argument
// shape (no `127.0.0.1`, `unix:` listen) is checked always.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct SDServerProcessTests {
    static let models = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func set() -> ImageModelSet {
        ImageModelSet(key: "img-klein-q4", diffusionModel: models.appendingPathComponent("img-klein/flux-2-klein-4b-Q4_0.gguf").path,
                      llm: models.appendingPathComponent("img-te/Qwen3-4B-Q4_K_M.gguf").path,
                      vae: models.appendingPathComponent("img-vae-flux2/split_files/vae/flux2-vae.safetensors").path,
                      footprintBytes: 6_300_000_000)
    }

    @Test func argumentsListenOnAUnixSocketOnly() throws {
        let a = SDServerSupervisor.arguments(Self.set(), socket: "/tmp/x/sd.sock", modelDir: "/tmp/empty")
        #expect(a.starts(with: ["--listen-ip", "unix:/tmp/x/sd.sock", "--listen-port", "80"]))
        #expect(!a.contains("127.0.0.1") && !a.contains { $0.hasPrefix("--api-key") })
        let dir = try SDServerSupervisor.socketDirectory()
        defer { rmdir(dir) }
        let perms = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o700 && (dir as NSString).appendingPathComponent("sd.sock").utf8.count < 104)
    }

    static func inetSockets(_ pid: pid_t) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-p", "\(pid)", "-i"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").dropFirst().map(String.init)
    }

    static var binary: String { repo.appendingPathComponent("build/binaries/sd-server").path }

    /// No weights (not a model run): the patched binary with an empty model dir listens on its unix socket only —
    /// `lsof -i` lists nothing — answers `models/status` over the socket, and its socket goes with it.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: SDServerProcessTests.binary)))
    func listensOnUnixSocketOnlyWithoutModels() async throws {
        let dir = try SDServerSupervisor.socketDirectory()
        let socket = (dir as NSString).appendingPathComponent("sd.sock")
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sd-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(at: empty) }
        // Spawned like every helper child (own process group + orphan watchdog), so a killed test process cannot
        // leave it behind; the run token tags it for test-unit's leftover check.
        var env = VideoChild.environment()
        if let t = ProcessInfo.processInfo.environment["ANTICHAT_TEST_RUN_TOKEN"] { env["ANTICHAT_TEST_RUN_TOKEN"] = t }
        let p = try VideoChild(executable: Self.binary, args: ["--listen-ip", "unix:\(socket)", "--listen-port", "80", "--model-dir", empty.path],
                               env: env, progressFD3: false, logFile: nil, watchdogExecutable: nil)
        try await LlamaFixtures.reaping({ await p.terminate() }) {
            Task { for await _ in p.lines {} }  // drain stdout
            var up = false
            for _ in 0..<150 where !up {
                up = FileManager.default.fileExists(atPath: socket)
                if !up { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(up && p.isRunning, "sd-server listens on \(socket)")
            let status = try await SDServerClient(socketPath: socket).modelStatus()
            #expect(["empty", "ready", "loading"].contains(status), "\(status)")
            #expect(Self.inetSockets(p.pid).isEmpty, "no TCP/UDP socket: \(Self.inetSockets(p.pid))")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_REAL_SD"] == "1"))
    func launchHealthNoTCPAndRestartAfterKill() async throws {
        let binary = Self.repo.appendingPathComponent("build/binaries/sd-server").path
        try #require(FileManager.default.isExecutableFile(atPath: binary), "make binaries first")
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sd-empty-\(UUID().uuidString)").path
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sd-server-test-\(UUID().uuidString).log").path
        let sup = SDServerSupervisor(config: .init(binary: binary, logFile: log, modelDir: empty))
        defer { print("SDServerProcessTests: sd-server log \(log)") }
        do {
            let load = try await sup.start(Self.set())
            let pid = await sup.pid
            #expect(pid > 0 && load > 0)
            #expect(Self.inetSockets(pid).isEmpty, "sd-server must open no TCP/UDP socket: \(Self.inetSockets(pid))")
            let socket = await sup.socketPath
            #expect(FileManager.default.fileExists(atPath: socket))
            let client = await sup.client
            #expect(try await client.modelStatus() == "ready")
            let job = try await client.submit(prompt: "a red cube on a table", width: 256, height: 256, steps: 2, seed: 7, cfg: 1,
                                              sampleMethod: "euler", preview: "proj")
            var st = try await client.job(job)
            let end = ContinuousClock.now + .seconds(300)
            while !["completed", "failed", "cancelled"].contains(st.status), ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(50))
                st = try await client.job(job)
            }
            #expect(st.status == "completed" && (st.imagePNG?.count ?? 0) > 1000, "\(st.status) \(st.error ?? "")")

            if pid > 1 { kill(pid, SIGKILL) }
            var gone = false
            for _ in 0..<100 where !gone {
                try await Task.sleep(for: .milliseconds(20))
                gone = await !sup.isRunning
            }
            #expect(gone)
            let t0 = ContinuousClock.now
            await sup.stop()
            let reload = try await sup.start(Self.set())
            let restart = Double((ContinuousClock.now - t0).components.attoseconds) / 1e18 + Double((ContinuousClock.now - t0).components.seconds)
            #expect(try await sup.client.modelStatus() == "ready")
            #expect(Self.inetSockets(await sup.pid).isEmpty)
            print("SDServerProcessTests: first load \(load) s, relaunch to ready \(restart) s (model load \(reload) s)")
        } catch {
            await sup.stop()  // never leave the child behind on a failure
            throw error
        }
        let lastSocket = await sup.socketPath
        await sup.stop()
        #expect(!FileManager.default.fileExists(atPath: lastSocket), "the socket and its directory go with the process")
    }
}
