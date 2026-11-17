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

    /// Small models often wrap a table in a ```markdown fence, which would show its pipes as code. A `markdown` / `md`
    /// fence whose body is only a pipe table loses its two fence lines, so the table renders as a table. Anything
    /// else (real code, mixed content, an unclosed fence) is returned unchanged.
    static func unwrappingFencedTables(_ markdown: String) -> String {
        guard markdown.contains("```m") || markdown.contains("```M") else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let open = lines[i].trimmingCharacters(in: .whitespaces).lowercased()
            if open == "```markdown" || open == "```md",
               let close = lines[(i + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "```" }) {
                let body = lines[(i + 1)..<close].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if body.count >= 2, body.allSatisfy({ $0.hasPrefix("|") }) {
                    lines.remove(at: close)
                    lines.remove(at: i)
                    i = close - 1
                    continue
                }
            }
            i += 1
        }
        return lines.joined(separator: "\n")
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
