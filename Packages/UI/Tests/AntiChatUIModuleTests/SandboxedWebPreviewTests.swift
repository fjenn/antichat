// M4.T11 task check `SandboxedWebPreviewTests`: fixtures/web/preview/network-probe.html (img, script src, stylesheet,
// iframe, fetch, sendBeacon, prefetch / dns-prefetch / preconnect, a JS redirect) loads with ZERO network. The probe
// host is rewritten to a local listener that counts TCP connections (WebKit's network process is not our child, so
// this counts what actually leaves WebKit); every in-page probe must report "blocked"; the redirect is cancelled.
import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import AntiChatUI

/// Counts accepted TCP connections on 127.0.0.1:<port>.
final class CountingListener: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "counting-listener")
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            self?.lock.withLock { self?._count += 1 }
            c.cancel()
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            final class Once: @unchecked Sendable { var done = false }  // touched only on `queue` (serial)
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e): once.done = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .enabled(if: FileFixtures.available, "fixtures/docs missing"), .isolatedSettings)
struct SandboxedWebPreviewTests {
    static var probe: URL { FileFixtures.root!.appendingPathComponent("web/preview/network-probe.html") }
    static var svg: URL { FileFixtures.root!.appendingPathComponent("web/preview/page.svg") }

    /// Copy of `source` with the probe host pointed at the local listener (http so a connection would be plain TCP).
    func rewritten(_ source: URL, port: UInt16) throws -> URL {
        let dir = try FileFixtures.scratch()
        let text = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "https://antichat-probe.invalid", with: "http://127.0.0.1:\(port)")
        let out = dir.appendingPathComponent(source.lastPathComponent)
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    func render(_ url: URL) async -> (SandboxedWebController, NSWindow) {
        let controller = await SandboxedWebController.make(fileURL: url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = controller.webView
        controller.load()
        await controller.waitUntilLoaded()
        return (controller, window)
    }

    @Test func rulesBlockEverythingButAboutAndFiles() throws {
        let json = SandboxedWebController.rulesJSON
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]])
        #expect(rules.first?["trigger"]?["url-filter"] == ".*" && rules.first?["action"]?["type"] == "block")
        #expect(rules.contains { $0["trigger"]?["url-filter"] == "^about:" })
        #expect(rules.last?["action"]?["type"] == "ignore-previous-rules")
        #expect(rules.last?["trigger"]?["url-filter"] == "^file:", "file reads are limited by allowingReadAccessTo")
    }

    /// M6 review #8: one compiled list for every preview (none per previewed path left in WebKit's store).
    @Test func oneRuleListForAllPreviews() async throws {
        let dir = try FileFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A store of its own (WebKit's default store is shared with every other test process of this user).
        let storeDir = dir.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = try #require(WKContentRuleListStore(url: storeDir))
        // A per-path list an earlier build left behind is removed on first use.
        _ = try await store.compileContentRuleList(forIdentifier: SandboxedWebController.ruleIdentifierPrefix + "stale",
                                                   encodedContentRuleList: SandboxedWebController.rulesJSON)
        for n in 0..<3 {
            let u = dir.appendingPathComponent("p\(n).svg")
            try "<svg xmlns='http://www.w3.org/2000/svg'/>".write(to: u, atomically: true, encoding: .utf8)
            let c = await SandboxedWebController.make(fileURL: u, ruleStore: storeDir)
            #expect(c.hasRules)
        }
        let ids = (try await store.availableIdentifiers() ?? []).filter { $0.hasPrefix(SandboxedWebController.ruleIdentifierPrefix) }
        #expect(ids == [SandboxedWebController.ruleIdentifier], "\(ids)")
    }

    /// M6 review #8: without the content rules nothing loads (fail closed) and the error is reported.
    @Test func noRulesRefusesToRender() async throws {
        let c = SandboxedWebController(fileURL: Self.svg, mode: .svg, rules: nil)
        c.load()
        await c.waitUntilLoaded()
        #expect(c.webView.url == nil && !c.webView.isLoading)
        #expect(c.errors == [SandboxedWebController.noSandboxError])
    }

    /// M6 review #8: the CSP meta goes into <head>, never into a <header>; a page without <head> gets it first.
    @Test func cspLandsInTheHead() {
        let headerOnly = PreviewPages.withCSP("<body><header>Title</header><p>x</p></body>")
        #expect(headerOnly.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""), "\(headerOnly.prefix(120))")
        let both = PreviewPages.withCSP("<html><head lang=en><title>t</title></head><body><header>h</header></body></html>")
        #expect(both.contains("<head lang=en><meta http-equiv=\"Content-Security-Policy\""))
        #expect(!both.contains("<header><meta"))
        let react = PreviewPages.reactHTML("<body><header>h</header><script type='text/babel'>1</script></body>", dark: false)
        #expect(react.hasPrefix("<meta http-equiv=\"Content-Security-Policy\""))
    }

    @Test func probePageMakesZeroConnections() async throws {
        let listener = try CountingListener()
        let port = try await listener.start()
        // Sanity: the listener does count a real connection.
        let sanity = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        sanity.start(queue: .global())
        for _ in 0..<50 where listener.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        sanity.cancel()
        #expect(listener.count == 1, "listener must see a plain TCP connect")

        let page = try rewritten(Self.probe, port: port)
        let (controller, _) = await render(page)
        #expect(controller.webView.configuration.websiteDataStore.isPersistent == false)
        // Let every probe (incl. the 50 ms redirect, prefetch and beacon) run.
        var title = ""
        for _ in 0..<100 {
            title = controller.webView.title ?? ""
            if title.contains("fetch") && title.contains("image") { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(title.contains(#""fetch":"blocked""#), "fetch: \(title)")
        #expect(title.contains(#""image":"blocked""#), "image: \(title)")
        #expect(listener.count == 1, "the page reached the network \(listener.count - 1) time(s)")
        // M6.T13: HTML previews load as a string (about:blank); the redirect must not have replaced it.
        #expect(controller.webView.url?.host != "127.0.0.1", "redirect was followed")
        #expect(controller.deniedNavigations.contains { $0.host == "127.0.0.1" }, "the JS redirect is refused and logged")
    }

    @Test func svgRendersWithJavaScriptOffAndNoNetwork() async throws {
        let listener = try CountingListener()
        let port = try await listener.start()
        let svg = try rewritten(Self.svg, port: port)
        let (controller, _) = await render(svg)
        #expect(controller.content == .svg)
        #expect(controller.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        try await Task.sleep(for: .seconds(1))
        #expect(listener.count == 0)
        let image = try await controller.webView.takeSnapshot(configuration: nil)
        #expect(image.size.width > 0)
    }
}
}  // extension WindowSuites
