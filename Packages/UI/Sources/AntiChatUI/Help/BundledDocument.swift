// M10.T06/T07 (R-217 AC2, R-303 AC1): Markdown documents bundled in the app (Resources/Legal/*.md, Help/guide.md),
// read offline. Front matter (`title`, `version`, `updated`) is parsed; the body renders as attributed Markdown.
import Foundation

struct BundledDocument: Identifiable, Equatable {
    let id: String          // file name without extension
    let title: String
    let version: String?
    let updated: String?
    let body: String

    /// Pure parser (unit-tested): `---\nkey: "value"\n---\nbody`.
    static func parse(id: String, text: String) -> BundledDocument {
        var meta: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = line[..<colon].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                meta[k] = v
            }
            body = String(text[end.upperBound...])
        }
        let firstHeading = body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        return BundledDocument(id: id, title: meta["title"] ?? firstHeading ?? id, version: meta["version"],
                               updated: meta["updated"], body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// M9.T04 (R-102): a help page in the UI language (`HelpL10n/<lang>/<name>.md`), else the English original.
    /// Legal pages stay English (the binding text equals the site's, A-M9-T04a).
    static func localizedURL(_ name: String, subdirectory: String?, bundle: Bundle = .main,
                             language: String = Bundle.main.preferredLocalizations.first ?? "en") -> URL? {
        let lang = String(language.prefix(2))
        if subdirectory == nil, lang != "en",
           let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "HelpL10n/\(lang)") {
            return url
        }
        return bundle.url(forResource: name, withExtension: "md", subdirectory: subdirectory)
    }

    static func load(_ name: String, subdirectory: String?, bundle: Bundle = .main) -> BundledDocument? {
        guard let url = localizedURL(name, subdirectory: subdirectory, bundle: bundle),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(id: name, text: s)
    }

    /// The legal pages in their reading order (tools/site/legal-sync.py writes them).
    static let legalOrder = ["terms", "privacy", "evil-mode-terms", "acceptable-use", "abuse", "security", "licenses", "model-licenses"]

    static func legalPages(bundle: Bundle = .main) -> [BundledDocument] {
        legalOrder.compactMap { load($0, subdirectory: "Legal", bundle: bundle) }
    }

    /// Headings become bold lines (inline Markdown keeps the rest: emphasis, code, links).
    var attributed: AttributedString {
        let text = body.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("#") else { return String(line) }
            return "**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**"
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
