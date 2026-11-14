// Tool-call scoring shared by the M1.T13 conformance suite (App/IntegrationTests/Conformance) and
// `antichat-bench tools` (AT-231): a JSON Schema checker for call arguments, the raw-syntax leak detector for
// delivered text, and the per-stream trace record. App-side (Harness), so neither consumer links AntiChatEngines.
// The schema checker (AntiChatTools `SpecValidator` since M6.T09) covers the keywords our tool schemas and the BFCL
// subset use: type (incl. BFCL `dict`/`float`/`tuple` aliases), properties, required, enum, const, minimum/maximum,
// items, additionalProperties: false, anyOf (+ oneOf, min/maxItems, min/maxLength).
import AntiChatEngineProtocol
import AntiChatTools
import Foundation

public enum ToolSchemaCheck {
    /// Problems of `value` against `schema` (empty = valid). M6.T09: the checker lives in AntiChatTools
    /// (`SpecValidator`, which also covers oneOf / minItems / maxItems / minLength / maxLength for the file-out specs).
    public static func problems(_ value: Any, _ schema: [String: Any], path: String = "$") -> [String] {
        SpecValidator.problems(value, schema, path: path)
    }
}

public enum RawToolSyntax {
    /// Raw call markers of every dialect (AT-231: `<tool_call>`, `<|tool|>`, `[TOOL_CALLS]`, + Gemma 4 / XML / Llama).
    public static let markers = [
        "<tool_call>", "</tool_call>", "<|tool_call>", "<tool_call|>", "<function=", "</function>", "<parameter=",
        "[TOOL_CALLS]", "<|tool|>", "<|python_tag|>", "<|tool_call_start|>",
    ]
    /// A JSON call object in prose (`{"name": "…", "arguments": …}`).
    static let jsonCall = try! NSRegularExpression(pattern: #"\{\s*"name"\s*:\s*"[^"]+"\s*,\s*"(arguments|parameters)"\s*:"#)

    /// Leaks in delivered answer text: each marker occurrence and each JSON call object counts once.
    public static func leaks(in text: String) -> [String] {
        var out: [String] = []
        for m in markers where text.contains(m) { out.append(m) }
        if jsonCall.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { out.append("json-call-object") }
        return out
    }
}

/// Everything one request produced, as the conformance suite and the bench record it.
public struct ToolStreamTrace: Sendable {
    public var events: [EngineEvent] = []
    public var text: String { events.compactMap { if case .textDelta(let s) = $0 { s } else { nil } }.joined() }
    public var reasoning: String { events.compactMap { if case .reasoningDelta(let s) = $0 { s } else { nil } }.joined() }
    public var calls: [(id: String, name: String, args: String)] {
        events.compactMap { if case .toolCallDone(let id, let n, let a) = $0 { (id, n, a) } else { nil } }
    }
    public var usage: Usage? { events.compactMap { if case .usage(let u) = $0 { u } else { nil } }.last }
    public var terminal: EngineEvent? { events.last(where: \.isTerminal) }

    public init(events: [EngineEvent] = []) { self.events = events }

    public struct CallCheck: Sendable {
        public var name: String
        public var parses: Bool
        public var declared: Bool
        public var schemaProblems: [String]
        public var args: [String: AnySendableJSON]
        public var schemaValid: Bool { parses && declared && schemaProblems.isEmpty }
    }

    /// Per-call validity against the offered tools (OpenAI objects or ToolSchema).
    public func checkCalls(_ tools: [ToolSchema]) -> [CallCheck] {
        let schemas = Dictionary(tools.map { ($0.name, $0.parametersJSON) }, uniquingKeysWith: { a, _ in a })
        return calls.map { c in
            let obj = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8))) as? [String: Any]
            let declared = schemas[c.name] != nil
            var problems: [String] = []
            if let obj, let s = schemas[c.name], let schema = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                problems = ToolSchemaCheck.problems(obj, schema)
            }
            return CallCheck(
                name: c.name, parses: obj != nil, declared: declared, schemaProblems: problems,
                args: (obj ?? [:]).mapValues { AnySendableJSON($0) })
        }
    }
}

/// A JSON value carried across concurrency domains (string form for matching).
public struct AnySendableJSON: Sendable, CustomStringConvertible {
    public let description: String
    init(_ v: Any) {
        if let s = v as? String {
            description = s
        } else if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) {
            description = String(decoding: d, as: UTF8.self)
        } else {
            description = "\(v)"
        }
    }
}

public enum ArgsMatch {
    /// `contains`: key → regex (case-insensitive, `|` alternatives) the argument's string form must match.
    public static func matches(_ args: [String: AnySendableJSON], _ contains: [String: String]) -> Bool {
        contains.allSatisfy { k, pattern in
            guard let v = args[k]?.description.lowercased() else { return false }
            return v.range(of: pattern.lowercased(), options: .regularExpression) != nil
        }
    }
}
