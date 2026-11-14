// M2.T08 definition of done: a real anonymous download of `chat-0.8b` (bundled catalog; Hugging Face `/resolve/<commit>/`
// URLs) through the DownloadCoordinator and NetworkGate, via proxy-logger.py (the `-TestProxy` path), every file
// sha256-verified into the store; no request on the wire carries `Authorization`. Real network: runs only with
// ANTICHAT_REAL_DOWNLOAD=1 (≈ 0.65 GB). Run: `ANTICHAT_REAL_DOWNLOAD=1 make test-unit FILTER=RealStarterDownloadTests`.
@testable import AntiChatNetwork
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_REAL_DOWNLOAD"] == "1"))
struct RealStarterDownloadTests {
    @Test func starterDownloadsAnonymouslyThroughTheGate() async throws {
        let dir = DL.tempDir("real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proxyLog = dir.appending(path: "proxy.log")
        let port = 18899
        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proxy.arguments = ["-I", DL.repoRoot.appending(path: "tools/offline/proxy-logger.py").path, "--port", "\(port)", "--log", proxyLog.path]
        try proxy.run()
        defer { proxy.terminate() }
        try await Task.sleep(for: .milliseconds(500))
        NetworkGate.testProxy = ["HTTPEnable": true, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
                                 "HTTPSEnable": true, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port]
        defer { NetworkGate.testProxy = nil }
        let headers = Headers()
        TransferEngine.observeWireRequest = { r in headers.add(r) }
        defer { TransferEngine.observeWireRequest = nil }

        let baseline = try #require(CatalogStore.bundledBaseline())
        let model = try #require(try ModelCatalog.decode(baseline.data).models["chat-0.8b"])
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: try AppDatabase.inMemory())
        let t0 = Date()
        let jobs = await dl.enqueue(model: model, pack: "chat")
        for j in jobs { #expect(await dl.wait(j.id)?.state == .done, "\(j.request.sources.first?.lastPathComponent ?? "?")") }
        let secs = Date().timeIntervalSince(t0)
        for f in model.files { #expect(try Verify.sha256(dl.blobs.url(f.sha256)) == f.sha256, "\(f.path)") }
        #expect(model.files.allSatisfy { $0.sources.allSatisfy { $0.contains("/resolve/\(model.commit)/") } })
        let sent = headers.all
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let connects = (try? String(contentsOf: proxyLog, encoding: .utf8)) ?? ""
        #expect(connects.contains("CONNECT huggingface.co:443"))
        ATLog.write("AT-204", "real-starter.log", String(format: "chat-0.8b %d files %.0f MB in %.1f s through proxy-logger; %d wire requests, 0 with Authorization; hosts: %@",
            model.files.count, Double(model.totalBytes) / 1e6, secs, sent.count,
            Set(sent.compactMap { $0.url?.host }).sorted().joined(separator: ",")))
    }
}

final class Headers: @unchecked Sendable {
    private let lock = NSLock()
    private var r: [URLRequest] = []
    func add(_ x: URLRequest) { lock.withLock { r.append(x) } }
    var all: [URLRequest] { lock.withLock { r } }
}
