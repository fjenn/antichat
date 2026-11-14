// Sandboxed web preview (M4.T11 step 2, P-files-tools-07, Apple WebKit; M6.T13 step 2, R-016 AC2): artifacts render with
// no way out. Non-persistent data store; a compiled WKContentRuleList (Resources/ContentRules/block-all.json) blocks
// every URL except `about:` and — added per load — the previewed file's own `file://` URL; every navigation after the
// first load is cancelled; no URLSession anywhere. WebKit's network process is not a child of the app, so the tests
// count connections on a local listener instead of trusting sandbox logs.
// Modes (M6.T13):
//   html    — the page itself (as a string, CSP injected), JavaScript on;
//   svg     — the file itself, JavaScript off;
//   react   — a `jsx` / `tsx` block (or an HTML page importing React) wrapped in a page with the vendored React 18.3.1 UMD
//             + @babel/standalone (A-M6-08): `Babel.transform(src, {presets: ['react', 'typescript']})`, the default
//             export mounted into #root;
//   mermaid — M1's mermaid 12.2.0; vega — the T09 Vega / Vega-Lite / vega-embed bundles.
// Generated pages load with `loadHTMLString` (base: the never-resolving `pageOrigin`, see there); every bundled script is inlined (no URL loads) and a CSP
// `default-src 'none'` meta is injected. The only message handler is `previewError` (window errors, unhandled
// rejections, render failures) → the panel's `panel.fix`.
import AntiChatHarness
import AntiChatTools
import AppKit
import CryptoKit
import SwiftUI
import WebKit

/// What the panel's web preview renders.
public enum PreviewMode: String, Sendable, Equatable, CaseIterable {
    case html, react, svg, mermaid, vega

    /// From the file name: html/htm, svg, jsx/tsx, mmd/mermaid, *.vl.json / *.vega.json.
    public init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "html", "htm", "xhtml": self = .html
        case "svg": self = .svg
        case "jsx", "tsx": self = .react
        case "mmd", "mermaid": self = .mermaid
        case "json" where name.hasSuffix(".vl.json") || name.hasSuffix(".vega.json"): self = .vega
        default: return nil
        }
    }

    /// From a promoted artifact's kind.
    public init?(kind: ArtifactKind, react: Bool, language: String) {
        switch kind {
        case .html: self = react ? .react : .html
        case .svg: self = .svg
        case .mermaid: self = .mermaid
        case .chart: self = .vega
        case .code, .doc: return nil
        }
    }

    public var allowsJavaScript: Bool { self != .svg }
    /// The page is generated (loadHTMLString) rather than the file itself.
    /// The page is loaded as a string (`loadHTMLString(_, baseURL: nil)`, CSP injected): everything but plain SVG, which
    /// loads as the file itself with JavaScript off. (A string page also gets full error messages for `previewError`;
    /// a file:// page reports only "Script error.")
    var isGenerated: Bool { self != .svg }
}

@MainActor
public final class SandboxedWebController: NSObject, WKNavigationDelegate {
    public enum Content: Equatable, Sendable { case html, svg }

    public let webView: WKWebView
    public let fileURL: URL
    public let mode: PreviewMode
    public var content: Content { mode == .svg ? .svg : .html }
    /// Navigations the delegate refused (logged for tests; never followed).
    public private(set) var deniedNavigations: [URL] = []
    /// JavaScript errors the page reported through `previewError` (newest last).
    public private(set) var errors: [String] = []
    public var onError: ((String) -> Void)?
    private var firstLoadDone = false
    /// The block-all content rules are installed (false: `load` refuses to render).
    public let hasRules: Bool
    nonisolated static let noSandboxError = "The preview sandbox is unavailable, so this preview was not shown."

    private var finished: [CheckedContinuation<Void, Never>] = []
    private var didFinish = false

    nonisolated static let ruleIdentifierPrefix = "antichat.preview.block-all."
    /// The origin of generated pages. A string page with `baseURL: nil` has an opaque origin, and WebKit mutes its
    /// error messages ("Script error."), so `panel.fix` would have nothing to send; this `.invalid` origin never
    /// resolves and every load from it is blocked by the rule list like any other URL.
    nonisolated static let pageOrigin = URL(string: "https://antichat-preview.invalid/")!
    static let errorHandlerName = "previewError"

    /// The bundled block-all rules plus `file:` (M6 review #8: one static list, compiled once, instead of one per
    /// previewed path left in WebKit's store forever, incognito paths included). Which file a page may read is
    /// `loadFileURL(_:allowingReadAccessTo:)`'s job: read access to the previewed file only.
    nonisolated static let rulesJSON: String = {
        let base = Bundle.module.url(forResource: "block-all", withExtension: "json", subdirectory: "ContentRules")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            ?? [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        let rules = base + [["trigger": ["url-filter": "^file:"], "action": ["type": "ignore-previous-rules"]]]
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }()

    nonisolated static var ruleIdentifier: String {
        ruleIdentifierPrefix + "v2." + SHA256.hash(data: Data(rulesJSON.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The compiled list (nil = WebKit could not compile it: the preview then refuses to render). The first call also
    /// removes the per-path lists earlier builds compiled into the store.
    /// `storeURL`: a store directory instead of WebKit's default one (tests).
    static func ruleList(storeURL: URL? = nil) async -> WKContentRuleList? {
        guard let store = storeURL.map({ WKContentRuleListStore(url: $0) }) ?? WKContentRuleListStore.default() else { return nil }
        if !purgedStores.contains(storeURL?.path ?? "") {
            purgedStores.insert(storeURL?.path ?? "")
            let ids = (try? await store.availableIdentifiers()) ?? []
            for id in ids where id.hasPrefix(ruleIdentifierPrefix) && id != ruleIdentifier {
                try? await store.removeContentRuleList(forIdentifier: id)
            }
        }
        if let cached = try? await store.contentRuleList(forIdentifier: ruleIdentifier) { return cached }
        return try? await store.compileContentRuleList(forIdentifier: ruleIdentifier, encodedContentRuleList: rulesJSON)
    }
    private static var purgedStores: Set<String> = []

    public static func content(for url: URL) -> Content {
        url.pathExtension.lowercased() == "svg" ? .svg : .html
    }

    /// The mode for a file: `mode` if given, else from its name; an HTML file that imports React runs as React.
    static func resolve(_ mode: PreviewMode?, for url: URL) -> PreviewMode {
        let m = mode ?? PreviewMode(url: url) ?? .html
        if m == .html, let s = try? String(contentsOf: url, encoding: .utf8), OutputPromotion.importsReact(s) { return .react }
        return m
    }

    /// Builds the web view with the rules already installed (no load can happen before them).
    public static func make(fileURL: URL, mode: PreviewMode? = nil, ruleStore: URL? = nil) async -> SandboxedWebController {
        let rules = await ruleList(storeURL: ruleStore)
        return SandboxedWebController(fileURL: fileURL, mode: resolve(mode, for: fileURL), rules: rules)
    }

    init(fileURL: URL, mode: PreviewMode, rules: WKContentRuleList?) {
        self.fileURL = fileURL
        self.mode = mode
        self.hasRules = rules != nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = mode.allowsJavaScript
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        if let rules { config.userContentController.add(rules) }
        if mode.allowsJavaScript {
            config.userContentController.addUserScript(
                WKUserScript(source: PreviewPages.errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        super.init()
        if mode.allowsJavaScript {
            config.userContentController.add(ErrorProxy(self), contentWorld: .page, name: Self.errorHandlerName)
        }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    /// The source text of the previewed file.
    public var source: String { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }

    /// Loads the preview: the file itself (html / svg, read access to the file only) or a generated page. Without the
    /// content rules nothing loads (fail closed, M6 review #8): the page reports an error instead.
    public func load(dark: Bool = false) {
        guard hasRules else {
            reported(Self.noSandboxError)
            markFinished()
            return
        }
        if mode.isGenerated {
            let page = PreviewPages.page(mode: mode, source: source, dark: dark)
            webView.loadHTMLString(page, baseURL: Self.pageOrigin)
        } else {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
        }
    }

    /// Waits for the first load to finish (or fail).
    public func waitUntilLoaded() async {
        if didFinish { return }
        await withCheckedContinuation { finished.append($0) }
    }

    /// Waits until a generated page finished rendering (`window.__antichatReady`) or reported an error; at most
    /// `timeout`. File pages are ready once loaded.
    @discardableResult
    public func waitUntilRendered(timeout: Duration = .seconds(10)) async -> Bool {
        await waitUntilLoaded()
        guard mode == .react || mode == .mermaid || mode == .vega else { return true }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let ready = try? await webView.evaluateJavaScript("window.__antichatReady === true") as? Bool, ready { return true }
            if !errors.isEmpty { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    fileprivate func reported(_ message: String) {
        errors.append(message)
        onError?(message)
    }

    private func markFinished() {
        didFinish = true
        let waiting = finished
        finished = []
        waiting.forEach { $0.resume() }
    }

    // MARK: Export (R-016 AC3 `panel.download`)

    /// The rendered drawing as SVG markup (svg: the file; mermaid: the drawn diagram; vega: `view.toSVG()`).
    public func svgMarkup() async -> String? {
        switch mode {
        case .svg: return source
        case .mermaid:
            return try? await webView.evaluateJavaScript("(document.querySelector('#d svg')||{}).outerHTML || null") as? String
        case .vega:
            return try? await webView.callAsyncJavaScript("return window.__view ? await window.__view.toSVG() : null",
                                                          arguments: [:], in: nil, contentWorld: .page) as? String
        default: return nil
        }
    }

    /// The preview as PNG (vega: `view.toImageURL('png', 2)`; else a snapshot of the web view).
    public func pngData() async -> Data? {
        if mode == .vega, let url = try? await webView.callAsyncJavaScript(
            "return window.__view ? await window.__view.toImageURL('png', 2) : null", arguments: [:], in: nil,
            contentWorld: .page) as? String, let comma = url.firstIndex(of: ",") {
            return Data(base64Encoded: String(url[url.index(after: comma)...]))
        }
        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The page as PDF (`WKWebView.createPDF`).
    public func pdfData() async -> Data? {
        try? await webView.pdf(configuration: WKPDFConfiguration())
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if !firstLoadDone, action.targetFrame?.isMainFrame == true,
           url?.standardizedFileURL == fileURL.standardizedFileURL || url == Self.pageOrigin {
            firstLoadDone = true
            return .allow
        }
        if url?.scheme == "about" { return .allow }
        if let url { deniedNavigations.append(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { markFinished() }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { markFinished() }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        markFinished()
    }
}

/// Weak bridge: the user content controller retains its handlers.
private final class ErrorProxy: NSObject, WKScriptMessageHandler {
    weak var owner: SandboxedWebController?
    init(_ owner: SandboxedWebController) { self.owner = owner }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = String(String(describing: message.body).prefix(500))
        MainActor.assumeIsolated { owner?.reported(text) }
    }
}

/// The generated preview pages (every script inlined).
@MainActor
enum PreviewPages {
    static let csp = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; "
        + "script-src 'unsafe-inline' 'unsafe-eval'"

    /// Reports page errors to the `previewError` handler (window errors, unhandled rejections).
    static let errorHook = """
    (function () {
      function post(m) { try { window.webkit.messageHandlers.previewError.postMessage(String(m).slice(0, 500)); } catch (e) {} }
      window.__antichatReport = post;
      window.addEventListener('error', function (e) { post((e && e.message) || 'Script error'); });
      window.addEventListener('unhandledrejection', function (e) {
        var r = e && e.reason; post((r && r.message) || String(r));
      });
    })();
    """

    static func js(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: d, as: UTF8.self)
        // `</script>` inside a string literal would end the inline script.
        return String(arr.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }

    static func inline(_ script: PreviewScripts.Script) -> String {
        "<script>\(PreviewScripts.source(script)?.replacingOccurrences(of: "</script", with: "<\\/script") ?? "window.__antichatReport('missing \(script.rawValue)')")</script>"
    }

    static func shell(_ body: String, head: String = "", dark: Bool) -> String {
        let fg = dark ? "#ececec" : "#1f1f1f", bg = dark ? "#212121" : "#ffffff"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>html,body{margin:0;padding:0;background:\(bg);color:\(fg);font:14px -apple-system,system-ui,sans-serif}
        #root,#d,#v{padding:16px}#d,#v{display:flex;justify-content:center}</style>\(head)</head><body>\(body)</body></html>
        """
    }

    static func page(mode: PreviewMode, source: String, dark: Bool) -> String {
        switch mode {
        case .react: OutputPromotion.importsReact(source) && source.range(of: "<html|<body|<script", options: [.regularExpression, .caseInsensitive]) != nil
            ? reactHTML(source, dark: dark) : react(source, dark: dark)
        case .mermaid: mermaid(source, dark: dark)
        case .vega: vega(source, dark: dark)
        case .html: withCSP(source)
        case .svg: source
        }
    }

    /// `<head>` / `<head …>`, never `<header>` (M6 review #8: a CSP meta inside the body is ignored).
    static let headTag = #"<head(\s[^>]*)?>"#

    /// A model-written page with the CSP meta first in its <head> (or before everything when it has none).
    static func withCSP(_ html: String) -> String {
        var s = html
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
        if let head = s.range(of: headTag, options: [.regularExpression, .caseInsensitive]) {
            s.insert(contentsOf: meta, at: head.upperBound)
        } else {
            s = meta + s
        }
        return s
    }

    /// A JSX / TSX module: transpiled by Babel, `import`s of react / react-dom resolved to the vendored globals, the
    /// default export (or the last capitalised function) mounted into #root.
    static func react(_ source: String, dark: Bool) -> String {
        let boot = """
        <script>
        (function () {
          try {
            var out = Babel.transform(\(js(source)), {
              filename: 'artifact.tsx',
              presets: ['react', ['typescript', { isTSX: true, allExtensions: true }]],
              plugins: ['transform-modules-commonjs']
            }).code;
            var module = { exports: {} };
            var require = function (n) {
              if (n === 'react') return React;
              if (n === 'react-dom' || n === 'react-dom/client') return ReactDOM;
              throw new Error('Cannot import "' + n + '" in the preview');
            };
            new Function('module', 'exports', 'require', 'React', 'ReactDOM', out)(module, module.exports, require, React, ReactDOM);
            var C = module.exports && (module.exports.default || module.exports.App);
            var root = document.getElementById('root');
            if (typeof C === 'function') {
              ReactDOM.createRoot(root).render(React.createElement(C));
            } else if (!root.hasChildNodes()) {
              throw new Error('The component has no default export');
            }
            setTimeout(function () { window.__antichatReady = true; }, 0);
          } catch (e) { window.__antichatReport(e && e.message ? e.message : String(e)); }
        })();
        </script>
        """
        return shell("<div id=\"root\"></div>" + inline(.react) + inline(.reactDOM) + inline(.babel) + boot, dark: dark)
    }

    /// An HTML page that loads React from a CDN: those script tags are replaced by the vendored copies (inlined), its
    /// `text/babel` scripts run through Babel standalone, and the CSP is put first in <head>.
    static func reactHTML(_ html: String, dark: Bool) -> String {
        var s = html.replacingOccurrences(
            of: #"<script[^>]*\bsrc\s*=\s*["'][^"']*(react|babel)[^"']*["'][^>]*>\s*</script>"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        let vendored = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">" + inline(.react) + inline(.reactDOM)
            + inline(.babel) + "<script>window.addEventListener('load',function(){setTimeout(function(){window.__antichatReady=true},0)})</script>"
        if let head = s.range(of: headTag, options: [.regularExpression, .caseInsensitive]) {
            s.insert(contentsOf: vendored, at: head.upperBound)
        } else {
            s = vendored + s
        }
        return s
    }

    static func mermaid(_ source: String, dark: Bool) -> String {
        let script = MermaidRenderer.script.map { "<script>\($0.replacingOccurrences(of: "</script", with: "<\\/script"))</script>" }
            ?? "<script>window.__antichatReport('missing mermaid')</script>"
        let boot = """
        <script>
        (async function () {
          try {
            mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: \(dark ? "'dark'" : "'default'"),
                                 fontFamily: '-apple-system, system-ui, sans-serif', flowchart: { htmlLabels: false } });
            var src = \(js(source));
            await mermaid.parse(src);
            var r = await mermaid.render('antichat-diagram', src);
            document.getElementById('d').innerHTML = r.svg;
            window.__antichatReady = true;
          } catch (e) { window.__antichatReport(e && e.message ? e.message : String(e)); }
        })();
        </script>
        """
        return shell("<div id=\"d\"></div>" + script + boot, dark: dark)
    }

    static func vega(_ source: String, dark: Bool) -> String {
        let boot = """
        <script>
        (async function () {
          try {
            var spec = JSON.parse(\(js(source)));
            var r = await vegaEmbed('#v', spec, { actions: false, renderer: 'svg', theme: \(dark ? "'dark'" : "undefined") });
            window.__view = r.view;
            window.__antichatReady = true;
          } catch (e) { window.__antichatReport(e && e.message ? e.message : String(e)); }
        })();
        </script>
        """
        return shell("<div id=\"v\"></div>" + inline(.vega) + inline(.vegaLite) + inline(.vegaEmbed) + boot, dark: dark)
    }
}

public struct SandboxedWebPreview: View {
    let url: URL
    let mode: PreviewMode?
    let onError: ((String) -> Void)?
    let onController: ((SandboxedWebController) -> Void)?
    @State private var controller: SandboxedWebController?
    @Environment(\.colorScheme) private var colorScheme

    public init(url: URL, mode: PreviewMode? = nil, onError: ((String) -> Void)? = nil,
                onController: ((SandboxedWebController) -> Void)? = nil) {
        self.url = url
        self.mode = mode
        self.onError = onError
        self.onController = onController
    }

    public var body: some View {
        Group {
            if let controller {
                WebViewHost(webView: controller.webView)
            } else {
                Color.clear
            }
        }
        .task(id: "\(url.path)|\(mode?.rawValue ?? "")|\(colorScheme == .dark)") {
            let c = await SandboxedWebController.make(fileURL: url, mode: mode)
            c.onError = onError
            controller = c
            onController?(c)
            c.load(dark: colorScheme == .dark)
        }
        .accessibilityIdentifier("sandboxedWebPreview")
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
