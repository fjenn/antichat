// Source-level helpers over swift-markdown (MarkdownView's parser): the CSV of the n-th table ("Copy as CSV",
// components.md Table) and the last fenced code block of a reply (⌘⇧; CopyLastCodeCommand).
import Markdown

enum MarkdownBlocks {
    /// The body of the last code block in `markdown` (fenced or indented), without its trailing newline.
    static func lastCodeBlock(in markdown: String) -> String? {
        var walker = CodeBlockCollector()
        walker.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        guard let code = walker.blocks.last else { return nil }
        return code.hasSuffix("\n") ? String(code.dropLast()) : code
    }

    /// Every table in `document` order, as rows of plain-text cells (header first).
    static func tables(in document: Document) -> [[[String]]] {
        var walker = TableCollector()
        walker.visit(document)
        return walker.tables
    }

    static func tables(in markdown: String) -> [[[String]]] {
        tables(in: Document(parsing: markdown, options: [.disableSmartOpts]))
    }

    /// RFC 4180 CSV: fields with a comma, quote or newline are quoted; quotes doubled; CRLF line ends.
    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { f in
                f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }
}

private struct CodeBlockCollector: MarkupWalker {
    var blocks: [String] = []
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) { blocks.append(codeBlock.code) }
}

private struct TableCollector: MarkupWalker {
    var tables: [[[String]]] = []
    mutating func visitTable(_ table: Table) {
        var rows: [[String]] = [Array(table.head.cells).map(visibleText)]
        for row in table.body.rows { rows.append(Array(row.cells).map(visibleText)) }
        tables.append(rows)
    }
}

/// The text a reader sees: emphasis and link markup dropped, inline code without its backticks.
private func visibleText(_ m: any Markup) -> String {
    switch m {
    case let t as Markdown.Text: t.string
    case let c as InlineCode: c.code
    case is SoftBreak, is LineBreak: " "
    case is InlineHTML: ""
    default: m.children.map(visibleText).joined()
    }
}
