// M6 review #1 (P0): HTML attachments → Markdown text with no loader. AppKit's HTML importer runs WebKit, which can
// fetch `<img>`, stylesheets, CSS `url()` and the like outside NetworkGate; this parses the bytes only. libxml2's lenient
// HTML parser (`htmlReadMemory`, `HTML_PARSE_NONET`, no base URL; it detects `<meta charset>` itself) builds a tree,
// and the walk feeds the EPUB chapter reader's element events (`XHTMLText`: headings, paragraphs, list items, breaks;
// script/style dropped). Attributes are never read, so no URL in the file is ever resolved.
import Foundation
import libxml2

public enum HTMLText {
    public static func markdown(_ data: Data) -> String {
        guard !data.isEmpty, data.count <= Int(Int32.max) else { return "" }
        let options = Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
            | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_COMPACT.rawValue)
        let doc: htmlDocPtr? = data.withUnsafeBytes { raw in
            raw.baseAddress.flatMap {
                htmlReadMemory($0.assumingMemoryBound(to: CChar.self), Int32(raw.count), nil, nil, options)
            }
        }
        guard let doc else { return "" }
        defer { xmlFreeDoc(doc) }
        let out = XHTMLText()
        walk(xmlDocGetRootElement(doc), into: out)
        return out.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Depth-first over element and text nodes (iterative: a deeply nested file cannot overflow the stack).
    private static func walk(_ root: xmlNodePtr?, into out: XHTMLText) {
        guard let root else { return }
        var stack: [(node: xmlNodePtr, entered: Bool)] = [(root, false)]
        while let (node, entered) = stack.popLast() {
            switch node.pointee.type {
            case XML_ELEMENT_NODE:
                let name = String(cString: node.pointee.name).lowercased()
                if entered { out.end(name); continue }
                out.start(name)
                stack.append((node, true))
                var children: [xmlNodePtr] = []
                var c = node.pointee.children
                while let n = c { children.append(n); c = n.pointee.next }
                for n in children.reversed() { stack.append((n, false)) }
            case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                if let content = node.pointee.content { out.text(String(cString: content)) }
            default: break
            }
        }
    }
}
