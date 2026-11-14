// M6.T13 step 1 (R-016 AC1): long outputs become artifacts. A fenced block in an assistant reply is promoted when it is
//   - `html` / `htm` (kind html; React when it imports React or carries `text/babel` scripts),
//   - `jsx` / `tsx` (React: kind html, `spec_json.react = true`),
//   - `svg` (or an `xml` block that is an <svg>), `mermaid`, `vega-lite` (or `json` whose `$schema` is vega-lite),
//   - or any other block longer than 40 lines (kind `doc` for markdown / text, else `code`).
// 40 lines stay inline, 41 promote. The classification is shared: the Harness saves the artifacts when the reply is done
// (ArtifactPromotionService) and the renderer swaps those blocks for an ArtifactCardView (UI LongOutputPromoter), matched
// by the block's sha256 (`spec_json.source_sha256`). The UI file named in the plan (`Renderer/LongOutputPromoter.swift`)
// keeps the view side; the rule lives here because the Harness cannot import the UI (PRD §6.1 import edges).
import CryptoKit
import Foundation

public enum ArtifactKind: String, Sendable, Codable, CaseIterable {
    case code, doc, html, svg, mermaid, chart
}

/// One block that becomes an artifact.
public struct PromotedBlock: Sendable, Equatable {
    public var language: String
    /// The block body without its trailing newline(s).
    public var source: String
    public var kind: ArtifactKind
    public var react: Bool
    public var lineCount: Int
    public var title: String
    /// File extension of the stored version (`vl.json` for Vega-Lite).
    public var ext: String

    public var sha256: String { OutputPromotion.sha256(source) }
    public var filename: String { OutputPromotion.filename(title: title, ext: ext) }

    /// `artifact_version.spec_json` of a promoted block.
    public var specJSON: String {
        let o: [String: Any] = ["source_sha256": sha256, "language": language, "kind": kind.rawValue, "react": react,
                                "lines": lineCount, "promoted": true]
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }
}

public enum OutputPromotion {
    /// Blocks up to this many lines stay inline (unless their language always promotes).
    public static let inlineLineLimit = 40

    public static func normalized(_ code: String) -> String {
        var s = code
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }

    public static func lineCount(_ code: String) -> Int { normalized(code).reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

    public static func sha256(_ code: String) -> String {
        SHA256.hash(data: Data(normalized(code).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The promotion of a fenced block (nil = it stays inline as a code block).
    public static func classify(language raw: String?, code: String) -> PromotedBlock? {
        let lang = (raw ?? "").trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.lowercased() } ?? ""
        let source = normalized(code)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = lineCount(source)
        func block(_ kind: ArtifactKind, ext: String, react: Bool = false) -> PromotedBlock {
            PromotedBlock(language: lang, source: source, kind: kind, react: react, lineCount: lines,
                          title: title(kind: kind, language: lang, source: source, react: react), ext: ext)
        }
        switch lang {
        case "html", "htm", "xhtml":
            return block(.html, ext: "html", react: importsReact(source))
        case "jsx", "tsx":
            return block(.html, ext: lang, react: true)
        case "svg":
            return block(.svg, ext: "svg")
        case "xml" where source.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^(<\\?xml[^>]*>\\s*)?<svg[\\s>]",
                                                                                         options: .regularExpression) != nil:
            return block(.svg, ext: "svg")
        case "mermaid":
            return block(.mermaid, ext: "mmd")
        case "vega-lite", "vegalite", "vl":
            return block(.chart, ext: "vl.json")
        case "json" where isVegaLite(source):
            return block(.chart, ext: "vl.json")
        default:
            guard lines > inlineLineLimit else { return nil }
            if ["markdown", "md", "text", "txt", "plaintext", ""].contains(lang) { return block(.doc, ext: "md") }
            return block(.code, ext: codeExtension(lang))
        }
    }

    public static func importsReact(_ s: String) -> Bool {
        s.range(of: #"from\s+['"]react(-dom)?(/client)?['"]|require\(\s*['"]react['"]\s*\)|text/babel|ReactDOM\.|React\.createElement|<script[^>]+react"#,
                options: .regularExpression) != nil
    }

    static func isVegaLite(_ s: String) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let schema = o["$schema"] as? String else { return false }
        return schema.lowercased().contains("vega-lite")
    }

    static let extensions: [String: String] = [
        "python": "py", "py": "py", "swift": "swift", "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts",
        "ruby": "rb", "rb": "rb", "go": "go", "rust": "rs", "rs": "rs", "java": "java", "kotlin": "kt", "c": "c",
        "cpp": "cpp", "c++": "cpp", "csharp": "cs", "cs": "cs", "php": "php", "sh": "sh", "bash": "sh", "zsh": "sh",
        "shell": "sh", "sql": "sql", "css": "css", "scss": "scss", "yaml": "yaml", "yml": "yaml", "toml": "toml",
        "json": "json", "xml": "xml", "r": "r", "lua": "lua", "dart": "dart", "scala": "scala", "objc": "m",
        "objective-c": "m", "perl": "pl", "haskell": "hs", "elixir": "ex", "dockerfile": "dockerfile", "makefile": "mk",
    ]

    static func codeExtension(_ lang: String) -> String {
        if let e = extensions[lang] { return e }
        let safe = lang.filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty || safe.count > 10 ? "txt" : safe
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let t = s[r].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(80))
    }

    static let displayLanguage: [String: String] = [
        "py": "Python", "python": "Python", "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript",
        "typescript": "TypeScript", "swift": "Swift", "sh": "Shell", "bash": "Shell", "sql": "SQL", "css": "CSS",
        "cpp": "C++", "c": "C", "go": "Go", "rust": "Rust", "java": "Java", "ruby": "Ruby", "kotlin": "Kotlin",
    ]

    /// A short human title: the page/drawing `<title>`, the component name, the diagram type, the chart title, the
    /// document's first heading, or "<Language> code".
    static func title(kind: ArtifactKind, language: String, source: String, react: Bool) -> String {
        switch kind {
        case .html where react && language != "html" && language != "htm":
            return firstMatch(#"export\s+default\s+(?:function|class)\s+([A-Za-z_$][\w$]*)"#, in: source)
                ?? firstMatch(#"export\s+default\s+([A-Za-z_$][\w$]*)"#, in: source)
                ?? firstMatch(#"function\s+([A-Z][\w$]*)"#, in: source) ?? "Component"
        case .html:
            return firstMatch(#"<title[^>]*>(.*?)</title>"#, in: source) ?? firstMatch(#"<h1[^>]*>(.*?)</h1>"#, in: source)
                .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) } ?? "Page"
        case .svg:
            return firstMatch(#"<title[^>]*>(.*?)</title>"#, in: source) ?? "Drawing"
        case .mermaid:
            let first = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("%%") && $0 != "---" } ?? ""
            if let t = firstMatch(#"^---\s*\ntitle:\s*([^\n]+)"#, in: source) { return t }
            let word = first.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init) ?? "diagram"
            let names = ["graph": "Flowchart", "flowchart": "Flowchart", "sequenceDiagram": "Sequence diagram",
                         "classDiagram": "Class diagram", "stateDiagram": "State diagram", "erDiagram": "ER diagram",
                         "gantt": "Gantt chart", "pie": "Pie chart", "mindmap": "Mind map", "journey": "User journey",
                         "timeline": "Timeline", "gitGraph": "Git graph"]
            return names[word] ?? names[String(word.prefix { $0 != "-" })] ?? "Diagram"
        case .chart:
            let o = (try? JSONSerialization.jsonObject(with: Data(source.utf8))) as? [String: Any]
            return (o?["title"] as? String) ?? ((o?["title"] as? [String: Any])?["text"] as? String) ?? "Chart"
        case .doc:
            return firstMatch(#"(?m)^#{1,3}\s+([^\n]+)"#, in: source) ?? "Document"
        case .code:
            return "\(displayLanguage[language] ?? (language.isEmpty ? "Code" : language.capitalized)) code"
        }
    }

    public static func filename(title: String, ext: String) -> String {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for c in ["/", ":", "\\", "\n", "\r", "\t", "\0", "\"", "<", ">", "|", "?", "*"] {
            base = base.replacingOccurrences(of: c, with: c == "/" || c == ":" ? "-" : "")
        }
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Untitled" }
        if base.count > 80 { base = String(base.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return base.lowercased().hasSuffix("." + ext) ? base : "\(base).\(ext)"
    }

    // MARK: Fences

    /// The fenced blocks of a Markdown reply, in order (CommonMark fences: ``` or ~~~, at most 3 spaces of indent; the
    /// closing fence uses the same character and is at least as long). An unclosed fence runs to the end.
    public static func fencedBlocks(in markdown: String) -> [(language: String, code: String)] {
        var out: [(String, String)] = []
        var open: (char: Character, len: Int, indent: Int, lang: String, lines: [Substring])?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let rest = line.dropFirst(indent)
            if var o = open {
                if indent <= 3, let c = rest.first, c == o.char {
                    let run = rest.prefix { $0 == c }.count
                    if run >= o.len, rest.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                        out.append((o.lang, o.lines.joined(separator: "\n")))
                        open = nil
                        continue
                    }
                }
                var l = line
                var drop = o.indent
                while drop > 0, l.first == " " { l = l.dropFirst(); drop -= 1 }
                o.lines.append(l)
                open = o
                continue
            }
            guard indent <= 3, let c = rest.first, c == "`" || c == "~" else { continue }
            let run = rest.prefix { $0 == c }.count
            guard run >= 3 else { continue }
            let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
            if c == "`", info.contains("`") { continue }
            open = (c, run, indent, info.split(separator: " ").first.map(String.init) ?? "", [])
        }
        if let o = open { out.append((o.lang, o.lines.joined(separator: "\n"))) }
        return out
    }

    /// The promoted blocks of a reply, in order.
    public static func promotions(in markdown: String) -> [PromotedBlock] {
        fencedBlocks(in: markdown).compactMap { classify(language: $0.language, code: $0.code) }
    }
}
