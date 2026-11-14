// M6.T13 (R-016 AC2/AC3; AT-016 checks 2 and 3, in process): the side panel's sandboxed preview modes. React — the
// vendored React 18.3.1 + Babel mount `counter.jsx` and its button increments; Mermaid and Vega draw an SVG; a broken page
// reports its error through `previewError` (→ `panel.fix`); a generated page and `net-probe.html` (fetch, img,
// WebSocket, iframe, stylesheet, script, redirect) make ZERO connections to a local counting listener; Download writes
// .svg / .png / .pdf / .html with the right bytes. Sources are inline (the same text as fixtures/docs/artifacts, made by
// tools/fixtures/make-artifacts.py), so the suite does not depend on the fixtures checkout.
import AntiChatFoundation
import AntiChatHarness
import AntiChatTools
import AppKit
import Foundation
import Network
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import AntiChatUI

enum ArtifactSources {
    static let counter = """
        import React, { useState } from 'react';

        export default function Counter() {
          const [count, setCount] = useState(0);
          return (
            <div style={{ fontFamily: 'system-ui', padding: 16 }}>
              <p id="value">Count: {count}</p>
              <button id="inc" onClick={() => setCount(count + 1)}>Add one</button>
            </div>
          );
        }
        """
    static let tsx = """
        import React from 'react';
        type Props = { name?: string };
        const Hello = ({ name = 'there' }: Props) => <p id="hello">Hello {name}</p>;
        export default Hello;
        """
    static let mermaid = "flowchart TD\n    A[Draft] --> B{Review}\n    B -->|approved| C[Publish]"
    static let vega = #"{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","title":"Quarterly revenue","data":{"values":[{"q":"Q1","r":120},{"q":"Q2","r":150}]},"mark":"bar","encoding":{"x":{"field":"q","type":"ordinal"},"y":{"field":"r","type":"quantitative"}}}"#
    static let broken = "<!doctype html><html><head><title>Broken widget</title></head><body><p id=\"c\"></p><script>document.getElementById('c').textContent = formatSteps(2);</script></body></html>"
    static let netProbe = """
        <!doctype html><html><head><meta charset="utf-8"><title>Net probe</title>
        <link rel="stylesheet" href="https://antichat-probe.invalid/style.css">
        <script src="https://antichat-probe.invalid/script.js"></script></head><body>
        <img src="https://antichat-probe.invalid/pixel.png" alt=""><iframe src="https://antichat-probe.invalid/frame.html"></iframe>
        <script>
          const results = {};
          const done = () => { document.title = 'probe:' + JSON.stringify(results); };
          fetch('https://antichat-probe.invalid/fetch.json').then(() => { results.fetch = 'loaded'; done(); })
            .catch(() => { results.fetch = 'blocked'; done(); });
          const img = new Image();
          img.onload = () => { results.image = 'loaded'; done(); };
          img.onerror = () => { results.image = 'blocked'; done(); };
          img.src = 'https://antichat-probe.invalid/js-pixel.png';
          try { const ws = new WebSocket('wss://antichat-probe.invalid/socket');
                ws.onopen = () => { results.websocket = 'open'; done(); };
                ws.onerror = () => { results.websocket = 'blocked'; done(); }; } catch (e) { results.websocket = 'blocked'; done(); }
          setTimeout(() => { location.href = 'https://antichat-probe.invalid/redirect.html'; }, 50);
        </script></body></html>
        """
    /// A React component that tries the network from inside the generated page.
    static let reactProbe = """
        import React, { useEffect } from 'react';
        export default function Probe() {
          useEffect(() => {
            fetch('https://antichat-probe.invalid/react-fetch').catch(() => {});
            const i = new Image(); i.src = 'https://antichat-probe.invalid/react-img.png';
            try { new WebSocket('ws://antichat-probe.invalid/ws'); } catch (e) {}
          }, []);
          return <img src="https://antichat-probe.invalid/react-tag.png" />;
        }
        """
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ArtifactsPreviewTests {
    func file(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func render(_ url: URL, mode: PreviewMode? = nil) async -> (SandboxedWebController, NSWindow) {
        let c = await SandboxedWebController.make(fileURL: url, mode: mode)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = c.webView
        c.load()
        await c.waitUntilRendered(timeout: .seconds(20))
        return (c, window)
    }

    @Test func vendoredScriptsAreBundled() {
        for s in PreviewScripts.Script.allCases { #expect((PreviewScripts.source(s)?.count ?? 0) > 1000, "\(s.rawValue)") }
        #expect(PreviewScripts.source(.react)?.contains("18.3.1") == true, "React 18.3.1 (A-M6-08)")
    }

    @Test func reactCounterMountsAndIncrements() async throws {
        let (c, _) = await render(try file("counter.jsx", ArtifactSources.counter))
        #expect(c.mode == .react && c.errors.isEmpty, "errors: \(c.errors)")
        let before = try await c.webView.evaluateJavaScript("document.getElementById('value').textContent") as? String
        #expect(before == "Count: 0")
        _ = try await c.webView.evaluateJavaScript("document.getElementById('inc').click(); 0")
        var after: String?
        for _ in 0..<40 {
            after = try await c.webView.evaluateJavaScript("document.getElementById('value').textContent") as? String
            if after == "Count: 1" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(after == "Count: 1")
        #expect(c.webView.url == SandboxedWebController.pageOrigin, "generated page, no file URL")
    }

    @Test func typescriptComponentRenders() async throws {
        let (c, _) = await render(try file("hello.tsx", ArtifactSources.tsx))
        #expect(c.errors.isEmpty, "errors: \(c.errors)")
        #expect(try await c.webView.evaluateJavaScript("document.getElementById('hello').textContent") as? String == "Hello there")
    }

    @Test func mermaidAndVegaDrawSVGAndPNG() async throws {
        let (m, _) = await render(try file("flow.mmd", ArtifactSources.mermaid))
        #expect(m.mode == .mermaid && m.errors.isEmpty, "errors: \(m.errors)")
        let msvg = await m.svgMarkup()
        #expect(msvg?.hasPrefix("<svg") == true && msvg?.contains("Publish") == true)
        let (v, _) = await render(try file("chart.vl.json", ArtifactSources.vega))
        #expect(v.mode == .vega && v.errors.isEmpty, "errors: \(v.errors)")
        let vsvg = await v.svgMarkup()
        #expect(vsvg?.contains("<svg") == true && vsvg?.contains("Quarterly revenue") == true)
        let png = try #require(await v.pngData())
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func brokenPageReportsPreviewErrorAndFixIsOffered() async throws {
        let url = try file("broken.html", ArtifactSources.broken)
        let (c, _) = await render(url)
        for _ in 0..<40 where c.errors.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(c.errors.contains { $0.contains("formatSteps") }, "errors: \(c.errors) title: \(c.webView.title ?? "")")
        let panel = SidePanelModel(windowID: "fix-\(UUID().uuidString)", defaults: UserDefaults.inMemory())
        var sent: ArtifactEditRequestBox?
        panel.onArtifactEdit = { sent = ArtifactEditRequestBox(value: $0) }
        panel.open(.init(artifactID: "a", title: "broken.html", kind: .html, react: false, language: "html", version: 1,
                         versions: [(n: 1, path: url.path)], createdAt: Date(), versionCreatedAt: Date()))
        panel.previewError = c.errors.first
        panel.fix()
        guard case .fix(let message)? = sent?.value.action else { Issue.record("no fix request"); return }
        #expect(message.contains("formatSteps") && sent?.value.source == ArtifactSources.broken)
    }

    @Test func netProbeAndGeneratedPagesMakeZeroConnections() async throws {
        let listener = try CountingListener()
        let port = try await listener.start()
        let host = "http://127.0.0.1:\(port)"
        let probe = try file("net-probe.html", ArtifactSources.netProbe
            .replacingOccurrences(of: "https://antichat-probe.invalid", with: host)
            .replacingOccurrences(of: "wss://antichat-probe.invalid", with: "ws://127.0.0.1:\(port)"))
        let (c, _) = await render(probe)
        var title = ""
        for _ in 0..<100 {
            title = c.webView.title ?? ""
            if title.contains("fetch") && title.contains("image") && title.contains("websocket") { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(title.contains(#""fetch":"blocked""#) && title.contains(#""image":"blocked""#), "probe: \(title)")
        #expect(!title.contains(#""websocket":"open""#), "probe: \(title)")
        let react = try file("probe.jsx", ArtifactSources.reactProbe
            .replacingOccurrences(of: "https://antichat-probe.invalid", with: host)
            .replacingOccurrences(of: "ws://antichat-probe.invalid", with: "ws://127.0.0.1:\(port)"))
        let (r, _) = await render(react)
        #expect(r.errors.isEmpty, "errors: \(r.errors)")
        try await Task.sleep(for: .seconds(1.5))
        #expect(listener.count == 0, "previews reached the network \(listener.count) time(s)")
        #expect(c.deniedNavigations.contains { $0.host == "127.0.0.1" }, "the JS redirect is refused")
    }

    @Test func downloadsWriteTheRightBytes() async throws {
        let (v, _) = await render(try file("chart.vl.json", ArtifactSources.vega))
        let vurl = v.fileURL
        let svg = try #require(await ArtifactExport.data(.svg, url: vurl, preview: .vega, language: "", web: v))
        #expect(String(decoding: svg, as: UTF8.self).contains("<svg"))
        let png = try #require(await ArtifactExport.data(.png, url: vurl, preview: .vega, language: "", web: v))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let (h, _) = await render(try file("counter.jsx", ArtifactSources.counter))
        let html = try #require(await ArtifactExport.data(.html, url: h.fileURL, preview: .react, language: "jsx", web: h))
        let page = String(decoding: html, as: UTF8.self)
        #expect(page.contains("Content-Security-Policy") && page.contains("Babel.transform") && !page.contains("<script src"),
                "the downloaded React page is self-contained")
        let pdf = try #require(await ArtifactExport.data(.pdf, url: h.fileURL, preview: .react, language: "jsx", web: h))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
        // Files land with the format's UTType.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (format, data) in [(DownloadFormat.svg, svg), (.png, png), (.pdf, pdf), (.html, html)] {
            let out = dir.appendingPathComponent(ArtifactExport.filename(title: "Artifact.jsx", format: format))
            try data.write(to: out)
            let type = try #require(try out.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(type.conforms(to: format.type), "\(out.lastPathComponent): \(type.identifier)")
        }
    }
}
}  // extension WindowSuites

struct ArtifactEditRequestBox { let value: ArtifactEditRequest }
