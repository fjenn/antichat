// M6.T09 step 2 (R-273 AC1, P-files-tools-05/06): one offscreen WKWebView that runs the vendored JS writers (docx,
// later PptxGenJS and Vega) and hands their output back as base64. Locked down:
//   • non-persistent website data store (no cookies, caches or storage on disk);
//   • a compiled WKContentRuleList that blocks every URL except the app's own `antichat-render://` scheme, which a
//     WKURLSchemeHandler serves from Resources/js only (WebKit traffic bypasses NetworkGate, so this is the gate);
//   • a page CSP of default-src 'none' (no fetch / WebSocket / remote images even if a rule failed to compile);
//   • a document-start guard script disables window.open, link clicks and form submits (WebKit preconnects to a clicked
//     link's host before the rules apply); every navigation that is not the host page is cancelled; no pop-ups;
//     no WKScriptMessageHandler at all — results come back
//     as the promise value of `callAsyncJavaScript`.
// Loaded once and reused (warm); torn down after 5 min idle and recreated on the next call. RenderHostNetworkTests
// proves zero connections (fetch, <img>, WebSocket) on a local probe listener.
import AppKit
import CryptoKit
import Foundation
import WebKit

public enum RenderHostError: Error, CustomStringConvertible, Sendable {
    case loadFailed(String)
    case script(String)
    case badResult

    public var description: String {
        switch self {
        case .loadFailed(let m): "the render page did not load: \(m)"
        case .script(let m): "the renderer failed: \(m)"
        case .badResult: "the renderer returned no data"
        }
    }
}

@MainActor
public final class RenderHost: NSObject {
    public static let shared = RenderHost()
    nonisolated public static let scheme = "antichat-render"
    nonisolated static let pageURL = URL(string: "\(scheme)://host/renderhost.html")!
    public static var idleTimeout: Duration = .seconds(300)

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loading: Task<WKWebView, Error>?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var idleTask: Task<Void, Never>?
    /// Navigations the host cancelled (tests).
    public private(set) var cancelledNavigations: [URL] = []
    /// How often the page was (re)created (tests: warm reuse, idle recreation).
    public private(set) var loads = 0

    override init() { super.init() }

    /// Runs before any page script: WebKit opens a TCP connection for a clicked link or a window.open() target before
    /// the content rules and the navigation policy cancel the load (RenderHostNetworkTests saw it), so the page can
    /// neither open windows nor follow links at all.
    nonisolated static let guardScript = """
        (function () {
          Object.defineProperty(window, "open", { value: function () { return null; }, writable: false, configurable: false });
          document.addEventListener("click", function (e) {
            if (e.target && e.target.closest && e.target.closest("a, area")) { e.preventDefault(); e.stopImmediatePropagation(); }
          }, true);
          HTMLAnchorElement.prototype.click = function () {};
          HTMLFormElement.prototype.submit = function () {};
          document.addEventListener("submit", function (e) { e.preventDefault(); }, true);
        })();
        """

    nonisolated static let rulesJSON: String = {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^\(scheme):"], "action": ["type": "ignore-previous-rules"]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    static func ruleList() async throws -> WKContentRuleList {
        let id = "antichat.renderhost." + SHA256.hash(data: Data(rulesJSON.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let store = WKContentRuleListStore.default() else { throw RenderHostError.loadFailed("no rule store") }
        if let cached = try? await store.contentRuleList(forIdentifier: id) { return cached }
        guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: rulesJSON) else {
            throw RenderHostError.loadFailed("content rules did not compile")
        }
        return list
    }

    /// The loaded page (creates it on first use or after the idle teardown).
    func page() async throws -> WKWebView {
        if let webView { return webView }
        if let loading { return try await loading.value }
        let task = Task<WKWebView, Error> { @MainActor in
            let rules = try await Self.ruleList()
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(rules)
            config.userContentController.addUserScript(WKUserScript(source: Self.guardScript, injectionTime: .atDocumentStart,
                                                                    forMainFrameOnly: false, in: .page))
            config.setURLSchemeHandler(self, forURLScheme: Self.scheme)
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            view.navigationDelegate = self
            view.uiDelegate = self
            // Hosted in a never-shown window so WebKit does not throttle the page as hidden.
            let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless],
                             backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.contentView = view
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                loadContinuation = c
                view.load(URLRequest(url: Self.pageURL))
            }
            window = w
            webView = view
            loads += 1
            return view
        }
        loading = task
        defer { loading = nil }
        return try await task.value
    }

    /// Runs `body` (an async function body; `payload` is bound to the argument) in the page and returns its string
    /// result. The renderers use `return await AntiChatRender.<name>(payload)`.
    public func call(_ body: String, payload: String) async throws -> String {
        let view = try await page()
        touch()
        do {
            let result = try await view.callAsyncJavaScript(body, arguments: ["payload": payload], in: nil, contentWorld: .page)
            touch()
            guard let s = result as? String else { throw RenderHostError.badResult }
            return s
        } catch let e as RenderHostError {
            throw e
        } catch {
            touch()
            let info = (error as NSError).userInfo
            let msg = (info["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
            throw RenderHostError.script(msg)
        }
    }

    /// Base64 result of `body` decoded.
    public func callData(_ body: String, payload: String) async throws -> Data {
        guard let d = Data(base64Encoded: try await call(body, payload: payload)) else { throw RenderHostError.badResult }
        return d
    }

    /// Evaluates `js` in the page (tests: the network probe).
    public func evaluate(_ js: String) async throws -> Any? {
        let view = try await page()
        touch()
        return try await view.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }

    /// Drops the page now (tests; the idle timer does it after `idleTimeout`).
    public func tearDown() {
        idleTask?.cancel()
        idleTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
    }

    private func touch() {
        idleTask?.cancel()
        let timeout = Self.idleTimeout
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.tearDown()
        }
    }

    // MARK: resources

    nonisolated static func resource(for url: URL) -> (Data, String)? {
        guard url.scheme == scheme, url.host == "host" else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains(".."), name == url.path.split(separator: "/").last.map(String.init),
              let dir = Bundle.module.url(forResource: "js", withExtension: nil) else { return nil }
        let file = dir.appendingPathComponent(name)
        guard file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
              let data = try? Data(contentsOf: file) else { return nil }
        let mime = name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".js") ? "text/javascript" : "application/octet-stream"
        return (data, mime)
    }
}

extension RenderHost: WKURLSchemeHandler {
    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (data, mime) = Self.resource(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "\(mime); charset=utf-8", "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

extension RenderHost: WKUIDelegate {
    /// No pop-ups, ever.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { cancelledNavigations.append(url) }
        return nil
    }
}

extension RenderHost: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.request.url == Self.pageURL, action.targetFrame?.isMainFrame == true { return .allow }
        if let url = action.request.url { cancelledNavigations.append(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: RenderHostError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: RenderHostError.loadFailed(error.localizedDescription))
        loadContinuation = nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page crashed: drop it; the next call recreates it.
        if webView === self.webView { tearDown() }
    }
}
