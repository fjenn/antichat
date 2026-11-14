// M8.T07 AT-019 (R-019 AC1–AC3): every single-chat exporter on a fixture chat with 2 pictures, code and math:
// Markdown has 2 `data:image/` URIs; HTML has no http(s) src/href and 2 base64 pictures; the PDF's text layer holds
// the turns and it has 2 image XObjects; the PNG is non-empty. An Evil chat starts with "Evil mode" in all four
// (the PNG read back with Vision). No NetworkGate event during the exports, and the Share sources name no network
// API. The exported files are kept under build/at/AT-019/.
//   make test-unit FILTER=ShareExportTests
import AntiChatNetwork
import AntiChatStorage
import AppKit
import Foundation
import GRDB
import PDFKit
import Testing
import Vision
@testable import AntiChatUI

@MainActor
@Suite("ShareExportTests", .serialized, .isolatedSettings) struct ShareExportTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
    static let reply = """
        Here is the loop:

        ```swift
        for i in 0..<3 { print(i) }
        ```

        The area is $A = \\pi r^2$. See [the docs](https://example.com/docs) and <b>bold</b>.
        """

    static func png(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
        let img = NSImage(size: NSSize(width: 24, height: 24))
        img.lockFocus()
        NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A chat (user with 2 pictures → assistant with code + math), Evil or not.
    static func fixture(evil: Bool) throws -> (AppDatabase, String) {
        let db = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chat = StorageID.make(), u = StorageID.make(), a = StorageID.make()
        let now = Date().timeIntervalSince1970
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat (id, title, title_state, mode, created_at, updated_at) VALUES (?, ?, 'user', ?, ?, ?)",
                          arguments: [chat, evil ? "Evil fixture" : "Share fixture", evil ? "evil" : "normal", now, now])
            try d.execute(sql: "INSERT INTO message (id, chat_id, parent_id, role, created_at) VALUES (?, ?, NULL, 'user', ?)", arguments: [u, chat, now])
            try d.execute(sql: "INSERT INTO message (id, chat_id, parent_id, role, created_at) VALUES (?, ?, ?, 'assistant', ?)", arguments: [a, chat, u, now + 1])
            try d.execute(sql: "UPDATE message SET active_child_id = ? WHERE id = ?", arguments: [a, u])
            try d.execute(sql: "UPDATE chat SET leaf_message_id = ? WHERE id = ?", arguments: [a, chat])
            try d.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES (?, 0, 'text', 'Compare these two pictures, please.')", arguments: [u])
            try d.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES (?, 0, 'text', ?)", arguments: [a, reply])
            for (i, data) in [png(220, 40, 40), png(40, 90, 220)].enumerated() {
                let url = dir.appendingPathComponent("p\(i).png")
                try data.write(to: url)
                let blob = StorageID.make()
                try d.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES (?, ?, ?, ?, ?, 'upload')",
                              arguments: [blob, "sha-\(i)-\(UUID().uuidString)", data.count, url.path, now])
                try d.execute(sql: "INSERT INTO attachment (id, message_id, blob_id, display_name, uti, created_at) VALUES (?, ?, ?, ?, 'public.png', ?)",
                              arguments: [StorageID.make(), u, blob, "picture-\(i + 1).png", now + Double(i) / 10])
            }
        }
        return (db, chat)
    }

    static func save(_ data: Data, _ name: String) {
        let dir = repo.appendingPathComponent("build/at/AT-019")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name))
    }

    static func imageXObjects(_ pdf: Data) -> Int {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider) else { return 0 }
        var count = 0
        for i in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: i), let dict = page.dictionary else { continue }
            var res: CGPDFDictionaryRef?, xobj: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res,
                  CGPDFDictionaryGetDictionary(res, "XObject", &xobj), let xobj else { continue }
            CGPDFDictionaryApplyBlock(xobj, { _, value, ctx in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(value, .stream, &stream), let stream, let sd = CGPDFStreamGetDictionary(stream) {
                    var name: UnsafePointer<Int8>?
                    if CGPDFDictionaryGetName(sd, "Subtype", &name), let name, String(cString: name) == "Image" {
                        ctx!.assumingMemoryBound(to: Int.self).pointee += 1
                    }
                }
                return true
            }, &count)
        }
        return count
    }

    static func ocrFirstLine(_ png: Data) throws -> String {
        guard let cg = NSBitmapImageRep(data: png)?.cgImage else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cg).perform([req])
        let lines = (req.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        return lines.first?.topCandidates(1).first?.string ?? ""
    }

    @Test func allFourFormats() async throws {
        final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
        let events = Counter()
        let token = NetworkGate.addObserver { _ in events.lock.lock(); events.n += 1; events.lock.unlock() }
        defer { NetworkGate.removeObserver(token) }
        let (db, chat) = try Self.fixture(evil: false)
        let doc = try ChatDocument.load(chat, from: db)
        #expect(doc.turns.count == 2 && doc.turns[0].pictures.count == 2)

        let md = String(decoding: try await ShareActions.data(doc, .markdown), as: UTF8.self)
        #expect(md.components(separatedBy: "](data:image/").count - 1 == 2)
        #expect(md.contains("for i in 0..<3"))

        let html = String(decoding: try await ShareActions.data(doc, .html), as: UTF8.self)
        #expect(html.range(of: #"(src|href)\s*=\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) == nil)
        #expect(html.components(separatedBy: "src=\"data:image/png;base64,").count - 1 == 2)
        #expect(html.contains("<span class=\"math\">$A = \\pi r^2$</span>"))
        #expect(html.contains("&lt;b&gt;bold&lt;/b&gt;"))  // raw HTML is text, never markup
        #expect(html.contains("<span style=\"color:"))  // highlighted code
        #expect(html.contains("(https://example.com/docs)"))  // the link's address as text

        let pdf = try await ShareActions.data(doc, .pdf)
        let text = PDFDocument(data: pdf)?.string ?? ""
        #expect(text.contains("Compare these two pictures"))
        #expect(text.contains("for i in 0..<3"))
        #expect(Self.imageXObjects(pdf) == 2)

        let image = ChatImageExporter.render(doc)
        #expect(image.pngs.count == 1 && (image.pngs.first?.count ?? 0) > 1000 && !image.truncated)

        let pb = NSPasteboard(name: .init("share-\(UUID().uuidString)"))
        ShareActions.copyMarkdown(doc, to: pb)
        #expect(pb.string(forType: ShareActions.markdownType) == md)
        #expect(pb.string(forType: .string) == md)
        _ = ChatImageExporter.copy(doc, to: pb)
        #expect(pb.data(forType: .png) != nil)

        Self.save(Data(md.utf8), "share.md"); Self.save(Data(html.utf8), "share.html"); Self.save(pdf, "share.pdf")
        Self.save(image.pngs[0], "share.png")
        #expect(events.n == 0)
    }

    @Test func evilHeaderInAllFour() async throws {
        let (db, chat) = try Self.fixture(evil: true)
        let doc = try ChatDocument.load(chat, from: db)
        let md = String(decoding: try await ShareActions.data(doc, .markdown), as: UTF8.self)
        #expect(md.hasPrefix("> Evil mode\n"))
        let html = String(decoding: try await ShareActions.data(doc, .html), as: UTF8.self)
        let body = html.components(separatedBy: "<body>").last ?? ""
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<div class=\"evil\" role=\"note\">Evil mode</div>"))
        let pdf = try await ShareActions.data(doc, .pdf)
        let lines = (PDFDocument(data: pdf)?.page(at: 0)?.string ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
        #expect(lines.prefix(2).contains { $0.hasPrefix("Evil mode") }, "\(lines.prefix(3))")
        let png = try #require(ChatImageExporter.render(doc).pngs.first)
        #expect(try Self.ocrFirstLine(png).hasPrefix("Evil mode"))
        Self.save(Data(html.utf8), "share-evil.html"); Self.save(pdf, "share-evil.pdf"); Self.save(png, "share-evil.png")
    }

    @Test func longChatIsCutTo20Turns() throws {
        var turns: [ChatDocument.Turn] = []
        for i in 0..<30 { turns.append(.init(role: i % 2 == 0 ? .user : .assistant, text: "Turn \(i)", pictures: [], createdAt: Date())) }
        let doc = ChatDocument(id: "x", title: "Long", isEvil: false, createdAt: Date(), updatedAt: Date(), turns: turns)
        let r = ChatImageExporter.render(doc)
        #expect(r.truncated && !r.pngs.isEmpty)
    }

    /// AC2: the Share sources reach no network API and make no links.
    @Test func shareSourcesHaveNoNetworkPath() throws {
        let dir = Self.repo.appendingPathComponent("Packages/UI/Sources/AntiChatUI/Share")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count == 4)
        for f in files {
            let src = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for banned in ["URLSession", "URLRequest", "NetworkGate", "http://", "https://", "WKWebView"] {
                #expect(!src.contains(banned), "\(f) references \(banned)")
            }
        }
    }
}
