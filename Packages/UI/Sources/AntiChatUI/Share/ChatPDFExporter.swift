// M8.T07 step 5 (R-019 AC1/AC3): a chat's active path as PDF through the M6 renderer (PDFRenderer, TPPDF 2.6.1,
// G-023): turns as `## You` / `## AntiChat` sections, pictures embedded (one image block each), the Evil header as
// the first line and in the running page header ("Evil mode · <title>"). No network.
import AntiChatStorage
import AntiChatTools
import Foundation

enum ChatPDFExporter {
    /// The Markdown fed to PDFRenderer plus its picture refs.
    static func source(_ doc: ChatDocument) -> (markdown: String, images: [String: FileOutImage]) {
        var md = doc.isEvil ? "> **\(ChatMarkdownRenderer.evilHeader)**\n\n" : ""
        md += "# \(doc.displayTitle)\n"
        var images: [String: FileOutImage] = [:]
        for turn in doc.turns {
            md += "\n## \(ChatMarkdownRenderer.roleHeading(turn.role))\n\n"
            if !turn.text.isEmpty { md += turn.text + "\n" }
            for p in turn.pictures {
                guard let data = p.data() else { md += "\n*[\(p.name)]*\n"; continue }
                let ref = "img-\(images.count + 1)"
                images[ref] = FileOutImage(data: data, alt: p.name)
                md += "\n![\(p.name.replacingOccurrences(of: "]", with: ")"))](\(ref))\n"
            }
        }
        return (md, images)
    }

    static func pdf(_ doc: ChatDocument) throws -> Data {
        let (md, images) = source(doc)
        let title = (doc.isEvil ? ChatMarkdownRenderer.evilHeader + " · " : "") + doc.displayTitle
        return try PDFRenderer.render(CreateDocumentSpec(format: .pdf, title: title, markdown: md), images: images)
    }
}
