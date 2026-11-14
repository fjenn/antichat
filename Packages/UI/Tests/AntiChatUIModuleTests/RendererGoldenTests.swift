// RendererGoldenTests (M1.T09; AT-008 legs 2 and 4): the 100 golden-100 samples (40 LaTeX, 30 tables, 20 Mermaid,
// 10 mixed) render within per-pixel ΔE ≤ 2 of their reference image, both when done and while streaming:
// - done: `MessageMarkdownView(text:streaming: false)` (one full off-main parse) vs `NNN.png`;
// - streaming: the same text revealed word by word through the binder's reveal clock (incremental parse, source
//   not finished) vs `NNN.png` for 001–070 (streaming and done must look identical) and vs `NNN.stream.png` for
//   071–100 (Mermaid shows its source and code highlights completed lines only until done);
// - Mermaid 071–090 done: the sandboxed WKWebView's own snapshot (cacheDisplay cannot capture a WKWebView).
//   The page clock is frozen (`fixedClock`): Mermaid's Gantt `todayMarker` draws a line at `new Date()`, so 078
//   otherwise changes with the wall-clock time of the run. The snapshot waits for the page to lay out at the new
//   width (`waitForLayout`), not for a fixed delay.
// Record (or re-record after an intended change): RECORD_GOLDEN=1 make test-unit FILTER=RendererGoldenTests
// (writes tools/fixtures/render/golden-100/, the staging copy of the fixtures repo).
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
import WebKit
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct RendererGoldenTests {
    static let record = ProcessInfo.processInfo.environment["RECORD_GOLDEN"] == "1"
    static let diffing = Diffing<NSImage>.image(precision: 1, perceptualPrecision: 0.98)  // ΔE ≤ 2 per pixel

    nonisolated static func ids(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "%03d", $0) } }
    static func markdown(_ id: String) throws -> String {
        try String(contentsOf: RendererRig.goldenDir.appendingPathComponent("\(id).md"), encoding: .utf8)
    }

    enum Kind { case done, streaming }

    /// Renders `id` in `kind` and compares with (or records) its golden. Returns nil on match, else a reason.
    /// The process's first renders load fonts (SwiftMath's Latin Modern, system text) lazily and can differ. A single
    /// discarded render was not enough under the parallel suite (001, the first LaTeX sample, failed: the fonts were
    /// still loading when it rendered), so warm up until two consecutive renders of a math + mixed sample are
    /// pixel-identical (a readiness condition, not a fixed delay).
    static var warmedUp = false

    static func warmUp() async throws {
        guard !warmedUp else { return }
        warmedUp = true
        for id in ["001", "095"] {
            let md = try markdown(id)
            var last = RendererRig.png(await render(MessageMarkdownView(text: md, streaming: false)))
            for _ in 0..<6 {
                let next = RendererRig.png(await render(MessageMarkdownView(text: md, streaming: false)))
                if next == last { break }
                last = next
            }
        }
    }

    static func check(_ id: String, _ kind: Kind) async throws -> String? {
        try await warmUp()
        let md = try markdown(id)
        let n = Int(id)!
        let image: NSImage
        let golden: String
        switch (kind, n) {
        case (.done, 71...90):
            image = try await mermaidImage(md)
            golden = "\(id).png"
        case (.done, _):
            image = await render(MessageMarkdownView(text: md, streaming: false))
            golden = "\(id).png"
        case (.streaming, _):
            let binder = StreamingMarkdownBinder(text: "", streaming: true)
            binder.update(text: md, streaming: true, interrupted: false)
            var t = 1.0
            while binder.reveal.backlog > 1, t < 120 {
                binder.tick(now: t)
                t += 1.0 / 60
            }
            image = await render(MessageMarkdownView(binder: binder))
            golden = n <= 70 ? "\(id).png" : "\(id).stream.png"
        }
        return try compare(image, golden: golden, recordIfStreaming: kind == .streaming && n > 70)
    }

    static func render(_ view: some View) async -> NSImage {
        let h = RendererRig.Host(view, look: .light)
        // Under parallel suites the off-main parse and math can land late: wait for content, then 0.4 s of stability.
        await h.settle(min: 0.3, stableFor: 0.4, max: 8, minHeight: 60)
        return h.image()
    }

    static func compare(_ image: NSImage, golden: String, recordIfStreaming: Bool) throws -> String? {
        let url = RendererRig.goldenDir.appendingPathComponent(golden)
        if record {
            let out = RendererRig.stagingGoldenDir.appendingPathComponent(golden)
            try RendererRig.png(image)?.write(to: out)
            return nil
        }
        // A streaming-state golden of 001–070 is the done golden: never recorded separately.
        guard let data = try? Data(contentsOf: url), let ref = NSImage(data: data) else {
            return "missing golden \(golden) (RECORD_GOLDEN=1)"
        }
        // Compare at the golden's pixel size (both are 2x renders of the same point size).
        ref.size = image.size
        if let (message, _) = diffing.diffV2(ref, image) { return "\(golden): \(message)" }
        return nil
    }

    static func mermaidSource(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("```mermaid") }),
            let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("```") })
        else { return "" }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    /// The diagram as the in-app WKWebView draws it, at the reading width.
    static func mermaidImage(_ md: String) async throws -> NSImage {
        let r = MermaidRenderer(rules: await MermaidRenderer.ruleList())
        // Before the (lazy) page load, so mermaid's dayjs sees the frozen clock from its first call.
        r.webView.configuration.userContentController.addUserScript(
            WKUserScript(source: fixedClock, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: RendererRig.width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = r.webView
        let result = await r.render(mermaidSource(md), dark: false, fg: "rgb(13,13,13)", bg: "rgb(255,255,255)")
        guard case .success(let d) = result else { throw MermaidError.failed("\(result)") }
        let height = MermaidBlockView.height(natural: d.size, width: RendererRig.width)
        window.setContentSize(CGSize(width: RendererRig.width, height: height))
        r.webView.frame = CGRect(x: 0, y: 0, width: RendererRig.width, height: height)
        try await waitForLayout(r.webView, width: RendererRig.width)
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image = try await r.webView.takeSnapshot(configuration: config)
        // Normalise to 2x pixels of the point size, like the other goldens.
        let size = CGSize(width: RendererRig.width, height: height)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    enum MermaidError: Error { case failed(String) }

    /// `Date()` / `Date.now()` without arguments return 2000-01-01T00:00:00Z (dated arguments are untouched), so a
    /// Gantt chart's today marker lies far left of every golden's time axis and is never drawn.
    static let fixedClock = """
    (() => {
      const fixed = 946684800000, Real = Date;
      class FixedDate extends Real {
        constructor(...a) { if (a.length) { super(...a); } else { super(fixed); } }
        static now() { return fixed; }
      }
      window.Date = FixedDate;
    })();
    """

    /// Readiness signal for the snapshot: the page's viewport has the new width and the diagram's SVG has been laid
    /// out at it (two consecutive equal non-zero heights). Fails instead of snapshotting a stale layout.
    static func waitForLayout(_ webView: WKWebView, width: CGFloat) async throws {
        let probe = """
        const el = document.querySelector('#d svg');
        return [document.documentElement.clientWidth, el ? el.getBoundingClientRect().height : 0];
        """
        var last = -1.0
        for _ in 0..<400 {
            let v = try await webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .page) as? [NSNumber]
            let w = v?.first?.doubleValue ?? 0, h = v?.last?.doubleValue ?? 0
            if abs(w - Double(width)) < 0.5, h > 0, h == last { return }
            last = h
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MermaidError.failed("page never laid out at width \(width)")
    }

    @Test(arguments: ids(1...40)) func latex(_ id: String) async throws {
        #expect(try await Self.check(id, .done) == nil)
        #expect(try await Self.check(id, .streaming) == nil)
    }

    @Test(arguments: ids(41...70)) func tables(_ id: String) async throws {
        #expect(try await Self.check(id, .done) == nil)
        #expect(try await Self.check(id, .streaming) == nil)
    }

    @Test(arguments: ids(71...90)) func mermaid(_ id: String) async throws {
        #expect(try await Self.check(id, .done) == nil)
        #expect(try await Self.check(id, .streaming) == nil)
    }

    @Test(arguments: ids(91...100)) func mixed(_ id: String) async throws {
        #expect(try await Self.check(id, .done) == nil)
        #expect(try await Self.check(id, .streaming) == nil)
    }

    @Test func fixturesAreComplete() throws {
        let dir = RendererRig.goldenDir
        let mds = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") && $0 != "SOURCES.md" }
        #expect(mds.count == 100)
    }
}
}  // extension WindowSuites
