// M6 review #1 (P0): attaching an HTML file must make zero network connections. A local listener counts TCP connects;
// the HTML references it through every subresource kind a renderer would load (img src/srcset, <link rel=stylesheet>,
// CSS url() and @import, inline style url(), <base href>, script/iframe/video/object/embed, a DOCTYPE system id, meta
// refresh). Extraction goes through the real `ExtractionService` path; the listener must see 0 connections.
import Foundation
import Network
import Testing
@testable import AntiChatKnowledge

/// Counts accepted TCP connections on 127.0.0.1:<port>.
final class IntakeProbeListener: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "intake-probe")
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

    /// A plain TCP connect must be counted (proves the probe works).
    func sanity(port: UInt16) async throws {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: .global())
        for _ in 0..<100 where count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        c.cancel()
    }

    deinit { listener.cancel() }
}

@Suite(.serialized) struct HTMLNetworkTests {
    static func probePage(_ base: String) -> String {
        """
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "\(base)/dtd/xhtml1-strict.dtd">
        <html><head><meta charset="utf-8"><title>Probe page</title>
        <base href="\(base)/base/">
        <meta http-equiv="refresh" content="0; url=\(base)/refresh">
        <link rel="stylesheet" href="\(base)/style.css">
        <link rel="icon" href="\(base)/favicon.ico">
        <link rel="preload" as="image" href="\(base)/preload.png">
        <style>@import url("\(base)/import.css"); body { background: url(\(base)/bg.png); }
        @font-face { font-family: X; src: url("\(base)/font.woff"); } h1 { font-family: X; }</style>
        <script src="\(base)/script.js"></script>
        </head><body>
        <h1>Probe heading</h1>
        <p style="background-image: url('\(base)/inline.png')">Paragraph with <b>bold</b> text &amp; an entity.</p>
        <img src="\(base)/img.png" alt="pic"><img src="relative.png">
        <img srcset="\(base)/a.png 1x, \(base)/b.png 2x" src="\(base)/c.png">
        <picture><source srcset="\(base)/pic.webp"><img src="\(base)/pic.png"></picture>
        <iframe src="\(base)/frame.html"></iframe>
        <video poster="\(base)/poster.png" src="\(base)/v.mp4"></video>
        <object data="\(base)/object.swf"></object><embed src="\(base)/embed.swf">
        <input type="image" src="\(base)/input.png">
        <table background="\(base)/tablebg.png"><tr><td>Cell one</td><td>Cell two</td></tr></table>
        <ul><li>First item</li><li>Second item</li></ul>
        </body></html>
        """
    }

    @Test func htmlAttachmentMakesZeroConnections() async throws {
        let listener = try IntakeProbeListener()
        let port = try await listener.start()
        try await listener.sanity(port: port)
        #expect(listener.count == 1, "the listener must count a plain TCP connect")

        let dir = try IntakeFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("page.html")
        try Self.probePage("http://127.0.0.1:\(port)").write(to: url, atomically: true, encoding: .utf8)
        let doc = try await ExtractionService().extract(url: url, kind: .html)
        try await Task.sleep(for: .seconds(1))
        #expect(listener.count == 1, "HTML intake reached the network \(listener.count - 1) time(s)")
        // The text still comes through.
        #expect(doc.markdown.contains("# Probe heading"), "\(doc.markdown)")
        #expect(doc.markdown.contains("Paragraph with bold text & an entity."), "\(doc.markdown)")
        #expect(doc.markdown.contains("- First item") && doc.markdown.contains("- Second item"), "\(doc.markdown)")
        #expect(doc.markdown.contains("Cell one") && doc.markdown.contains("Cell two"))
        #expect(!doc.markdown.contains("127.0.0.1"), "URLs must not leak into the text: \(doc.markdown)")
    }

    /// Real-world HTML is not XML: unclosed tags, bare ampersands, uppercase tags, no <body>, other charsets.
    @Test func lenientParsing() throws {
        let html = "<HTML><H2>Title & more</H2><P>One<BR>two<P>three &nbsp;four &copy; <script>var x = 1 < 2;</script>five"
        let md = HTMLText.markdown(Data(html.utf8))
        #expect(md.contains("## Title & more"), "\(md)")
        #expect(md.contains("One\ntwo"), "\(md)")
        #expect(md.contains("three"), "\(md)")
        #expect(md.contains("©"), "\(md)")
        #expect(md.contains("five"), "\(md)")
        #expect(!md.contains("var x"), "\(md)")
        let latin1 = "<html><head><meta charset=\"iso-8859-1\"></head><body><p>caf\u{E9}</p></body></html>"
        #expect(HTMLText.markdown(latin1.data(using: .isoLatin1)!).contains("café"))
    }
}
