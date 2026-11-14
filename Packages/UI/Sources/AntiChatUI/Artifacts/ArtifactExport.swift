// M6.T13 step 3 (R-016 AC3): the panel header's Copy and `panel.download` menu. Formats per kind:
//   code / doc → .md (code fenced in its language; plus the code's own extension); html → .html, .pdf (createPDF);
//   React → .html (the self-contained preview page, scripts inlined) and .pdf; svg / mermaid / chart → .svg, .png;
//   documents and images → the native file.
// Copy puts the source text on the pasteboard (binary files: the file URL, as the card's Copy).
import AntiChatDesign
import AppKit
import UniformTypeIdentifiers

public enum DownloadFormat: Hashable, Sendable {
    case markdown, html, pdf, svg, png
    case native(String)

    public var ext: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        case .pdf: "pdf"
        case .svg: "svg"
        case .png: "png"
        case .native(let e): e
        }
    }

    public var type: UTType {
        switch self {
        case .markdown: UTType("net.daringfireball.markdown") ?? .plainText
        case .html: .html
        case .pdf: .pdf
        case .svg: .svg
        case .png: .png
        case .native(let e): UTType(filenameExtension: e) ?? .data
        }
    }

    /// Menu label: ".md", ".pdf", …
    public var label: String { ".\(ext)" }
}

public enum ArtifactExport {
    /// The download formats for what the panel shows.
    public static func formats(preview: PreviewMode?, body: PanelBody, url: URL) -> [DownloadFormat] {
        let ext = url.pathExtension.lowercased()
        switch preview {
        case .html: return [.html, .pdf]
        case .react: return [.html, .pdf] + (ext == "jsx" || ext == "tsx" ? [.native(ext)] : [])
        case .svg, .mermaid, .vega: return [.svg, .png]
        case nil: break
        }
        if body == .text {
            return ext == "md" || ext.isEmpty ? [.markdown] : [.markdown, .native(ext)]
        }
        return [.native(ext.isEmpty ? "dat" : ext)]
    }

    /// The file name for `title` in `format` (the title's own extension replaced).
    public static func filename(title: String, format: DownloadFormat) -> String {
        var base = title
        for suffix in [".vl.json", ".vega.json"] where base.lowercased().hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
        let ns = base as NSString
        if !ns.pathExtension.isEmpty { base = ns.deletingPathExtension }
        return "\(base).\(format.ext)"
    }

    /// The bytes of `format` for the file at `url` (`web` = the live preview, needed for .pdf / .svg / .png of a
    /// rendered page; `language` = the code fence for .md).
    @MainActor
    public static func data(_ format: DownloadFormat, url: URL, preview: PreviewMode?, language: String,
                            web: SandboxedWebController?, dark: Bool = false) async -> Data? {
        let source = try? String(contentsOf: url, encoding: .utf8)
        switch format {
        case .native:
            return try? Data(contentsOf: url)
        case .markdown:
            guard let source else { return nil }
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" || ext == "txt" || ext.isEmpty { return Data(source.utf8) }
            let lang = language.isEmpty ? ext : language
            let longest = source.components(separatedBy: "\n").map { $0.prefix { $0 == "`" }.count }.max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return Data("\(fence)\(lang)\n\(source)\n\(fence)\n".utf8)
        case .html:
            guard let source else { return nil }
            if preview == .react { return Data(PreviewPages.page(mode: .react, source: source, dark: dark).utf8) }
            return Data(source.utf8)
        case .pdf:
            guard let web = await rendered(web) else { return nil }
            return await web.pdfData()
        case .svg:
            if preview == .svg, let source { return Data(source.utf8) }
            guard let web = await rendered(web) else { return nil }
            return await web.svgMarkup().map { Data($0.utf8) }
        case .png:
            guard let web = await rendered(web) else { return nil }
            return await web.pngData()
        }
    }

    /// The live preview once it has rendered (nil: none, or it failed / timed out), so an early Download waits instead
    /// of exporting a blank page (M6 review #17).
    @MainActor
    static func rendered(_ web: SandboxedWebController?) async -> SandboxedWebController? {
        guard let web, web.hasRules else { return nil }
        return await web.waitUntilRendered() ? web : nil
    }

    public enum DownloadResult: Equatable, Sendable {
        case saved(URL)
        case cancelled
        /// No bytes for the format (the preview has not rendered or failed) or the write failed: the panel says so.
        case failed
    }

    /// The panel's toast for a failed download (nil for saved / cancelled).
    public static func toast(for result: DownloadResult) -> Toast? {
        result == .failed ? Toast(.warning, CopyText(CopyKey("download.failed"))) : nil
    }

    /// Copy: text files → the text; binary → the file URL.
    @MainActor
    public static func copy(url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if let text = try? String(contentsOf: url, encoding: .utf8), PanelBody(url: url) != .quickLook,
           PanelBody(url: url) != .image, PanelBody(url: url) != .pdf {
            pasteboard.setString(text, forType: .string)
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
    }

    /// Save panel → writes the format. `choose` asks for the destination (the save panel; tests inject one).
    @MainActor
    public static func download(_ format: DownloadFormat, title: String, url: URL, preview: PreviewMode?, language: String,
                                web: SandboxedWebController?,
                                choose: (@MainActor (String, UTType) -> URL?)? = nil) async -> DownloadResult {
        guard let data = await data(format, url: url, preview: preview, language: language, web: web) else { return .failed }
        let name = filename(title: title, format: format)
        guard let dest = (choose ?? savePanel)(name, format.type) else { return .cancelled }
        do {
            try data.write(to: dest, options: .atomic)
            return .saved(dest)
        } catch {
            return .failed
        }
    }

    @MainActor
    static func savePanel(_ name: String, _ type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
