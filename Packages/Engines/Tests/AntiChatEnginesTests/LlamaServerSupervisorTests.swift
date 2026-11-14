// M1.T12 steps 1–3 against the real llama-server (b12254 @ 45c8ea8, was b11669 @ 620d222;
// `build/binaries/llama-server` or $ANTICHAT_LLAMA_SERVER) and the `tiny-gguf` stub ($ANTICHAT_FIXTURES/stub-models/tiny-gguf). Skipped when
// either is missing (a SwiftPM-only checkout without `make binaries` / fixtures).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Subprocess
import Testing
@testable import AntiChatEngines

enum LlamaFixtures {
    static let repoRoot = ScriptFixtures.repoRoot

    static var binary: String? {
        let env = ProcessInfo.processInfo.environment["ANTICHAT_LLAMA_SERVER"]
        let p = env ?? repoRoot.appendingPathComponent("build/binaries/llama-server").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static var tinyGGUF: String? {
        var roots = [repoRoot.appendingPathComponent("fixtures")]
        if let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] { roots.insert(URL(fileURLWithPath: f), at: 0) }
        return roots.map { $0.appendingPathComponent("stub-models/tiny-gguf/tiny.gguf").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static var available: Bool { binary != nil && tinyGGUF != nil }

    static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    static func tcpListeners(_ pid: pid_t) -> String {
        run(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
    }

    static func slot(_ path: String, key: String = "tiny-gguf") -> ModelSlot {
        ModelSlot(engine: .llama, key: key, path: path, contextTokens: 512)
    }

    /// Runs `body`, then `stop` on every exit path (a throw, or a failed check's early return), so a failing test never
    /// leaves its server behind (the watchdog would still end it when the test process exits).
    static func reaping<T>(_ stop: () async -> Void, _ body: () async throws -> T) async throws -> T {
        do {
            let r = try await body()
            await stop()
            return r
        } catch {
            await stop()
            throw error
        }
    }

    static func ask(_ slot: ModelSlot, maxTokens: Int = 64) -> ChatRequest {
        var r = ChatRequest(modelSlot: slot, messages: [ChatMessage(role: .user, content: "hello")])
        r.sampling.maxTokens = maxTokens
        return r
    }
}

@Suite("LlamaServerSupervisorTests", .serialized, .enabled(if: LlamaFixtures.available))
struct LlamaServerSupervisorTests {
    @Test func listensOnTheUnixSocketOnlyAndHidesTheKey() async throws {
        var cfg = LlamaServerSupervisor.Config(binary: LlamaFixtures.binary!, model: LlamaFixtures.tinyGGUF!)
        cfg.ctxSize = 512
        // What is checked is where it listens, not how fast it starts: the 10 s listener deadline ran out at load ~100.
        cfg.healthTimeout = .seconds(120)
        let sup = LlamaServerSupervisor(config: cfg)
        try await LlamaFixtures.reaping({ await sup.stop() }) {
            try await sup.start()
            let pid = await sup.pid
            let sock = await sup.socketPath
            #expect(pid > 0)
            #expect(LlamaFixtures.tcpListeners(pid).isEmpty, "llama-server must not listen on TCP (NFR-SEC6)")
            let args = LlamaFixtures.run(["/bin/ps", "-o", "args=", "-p", String(pid)])
            #expect(args.contains("--host \(sock)"))
            #expect(sock.hasSuffix(".sock"))
            #expect(!args.contains("--api-key") && !args.contains("--models-dir") && !args.contains("-hf"))
            // The key is required (401 without it, 200 with it).
            let anon = try await UnixHTTPClient(socketPath: sock, apiKey: nil).get("/v1/models")
            _ = try await anon.data()
            #expect(anon.status == 401)
            let authed = try await sup.client.get("/v1/models")
            _ = try await authed.data()
            #expect(authed.status == 200)
            await sup.stop()
            #expect(!FileManager.default.fileExists(atPath: sock))
            #expect(kill(pid, 0) != 0)
        }
    }

    /// fix/soak-engine (M9.T06 dry run: SIGBUS in `common_memory_breakdown_print` on an Evil→Normal swap): `stop()`
    /// sends one SIGTERM, so llama-server shuts down gracefully — exit 0, never its "Received second interrupt" `exit(1)`
    /// path — and the exit is marked intentional. Several rounds: the old double SIGTERM crashed ~1 in 16 swaps.
    @Test func stopIsOneGracefulSigtermAndIntentional() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("llama-stop-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        var cfg = LlamaServerSupervisor.Config(binary: LlamaFixtures.binary!, model: LlamaFixtures.tinyGGUF!, logFile: log.path)
        cfg.ctxSize = 512
        cfg.healthTimeout = .seconds(120)
        for round in 1...4 {
            let sup = LlamaServerSupervisor(config: cfg)
            try await LlamaFixtures.reaping({ await sup.stop() }) {
                try await sup.start()
                // A request first, so the server is past its signal-handler install and has served (as in a swap).
                let r = try await sup.client.get("/props")
                _ = try await r.data()
                let pid = await sup.pid
                await sup.stop()
                let exit = try #require(sup.exit, "round \(round): no exit recorded")
                #expect(exit.intentional, "round \(round): \(exit)")
                #expect(exit.status == "exited(0)", "round \(round): graceful shutdown expected, got \(exit)")
                #expect(kill(pid, 0) != 0)
            }
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(!text.contains("Received second interrupt"), "a second SIGTERM reached llama-server")
    }

    @Test func streamsThenReportsAKilledServerAsEngineRestarted() async throws {
        let adapter = LlamaServerAdapter(binary: LlamaFixtures.binary!, kvDir: NSTemporaryDirectory(), logFile: nil, watchdogExecutable: nil)
        let slot = LlamaFixtures.slot(LlamaFixtures.tinyGGUF!)
        try await LlamaFixtures.reaping({ await adapter.stop() }) {
            try await adapter.load(slot)
            // A whole turn first: deltas, usage, done.
            var events: [EngineEvent] = []
            for await o in try await adapter.generate(LlamaFixtures.ask(slot, maxTokens: 16), context: GenerationContext()) {
                if case .event(let e) = o { events.append(e) }
            }
            #expect(events.last?.isTerminal == true)
            #expect(events.filter(\.isTerminal).count == 1)
            guard case .done = events.last else { Issue.record("expected done, got \(String(describing: events.last))"); return }

            // kill -9 mid-stream → exactly one terminal: error(engine.restarted).
            let pid = await adapter.serverPID
            var killed = false
            var after: [EngineEvent] = []
            for await o in try await adapter.generate(LlamaFixtures.ask(slot, maxTokens: 4000), context: GenerationContext()) {
                guard case .event(let e) = o else { continue }
                after.append(e)
                if !killed, e.isDelta, pid > 1 { kill(pid, SIGKILL); killed = true }
            }
            #expect(killed)
            #expect(after.filter(\.isTerminal).count == 1)
            guard case .error(let err)? = after.last else { Issue.record("expected error, got \(String(describing: after.last))"); return }
            #expect(err.is(.engineRestarted), "\(err)")
            #expect(await adapter.isAlive == false)
            // The next load respawns it.
            try await adapter.load(slot)
            #expect(await adapter.isAlive)
            #expect(await adapter.serverPID != pid)
        }
    }

    /// R2 review P1-2: the pinned llama-server reports prompt processing (`return_progress`) and the adapter forwards
    /// it as `prefillProgress` before the first token (never after content), so a long prefill is not silence to the
    /// turn's stall watchdog.
    @Test func promptProcessingProgressPrecedesTheFirstToken() async throws {
        let adapter = LlamaServerAdapter(binary: LlamaFixtures.binary!, kvDir: NSTemporaryDirectory(), logFile: nil, watchdogExecutable: nil)
        let slot = LlamaFixtures.slot(LlamaFixtures.tinyGGUF!)
        try await LlamaFixtures.reaping({ await adapter.stop() }) {
            try await adapter.load(slot)
            var req = LlamaFixtures.ask(slot, maxTokens: 8)
            req.messages = [.message(ChatMessage(role: .user, content: Array(repeating: "lorem ipsum dolor", count: 25).joined(separator: " ")))]
            var out: [AdapterOutput] = []
            for await o in try await adapter.generate(req, context: GenerationContext()) { out.append(o) }
            let progress = out.compactMap { if case .lifecycle(.prefillProgress(let f)) = $0 { f } else { nil } }
            #expect(!progress.isEmpty, "no prefill progress: \(out.prefix(5))")
            #expect(progress.allSatisfy { (0...1).contains($0) } && progress == progress.sorted(), "\(progress)")
            if let first = out.firstIndex(where: { if case .event(let e) = $0 { e.isDelta } else { false } }) {
                #expect(!out[first...].contains { if case .lifecycle = $0 { true } else { false } })
                #expect(out[..<first].contains { if case .lifecycle(.prefillProgress) = $0 { true } else { false } })
            }
            guard case .event(let last)? = out.last, last.isTerminal else { Issue.record("no terminal"); return }
        }
    }

    @Test func corruptModelFailsTheLoadWithModelCorrupt() async throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString).gguf")
        // Valid magic + header bytes of the stub, then truncated: tensor data outside the file bounds.
        let good = try Data(contentsOf: URL(fileURLWithPath: LlamaFixtures.tinyGGUF!))
        try good.prefix(min(good.count / 2, 64 * 1024)).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let sup = LlamaServerSupervisor(config: .init(binary: LlamaFixtures.binary!, model: bad.path))
        do {
            try await sup.start()
            Issue.record("a truncated model must not load")
            await sup.stop()
        } catch let e as AntiChatError {
            #expect(e.is(.modelCorrupt), "\(e)")
        }
        #expect(await sup.isRunning == false)

        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).gguf")
        try Data("this is not a gguf file".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        let sup2 = LlamaServerSupervisor(config: .init(binary: LlamaFixtures.binary!, model: garbage.path))
        do {
            try await sup2.start()
            Issue.record("bad magic must not load")
            await sup2.stop()
        } catch let e as AntiChatError {
            #expect(e.is(.modelCorrupt), "\(e)")
        }
    }
}

/// M10.T09 (AT-FA-07): the listener wait covers a first launch's Metal shader compile (llama-server opens its socket
/// after Metal init); a server that exits is still reported at once by `waitListening`.
@Suite("LlamaServerConfigDefaultsTests")
struct LlamaServerConfigDefaultsTests {
    @Test func listenerWaitCoversAColdMetalCompile() {
        let cfg = LlamaServerSupervisor.Config(binary: "/bin/false", model: "/dev/null")
        #expect(cfg.healthTimeout >= .seconds(60))
        #expect(cfg.loadTimeout >= cfg.healthTimeout)
    }

    /// llama.cpp b12254 added `--connect` (a peer-to-peer tunnel, env `LLAMA_ARG_CONNECT`): the helper's
    /// environment clears it with the HF and proxy variables, so an inherited value never reaches llama-server.
    @Test func environmentClearsNetworkVariables() {
        let env = LlamaServerSupervisor.environment(apiKey: "k")
        #expect(env["LLAMA_API_KEY"] == .some("k"))
        for k in ["LLAMA_ARG_CONNECT", "LLAMA_ARG_CONNECT_CODE", "LLAMA_ARG_HF_REPO", "HF_TOKEN", "HTTPS_PROXY"] {
            let key = Environment.Key(stringLiteral: k)
            #expect(env.keys.contains(key), "\(k) is not cleared")
            #expect(env[key] == .some(nil), "\(k) is not cleared")
        }
    }
}
