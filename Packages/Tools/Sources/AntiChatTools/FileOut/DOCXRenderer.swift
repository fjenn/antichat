// M6.T09 step 6 (R-273 AC1, P-files-tools-05): `create_document` → DOCX. Swift parses the Markdown into the document
// AST (DocumentAST) and resolves image refs to base64 + pixel size; `bridge-docx.js` maps the AST to a `docx` 9.15.0
// Document (headings, paragraphs, numbered/bulleted lists, bordered tables with a repeated header row, images, header
// title, footer "Page n of N", core properties creator "AntiChat") inside RenderHost; `Packer.toBase64String` → bytes.
import AppKit
import Foundation

public enum DOCXRenderer {
    struct Payload: Encodable {
        struct Img: Encodable { var base64: String; var type: String; var width: Int; var height: Int }
        var title: String
        var page_size: String
        var style: String
        var blocks: [DocNode]
        var images: [String: Img]
    }

    static func payload(_ spec: CreateDocumentSpec, images: [String: FileOutImage], locale: Locale) throws -> String {
        let blocks = DocumentAST.parse(spec.markdown)
        var imgs: [String: Payload.Img] = [:]
        for ref in Set(DocumentAST.imageRefs(blocks)) {
            guard let img = images[ref], let ns = NSImage(data: img.data) else { continue }
            let rep = ns.representations.first
            let w = rep?.pixelsWide ?? Int(ns.size.width), h = rep?.pixelsHigh ?? Int(ns.size.height)
            imgs[ref] = Payload.Img(base64: img.data.base64EncodedString(), type: imageType(img.data), width: max(w, 1), height: max(h, 1))
        }
        let p = Payload(title: spec.title,
                        page_size: (spec.page_size ?? CreateDocumentSpec.defaultPageSize(locale: locale)).rawValue,
                        style: (spec.style ?? .plain).rawValue, blocks: blocks, images: imgs)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(p), as: UTF8.self)
    }

    /// docx ImageRun types: png | jpg | gif | bmp (by magic bytes; anything else is re-encoded as PNG by the caller).
    static func imageType(_ d: Data) -> String {
        let b = [UInt8](d.prefix(4))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.starts(with: [0x42, 0x4D]) { return "bmp" }
        return "png"
    }

    /// Images WebKit's docx cannot embed (HEIC, TIFF, WebP…) become PNG first.
    public static func normalized(_ images: [String: FileOutImage]) -> [String: FileOutImage] {
        images.mapValues { img in
            let b = [UInt8](img.data.prefix(4))
            let ok = b.starts(with: [0x89, 0x50, 0x4E, 0x47]) || b.starts(with: [0xFF, 0xD8]) || b.starts(with: [0x47, 0x49, 0x46])
            guard !ok, let rep = NSImage(data: img.data).flatMap({ $0.tiffRepresentation }).flatMap(NSBitmapImageRep.init(data:)),
                  let png = rep.representation(using: .png, properties: [:]) else { return img }
            return FileOutImage(data: png, alt: img.alt)
        }
    }

    @MainActor
    public static func render(_ spec: CreateDocumentSpec, images: [String: FileOutImage] = [:], locale: Locale = .current,
                              host: RenderHost = .shared) async throws -> Data {
        let json = try payload(spec, images: normalized(images), locale: locale)
        do {
            return try await host.callData("return await AntiChatRender.docx(payload);", payload: json)
        } catch {
            throw FileOutError.render("\(error)")
        }
    }
}
