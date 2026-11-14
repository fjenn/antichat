// AT-273 / AT-275 (M9.T05 Phase B, round 60: 121/150 files, 7/20 decks): a T1 model's file-out calls are usually
// *nearly* right. Before the schema check, the validator and the run, the file-out tools rewrite the near misses a 9B
// model typically emits into the spec the user asked for, and say what they changed (notes → the tool result → the
// model's reply). Rules (PRD-AMENDMENTS "File-output normalisation", proposed):
//   * shapes: a list sent as a JSON string (also cut short by a bracket or two, or with a list's bracket missing or
//     misplaced: `wrapBareArrayRuns`), one object where a list belongs, a
//     list of strings for column / image objects, records instead of row arrays, `column_widths: ["auto"]`;
//   * the requested format wins inside one tool: the user's message asks for exactly one output format of the tool's
//     family (CSV vs Excel; PDF vs Word vs Markdown) → that format, never a file of another one; a format the message
//     names only as its source ("from this PDF") is not a request (M9 review F2);
//   * CSV holds one table: the sheet the prompt names (else the first with data) is written; other sheets, charts and
//     formulas are left out with a note;
//   * charts that name columns by header, by their literal values, or sit on a sheet of their own → the data sheet's
//     ranges; formulas keyed by a column name ("Total": "SUM(Hours)") → cells (a total row or a per-row column);
//   * image refs that do not resolve (`photo1`, the alt text, `photo_<id>`, an invented name) → the chat's attached
//     pictures (by id inside the ref, by file name, by number, else the next unused one); a ref that still does not
//     resolve → a visible "[Image not available: …]" line, never a failed file;
//   * a `data_ref` naming a query result in a chat that has none → the sheet keeps its columns, without data.
// Anything that cannot be fixed this way stays as sent and fails the checks (the repair turn, then the error card).
import Foundation

/// A picture attached to a message of the chat (attach order).
public struct AttachedImage: Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// What the normaliser may look at besides the arguments.
public struct FileOutAdjustContext: Sendable {
    /// The newest user message (the requested format).
    public var userText: String?
    /// Image attachments of the chat, oldest first.
    public var attachedImages: [AttachedImage]
    /// Whether an attachment / artifact id resolves in this chat.
    public var imageExists: @Sendable (String) -> Bool
    /// Query results (`data_ref`s) of this chat.
    public var dataRefs: [String]

    public init(userText: String? = nil, attachedImages: [AttachedImage] = [], imageExists: @escaping @Sendable (String) -> Bool = { _ in false },
                dataRefs: [String] = []) {
        self.userText = userText
        self.attachedImages = attachedImages
        self.imageExists = imageExists
        self.dataRefs = dataRefs
    }
}

/// The rewritten arguments and what was changed (empty = nothing worth telling the user).
public struct FileOutAdjusted: Sendable, Equatable {
    public var json: String
    public var notes: [String]
}

public enum FileOutNormalizer {
    // MARK: - Requested format

    static let formatPatterns: [(String, String)] = [
        ("csv", #"\bcsv\b"#),
        ("xlsx", #"\b(excel|xlsx|xls)\b"#),
        ("pdf", #"\bpdf\b"#),
        ("docx", #"\b(docx|ms word|microsoft word|word (document|doc|file))\b"#),
        ("md", #"\b(markdown|md file)\b|\.md\b"#),
        ("pptx", #"\b(pptx|powerpoint|keynote|slide ?deck|slides|presentation)\b"#),
    ]

    /// Words before a format name that make it the file to produce ("as a", "make me a", "I need a").
    static let targetCues: Set<String> = [
        "as", "make", "create", "generate", "build", "write", "produce", "give", "send", "need", "want", "prepare", "draft",
        "output",
    ]
    /// Target cues unless "the" comes between ("into a spreadsheet", "export to CSV", "convert to PDF" — but "convert the
    /// PDF", "in the PDF": that file is the source).
    static let directedCues: Set<String> = ["into", "to", "in", "export", "save", "convert", "turn", "translate", "download", "put"]
    /// Words before a format name that make it the source or a context ("from this", "of the", "for my", "summarize the").
    static let sourceCues: Set<String> = [
        "from", "of", "for", "this", "that", "these", "those", "attached", "uploaded", "my", "our", "your", "his", "her",
        "their", "its", "read", "summarize", "summarise", "analyze", "analyse", "review", "open", "extract", "parse", "using",
        "use", "based", "inside", "within", "check",
    ]

    /// Whether a format name at `index` is the output, the source / a context, or unclear: the nearest cue among the
    /// up to 4 words before it (in the same clause) decides.
    enum FormatRole { case target, source, neutral }

    static func role(before index: String.Index, in text: String) -> FormatRole {
        var head = String(text[..<index])
        if let cut = head.lastIndex(where: { ".;!?,\n:".contains($0) }) { head = String(head[head.index(after: cut)...]) }
        let words = head.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }).map(String.init)
        var the = false
        for w in words.reversed().prefix(4) {
            if targetCues.contains(w) { return .target }
            if directedCues.contains(w) { return the ? .source : .target }
            if sourceCues.contains(w) { return .source }
            if w == "and" || w == "or" { break }
            if w == "the" { the = true }
        }
        return .neutral
    }

    /// The one file format the user's message asks to be made (nil = none, or more than one). M9 review F2: a format the
    /// message only names as its source or context ("numbers from this PDF into a spreadsheet", "a doc for my
    /// presentation") is not a request; a format after "into a / as a / make a / export to …" is. With no such cue, a
    /// format named on its own ("Excel budget for my trip") counts unless it also appears as a source.
    public static func requestedFormat(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        var target = Set<String>(), source = Set<String>(), neutral = Set<String>()
        for (format, pattern) in formatPatterns {
            var from = lower.startIndex
            while let r = lower.range(of: pattern, options: .regularExpression, range: from..<lower.endIndex) {
                switch role(before: r.lowerBound, in: lower) {
                case .target: target.insert(format)
                case .source: source.insert(format)
                case .neutral: neutral.insert(format)
                }
                from = r.upperBound > r.lowerBound ? r.upperBound : lower.index(after: r.lowerBound)
                if from >= lower.endIndex { break }
            }
        }
        let wanted = target.union(neutral.subtracting(source))
        return wanted.count == 1 ? wanted.first : nil
    }

    /// The tool that writes `format`.
    public static func tool(for format: String) -> String {
        switch format {
        case "csv", "xlsx": SpreadsheetSchemas.createName
        case "pptx": PresentationSchemas.name
        default: FileOutSchemas.createDocumentName
        }
    }

    /// A problem when the user asked for a format another file tool writes (nil = fine or unknown).
    public static func wrongToolProblem(tool: String, userText: String?) -> String? {
        guard let want = requestedFormat(userText), Self.tool(for: want) != tool else { return nil }
        return "$: the user asked for a .\(want) file, which \(tool) cannot make; call \(Self.tool(for: want)) instead"
    }

    // MARK: - Lenient JSON

    /// JSON text → value; text cut short by a few closing brackets / braces (or inside a string) is closed first.
    /// A complete value followed only by stray closers (T05 csv-14: `[{…}]}`) is that value.
    public static func parseLenient(_ text: String) -> Any? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed]) { return v }
        guard let first = t.first, first == "{" || first == "[" else { return nil }
        if let w = wrapBareArrayRuns(t) {
            t = w
            if let v = try? JSONSerialization.jsonObject(with: Data(t.utf8)) { return v }
        }
        var stack: [Character] = [], inString = false, escaped = false
        for (i, c) in zip(t.indices, t) {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                if stack.isEmpty, t[i...].allSatisfy({ $0 == "}" || $0 == "]" || $0.isWhitespace }) {
                    t = String(t[..<i])  // the value ended: what follows is surplus
                    return try? JSONSerialization.jsonObject(with: Data(t.utf8))
                }
                guard stack.last == c else { return nil }  // a wrong closer is not a cut, it is broken
                stack.removeLast()
            default: break
            }
        }
        guard !stack.isEmpty || inString, stack.count <= 4 else { return nil }
        var fixed = t + (inString ? "\"" : "")
        while let last = fixed.last, last == "," || last.isWhitespace { fixed.removeLast() }
        fixed += String(stack.reversed())
        return try? JSONSerialization.jsonObject(with: Data(fixed.utf8))
    }

    /// A list of lists whose outer `[` is missing (T05 csv-30, round 67: `"rows": ["a", 1], ["b", 2], "formulas": …` —
    /// an object then meets `[` where a key belongs) → that run wrapped in one list (`"rows": [["a", 1], ["b", 2]]`).
    /// The run ends at the next key, the object's `}`, or a stray `]` (the closer the model did write). A list still open
    /// when its object's `}` comes is closed there; a top-level list closed after its first item and continued
    /// (`[{…}], {…}]`) is reopened. nil: nothing to repair.
    static func wrapBareArrayRuns(_ text: String) -> String? {
        enum Kind { case object, array, run }
        struct Level { var kind: Kind; var open: Int; var lastArray: Int? }  // lastArray: where the value just closed began
        let cs = Array(text)
        var out: [Character] = [], stack: [Level] = [], changed = false, i = 0
        var rootClose: (at: Int, open: Int)?  // the top-level list's `]` (its index in `out`) and where that list began
        out.reserveCapacity(cs.count + 8)
        func next(_ j: Int) -> Character? { var k = j; while k < cs.count, cs[k].isWhitespace { k += 1 }; return k < cs.count ? cs[k] : nil }
        func lastSolid() -> Character? { out.last { !$0.isWhitespace } }
        while i < cs.count {
            let c = cs[i]
            if c == "\"" {
                var j = i + 1, esc = false
                while j < cs.count { if esc { esc = false } else if cs[j] == "\\" { esc = true } else if cs[j] == "\"" { break }; j += 1 }
                out.append(contentsOf: cs[i..<min(j + 1, cs.count)]); i = j + 1; continue
            }
            switch c {
            case "{": stack.append(Level(kind: .object, open: out.count, lastArray: nil))
            case "[": stack.append(Level(kind: .array, open: out.count, lastArray: nil))
            case ":": if !stack.isEmpty { stack[stack.count - 1].lastArray = nil }
            case ",":
                // T05 round 67 xlsx-30: `[{…sheet 1…}], {…sheet 2…}]` — the list was closed after its first item.
                if stack.isEmpty, let rc = rootClose, let n = next(i + 1), n == "{" || n == "[" {
                    out.remove(at: rc.at)
                    stack.append(Level(kind: .array, open: rc.open, lastArray: nil))
                    rootClose = nil; changed = true
                }
                if stack.last?.kind == .run, next(i + 1) != "[" { out.append("]"); stack.removeLast() }
                if let top = stack.last, top.kind == .object, let start = top.lastArray, lastSolid() == "]", next(i + 1) == "[" {
                    out.insert("[", at: start)
                    stack[stack.count - 1].lastArray = nil
                    stack.append(Level(kind: .run, open: start, lastArray: nil))
                    changed = true
                }
            case "}":
                // T05 round 67 xlsx-01 (`…]}]}, {"name": "Monthly Goals", …`): a `}` after the top-level list closed is
                // surplus; dropped, so the `, {` that follows reopens the list.
                if stack.isEmpty, rootClose != nil { changed = true; i += 1; continue }
                if stack.last?.kind == .run { out.append("]"); stack.removeLast() }
                // T05 round 67 xlsx-01: `"rows": [["Housing", 1500], …, ["Total", 2900]}` — the list's `]` is missing.
                while stack.last?.kind == .array, stack.contains(where: { $0.kind == .object }) {
                    out.append("]"); stack.removeLast(); changed = true
                }
                if !stack.isEmpty { stack.removeLast() }
                if !stack.isEmpty { stack[stack.count - 1].lastArray = nil }
            case "]":
                if let top = stack.popLast(), top.kind == .array {
                    if stack.last?.kind == .object { stack[stack.count - 1].lastArray = top.open }
                    if stack.isEmpty { rootClose = (out.count, top.open) }
                }
            default: break
            }
            out.append(c); i += 1
        }
        return changed ? String(out) : nil
    }

    static func encode(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// A list where the schema wants one: a JSON string of a list, one object, or the list itself.
    static func list(_ v: Any?) -> [Any]? {
        switch v {
        case let a as [Any]: return a
        case let s as String:
            switch parseLenient(s) {
            case let a as [Any]: return a
            case let o as [String: Any]: return [o]
            default: return nil
            }
        case let o as [String: Any]: return [o]
        default: return nil
        }
    }

    static func object(_ v: Any?) -> [String: Any]? {
        switch v {
        case let o as [String: Any]: return o
        case let s as String: return parseLenient(s) as? [String: Any]
        default: return nil
        }
    }

    static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = v as? String { return ["true", "yes", "on"].contains(s.lowercased()) ? true : ["false", "no", "off"].contains(s.lowercased()) ? false : nil }
        return nil
    }

    static func quoted(_ names: [String]) -> String { names.map { "\"\($0)\"" }.joined(separator: ", ") }

    static func stripExtension(_ name: String, _ exts: [String]) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return exts.contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    // MARK: - create_spreadsheet

    static let spreadsheetKeys: Set<String> = ["filename", "format", "sheets", "revises"]
    static let sheetKeys: Set<String> = ["name", "columns", "rows", "data_ref", "formulas", "freeze_header", "autofilter", "column_widths", "chart"]
    static let columnKinds: [String: String] = [
        "number": "number", "numeric": "number", "int": "number", "integer": "number", "float": "number", "double": "number",
        "decimal": "number", "text": "text", "string": "text", "str": "text", "date": "date", "datetime": "date",
        "currency": "currency", "money": "currency", "percent": "percent", "percentage": "percent", "bool": "bool", "boolean": "bool",
    ]

    public static func spreadsheet(_ raw: String, _ ctx: FileOutAdjustContext) -> FileOutAdjusted {
        guard var o = parseLenient(raw) as? [String: Any] else { return FileOutAdjusted(json: raw, notes: []) }
        var notes: [String] = []
        if o["filename"] == nil, let t = (o["title"] ?? o["name"]) as? String { o["filename"] = t }
        // A sheet given at the top level (columns / rows beside filename).
        if o["sheets"] == nil, o["columns"] != nil || o["rows"] != nil {
            var s: [String: Any] = ["name": (o["filename"] as? String).map { stripExtension($0, ["csv", "xlsx", "xls"]) } ?? "Sheet1"]
            for k in ["columns", "rows", "formulas", "chart", "column_widths", "freeze_header", "autofilter", "data_ref"] { s[k] = o[k] }
            o["sheets"] = [s]
        }
        if let s = list(o["sheets"]) { o["sheets"] = s }
        o = o.filter { spreadsheetKeys.contains($0.key) }
        // Format: as sent (".csv" / "CSV"), else the filename's extension; the user's request wins.
        var format = ((o["format"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if format == "excel" || format == "xls" { format = "xlsx" }
        if !["csv", "xlsx"].contains(format) {
            let ext = ((o["filename"] as? String ?? "") as NSString).pathExtension.lowercased()
            format = ext == "csv" ? "csv" : "xlsx"
        }
        if let want = requestedFormat(ctx.userText), ["csv", "xlsx"].contains(want), want != format {
            notes.append("You asked for a \(want == "csv" ? "CSV" : "Excel") file, so it is a .\(want) file (the call asked for .\(format)).")
            format = want
        }
        o["format"] = format
        if let f = o["filename"] as? String { o["filename"] = stripExtension(f, ["csv", "xlsx", "xls"]) }
        guard var sheets = (o["sheets"] as? [Any])?.compactMap({ object($0) }), !sheets.isEmpty else {
            return FileOutAdjusted(json: encode(o), notes: notes)
        }
        for i in sheets.indices { sheets[i] = sheet(sheets[i], index: i, ctx: ctx, notes: &notes) }
        sheets = moveChartOnlySheets(sheets)
        if format == "csv" { sheets = [csvSheet(sheets, ctx: ctx, notes: &notes)] }
        for i in sheets.indices { formulas(&sheets[i], csv: format == "csv", notes: &notes) }
        for i in sheets.indices { chart(&sheets[i], csv: format == "csv", notes: &notes) }
        o["sheets"] = sheets
        return FileOutAdjusted(json: encode(o), notes: notes)
    }

    static func headers(_ s: [String: Any]) -> [String] {
        ((s["columns"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["header"] as? String }
    }

    static func hasData(_ s: [String: Any]) -> Bool {
        !((s["rows"] as? [Any]) ?? []).isEmpty || s["data_ref"] != nil
    }

    static func sheet(_ raw: [String: Any], index i: Int, ctx: FileOutAdjustContext, notes: inout [String]) -> [String: Any] {
        var s = raw.filter { sheetKeys.contains($0.key) }
        if s["name"] == nil, let t = (raw["title"] ?? raw["sheet_name"]) as? String { s["name"] = t }
        var name = (s["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        for c in ["[", "]", ":", "*", "?", "/", "\\"] { name = name.replacingOccurrences(of: c, with: " ") }
        if name.isEmpty { name = "Sheet\(i + 1)" }
        s["name"] = String(name.prefix(31))
        // Rows: a JSON string, records (objects) instead of arrays.
        var rows: [[Any]] = []
        if let r = list(s["rows"]) {
            var recordKeys: [String] = []
            for row in r {
                if let a = row as? [Any] {
                    rows.append(a)
                } else if let rec = row as? [String: Any] {
                    if recordKeys.isEmpty { recordKeys = headers(s).isEmpty ? rec.keys.sorted() : headers(s) }
                    rows.append(recordKeys.map { rec[$0] ?? NSNull() })
                } else {
                    rows.append([row])
                }
            }
            if s["columns"] == nil, !recordKeys.isEmpty { s["columns"] = recordKeys.map { ["header": $0] as [String: Any] } }
            rows = rows.map { $0.map { v -> Any in
                switch v {
                case is NSNull, is String, is NSNumber: v
                default: encode(v)
                }
            } }
            s["rows"] = rows
        } else if s["rows"] != nil {
            s["rows"] = nil
        }
        // Columns: strings → objects; type synonyms / missing types inferred from the values.
        if let cols = list(s["columns"]) {
            s["columns"] = cols.enumerated().map { c, col -> [String: Any] in
                var out: [String: Any]
                if let h = col as? String { out = ["header": h] } else { out = (col as? [String: Any] ?? [:]).filter { ["header", "type", "format"].contains($0.key) } }
                if out["header"] == nil, let h = (col as? [String: Any])?["name"] as? String { out["header"] = h }
                if (out["header"] as? String ?? "").isEmpty { out["header"] = "Column \(c + 1)" }
                let kind = columnKinds[(out["type"] as? String ?? "").lowercased()]
                out["type"] = kind ?? inferKind(rows.compactMap { c < $0.count ? $0[c] : nil })
                if let f = out["format"], !(f is String) { out["format"] = nil }
                return out
            }
        }
        if let w = s["column_widths"] {
            if let a = w as? [Any] {
                let nums = a.compactMap { v -> Double? in (v as? NSNumber).map(\.doubleValue) ?? (v as? String).flatMap(Double.init) }
                s["column_widths"] = nums.count == a.count && !nums.isEmpty ? nums.map { min(max($0, 1), 255) } as Any : "auto"
            } else if let n = (w as? NSNumber)?.doubleValue {
                s["column_widths"] = Array(repeating: min(max(n, 1), 255), count: max(headers(s).count, 1))
            } else {
                s["column_widths"] = "auto"
            }
        }
        for k in ["freeze_header", "autofilter"] where s[k] != nil {
            s[k] = bool(s[k]) ?? true
        }
        if let ref = s["data_ref"] {
            if let id = ref as? String, !id.isEmpty, ctx.dataRefs.contains(id) {
                if !rows.isEmpty { s["rows"] = nil }  // the query result is the data
            } else if ctx.dataRefs.isEmpty || !rows.isEmpty {
                s["data_ref"] = nil
                if rows.isEmpty {
                    notes.append("There is no query result \(quoted([String(describing: ref)])) in this chat, so sheet \"\(s["name"]!)\" has its columns but no data yet.")
                }
            }
        }
        if let f = s["formulas"] {
            if let list = f as? [Any] {  // [{"cell": "B9", "formula": "SUM(B2:B8)"}]
                var d: [String: Any] = [:]
                for item in list {
                    if let e = item as? [String: Any], let k = (e["cell"] ?? e["ref"] ?? e["name"]) as? String, let v = (e["formula"] ?? e["value"]) {
                        d[k] = v
                    }
                }
                s["formulas"] = d
            } else if let d = object(f) {
                s["formulas"] = d
            } else {
                s["formulas"] = nil
            }
        }
        if let c = s["chart"] { s["chart"] = object(c) }
        return s
    }

    static func inferKind(_ values: [Any]) -> String {
        let v = values.filter { !($0 is NSNull) && ($0 as? String) != "" }
        guard !v.isEmpty else { return "text" }
        if v.allSatisfy({ SpecValidator.number($0) != nil }) { return "number" }
        if v.allSatisfy({ bool($0) != nil && !($0 is String) }) { return "bool" }
        if v.allSatisfy({ ($0 as? String)?.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }) { return "date" }
        return "text"
    }

    /// A sheet that only holds a chart (no columns, no data) → the chart goes onto the data sheet it names.
    static func moveChartOnlySheets(_ sheets: [[String: Any]]) -> [[String: Any]] {
        var out = sheets
        var drop: [Int] = []
        for (i, s) in sheets.enumerated() where s["chart"] != nil && headers(s).isEmpty && !hasData(s) {
            let chart = s["chart"] as? [String: Any] ?? [:]
            let named = ([chart["categories"]] + ((chart["values"] as? [Any]) ?? [chart["values"]])).compactMap { $0 as? String }
                .map { $0.lowercased() }
            let target = out.indices.first { j in
                j != i && out[j]["chart"] == nil && hasData(out[j]) && headers(out[j]).contains { named.contains($0.lowercased()) }
            } ?? out.indices.first { j in j != i && out[j]["chart"] == nil && hasData(out[j]) }
            guard let t = target else { continue }
            out[t]["chart"] = chart
            drop.append(i)
        }
        return out.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// The one sheet of a CSV: the one the prompt names, else the first with data, else the first.
    static func csvSheet(_ sheets: [[String: Any]], ctx: FileOutAdjustContext, notes: inout [String]) -> [String: Any] {
        guard sheets.count > 1 else { return sheets[0] }
        let text = (ctx.userText ?? "").lowercased()
        let named = sheets.firstIndex { s in
            guard let n = s["name"] as? String, n.count >= 2 else { return false }
            return text.contains(n.lowercased()) && hasData(s)
        }
        let pick = named ?? sheets.firstIndex(where: hasData) ?? 0
        let left = sheets.enumerated().filter { $0.offset != pick }.compactMap { $0.element["name"] as? String }
        notes.append("A CSV file holds one table, so it has sheet \"\(sheets[pick]["name"] as? String ?? "")\" only; left out \(quoted(left)) (ask for an Excel file to keep every sheet).")
        return sheets[pick]
    }

    static func columnLetters(_ c: Int) -> String {
        var letters = "", n = c + 1
        while n > 0 { let m = (n - 1) % 26; letters = String(UnicodeScalar(65 + m)!) + letters; n = (n - 1) / 26 }
        return letters
    }

    static func isEmptyCell(_ v: Any?) -> Bool { v == nil || v is NSNull || (v as? String)?.isEmpty == true }

    static let aggregate = try! NSRegularExpression(pattern: #"^\s*=?\s*(SUM|AVERAGE|AVG|MIN|MAX|COUNT|COUNTA|MEDIAN)\s*\((.*)\)\s*$"#, options: [.caseInsensitive])

    /// Formulas keyed by a column name → cells; CSV → none (with a note).
    static func formulas(_ s: inout [String: Any], csv: Bool, notes: inout [String]) {
        guard let f = s["formulas"] as? [String: Any], !f.isEmpty else { s["formulas"] = nil; return }
        if csv {
            s["formulas"] = nil
            notes.append("A CSV file cannot hold formulas, so \(quoted(f.keys.sorted())) were left out (ask for an Excel file to keep them).")
            return
        }
        var rows = (s["rows"] as? [[Any]]) ?? []
        if s["data_ref"] is String, rows.isEmpty {
            // M9 review F3: the query result's rows are not known here; `SpreadsheetSpec.parse` places these formulas
            // once it has filled the sheet (totals below the last row, never over data).
            s["formulas"] = f.mapValues { ($0 as? String) ?? "\($0)" }
            return
        }
        var cols = (s["columns"] as? [[String: Any]]) ?? []
        var hs = cols.compactMap { $0["header"] as? String }
        // Trailing empty rows (a model's placeholder for the total row) are free cells below the data.
        while let last = rows.last, last.allSatisfy({ isEmptyCell($0) }) { rows.removeLast() }
        // A header-only template (no rows yet) gets its totals under 10 blank rows, never over its own cell.
        let lastData = rows.isEmpty ? 11 : rows.count + 1
        var nextFree = lastData + 1
        var out: [String: String] = [:]
        func names() -> [(String, Int)] {
            var n: [(String, Int)] = []
            for (i, h) in hs.enumerated() {
                n.append((h, i))
                if let p = h.range(of: " (") { n.append((String(h[..<p.lowerBound]), i)) }
            }
            return n.sorted { $0.0.count > $1.0.count }
        }
        func substitute(_ expr: String, _ cell: (Int) -> String) -> (String, [Int]) {
            var e = expr, used: [Int] = []
            for (name, c) in names() {
                let esc = NSRegularExpression.escapedPattern(for: name)
                for pattern in [#"\[@?\#(esc)\]"#, #"(?<![A-Za-z0-9_$])\#(esc)(?![A-Za-z0-9_(])"#] {
                    let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                    let range = NSRange(e.startIndex..., in: e)
                    if re.firstMatch(in: e, range: range) != nil {
                        e = re.stringByReplacingMatches(in: e, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: cell(c)))
                        used.append(c)
                    }
                }
            }
            return (e, used)
        }
        for (key, value) in f.sorted(by: { $0.key < $1.key }) {
            let formula = (value as? String) ?? "\(value)"
            var body = formula.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("=") { body.removeFirst() }
            if XLSXWriter.cell(key) != nil { out[key.uppercased()] = body; continue }
            let target = hs.firstIndex { $0.caseInsensitiveCompare(key) == .orderedSame }
            let range = NSRange(body.startIndex..., in: body)
            if let m = aggregate.firstMatch(in: body, range: range) {
                // A total: the column's range, in the first free row below the data, labelled in column A.
                let fn = (body as NSString).substring(with: m.range(at: 1)).uppercased()
                var (args, used) = substitute((body as NSString).substring(with: m.range(at: 2))) { c in
                    "\(columnLetters(c))2:\(columnLetters(c))\(lastData)"
                }
                if used.isEmpty, args.trimmingCharacters(in: .whitespaces).isEmpty, let t = target {
                    args = "\(columnLetters(t))2:\(columnLetters(t))\(lastData)"
                }
                let col = target ?? used.first ?? min(1, max(hs.count - 1, 0))
                let row = nextFree
                nextFree += 1
                out["\(columnLetters(col))\(row)"] = "\(fn == "AVG" ? "AVERAGE" : fn)(\(args))"
                if col != 0 { out["A\(row)"] = "\"\(key.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            } else {
                // A per-row formula: the named column (added when missing), one cell per data row that is empty.
                let col: Int
                if let t = target { col = t } else {
                    cols.append(["header": key, "type": "number"])
                    hs.append(key)
                    col = hs.count - 1
                }
                guard rows.count > 0 else { continue }
                for r in 0..<rows.count where col >= rows[r].count || isEmptyCell(rows[r][col]) {
                    let (e, _) = substitute(body) { c in "\(columnLetters(c))\(r + 2)" }
                    out["\(columnLetters(col))\(r + 2)"] = e
                }
            }
        }
        if !cols.isEmpty { s["columns"] = cols }
        if s["rows"] != nil { s["rows"] = rows }
        s["formulas"] = out.isEmpty ? nil : out
    }

    static func isRange(_ r: String) -> Bool { CreateSpreadsheetTool.isRange(r) }

    /// Chart refs → headers or ranges of this sheet's data; a CSV or a sheet without data has no chart.
    static func chart(_ s: inout [String: Any], csv: Bool, notes: inout [String]) {
        guard var c = s["chart"] as? [String: Any] else { s["chart"] = nil; return }
        let hs = headers(s)
        if csv {
            s["chart"] = nil
            notes.append("A CSV file cannot hold a chart, so the CSV has the data only (ask for an Excel file to get the chart).")
            return
        }
        guard !hs.isEmpty, hasData(s) else {
            s["chart"] = nil
            notes.append("The chart was left out: sheet \"\(s["name"] as? String ?? "")\" has no data for it.")
            return
        }
        c = c.filter { ["type", "title", "categories", "values"].contains($0.key) }
        var type = (c["type"] as? String ?? "column").lowercased().replacingOccurrences(of: " chart", with: "")
        type = ["doughnut": "pie", "donut": "pie", "area": "line", "histogram": "column", "horizontal bar": "bar"][type] ?? type
        c["type"] = ["column", "bar", "line", "pie", "scatter"].contains(type) ? type : "column"
        let cols = (s["columns"] as? [[String: Any]]) ?? []
        let rows = (s["rows"] as? [[Any]]) ?? []
        let numeric = cols.indices.filter { ["number", "currency", "percent"].contains(cols[$0]["type"] as? String ?? "") }
        func known(_ r: String) -> Bool { isRange(r) || hs.contains { $0.caseInsensitiveCompare(r.trimmingCharacters(in: .whitespaces)) == .orderedSame } }
        // Categories: a header / range; a list of the column's own values → that column; else the first text column.
        var cat: String?
        if let r = c["categories"] as? String, known(r) { cat = r }
        if cat == nil, let a = c["categories"] as? [Any] {
            if a.count == 1, let r = a[0] as? String, known(r) { cat = r }
            let texts = Set(a.compactMap { $0 as? String })
            if cat == nil, let col = cols.indices.first(where: { col in
                !texts.isEmpty && texts.isSubset(of: Set(rows.compactMap { col < $0.count ? "\($0[col])" : nil }))
            }) { cat = hs[col] }
        }
        if cat == nil {
            let col = cols.indices.first { !numeric.contains($0) } ?? 0
            cat = hs[col]
        }
        c["categories"] = cat
        // Values: headers / ranges as sent (a single string → a list); literals → the numeric columns.
        let raw: [Any] = (c["values"] as? [Any]) ?? (c["values"].map { [$0] } ?? [])
        var values = raw.compactMap { $0 as? String }.filter(known)
        if values.isEmpty {
            values = numeric.filter { hs[$0].caseInsensitiveCompare(cat ?? "") != .orderedSame }.prefix(8).map { hs[$0] }
        }
        guard !values.isEmpty else {
            s["chart"] = nil
            notes.append("The chart was left out: sheet \"\(s["name"] as? String ?? "")\" has no number column to plot.")
            return
        }
        c["values"] = Array(values.prefix(8))
        s["chart"] = c
    }

    // MARK: - Images (create_document, create_presentation)

    struct ImageResolver {
        let ctx: FileOutAdjustContext
        var used: Set<String> = []
        /// ref → alt of the spec's `images` list.
        var declaredAlts: [(ref: String, alt: String?)] = []

        mutating func firstPass(_ ref: String, alt: String?) -> String? {
            if ctx.imageExists(ref) { used.insert(ref); return ref }
            if let alt, !alt.isEmpty, let d = declaredAlts.first(where: {
                $0.ref != ref && ($0.alt ?? "").caseInsensitiveCompare(alt) == .orderedSame && ctx.imageExists($0.ref)
            }) { used.insert(d.ref); return d.ref }
            let lower = ref.lowercased()
            if let a = ctx.attachedImages.first(where: { lower.contains($0.id.lowercased()) }) { used.insert(a.id); return a.id }
            if let a = ctx.attachedImages.first(where: {
                let n = $0.name.lowercased()
                return lower == n || lower == (n as NSString).deletingPathExtension
            }) { used.insert(a.id); return a.id }
            // By number ("photo1" → the first picture). M9 review F1: no `1...count` range, which traps when the chat
            // has no pictures; such a ref stays unresolved and becomes the visible placeholder.
            if let m = ref.range(of: #"(\d+)$"#, options: .regularExpression), let n = Int(ref[m]),
               ctx.attachedImages.indices.contains(n - 1), ref.range(of: #"^[A-Za-z_\- ]*\d+$"#, options: .regularExpression) != nil {
                let id = ctx.attachedImages[n - 1].id
                used.insert(id)
                return id
            }
            return nil
        }

        mutating func secondPass() -> String? {
            guard let a = ctx.attachedImages.first(where: { !used.contains($0.id) }) else { return nil }
            used.insert(a.id)
            return a.id
        }
    }

    static let imagePattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)

    static func isWeb(_ ref: String) -> Bool { ref.hasPrefix("http://") || ref.hasPrefix("https://") }

    // MARK: - create_document

    static let documentKeys: Set<String> = ["format", "title", "markdown", "page_size", "style", "images", "revises"]

    public static func document(_ raw: String, _ ctx: FileOutAdjustContext) -> FileOutAdjusted {
        guard var o = parseLenient(raw) as? [String: Any] else { return FileOutAdjusted(json: raw, notes: []) }
        var notes: [String] = []
        if o["title"] == nil, let t = (o["filename"] ?? o["name"]) as? String { o["title"] = t }
        if o["markdown"] == nil, let m = (o["content"] ?? o["body"] ?? o["text"]) as? String { o["markdown"] = m }
        o = o.filter { documentKeys.contains($0.key) }
        var format = ((o["format"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        format = ["word": "docx", "doc": "docx", "markdown": "md", "markdown file": "md"][format] ?? format
        if !["pdf", "docx", "md"].contains(format) {
            let ext = ((o["title"] as? String ?? "") as NSString).pathExtension.lowercased()
            format = ["pdf", "docx", "md"].contains(ext) ? ext : format
        }
        if let want = requestedFormat(ctx.userText), ["pdf", "docx", "md"].contains(want), want != format {
            if ["pdf", "docx", "md"].contains(format) {
                notes.append("You asked for a \(["pdf": "PDF", "docx": "Word", "md": "Markdown"][want]!) file, so it is a .\(want) file (the call asked for .\(format)).")
            }
            format = want
        }
        if !format.isEmpty { o["format"] = format }
        if let t = o["title"] as? String { o["title"] = stripExtension(t, ["pdf", "docx", "doc", "md"]) }
        if let p = o["page_size"] as? String { o["page_size"] = ["a4": "A4", "letter": "Letter"][p.lowercased()] }
        if let st = o["style"] as? String { o["style"] = ["plain", "report"].contains(st.lowercased()) ? st.lowercased() : nil }
        // Images: a JSON string, one object, or a list of ids.
        var declared: [[String: Any]] = []
        if let imgs = list(o["images"]) {
            for i in imgs {
                if let r = i as? String { declared.append(["ref": r]) } else if var d = i as? [String: Any] {
                    if d["ref"] == nil, let r = (d["id"] ?? d["image_id"] ?? d["src"]) as? String { d["ref"] = r }
                    d = d.filter { ["ref", "alt"].contains($0.key) }
                    if let r = d["ref"] as? String, !r.isEmpty { declared.append(d) }
                }
            }
        }
        guard var markdown = o["markdown"] as? String else {
            if !declared.isEmpty { o["images"] = declared }
            return FileOutAdjusted(json: encode(o), notes: notes)
        }
        var resolver = ImageResolver(ctx: ctx)
        resolver.declaredAlts = declared.map { ($0["ref"] as! String, $0["alt"] as? String) }
        let ns = markdown as NSString
        let matches = imagePattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var mapped: [String?] = matches.map { m in
            let ref = ns.substring(with: m.range(at: 2))
            return isWeb(ref) ? nil : resolver.firstPass(ref, alt: ns.substring(with: m.range(at: 1)))
        }
        for (i, m) in matches.enumerated() where mapped[i] == nil && !isWeb(ns.substring(with: m.range(at: 2))) {
            mapped[i] = resolver.secondPass()
        }
        var missing: [String] = [], web = false
        for (i, m) in matches.enumerated().reversed() {
            let alt = ns.substring(with: m.range(at: 1)), ref = ns.substring(with: m.range(at: 2))
            let r = Range(m.range, in: markdown)!
            if let id = mapped[i] {
                if id != ref { markdown.replaceSubrange(r, with: "![\(alt)](\(id))") }
            } else {
                if isWeb(ref) { web = true } else { missing.append(alt.isEmpty ? ref : alt) }
                markdown.replaceSubrange(r, with: "*[Image not available: \(alt.isEmpty ? "image" : alt)]*")
            }
        }
        o["markdown"] = markdown
        // `images`: the declared entries that resolve (mapped the same way), plus every id the Markdown now uses.
        var images: [[String: Any]] = []
        var seen = Set<String>()
        for d in declared {
            let ref = d["ref"] as! String
            guard let id = resolver.firstPass(ref, alt: d["alt"] as? String), !seen.contains(id) else { continue }
            var e: [String: Any] = ["ref": id]
            if let a = d["alt"] { e["alt"] = a }
            images.append(e)
            seen.insert(id)
        }
        for id in mapped.compactMap({ $0 }) where !seen.contains(id) {
            images.append(["ref": id])
            seen.insert(id)
        }
        o["images"] = images.isEmpty ? nil : Array(images.prefix(20))
        if !missing.isEmpty {
            let n = missing.count
            notes.append(ctx.attachedImages.isEmpty
                ? "No picture is attached to this chat, so \(n == 1 ? "1 image" : "\(n) images") (\(quoted(missing.reversed()))) shows as \"[Image not available]\"; attach the photos and try again to include them."
                : "Only \(ctx.attachedImages.count) attached picture\(ctx.attachedImages.count == 1 ? " is" : "s are") available, so \(n == 1 ? "1 more image" : "\(n) more images") (\(quoted(missing.reversed()))) \(n == 1 ? "shows" : "show") as \"[Image not available]\".")
        }
        if web { notes.append("Pictures from web addresses cannot be embedded; they show as \"[Image not available]\".") }
        return FileOutAdjusted(json: encode(o), notes: notes)
    }

    // MARK: - create_presentation

    static let presentationKeys: Set<String> = ["filename", "theme", "slides", "revises"]
    static let slideKeys: Set<String> = ["layout", "title", "subtitle", "bullets", "image_ref", "notes"]

    public static func presentation(_ raw: String, _ ctx: FileOutAdjustContext) -> FileOutAdjusted {
        guard var o = parseLenient(raw) as? [String: Any] else { return FileOutAdjusted(json: raw, notes: []) }
        var notes: [String] = []
        if o["filename"] == nil, let t = (o["title"] ?? o["name"]) as? String { o["filename"] = t }
        if let s = list(o["slides"]) { o["slides"] = s }
        o = o.filter { presentationKeys.contains($0.key) }
        if let t = o["theme"] as? String { o["theme"] = PresentationSpec.themes.contains(t.lowercased()) ? t.lowercased() : nil }
        guard let raws = (o["slides"] as? [Any])?.compactMap({ object($0) }), !raws.isEmpty else {
            return FileOutAdjusted(json: encode(o), notes: notes)
        }
        var resolver = ImageResolver(ctx: ctx)
        var slides: [[String: Any]] = []
        var refs: [String?] = []
        for r in raws {
            var s = r.filter { slideKeys.contains($0.key) }
            if s["bullets"] == nil, let c = (r["content"] ?? r["points"] ?? r["body"]) { s["bullets"] = c }
            if s["image_ref"] == nil, let i = (r["image"] ?? r["image_id"] ?? r["image_url"]) as? String { s["image_ref"] = i }
            if s["notes"] == nil, let n = r["speaker_notes"] as? String { s["notes"] = n }
            if let b = s["bullets"] as? String {
                s["bullets"] = b.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t")) }.filter { !$0.isEmpty }
            } else if let b = s["bullets"] as? [Any] {
                s["bullets"] = b.map { ($0 as? String) ?? "\($0)" }
            }
            var layout = (s["layout"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            layout = ["title_slide": "title", "cover": "title", "photo": "image", "picture": "image", "content": "bullets", "text": "bullets",
                      "image_with_text": "title_bullets_image", "bullets_image": "title_bullets_image", "text_image": "title_bullets_image"][layout] ?? layout
            if !["title", "bullets", "image", "title_bullets_image"].contains(layout) {
                layout = s["image_ref"] != nil ? ((s["bullets"] as? [String])?.isEmpty == false ? "title_bullets_image" : "image")
                    : slides.isEmpty && s["bullets"] == nil ? "title" : "bullets"
            }
            s["layout"] = layout
            for k in ["title", "subtitle", "notes"] where s[k] != nil && !(s[k] is String) { s[k] = "\(s[k]!)" }
            // More than 8 bullets → the rest on a continuation slide.
            var bullets = (s["bullets"] as? [String]) ?? []
            let ref = s["image_ref"] as? String
            s["image_ref"] = nil
            if bullets.count > 8 {
                var first = true
                while bullets.count > 8 {
                    var head = s
                    head["bullets"] = Array(bullets.prefix(8))
                    slides.append(head); refs.append(first ? ref : nil)
                    first = false
                    bullets.removeFirst(8)
                    s["title"] = ((s["title"] as? String) ?? "") + " (cont.)"
                    s["notes"] = nil
                }
                s["bullets"] = bullets
                slides.append(s); refs.append(nil)
            } else {
                slides.append(s); refs.append(ref)
            }
        }
        // Image refs: resolved like a document's (by id inside the ref, name, number, then the next unused picture).
        var mapped: [String?] = refs.enumerated().map { i, r in r.flatMap { isWeb($0) ? nil : resolver.firstPass($0, alt: slides[i]["title"] as? String) } }
        for i in refs.indices where refs[i] != nil && mapped[i] == nil && !isWeb(refs[i]!) { mapped[i] = resolver.secondPass() }
        var missing = 0
        for i in slides.indices {
            if let id = mapped[i] { slides[i]["image_ref"] = id } else if let ref = refs[i] {
                // M9 review F1: the slide says so (an image layout shows no text, so it becomes a bullets slide).
                missing += 1
                var bullets = (slides[i]["bullets"] as? [String]) ?? []
                if bullets.count < 8 { bullets.append("[Image not available: \(ref)]") }
                slides[i]["bullets"] = bullets
                if ["image", "title_bullets_image"].contains(slides[i]["layout"] as? String ?? "") { slides[i]["layout"] = "bullets" }
            }
        }
        if missing > 0 {
            let what = "\(missing == 1 ? "1 slide's picture was" : "\(missing) slides' pictures were")"
            notes.append(ctx.attachedImages.isEmpty
                ? "No picture is attached to this chat, so \(missing == 1 ? "that slide shows" : "those slides show") \"[Image not available]\" instead of \(missing == 1 ? "its picture" : "their pictures"); attach the photos and try again to include them."
                : "\(what) not found among the attached pictures, so \(missing == 1 ? "that slide shows" : "those slides show") \"[Image not available]\" instead.")
        }
        if slides.count > 30 {
            notes.append("A deck holds at most 30 slides; the last \(slides.count - 30) were left out.")
            slides = Array(slides.prefix(30))
        }
        o["slides"] = slides
        if let f = o["filename"] as? String { o["filename"] = stripExtension(f, ["pptx", "ppt", "key"]) }
        return FileOutAdjusted(json: encode(o), notes: notes)
    }

    // MARK: - Repair examples

    /// A minimal valid call for the tool (and format) the model was writing, with the chat's real picture ids.
    public static func repairExample(tool: String, argumentsJSON: String, ctx: FileOutAdjustContext) -> String {
        let o = parseLenient(argumentsJSON) as? [String: Any] ?? [:]
        let img = ctx.attachedImages.first?.id
        switch tool {
        case SpreadsheetSchemas.createName:
            let csv = ((o["format"] as? String) ?? "").lowercased() == "csv"
            if csv {
                return #"{"filename":"Budget","format":"csv","sheets":[{"name":"Budget","columns":[{"header":"Item","type":"text"},{"header":"Amount","type":"number"}],"rows":[["Rent",1200],["Food",300]]}]}"#
                    + " (a CSV has exactly one sheet and no formulas or chart; `sheets` is a JSON array, not a string)"
            }
            return #"{"filename":"Budget","format":"xlsx","sheets":[{"name":"Budget","columns":[{"header":"Item","type":"text"},{"header":"Amount","type":"number"}],"rows":[["Rent",1200],["Food",300]],"formulas":{"B4":"SUM(B2:B3)"},"chart":{"type":"column","categories":"A2:A3","values":["B2:B3"]}}]}"#
                + " (`sheets` is a JSON array, not a string; formula keys are cells like B4; chart ranges are cell ranges like A2:A3)"
        case PresentationSchemas.name:
            let slide = img.map { #",{"layout":"image","title":"Photo","image_ref":"\#($0)"}"# } ?? ""
            return #"{"filename":"Deck","slides":[{"layout":"title","title":"Deck"},{"layout":"bullets","title":"Points","bullets":["One","Two"]}\#(slide)]}"#
                + (img == nil ? " (no picture is attached: leave image_ref out)" : " (image_ref is one of the attached picture ids: \(ctx.attachedImages.map(\.id).joined(separator: ", ")))")
        default:
            let format = ["pdf", "docx", "md"].contains(o["format"] as? String ?? "") ? o["format"] as! String : "docx"
            if let img {
                return ##"{"format":"\##(format)","title":"Notes","markdown":"# Notes\n\nText.\n\n![Photo](\##(img))","images":[{"ref":"\##(img)","alt":"Photo"}]}"##
                    + " (image refs are the attached picture ids: \(ctx.attachedImages.map(\.id).joined(separator: ", ")))"
            }
            return ##"{"format":"\##(format)","title":"Notes","markdown":"# Notes\n\nText."}"## + " (no picture is attached: no images)"
        }
    }
}
