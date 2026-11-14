// M7.T06 step 9 / AT-258 (R-258): initialize + tools/list + one tools/call against three 2025-11-25 reference
// servers from tools/mcp-ref (lockfile-exact `npm ci --ignore-scripts`; never `npx --yes`): server-everything over
// Streamable HTTP through the app's own path (MCPHost → MCPHTTPTransport → NetworkGate `.mcp`, one ledger row per
// request), server-filesystem (temp dir) and server-memory over stdio (StdioPipeTransport). The 2026-07-28 profile
// is recorded `pending PR #314` (A-M7-03; no swift-sdk or TS SDK release speaks it). Writes build/at/AT-258/<date>.json.
// Needs Node ≥ 24 (Q-007); without node_modules the test records "not run" and skips.
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class InteropTests: XCTestCase {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u
    }()
    static let bin = repo.appendingPathComponent("tools/mcp-ref/node_modules/.bin")
    static let node: String? = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }

    func process(_ script: String, _ args: [String], env: [String: String] = [:]) throws -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.node!)
        p.arguments = [Self.bin.appendingPathComponent(script).resolvingSymlinksInPath().path] + args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()].merging(env) { $1 }
        let i = Pipe(), o = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        try p.run()
        addTeardownBlock { p.terminate() }
        return (p, i, o)
    }

    func stdio(_ script: String, _ args: [String], tool: String, arguments: String, env: [String: String] = [:]) async throws -> [String: Any] {
        let (_, i, o) = try process(script, args, env: env)
        let c = MCPConnection(serverID: script, transport: StdioPipeTransport(readingFrom: o.fileHandleForReading, writingTo: i.fileHandleForWriting))
        NSLog("AT-258 \(script): open")
        let v = try await c.open()
        NSLog("AT-258 \(script): negotiated \(v)")
        let tools = try await c.listTools()
        NSLog("AT-258 \(script): \(tools.count) tools")
        let r = try await c.call(tool, argumentsJSON: arguments)
        NSLog("AT-258 \(script): \(tool) ok=\(!r.isError)")
        await c.close()
        return ["negotiated": v, "transport": "stdio", "tools": tools.count, "call": tool, "call_ok": !r.isError]
    }

    func testThreeReferenceServers() async throws {
        guard Self.node != nil, FileManager.default.fileExists(atPath: Self.bin.path) else {
            throw XCTSkip("not run: node or tools/mcp-ref/node_modules missing (npm ci --ignore-scripts)")
        }
        var out: [String: Any] = [:]
        // 1. server-everything over Streamable HTTP, the app's own path.
        let port = 39_000 + Int.random(in: 0..<900)
        _ = try process("mcp-server-everything", ["streamableHttp"], env: ["PORT": "\(port)"])
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let db = try AppDatabase.inMemory()
        let policy = NetworkPolicyStore.shared  // the gate checks the shared store; restore its .mcp value after
        let wasOn = policy.storedValue(.mcp)
        defer { policy.setEnabled(.mcp, wasOn) }
        let rows = Rows()
        let token = NetworkGate.addObserver { e in if e.category == .mcp { rows.add(e.host) } }
        defer { NetworkGate.removeObserver(token) }
        let host = MCPHost(database: db, secrets: MemorySecrets(), policy: policy)
        var preview: MCPPreview?
        for _ in 0..<50 {  // the server needs a moment to listen
            preview = try? await host.preview(url: url, auth: .none)
            if preview != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let p = try XCTUnwrap(preview, "server-everything did not answer")
        let row = try await host.add(name: "Everything", url: url, auth: .none, preview: p)
        XCTAssertEqual(row.state, .connected)
        let echo = try await host.call(server: row.id, tool: "echo", argumentsJSON: #"{"message":"hi"}"#)
        XCTAssertTrue(echo.text.contains("hi"), echo.text)
        XCTAssertGreaterThan(rows.count, 0, "MCP requests left no ledger rows")
        out["server-everything@2.2.1"] = ["negotiated": p.protocolVersion, "transport": "streamable-http", "tools": p.tools.count,
                                          "call": "echo", "call_ok": !echo.isError, "ledger_rows_mcp": rows.count]
        NSLog("AT-258 everything: ok (\(rows.count) ledger rows)")
        await host.closeAll()
        // 2. server-filesystem on a temp dir, 3. server-memory.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("interop-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        out["server-filesystem@2.2.0"] = try await stdio("mcp-server-filesystem", [dir.path], tool: "list_directory",
                                                         arguments: #"{"path":"\#(dir.path)"}"#)
        out["server-memory@2.1.0"] = try await stdio("mcp-server-memory", [], tool: "read_graph", arguments: "{}",
                                                      env: ["MEMORY_FILE_PATH": dir.appendingPathComponent("memory.jsonl").path])
        for (k, v) in out { XCTAssertEqual((v as? [String: Any])?["negotiated"] as? String, "2025-11-25", k) }
        out["modern_profile"] = ModernProfile.status
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let atDir = Self.repo.appendingPathComponent("build/at/AT-258")
        try FileManager.default.createDirectory(at: atDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: atDir.appendingPathComponent("\(f.string(from: Date())).json"))
    }

    final class Rows: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []
        func add(_ h: String) { lock.withLock { hosts.append(h) } }
        var count: Int { lock.withLock { hosts.count } }
    }
}
