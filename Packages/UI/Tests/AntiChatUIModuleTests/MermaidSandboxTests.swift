// MermaidSandboxTests (M1.T09 step 4): diagrams render from the bundled mermaid 12.2.0 only; the WebView cannot load
// anything (content rule list blocks every URL, page JavaScript is off, the data store is non-persistent); a parse
// error is reported so the block can show its source.
import AppKit
import Testing
import WebKit
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct MermaidSandboxTests {
    static func renderer() async -> (MermaidRenderer, NSWindow) {
        let r = MermaidRenderer(rules: await MermaidRenderer.ruleList())
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.contentView = r.webView
        return (r, w)
    }

    @Test func bundledLibraryIsPresent() {
        #expect((MermaidRenderer.script?.count ?? 0) > 1_000_000)
    }

    @Test func rendersAFlowchart() async {
        let (r, _) = await Self.renderer()
        let result = await r.render("flowchart LR\n  A --> B --> C", dark: false, fg: "rgb(0,0,0)", bg: "rgb(255,255,255)")
        guard case .success(let d) = result else { Issue.record("render failed: \(result)"); return }
        #expect(d.size.width > 50 && d.size.height > 10)
        #expect(r.webView.configuration.websiteDataStore.isPersistent == false)
        #expect(r.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
    }

    /// RC review P2-10: if the block-all rule list failed to compile, nothing is loaded or rendered (fail closed).
    @Test func noRuleListMeansNoRender() async {
        let r = MermaidRenderer(rules: nil)
        #expect(!r.isSandboxed)
        let result = await r.render("flowchart LR\n  A --> B", dark: false, fg: "rgb(0,0,0)", bg: "rgb(255,255,255)")
        #expect(result == .failure(.unavailable))
        #expect(r.webView.url == nil && !r.webView.isLoading, "the page was never loaded")
        #expect(await MermaidRenderer.ruleList() != nil)  // the real rule list compiles, so the app renders
    }

    @Test func parseErrorIsReported() async {
        let (r, _) = await Self.renderer()
        let result = await r.render("flowchart LR\n  A -->", dark: false, fg: "rgb(0,0,0)", bg: "rgb(255,255,255)")
        guard case .failure(.parse) = result else { Issue.record("expected a parse error, got \(result)"); return }
    }

    /// Every network load is refused: a fetch from inside the sandbox page fails.
    @Test func networkIsBlocked() async throws {
        let (r, _) = await Self.renderer()
        _ = await r.render("flowchart LR\n  A --> B", dark: false, fg: "rgb(0,0,0)", bg: "rgb(255,255,255)")
        let outcome = try await r.webView.callAsyncJavaScript(
            """
            try { await fetch('https://example.com/antichat-mermaid-probe'); return 'loaded'; }
            catch (e) { return 'blocked'; }
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(outcome as? String == "blocked")
        let img = try await r.webView.callAsyncJavaScript(
            """
            return await new Promise(res => { const i = new Image(); i.onload = () => res('loaded');
              i.onerror = () => res('blocked'); i.src = 'https://example.com/x.png'; setTimeout(() => res('timeout'), 3000); });
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(img as? String == "blocked")
    }
}
}  // extension WindowSuites
