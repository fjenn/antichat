// M8.T07 step 5 (R-019 AC1/AC2): the single-chat Share menu, in the title bar (Share button, `square.and.arrow.up`)
// and in the chat ⋯ menu (Export ›). Exactly six items, in order: Copy as Markdown, Export as Markdown…, Export as
// PDF…, Export as HTML…, Copy as Image, Share… (NSSharingServicePicker with the HTML file). Everything is built on
// this Mac from the chat's rows; no exporter touches the network gate and there is no public-link concept.
import AntiChatDesign
import AntiChatFoundation
import AntiChatStorage
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShareMenuItems: View {
    let chatID: String
    let database: AppDatabase

    var body: some View {
        // What most people want first (copy, a PDF), the other formats one level down.
        Button { ShareActions.copyMarkdown(chatID, database) } label: { Text(CopyKey("share.copyMarkdown")) }
            .accessibilityIdentifier("share.copyMarkdown")
        Button { ShareActions.save(chatID, database, as: .pdf) } label: { Text(CopyKey("share.exportPDF")) }
            .accessibilityIdentifier("share.exportPDF")
        Menu {
            Button { ShareActions.save(chatID, database, as: .markdown) } label: { Text(CopyKey("share.exportMarkdown")) }
                .accessibilityIdentifier("share.exportMarkdown")
            Button { ShareActions.save(chatID, database, as: .html) } label: { Text(CopyKey("share.exportHTML")) }
                .accessibilityIdentifier("share.exportHTML")
            Button { ShareActions.copyImage(chatID, database) } label: { Text(CopyKey("share.copyImage")) }
                .accessibilityIdentifier("share.copyImage")
        } label: { Text(CopyKey("share.export")) }
            .accessibilityIdentifier("share.export")
        Button { ShareActions.share(chatID, database) } label: { Text(CopyKey("share.sheet")) }
            .accessibilityIdentifier("share.sheet")
    }
}

/// The title-bar Share button.
struct ShareToolbarButton: View {
    let chatID: String?
    let database: AppDatabase

    var body: some View {
        Menu {
            if let chatID { ShareMenuItems(chatID: chatID, database: database) }
        } label: { Image(systemName: "square.and.arrow.up") }
            .menuIndicator(.hidden)
            .tint(.primary)  // M9.T08: not the accent — the other toolbar buttons are label-coloured
            .disabled(chatID == nil)
            .help(Text(CopyKey("share.title")))
            .accessibilityLabel(Text(CopyKey("share.title")))
            .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
            .probeID("shareButton")
    }
}

@MainActor
enum ShareActions {
    enum FileKind { case markdown, pdf, html
        var ext: String { switch self { case .markdown: "md"; case .pdf: "pdf"; case .html: "html" } }
        var type: UTType { switch self { case .markdown: UTType(filenameExtension: "md") ?? .plainText; case .pdf: .pdf; case .html: .html } }
    }

    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    static func document(_ id: String, _ db: AppDatabase) -> ChatDocument? {
        do { return try ChatDocument.load(id, from: db) } catch {
            AppLog.log(.ui, .error, "share: \(error)")
            return nil
        }
    }

    static func fileName(_ doc: ChatDocument, _ kind: FileKind) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let base = doc.displayTitle.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "Chat" : String(base.prefix(80))).\(kind.ext)"
    }

    /// Markdown (pictures inline as `data:` URIs) as plain text and as `net.daringfireball.markdown`.
    static func copyMarkdown(_ doc: ChatDocument, to pasteboard: NSPasteboard = .general) {
        let md = ChatMarkdownRenderer.render(doc, pictures: .inline)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(md, forType: .string)
        item.setString(md, forType: markdownType)
        pasteboard.writeObjects([item])
    }

    static func copyMarkdown(_ id: String, _ db: AppDatabase) {
        if let doc = document(id, db) { copyMarkdown(doc) }
    }

    static func data(_ doc: ChatDocument, _ kind: FileKind) async throws -> Data {
        switch kind {
        case .markdown: Data(ChatMarkdownRenderer.render(doc, pictures: .inline).utf8)
        case .html: Data(await ChatHTMLExporter.html(doc).utf8)
        case .pdf: try ChatPDFExporter.pdf(doc)
        }
    }

    static func save(_ id: String, _ db: AppDatabase, as kind: FileKind) {
        guard let doc = document(id, db) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(doc, kind)
        panel.allowedContentTypes = [kind.type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await data(doc, kind).write(to: url, options: .atomic) } catch {
                AppLog.log(.ui, .error, "share export: \(error)")
            }
        }
    }

    static func copyImage(_ id: String, _ db: AppDatabase) {
        guard let doc = document(id, db) else { return }
        _ = ChatImageExporter.copy(doc)
    }

    /// The share sheet with the self-contained HTML file (written to a temporary folder).
    static func share(_ id: String, _ db: AppDatabase) {
        guard let doc = document(id, db) else { return }
        Task {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-share-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName(doc, .html))
            guard (try? await data(doc, .html).write(to: url, options: .atomic)) != nil,
                  let view = NSApp.keyWindow?.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 8, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }
}
