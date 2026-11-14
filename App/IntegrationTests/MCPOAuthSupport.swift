// M7.T07 (AT-257): shared harness for MCPOAuthFlowTests / OAuthNegativeTests. Starts the reference OAuth AS + protected
// MCP server (`node tools/mcp-ref/mcp.ts`, toggles per case) and the local site server serving
// `site/public/oauth/mcp-client-metadata.json` (what `make site-dev` serves; CIMD local test mode, M7.md §0.1), and
// builds an MCPHost whose sign-in runs through HeadlessAuthPresenter on the gated `.mcp` session. Tokens go to the
// real Keychain (service `app.antichat.mcp.oauth`); every issued token is appended to
// build/at/AT-257/issued-tokens.txt for `tools/ci/token-file-scan.py`.
#if DEBUG
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

enum OAuthRef {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }()
    static let node: String? = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let atDir = repo.appendingPathComponent("build/at/AT-257")
    static let issued = atDir.appendingPathComponent("issued-tokens.txt")
    static let logFile: URL = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return atDir.appendingPathComponent("\(f.string(from: Date())).log")
    }()

    static func log(_ s: String) {
        try? FileManager.default.createDirectory(at: atDir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logFile) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: logFile, atomically: true, encoding: .utf8) }
        NSLog("AT-257 %@", s)
    }

    struct Server {
        let mcp: URL
        let asBase: URL
        let cimd: URL
    }

    static func skipUnlessAvailable() throws {
        guard node != nil else { throw XCTSkip("not run: node missing (Q-007)") }
    }

    static func run(_ exe: String, _ args: [String], test: XCTestCase) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "NODE_NO_WARNINGS": "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        // Not `waitUntilExit()`: the teardown runs on another thread than this `run()`, and from there Foundation's
        // run-loop wake-up can be lost (fix/resume-hang). `isRunning` is updated off the run loop; bounded poll.
        test.addTeardownBlock {
            p.terminate()
            let end = Date().addingTimeInterval(10)
            while p.isRunning, Date() < end { usleep(10_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        return p
    }

    /// Starts the site server and the reference AS/MCP pair with `toggles`; waits (condition-based, bounded) until all
    /// three endpoints answer — the CIMD file, the AS metadata **and** the MCP server's protected-resource metadata
    /// (mcp.ts starts the AS before the MCP listener, so the AS answering did not mean the MCP port was up).
    /// Ports come from the OS (free when picked), and an answer only counts once each port's listener is one of
    /// *these* processes: other worktrees run the same suite on this Mac, and with random ports from a fixed range a
    /// server of theirs could hold one of ours, answer the probes, and then vanish mid-test (refused + "authorization
    /// failed (500)" under load, 2026-11-08). A pair that loses a port race is restarted on fresh ports, up to 3 times.
    static func start(_ toggles: [String], test: XCTestCase, timeout: Duration = .seconds(60)) async throws -> Server {
        try FileManager.default.createDirectory(at: atDir, withIntermediateDirectories: true)
        for attempt in 1...3 {
            let ports = try freePorts(3)
            let (mcpPort, asPort, sitePort) = (ports[0], ports[1], ports[2])
            let site = try run("/usr/bin/python3", ["-I", "-m", "http.server", "\(sitePort)", "--bind", "127.0.0.1", "-d",
                                                    repo.appendingPathComponent("site/public").path], test: test)
            let pair = try run(node!, [repo.appendingPathComponent("tools/mcp-ref/mcp.ts").path, "--port", "\(mcpPort)", "--as-port", "\(asPort)",
                                       "--issued-file", issued.path] + toggles, test: test)
            let s = Server(mcp: URL(string: "http://127.0.0.1:\(mcpPort)/mcp")!, asBase: URL(string: "http://127.0.0.1:\(asPort)")!,
                           cimd: URL(string: "http://127.0.0.1:\(sitePort)/oauth/mcp-client-metadata.json")!)
            let owners = [mcpPort: pair.processIdentifier, asPort: pair.processIdentifier, sitePort: site.processIdentifier]
            let probes = [s.cimd, s.asBase.appendingPathComponent(".well-known/oauth-authorization-server"),
                          URL(string: "http://127.0.0.1:\(mcpPort)/.well-known/oauth-protected-resource/mcp")!]
            var pending = Set(probes)
            let deadline = ContinuousClock.now + timeout
            while !pending.isEmpty, ContinuousClock.now < deadline, site.isRunning, pair.isRunning {
                for u in pending {
                    if let (_, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200 { pending.remove(u) }
                }
                if !pending.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            }
            let ours = pending.isEmpty && owners.allSatisfy { port, pid in listeners(port).contains(pid) }
            if ours, site.isRunning, pair.isRunning {
                log("start \(toggles.joined(separator: " ")) mcp=\(s.mcp.absoluteString) attempt=\(attempt)")
                return s
            }
            if pending.isEmpty || !site.isRunning || !pair.isRunning {
                // Answered by someone else's server, or one of ours died (port taken): new ports.
                site.terminate()
                pair.terminate()
                continue
            }
            XCTFail("\(pending.map(\.absoluteString)) did not answer within \(timeout)")  // both alive, silent: real failure
            return s
        }
        XCTFail("reference AS/MCP did not start on 3 port picks")
        throw CocoaError(.featureUnsupported)
    }

    /// `n` distinct TCP ports the OS reports free on 127.0.0.1 (all bound at once, then released).
    static func freePorts(_ n: Int) throws -> [Int] {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        var ports: [Int] = []
        for _ in 0..<n {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EMFILE) }
            fds.append(fd)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
            }
            guard ok else { throw POSIXError(.EADDRINUSE) }
            ports.append(Int(UInt16(bigEndian: addr.sin_port)))
        }
        return ports
    }

    /// PIDs listening on TCP `port` (lsof).
    static func listeners(_ port: Int) -> Set<Int32> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) })
    }

    /// The AS's request log (`cimd …`, `dcr …`, `authorize <kind> method=S256`, `token refresh …`).
    static func asLog(_ s: Server) async throws -> [String] {
        let (d, _) = try await URLSession.shared.data(from: s.asBase.appendingPathComponent("log"))
        return (try JSONSerialization.jsonObject(with: d) as? [String]) ?? []
    }

    static func revokeAll(_ s: Server) async throws {
        var r = URLRequest(url: s.asBase.appendingPathComponent("revoke-all"))
        r.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: r)
    }

    /// Test hook: every access token the AS issued is now past its expiry (refresh tokens stay valid). Replaces a
    /// 1 s `--token-ttl` + fixed sleeps, which failed under host load: refreshed tokens also lived 1 s and could
    /// expire again in the middle of a reconnect.
    static func expireAccessTokens(_ s: Server) async throws {
        var r = URLRequest(url: s.asBase.appendingPathComponent("expire-access"))
        r.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: r)
    }

    /// Bounded condition wait: polls the MCP endpoint with `token` until it answers 401 `invalid_token` (the state
    /// the client must recover from). Fails the test if that does not happen within `timeout`.
    static func waitUntilRejected(_ s: Server, token: String, timeout: Duration = .seconds(30),
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        var r = URLRequest(url: s.mcp)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let (_, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse, h.statusCode == 401,
               h.value(forHTTPHeaderField: "WWW-Authenticate")?.contains(#"error="invalid_token""#) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the access token was still accepted after \(timeout)", file: file, line: line)
    }

    /// A host over an in-memory DB, the real Keychain and the headless presenter.
    static func host(_ s: Server, presenter: any MCPAuthPresenter = HeadlessAuthPresenter(),
                     redirect: URL = URL(string: "antichat://oauth/callback")!) throws -> MCPHost {
        let settings = MCPOAuthSettings(cimdURL: s.cimd, redirectURI: redirect, allowLoopbackHTTP: true)
        return MCPHost(database: try AppDatabase.inMemory(), secrets: KeychainSecrets(), policy: .shared,
                       oauth: MCPOAuthEnvironment(settings: settings, presenter: presenter))
    }
}

/// Rewrites each callback's `code` to the first code it ever saw (an attacker replaying a used code).
final class ReplayingPresenter: MCPAuthPresenter, @unchecked Sendable {
    let inner = HeadlessAuthPresenter()
    private let lock = NSLock()
    private var firstCode: String?

    func present(_ url: URL, callbackScheme: String) async throws -> URL {
        let cb = try await inner.present(url, callbackScheme: callbackScheme)
        var c = URLComponents(url: cb, resolvingAgainstBaseURL: false)!
        let code = c.queryItems?.first { $0.name == "code" }?.value
        let use = lock.withLock { () -> String? in
            if firstCode == nil { firstCode = code }
            return firstCode
        }
        c.queryItems = c.queryItems?.map { $0.name == "code" ? URLQueryItem(name: "code", value: use) : $0 }
        return c.url!
    }
}
#endif
