// Tool block, layer (5) (M1.T14 step 1; R-269): canonical order by tool key, compact schemas, byte-stable JSON.
// The same tool set always yields the same bytes, whatever order tools were registered in, so two turns with the
// same tools share the cached prefix (AT-269).
import AntiChatEngineProtocol
import Foundation

public struct ToolBlockRenderer: Sendable {
    /// Drop schema `description` annotations and keep a one-line tool description (Osaurus bootstrap compaction).
    public var compact: Bool

    public init(compact: Bool = true) {
        self.compact = compact
    }

    /// Canonical, compacted tools: sorted by name, parameters re-serialised with sorted keys.
    public func canonical(_ tools: [ToolSchema]) -> [ToolSchema] {
        Self.canonicalToolOrder(tools).map { t in
            let description = compact ? (Self.oneLineToolDescription(t.description) ?? "") : PromptText.normalize(t.description)
            var params: Any = (try? JSONSerialization.jsonObject(with: Data(t.parametersJSON.utf8))) ?? ["type": "object"]
            if compact { params = Self.compactSchema(params, keysArePropertyNames: false) }
            return ToolSchema(name: t.name, description: description, parametersJSON: Self.json(params))
        }
    }

    /// The block's text: one OpenAI function object per line (`{"function":{…},"type":"function"}`), sorted keys.
    /// It is what the manifest hashes and, under `ToolPlacement.systemLayer`, what layer (5) contains.
    public func render(_ canonicalTools: [ToolSchema]) -> String {
        canonicalTools.map { Self.json($0.openAIObject) }.joined(separator: "\n")
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift:L3637-3668
    // (canonicalToolOrder). AntiChat has no agent-loop/sandbox/capability buckets, so the order is the tool key
    // (name) alone; ties keep their input order.
    static func canonicalToolOrder(_ tools: [ToolSchema]) -> [ToolSchema] {
        tools.enumerated().sorted { a, b in
            a.element.name != b.element.name ? a.element.name < b.element.name : a.offset < b.offset
        }.map(\.element)
    }

    // Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift:L2088-2156
    // (oneLineToolDescription / oneLineToolDescriptionImpl / endsWithAbbreviation): the first sentence, ≤ 180
    // characters; a period only ends a sentence before whitespace or the end, and not after a common abbreviation.
    // The upstream memo cache is dropped (the composer runs once per turn, off the main actor).
    static func oneLineToolDescription(_ description: String) -> String? {
        let collapsed = description.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let chars = Array(collapsed)
        var sentenceEndOffset: Int?
        for i in chars.indices where ".!?".contains(chars[i]) {
            let isLast = i == chars.count - 1
            guard isLast || chars[i + 1].isWhitespace else { continue }
            if chars[i] == ".", endsWithAbbreviation(chars, at: i) { continue }
            sentenceEndOffset = i
            break
        }
        let firstSentence = sentenceEndOffset.map { String(chars[...$0]) } ?? collapsed
        if firstSentence.count <= 180 { return firstSentence }
        return String(firstSentence.prefix(177)) + "..."
    }

    private static let descriptionAbbreviations: Set<String> = [
        "e.g.", "i.e.", "etc.", "vs.", "approx.", "incl.", "no.", "fig.",
    ]

    private static func endsWithAbbreviation(_ chars: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        return descriptionAbbreviations.contains(String(chars[start...index]).lowercased())
    }

    // Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift:L2157-2198
    // (compactParameterSkeleton / compactSchema) over JSONSerialization values instead of Osaurus' JSONValue:
    // drop `description` annotations, keep shape, `required`, enums and nesting; keys under `properties` are
    // parameter names and are kept even when a parameter is literally called `description`.
    static func compactSchema(_ value: Any, keysArePropertyNames: Bool) -> Any {
        if let object = value as? [String: Any] {
            var compact: [String: Any] = [:]
            for (key, nested) in object {
                if keysArePropertyNames {
                    compact[key] = compactSchema(nested, keysArePropertyNames: false)
                } else if key == "description" {
                    continue
                } else {
                    compact[key] = compactSchema(nested, keysArePropertyNames: key == "properties")
                }
            }
            return compact
        }
        if let array = value as? [Any] { return array.map { compactSchema($0, keysArePropertyNames: false) } }
        return value
    }
}
