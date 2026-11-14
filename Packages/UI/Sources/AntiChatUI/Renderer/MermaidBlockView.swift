// Mermaid fenced blocks (components.md §3 "Mermaid in a sandboxed WebView"; M1.T09 step 4). A WKWebView with
// a non-persistent data store, page JavaScript off (only the bundled mermaid 12.2.0, injected as a user script,
// runs), and a WKContentRuleList that blocks every URL load, so a diagram can never reach the network.
// While the reply streams the block shows its source as code (the documented S1 fallback: render after done);
// a parse error keeps the source visible with `mermaid.error`.
import AntiChatDesign
import AppKit
import SwiftUI
import WebKit

@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    struct Rendered: Equatable { var size: CGSize }
    enum Failure: Error, Equatable { case unavailable, parse(String) }

    /// The bundled library (Packages/UI/Sources/AntiChatUI/Resources/mermaid, `make vendor-js`).
    static let script: String? = Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Blocks every load (the page itself is an in-memory string; nothing else may load).
    static let blockAllRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    private static var compiledRules: WKContentRuleList?

    static func ruleList() async -> WKContentRuleList? {
        if let r = compiledRules { return r }
        let r = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "antichat.mermaid.block-all", encodedContentRuleList: blockAllRules)
        compiledRules = r
        return r
    }

    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Never>?
    private var isLoaded = false
    /// RC review P2-10: the block-all rule list compiled and is installed. Without it nothing is loaded or rendered
    /// (fail closed, like `SandboxedWebPreview`); the block keeps showing its source.
    let isSandboxed: Bool
    /// URLs the content rules or the navigation policy refused (tests: must stay empty in practice, every load denied).
    private(set) var deniedNavigations: [URL] = []

    init(rules: WKContentRuleList?) {
        isSandboxed = rules != nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        if let rules { config.userContentController.add(rules) }
        if let js = Self.script {
            config.userContentController.addUserScript(
                WKUserScript(source: js + "\n" + Self.bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = PassThroughWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 200), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// `window.antichatRender(source, dark)` → `{w, h}` of the drawn SVG, or throws mermaid's parse error.
    static let bootstrap = """
    window.antichatRender = async function (source, dark, fg, bg) {
      document.body.style.background = bg;
      document.body.style.color = fg;
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default',
                           fontFamily: '-apple-system, system-ui, sans-serif', flowchart: { htmlLabels: false } });
      await mermaid.parse(source);
      const { svg } = await mermaid.render('antichat-diagram', source);
      const host = document.getElementById('d');
      host.innerHTML = svg;
      const el = host.querySelector('svg');
      const vb = el.viewBox && el.viewBox.baseVal;
      const w = (vb && vb.width) || el.getBoundingClientRect().width;
      const h = (vb && vb.height) || el.getBoundingClientRect().height;
      el.removeAttribute('height');
      el.style.maxWidth = w + 'px';
      el.style.width = '100%';
      el.style.height = 'auto';
      return { w: w, h: h };
    };
    """

    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;overflow:hidden;font:13px -apple-system,system-ui,sans-serif}
    #d{display:flex;justify-content:center}
    </style></head><body><div id="d"></div></body></html>
    """

    private func ensureLoaded() async {
        if isLoaded { return }
        await withCheckedContinuation { c in
            loaded = c
            webView.loadHTMLString(Self.page, baseURL: nil)
        }
    }

    func render(_ source: String, dark: Bool, fg: String, bg: String) async -> Result<Rendered, Failure> {
        guard Self.script != nil, isSandboxed else { return .failure(.unavailable) }
        await ensureLoaded()
        do {
            let r = try await webView.callAsyncJavaScript(
                "return await window.antichatRender(source, dark, fg, bg);",
                arguments: ["source": source, "dark": dark, "fg": fg, "bg": bg], in: nil, contentWorld: .page)
            guard let d = r as? [String: Any], let w = (d["w"] as? NSNumber)?.doubleValue,
                let h = (d["h"] as? NSNumber)?.doubleValue, w > 0, h > 0
            else { return .failure(.parse("no diagram")) }
            return .success(Rendered(size: CGSize(width: w, height: h)))
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "\(error)"
            return .failure(.parse(message))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoaded = true
        loaded?.resume()
        loaded = nil
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Only the initial in-memory page; links inside a diagram never navigate.
        if action.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            if let u = action.request.url { deniedNavigations.append(u) }
            decisionHandler(.cancel)
        }
    }
}

/// Scroll wheel events go to the transcript, not to the diagram.
private final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

struct MermaidBlockView: View {
    let source: String
    @Environment(\.markdownStream) private var stream  // fix/t05-u5-part5: the block's own flag (observed)
    private var streaming: Bool { stream?.streaming ?? false }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var state: Phase = .rendering
    @State private var renderer: MermaidRenderer?

    enum Phase: Equatable { case rendering, rendered(CGSize), failed }

    var body: some View {
        if streaming {
            CodeBlockView(language: "mermaid", code: source)
        } else {
            switch state {
            case .failed:
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    Text(CopyKey("mermaid.error"))
                        .typeStyle(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .probeID("mermaidError")
                    CodeBlockView(language: "mermaid", code: source)
                }
            case .rendering, .rendered:
                diagram
            }
        }
    }

    private var diagram: some View {
        ZStack {
            if let renderer {
                WebViewHost(webView: renderer.webView)
                    .opacity(state == .rendering ? 0 : 1)
            }
            if state == .rendering {
                Text(CopyKey("mermaid.rendering"))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: displayHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: source))
        .probeID("mermaidBlock")
        .task(id: RenderKey(source: source, dark: colorScheme == .dark)) { await render() }
    }

    @State private var width: CGFloat = 640
    private var displayHeight: CGFloat {
        if case .rendered(let s) = state { return Self.height(natural: s, width: width) }
        return 120
    }

    /// The SVG scales down to the column, never up (CSS `max-width` = natural width).
    static func height(natural: CGSize, width: CGFloat) -> CGFloat {
        guard natural.width > 1 else { return natural.height }
        return (natural.height * min(1, width / natural.width)).rounded(.up)
    }

    static func css(_ color: Color, _ env: EnvironmentValues) -> String {
        let c = color.resolve(in: env)
        return String(format: "rgb(%d,%d,%d)", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255))
    }

    struct RenderKey: Equatable { var source: String; var dark: Bool }

    private func render() async {
        let r: MermaidRenderer
        if let renderer { r = renderer } else {
            r = MermaidRenderer(rules: await MermaidRenderer.ruleList())
            renderer = r
        }
        state = .rendering
        let dark = colorScheme == .dark
        let result = await r.render(
            source, dark: dark, fg: Self.css(Color.textPrimary, environment), bg: Self.css(Color.surfaceCanvas, environment))
        switch result {
        case .success(let d): state = .rendered(d.size)
        case .failure: state = .failed
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
