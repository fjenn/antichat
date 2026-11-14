// M6.T09 task check `RenderHostNetworkTests` (AT-273 check 1, step 11): WKWebView traffic bypasses NetworkGate, so the
// RenderHost page is proven offline here. A page script tries fetch(), an <img>, a WebSocket and an XHR to a local
// listener that counts TCP connections (WebKit's network process is not our child, so this counts what actually leaves
// WebKit), and page-initiated navigations (location, link click, window.open) to the listener: every probe must fail and the listener must see 0 connections.
import Foundation
import Network
import Testing
@testable import AntiChatTools

/// Counts accepted TCP connections on 127.0.0.1:<port>.
final class ProbeListener: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "renderhost-probe")
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
            final class Once: @unchecked Sendable { var done = false }
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

@MainActor
@Suite(.serialized)
struct RenderHostNetworkTests {
    @Test func rulesBlockEverythingButTheRenderScheme() throws {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(RenderHost.rulesJSON.utf8)) as? [[String: [String: String]]])
        #expect(rules.first?["trigger"]?["url-filter"] == ".*" && rules.first?["action"]?["type"] == "block")
        #expect(rules.last?["trigger"]?["url-filter"] == "^antichat-render:" && rules.last?["action"]?["type"] == "ignore-previous-rules")
        #expect(RenderHost.resource(for: URL(string: "antichat-render://host/../Package.swift")!) == nil)
        #expect(RenderHost.resource(for: URL(string: "antichat-render://host/bridge-docx.js")!) != nil)
        #expect(RenderHost.resource(for: URL(string: "https://host/bridge-docx.js")!) == nil)
    }

    @Test func pageMakesZeroConnections() async throws {
        let listener = try ProbeListener()
        let port = try await listener.start()
        let sanity = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        sanity.start(queue: .global())
        for _ in 0..<50 where listener.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        sanity.cancel()
        #expect(listener.count == 1, "the listener must count a plain TCP connect")

        let host = RenderHost.shared
        let base = "http://127.0.0.1:\(port)"
        let js = """
            const out = {};
            try { await fetch("\(base)/probe"); out.fetch = "reached"; } catch (e) { out.fetch = "blocked"; }
            out.image = await new Promise((res) => { const i = new Image(); i.onload = () => res("reached");
                i.onerror = () => res("blocked"); i.src = "\(base)/pixel.png?" + Date.now(); setTimeout(() => res("timeout"), 3000); });
            out.ws = await new Promise((res) => { try { const w = new WebSocket("ws://127.0.0.1:\(port)/ws");
                w.onopen = () => res("reached"); w.onerror = () => res("blocked"); setTimeout(() => res("timeout"), 3000); }
                catch (e) { res("blocked"); } });
            out.xhr = await new Promise((res) => { const x = new XMLHttpRequest(); x.onload = () => res("reached");
                x.onerror = () => res("blocked"); try { x.open("GET", "\(base)/xhr"); x.send(); } catch (e) { res("blocked"); } });
            out.beacon = navigator.sendBeacon ? String(navigator.sendBeacon("\(base)/beacon", "x")) : "none";
            return JSON.stringify(out);
            """
        let result = try await host.evaluate(js) as? String ?? ""
        try await Task.sleep(for: .seconds(1))
        let afterScript = listener.count
        #expect(result.contains(#""fetch":"blocked""#), "fetch: \(result)")
        #expect(!result.contains("reached"), "a probe reached the network: \(result)")
        // Page-initiated navigations (the only kind the page could make): location change, link click, window.open.
        _ = try? await host.evaluate("""
            setTimeout(() => { location.href = "\(base)/navigate"; }, 0);
            const a = document.createElement("a"); a.href = "\(base)/link"; document.body.appendChild(a); a.click();
            window.open("\(base)/popup"); return "ok";
            """)
        try await Task.sleep(for: .seconds(1.5))
        #expect(host.cancelledNavigations.contains { $0.absoluteString.hasPrefix(base) }, "the location change was not cancelled")
        #expect(afterScript == 1, "the page script reached the network \(afterScript - 1) time(s): \(result)")
        #expect(listener.count == 1, "RenderHost reached the network \(listener.count - 1) time(s) (after navigating: \(listener.count - afterScript))")
        // The page still renders after the probes.
        let still = try await host.evaluate("return typeof AntiChatRender.docx;") as? String
        #expect(still == "function")
    }

    @Test func idleTeardownRecreatesThePage() async throws {
        let host = RenderHost.shared
        _ = try await host.evaluate("return 1;")
        let loads = host.loads
        host.tearDown()
        _ = try await host.evaluate("return 1;")
        #expect(host.loads == loads + 1)
    }
}
