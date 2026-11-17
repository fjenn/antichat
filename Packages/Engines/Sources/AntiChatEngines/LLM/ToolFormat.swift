// ToolFormat (M1.T13 step 1; P-shell-09 mlx-swift-lm @ f5b0677): the native tool-call dialect of a model family,
// read from the model's own `chat_template` (chat_template.jinja or tokenizer_config.json). Never a custom text
// protocol: the dialect decides (a) which upstream parser mlx-swift-lm runs, (b) which grammar GrammarBuilder
// builds for the tool-call span, (c) which raw markers RawToolSyntaxScrubber and the leak check look for.
//   Qwen3.5 / Qwen3.6:  <tool_call>\n<function=NAME>\n<parameter=K>\nV\n</parameter>\n</function>\n</tool_call>
//                       (template text "<tool_call>\n<function=" → upstream `.xmlFunction`; the model config
//                       selects the `.qwen35` superset parser, ToolCallFormatInference.swift:83-110)
//   Hermes JSON (tiny fixture, Qwen3): <tool_call>\n{"name": …, "arguments": {…}}\n</tool_call>  (`.json`)
//   Gemma 4:            <|tool_call>call:NAME{k:<|"|>v<|"|>,n:3,o:{k:v},a:[v]}<tool_call|>  (`.gemma4`; the template
//                       of mlx-community/gemma-4-26b-a4b-it-4bit@0d77464: strings in the `<|"|>` escape token,
//                       numbers / booleans bare, nested keys unquoted, no whitespace)
import Foundation
import MLXLMCommon

public enum ToolFormat: String, Codable, Sendable, CaseIterable {
    case qwenXML
    case hermesJSON
    case gemma4
    /// Some other upstream dialect (parsed by mlx-swift-lm, not grammar-constrained by AntiChat).
    case other
    /// The template renders no tool calls.
    case none

    /// Upstream inference from the template text (mlx-swift-lm `ToolCallFormat.inferred(fromChatTemplate:)`).
    public static func detect(chatTemplate: String) -> ToolFormat {
        let f = ToolFormat(upstream: ToolCallFormat.inferred(fromChatTemplate: chatTemplate))
        // Hermes templates that spell the call with `tc.function.name` (e.g. the tiny fixture) escape upstream's
        // `tool_call.name` signature; the rendered dialect is the same framed JSON.
        if f == .none, chatTemplate.contains("<tool_call>"), chatTemplate.contains("\"name\"") { return .hermesJSON }
        return f
    }

    public init(upstream: ToolCallFormat?) {
        switch upstream {
        case .xmlFunction?, .qwen35?: self = .qwenXML
        case .json?: self = .hermesJSON
        case .gemma4?: self = .gemma4
        case nil: self = .none
        default: self = .other
        }
    }

    /// The chat template of a model directory: `chat_template.jinja` wins over `tokenizer_config.json`'s
    /// `chat_template` (string or the named-template list's `default`/`tool_use` entry).
    public static func chatTemplate(modelDirectory dir: URL) -> String? {
        if let s = try? String(contentsOf: dir.appendingPathComponent("chat_template.jinja"), encoding: .utf8) { return s }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("tokenizer_config.json")),
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        if let s = obj["chat_template"] as? String { return s }
        if let list = obj["chat_template"] as? [[String: Any]] {
            let pick = list.first { ($0["name"] as? String) == "tool_use" } ?? list.first { ($0["name"] as? String) == "default" }
            return pick?["template"] as? String
        }
        return nil
    }

    public static func detect(modelDirectory dir: URL) -> ToolFormat {
        chatTemplate(modelDirectory: dir).map(detect(chatTemplate:)) ?? .none
    }

    /// The special token that opens a call (the lazy grammar's trigger).
    public var openTag: String? {
        switch self {
        case .qwenXML, .hermesJSON: "<tool_call>"
        case .gemma4: "<|tool_call>"
        case .other, .none: nil
        }
    }

    public var closeTag: String? {
        switch self {
        case .qwenXML, .hermesJSON: "</tool_call>"
        case .gemma4: "<tool_call|>"
        case .other, .none: nil
        }
    }

    /// Whether GrammarBuilder can constrain this dialect's call span on MLX. Every shipped dialect: xgrammar structural
    /// tags (v0.1.30) take a `json_schema` content (Hermes) or an EBNF `grammar` content, which carries Qwen's XML
    /// parameter list and Gemma 4's `call:NAME{k:<|"|>v<|"|>}` argument list (`GrammarBuilder.gemma4Arguments`).
    public var grammarConstrainable: Bool { self == .qwenXML || self == .hermesJSON || self == .gemma4 }

    /// The special tokens around a reasoning span, and whether the template itself opens the span in the generation
    /// prompt (Qwen: `<think>\n` is rendered; Gemma 4: the model writes `<|channel>thought` itself). The lazy grammar
    /// ignores a call marker inside the span. A forced call waits for a span the template opened to close; where the
    /// model would open it itself (Gemma 4) the forced call comes first, without reasoning.
    public var reasoningTags: (open: String, close: String, openedByTemplate: Bool) {
        self == .gemma4 ? ("<|channel>", "<channel|>", false) : ("<think>", "</think>", true)
    }

    /// Every raw tool-call marker of the dialects AntiChat ships or meets (AT-231 "raw syntax": `<tool_call>`,
    /// `<|tool|>`, `[TOOL_CALLS]`, plus the Gemma 4 / XML / Llama tags), paired with its closing marker when the
    /// dialect has one. RawToolSyntaxScrubber and the conformance leak check share this list.
    public static let rawMarkers: [(open: String, close: String?)] = [
        ("<tool_call>", "</tool_call>"),
        ("<|tool_call>", "<tool_call|>"),
        ("<function=", "</function>"),
        ("<|tool_call_start|>", "<|tool_call_end|>"),
        ("[TOOL_CALLS]", nil),
        ("<|tool|>", nil),
        ("<|python_tag|>", nil),
        ("</tool_call>", nil),
        ("<tool_call|>", nil),
    ]
}
