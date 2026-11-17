// Gemma 4 tool calls (the 32 GB tier's chat-g26 / evil-g26): the argument grammar GrammarBuilder builds for the
// dialect of the model's own template (mlx-community/gemma-4-26b-a4b-it-4bit@0d77464 chat_template.jinja), the forced
// `tool_choice` constraint, parsing through mlx-swift-lm's ToolCallProcessor (the parser MLXAdapter uses) and the
// cut-off / malformed path. The grammar is text level, so it is walked on the tiny fixture tokenizer everywhere and on
// the real Gemma 4 tokenizer (no weights) when its files are there: an installed chat-g26 / evil-g26, or a directory
// with tokenizer.json, tokenizer_config.json, config.json and chat_template.jinja named by ANTICHAT_GEMMA4_TOKENIZER.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import Testing
@testable import AntiChatEngines

enum Gemma4Files {
    static var dir: URL? {
        if let p = ProcessInfo.processInfo.environment["ANTICHAT_GEMMA4_TOKENIZER"], !p.isEmpty {
            let d = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("tokenizer.json").path) { return d }
        }
        return DevModels.path("chat-g26") ?? DevModels.path("evil-g26")
    }
}

/// A call in the template's layout, written from a tool's schema (every declared parameter, sample values).
enum Gemma4Sample {
    static let q = "<|\"|>"
    /// Text with the punctuation the dialect itself uses: it must survive inside the escape token.
    static let awkward = "a, b: {c} [d] \"e\"\n2 }"

    static func value(_ s: [String: Any], depth: Int = 0) -> String {
        if let e = s["enum"] as? [Any], let first = e.first { return first is String ? q + "\(first)" + q : "\(first)" }
        if let a = (s["anyOf"] ?? s["oneOf"]) as? [[String: Any]], let last = a.last { return value(last, depth: depth + 1) }
        switch (s["type"] as? String) ?? (s["type"] as? [String])?.first {
        case "string": return q + awkward + q
        case "integer": return "-3"
        case "number": return "2.5"
        case "boolean": return "true"
        case "null": return "null"
        case "array":
            let item = (s["items"] as? [String: Any]).map { value($0, depth: depth + 1) } ?? q + "x" + q
            return "[" + Array(repeating: item, count: max(1, s["minItems"] as? Int ?? 2)).joined(separator: ",") + "]"
        case "object":
            let props = s["properties"] as? [String: Any] ?? [:]
            if props.isEmpty { return "{k:\(q)v\(q),n:1,o:{b:true},a:[1,null]}" }
            return "{" + fields(s, depth: depth + 1) + "}"
        default: return q + "v" + q
        }
    }

    static func fields(_ s: [String: Any], depth: Int = 0) -> String {
        (s["properties"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key):" + value($0.value as? [String: Any] ?? [:], depth: depth) }.joined(separator: ",")
    }

    /// The body after `<|tool_call>` and the keys it carries.
    static func call(_ t: ToolSchema) -> (body: String, keys: [String]) {
        let s = GrammarBuilder.normalizedSchema(t.parametersJSON)
        return ("call:\(t.name){\(fields(s))}<tool_call|>", (s["properties"] as? [String: Any] ?? [:]).keys.sorted())
    }
}

@Suite(.serialized) struct Gemma4ToolCallTests {
    static let weather = GrammarBuilderTests.weather
    static let time = GrammarBuilderTests.time
    static let search = ToolSchema(name: "web_search", description: "Search", parametersJSON: #"{"type":"object","properties":{"queries":{"type":"array","items":{"type":"string"},"minItems":1},"freshness":{"type":"string","enum":["day","week"]},"safe":{"type":"boolean"},"filter":{"type":"object","properties":{"site":{"type":"string"},"max":{"type":"integer"}}}},"required":["queries"]}"#)

    /// The real Gemma 4 tokenizer when its files are present, else the tiny fixture's (whose `<tool_call>` stands in
    /// for the opening token; the body is then spelled in plain characters, which the text-level grammar also takes).
    static func tokenizer() async throws -> (tok: any MLXLMCommon.Tokenizer, trigger: Int, real: Bool)? {
        if let d = Gemma4Files.dir {
            let tok = try await GrammarBuilderTests.tokenizer(d)
            return (tok, try #require(tok.convertTokenToId("<|tool_call>")), true)
        }
        guard let d = TinyModel.dir else { return nil }
        let tok = try await GrammarBuilderTests.tokenizer(d)
        return (tok, try #require(tok.convertTokenToId("<tool_call>")), false)
    }

    struct Walk {
        var allowed = true
        var completed = 0
        /// The text up to the token at which the span completed.
        var completedAt: String?
        /// Forced only: the opening tag was the single admitted first token, and the token after it was masked.
        var openedAlone = false
        var firstMasked = false
        /// The text up to the first token the mask refused.
        var refusedAfter: String?
    }

    /// Walks `body` (what follows the opening token) under the lazy processor, as the sampler would.
    static func walk(_ t: (tok: any MLXLMCommon.Tokenizer, trigger: Int, real: Bool), format: ToolFormat = .gemma4,
                     tools: [ToolSchema], body: String, forced: Bool = false, cache: ToolGrammarCache = ToolGrammarCache()) throws -> Walk {
        let tag = try #require(GrammarBuilder.structuralTag(format: format, tools: tools))
        let stats = ToolGrammarStats()
        let tok = t.tok
        let p = LazyToolGrammarProcessor(
            triggerID: t.trigger, thinkOpenID: nil, thinkCloseID: nil, eosID: tok.eosTokenId ?? 0, startsInThink: false,
            stats: stats, forced: forced, make: { cache.checkout(modelKey: "t", tokenizer: tok, tag: tag) },
            release: { cache.checkin($0, tag: tag) })
        #expect(cache.prepare(modelKey: "t", tokenizer: tok, tag: tag), "grammar compiles: \(cache.lastError ?? "")")
        let ids = tok.encode(text: body, addSpecialTokens: false)
        let logits = MLXArray.zeros([1, 300_000])
        var w = Walk()
        func judge(_ out: MLXArray, next i: Int) {
            guard i < ids.count, w.allowed else { return }
            if out[0, ids[i]].item(Float.self) == -Float.infinity {
                w.allowed = false
                w.refusedAfter = tok.decode(tokenIds: Array(ids[0..<i]), skipSpecialTokens: false)
            }
        }
        if forced {
            let first = p.process(logits: logits)
            w.openedAlone = first[0, t.trigger].item(Float.self) == 0 && first.max().item(Float.self) == 0
                && first.sum().item(Float.self) == -Float.infinity && (first .== 0).sum().item(Int.self) == 1
            p.didSample(token: MLXArray([Int32(t.trigger)]))
            let out = p.process(logits: logits)
            w.firstMasked = out.min().item(Float.self) == -Float.infinity
            judge(out, next: 0)
        } else {
            p.didSample(token: MLXArray([Int32(t.trigger)]))
        }
        for (i, id) in ids.enumerated() {
            p.didSample(token: MLXArray([Int32(id)]))
            let out = p.process(logits: logits)
            if w.completedAt == nil, stats.completed > 0 { w.completedAt = tok.decode(tokenIds: Array(ids[0...i]), skipSpecialTokens: false) }
            judge(out, next: i + 1)
        }
        w.completed = stats.completed
        return w
    }

    static func parse(_ text: String, tools: [ToolSchema], chunks: [String]? = nil) -> (calls: [ToolCall], rejected: [RejectedToolCall], visible: String) {
        let proc = ToolCallProcessor(format: .gemma4, tools: MLXAdapter.toolSpecs(tools))
        var scrub = RawToolSyntaxScrubber()
        var visible = ""
        for c in chunks ?? [text] { visible += scrub.feed(proc.processChunk(c) ?? "") }
        visible += scrub.feed(proc.processEOS() ?? "") + scrub.finish()
        return (proc.toolCalls, proc.rejectedToolCalls, visible)
    }

    // MARK: Format, rendering of the grammar

    @Test func gemma4IsAConstrainableDialectWithItsOwnReasoningTokens() {
        #expect(ToolFormat.gemma4.grammarConstrainable)
        #expect(ToolFormat.gemma4.openTag == "<|tool_call>" && ToolFormat.gemma4.closeTag == "<tool_call|>")
        #expect(ToolFormat.gemma4.reasoningTags == ("<|channel>", "<channel|>", false))
        #expect(ToolFormat.qwenXML.reasoningTags == ("<think>", "</think>", true))
        #expect(!ToolFormat.other.grammarConstrainable && !ToolFormat.none.grammarConstrainable)
        if let d = Gemma4Files.dir { #expect(ToolFormat.detect(modelDirectory: d) == .gemma4) }
    }

    @Test func structuralTagNamesEachToolAndTypesItsArguments() throws {
        let tag = try #require(GrammarBuilder.structuralTag(format: .gemma4, tools: [Self.weather, Self.search]))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(tag.utf8)) as? [String: Any])
        let elements = try #require((root["format"] as? [String: Any])?["elements"] as? [[String: Any]])
        #expect(elements.map { $0["begin"] as? String } == ["call:weather{", "call:web_search{"])
        #expect(elements.allSatisfy { $0["end"] as? String == "}" })
        // One tool (a forced call's scope): a single tag, no alternative.
        let one = try #require(GrammarBuilder.structuralTag(format: .gemma4, tools: [Self.weather]))
        #expect(one.contains(#""begin":"call:weather{""#) && !one.contains(#""or""#))

        let g = GrammarBuilder.gemma4Arguments(GrammarBuilder.normalizedSchema(Self.search.parametersJSON))
        let rules = Dictionary(uniqueKeysWithValues: g.split(separator: "\n").map { l -> (String, String) in
            let parts = l.components(separatedBy: " ::= ")
            return (parts[0], parts.dropFirst().joined(separator: " ::= "))
        })
        #expect(rules["q"] == #""<|\"|>""#, "strings are wrapped in the escape token")
        #expect(rules["str"] == "q text q")
        #expect(rules["text"]?.contains(#"excludes=("<|\"|>", "<tool_call|>", "<turn|>")"#) == true)
        #expect(g.contains(#""freshness:" (q "day" q | q "week" q)"#), "string enum: its values only")
        #expect(g.contains(#""safe:" bool"#))
        #expect(g.contains(#""[" (str ("," str)*)? "]""#), "array of strings")
        #expect(g.contains(#""site:" str"#) && g.contains(#""max:" int"#), "nested object follows its properties")
        #expect(rules["root"]?.hasPrefix("(f") == true, "any order, comma separated: \(rules["root"] ?? "")")
        // No declared parameters: an empty list; open-ended objects: any pairs.
        #expect(GrammarBuilder.gemma4Arguments(["type": "object", "properties": [String: Any]()]).hasPrefix("root ::= \"\"\n"))
        #expect(GrammarBuilder.gemma4Arguments(["type": "object", "additionalProperties": true]).hasPrefix(#"root ::= (key ":" any"#))
        // Untyped, union and non-string enum values.
        var b = GrammarBuilder.Gemma4Rules()
        #expect(b.value([:], depth: 0) == "any")
        #expect(b.value(["type": ["string", "null"]], depth: 0) == #"(str | "null")"#)
        #expect(b.value(["enum": [1, true, "a"]], depth: 0) == #"("1" | "true" | q "a" q)"#)
        #expect(b.value(["anyOf": [["type": "integer"], ["type": "string"]]], depth: 0) == "(int | str)")
        #expect(b.value(["$ref": "#/x"], depth: 0) == "any" && b.value(["type": "array"], depth: 0) == "arr")
    }

    // MARK: Grammar walks

    @Test func grammarAcceptsTheTemplateLayoutAndNothingElse() async throws {
        guard let t = try await Self.tokenizer() else { return }
        let q = Gemma4Sample.q
        let tools = [Self.weather, Self.time, Self.search]
        let good = "call:weather{city:\(q)Paris\(q)}<tool_call|>"
        let w = try Self.walk(t, tools: tools, body: good)
        #expect(w.allowed && w.completed == 1, "refused after: \(w.refusedAfter ?? "-")")
        #expect(w.completedAt == "call:weather{city:\(q)Paris\(q)}", "the span ends at the closing brace: \(w.completedAt ?? "never")")

        let accepted = [
            "call:get_time{}<tool_call|>",
            "call:get_time{n:4,tz:\(q)Asia/Tokyo\(q)}<tool_call|>",
            "call:get_time{tz:\(q)UTC\(q),n:-12}<tool_call|>",
            "call:weather{city:\(q)\(Gemma4Sample.awkward)\(q)}<tool_call|>",
            "call:weather{city:\(q)\(q)}<tool_call|>",
            "call:web_search{queries:[\(q)a b\(q),\(q)c\(q)],freshness:\(q)week\(q),safe:false,filter:{site:\(q)x.org\(q),max:3}}<tool_call|>",
            "call:web_search{filter:{},queries:[]}<tool_call|>",
        ]
        for body in accepted {
            let w = try Self.walk(t, tools: tools, body: body)
            #expect(w.allowed && w.completed == 1, "\(body) refused after: \(w.refusedAfter ?? "-")")
        }
        let refused: [(String, String)] = [
            ("call:nuke{}<tool_call|>", "undeclared tool"),
            ("call:weather{town:\(q)Paris\(q)}<tool_call|>", "undeclared parameter"),
            ("call:weather{city:Paris}<tool_call|>", "string outside the escape token"),
            ("call:weather{city:\"Paris\"}<tool_call|>", "JSON-quoted string"),
            ("call:get_time{n:three}<tool_call|>", "text for an integer"),
            ("call:get_time{n:\(q)3\(q)}<tool_call|>", "escaped string for an integer"),
            ("call:get_time{n:4 ,tz:\(q)UTC\(q)}<tool_call|>", "whitespace between pairs"),
            ("call:web_search{queries:[\(q)a\(q)],freshness:\(q)year\(q)}<tool_call|>", "value outside the enum"),
            ("call:web_search{queries:\(q)a\(q)}<tool_call|>", "string for an array"),
            ("call:web_search{queries:[3]}<tool_call|>", "number in an array of strings"),
            ("call:web_search{filter:{depth:1},queries:[]}<tool_call|>", "undeclared nested key"),
            ("call:web_search{safe:yes}<tool_call|>", "non-boolean"),
        ]
        for (body, why) in refused {
            #expect(try Self.walk(t, tools: tools, body: body).allowed == false, "\(why): \(body)")
        }
    }

    /// Partial output: while a call is open, neither the call's closing token nor the turn's end is admitted, so a
    /// call cannot end inside a string or before its closing brace.
    @Test func anOpenCallCannotBeClosedEarly() async throws {
        guard let t = try await Self.tokenizer() else { return }
        let q = Gemma4Sample.q
        for (body, cut) in [
            ("call:weather{city:\(q)Par<tool_call|>", "call:weather{city:\(q)Par"),
            ("call:weather{city:\(q)Par<turn|>", "call:weather{city:\(q)Par"),
            ("call:weather{city:\(q)Paris\(q)<tool_call|>", "call:weather{city:\(q)Paris\(q)"),
            ("call:weather{<tool_call|>", "call:weather{"),
            ("call:weather<tool_call|>", "call:weather"),
        ] {
            let w = try Self.walk(t, tools: [Self.weather], body: body)
            #expect(!w.allowed && w.completed == 0, "\(body)")
            if t.real { #expect(w.refusedAfter == cut, "refused after \(w.refusedAfter ?? "-")") }
        }
        if t.real, let eos = t.tok.eosTokenId {
            // The stop token itself is cleared from every mask of the span (checked inside a string value).
            let tag = try #require(GrammarBuilder.structuralTag(format: .gemma4, tools: [Self.weather]))
            let cache = ToolGrammarCache()
            let p = LazyToolGrammarProcessor(
                triggerID: t.trigger, thinkOpenID: nil, thinkCloseID: nil, eosID: eos, startsInThink: false, stats: ToolGrammarStats(),
                make: { cache.checkout(modelKey: "t", tokenizer: t.tok, tag: tag) }, release: { cache.checkin($0, tag: tag) })
            let logits = MLXArray.zeros([1, 300_000])
            var out = logits
            for id in [t.trigger] + t.tok.encode(text: "call:weather{city:\(q)Par", addSpecialTokens: false) {
                p.didSample(token: MLXArray([Int32(id)]))
                out = p.process(logits: logits)
            }
            #expect(out[0, eos].item(Float.self) == -Float.infinity)
            #expect(out[0, t.tok.convertTokenToId("<turn|>")!].item(Float.self) == -Float.infinity)
            #expect(out[0, t.tok.convertTokenToId(q)!].item(Float.self) == 0, "the string can be closed")
        }
    }

    /// A reasoning span is not a call: a call marker inside Gemma's `<|channel>…<channel|>` does not open the grammar.
    @Test func aCallMarkerInsideReasoningDoesNotActivate() {
        let stats = ToolGrammarStats()
        let p = LazyToolGrammarProcessor(triggerID: 48, thinkOpenID: 100, thinkCloseID: 101, eosID: 1, startsInThink: false,
                                         stats: stats, make: { nil })
        let logits = MLXArray.ones([1, 128])
        for id in [100, 9, 48, 9, 101, 9, 9] {
            p.didSample(token: MLXArray([Int32(id)]))
            #expect(p.process(logits: logits).min().item(Float.self) == 1)
        }
        #expect(stats.activations == 0)
        for id in [48, 9, 9] {
            p.didSample(token: MLXArray([Int32(id)]))
            _ = p.process(logits: logits)
        }
        #expect(stats.activations == 1, "outside reasoning the marker opens the span")
    }

    // MARK: Forced tool

    @Test func toolChoiceScopesTheGrammar() {
        let offered = [Self.weather, Self.time]
        #expect(MLXAdapter.grammarScope(.function("get_time"), offered: offered) == (true, [Self.time]))
        #expect(MLXAdapter.grammarScope(.function("missing"), offered: offered) == (false, offered))
        #expect(MLXAdapter.grammarScope(.required, offered: offered) == (true, offered))
        #expect(MLXAdapter.grammarScope(.auto, offered: offered) == (false, offered))
        #expect(MLXAdapter.grammarScope(nil, offered: offered) == (false, offered))
        #expect(MLXAdapter.grammarScope(.required, offered: []) == (false, []))
    }

    /// A forced call: the opening token is the only first token, and the body is constrained from its first token on
    /// to the forced tool's call (no free token after the tag, so the call cannot start as another tool's).
    @Test func forcedCallIsThatToolsCallFromItsFirstToken() async throws {
        guard let t = try await Self.tokenizer() else { return }
        let q = Gemma4Sample.q
        let scope = MLXAdapter.grammarScope(.function("weather"), offered: [Self.weather, Self.time, Self.search])
        #expect(scope.forced)
        let w = try Self.walk(t, tools: scope.tools, body: "call:weather{city:\(q)Paris\(q)}<tool_call|>", forced: true)
        #expect(w.openedAlone && w.firstMasked)
        #expect(w.allowed && w.completed == 1, "refused after: \(w.refusedAfter ?? "-")")
        for body in ["call:get_time{}<tool_call|>", "call:web_search{queries:[]}<tool_call|>", "Sure, the weather", "<tool_call|>", "\ncall:weather{}"] {
            let w = try Self.walk(t, tools: scope.tools, body: body, forced: true)
            #expect(w.openedAlone && w.firstMasked && !w.allowed && w.completed == 0, "\(body)")
        }
        // `required`: any offered tool, still a call.
        let any = MLXAdapter.grammarScope(.required, offered: [Self.weather, Self.time])
        #expect(try Self.walk(t, tools: any.tools, body: "call:get_time{n:1}<tool_call|>", forced: true).completed == 1)
        #expect(try Self.walk(t, tools: any.tools, body: "call:nuke{}<tool_call|>", forced: true).allowed == false)
    }

    /// The same forced path for the Qwen dialects (shared machinery): the body starts constrained there too.
    @Test func forcedCallStartsConstrainedForTheOtherDialects() async throws {
        if let d = TinyModel.dir {
            let tok = try await GrammarBuilderTests.tokenizer(d)
            let t = (tok: tok, trigger: try #require(tok.convertTokenToId("<tool_call>")), real: true)
            let good = "\n{\"name\": \"weather\", \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>"
            let w = try Self.walk(t, format: .hermesJSON, tools: [Self.weather], body: good, forced: true)
            #expect(w.openedAlone && w.firstMasked && w.allowed && w.completed == 1, "refused after: \(w.refusedAfter ?? "-")")
            let other = "\n{\"name\": \"get_time\", \"arguments\": {}}\n</tool_call>"
            #expect(try Self.walk(t, format: .hermesJSON, tools: [Self.weather], body: other, forced: true).allowed == false)
        }
        for key in ["chat-0.8b", "chat-9b-q4"] {
            guard let d = DevModels.path(key) else { continue }
            let tok = try await GrammarBuilderTests.tokenizer(d)
            let t = (tok: tok, trigger: try #require(tok.convertTokenToId("<tool_call>")), real: true)
            let good = "\n<function=weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"
            let w = try Self.walk(t, format: .qwenXML, tools: [Self.weather], body: good, forced: true)
            #expect(w.openedAlone && w.firstMasked && w.allowed && w.completed == 1, "\(key) refused after: \(w.refusedAfter ?? "-")")
            let other = "\n<function=get_time>\n</function>\n</tool_call>"
            #expect(try Self.walk(t, format: .qwenXML, tools: [Self.weather], body: other, forced: true).allowed == false, "\(key)")
        }
    }

    // MARK: Parsing

    @Test func parsesWhatTheGrammarAdmitsIntoTypedArguments() {
        let q = Gemma4Sample.q
        let tools = [Self.weather, Self.time, Self.search]
        let text = "<|tool_call>call:web_search{queries:[\(q)a, b\(q),\(q)c\(q)],freshness:\(q)week\(q),safe:false,filter:{site:\(q)x.org\(q),max:3}}<tool_call|>"
        let r = Self.parse(text, tools: tools)
        #expect(r.calls.count == 1 && r.rejected.isEmpty && r.visible.isEmpty)
        let a = r.calls.first?.function.arguments ?? [:]
        #expect(r.calls.first?.function.name == "web_search")
        #expect(a["queries"] == .array([.string("a, b"), .string("c")]))
        #expect(a["freshness"] == .string("week") && a["safe"] == .bool(false))
        #expect(a["filter"] == .object(["site": .string("x.org"), "max": .int(3)]))
        // Punctuation of the dialect inside a string stays in the string.
        let awkward = Self.parse("<|tool_call>call:weather{city:\(q)\(Gemma4Sample.awkward)\(q)}<tool_call|>", tools: tools)
        #expect(awkward.calls.first?.function.arguments["city"] == .string(Gemma4Sample.awkward))
        // Typed from the schema; two calls in one step; text around them stays visible, the syntax does not.
        let two = Self.parse("Checking. <|tool_call>call:get_time{n:4,tz:\(q)UTC\(q)}<tool_call|><|tool_call>call:weather{city:\(q)Oslo\(q)}<tool_call|>", tools: tools)
        #expect(two.calls.map(\.function.name) == ["get_time", "weather"])
        #expect(two.calls.first?.function.arguments["n"] == .int(4))
        #expect(two.visible.contains("Checking.") && !two.visible.contains("call:"))
        // Split at every boundary (streaming).
        let one = "<|tool_call>call:weather{city:\(q)New York\(q)}<tool_call|>"
        for k in 1..<one.count {
            let s = Self.parse(one, tools: tools, chunks: [String(one.prefix(k)), String(one.dropFirst(k))])
            #expect(s.calls.count == 1 && s.calls.first?.function.arguments["city"] == .string("New York"), "split \(k)")
            #expect(s.visible.isEmpty, "split \(k): \(s.visible)")
        }
    }

    /// Malformed and partial output without the grammar (a failed compile, the one free token of an unforced call):
    /// nothing runs as a call that is not one, no raw syntax reaches the answer, and a cut-off call keeps its tool
    /// name for the harness's cut-off retry (`usage.rejectedToolName`).
    @Test func malformedAndPartialOutput() {
        let q = Gemma4Sample.q
        let tools = [Self.weather, Self.time]
        let cut = "<|tool_call>call:weather{city:\(q)Par"
        let partial = Self.parse(cut, tools: tools)
        #expect(partial.calls.isEmpty)
        #expect(partial.rejected.count == 1 && partial.rejected.first?.reason == .incompleteOutput)
        for m in ToolFormat.rawMarkers.map(\.open) { #expect(!partial.visible.contains(m)) }
        var mapper = MLXEventMapper()
        #expect(mapper.map(.rejectedToolCall(RejectedToolCall(reason: .incompleteOutput, format: .gemma4, rawText: cut))).isEmpty)
        #expect(mapper.lastRejected?.name == "weather" && mapper.lastRejected?.reason == "incomplete_output")
        #expect(MLXEventMapper.toolName(inPreview: "<|tool_call>call:create_spreadsheet{rows:[[") == "create_spreadsheet")
        #expect(MLXEventMapper.toolName(inPreview: "<|tool_call>call:") == nil)
        #expect(MLXEventMapper.toolName(inPreview: "I would call:weather{ for that") == nil, "prose is not a call")

        // An undeclared tool never becomes a call.
        let unknown = Self.parse("<|tool_call>call:nuke{target:\(q)x\(q)}<tool_call|>", tools: tools)
        #expect(unknown.calls.isEmpty)
        for m in ToolFormat.rawMarkers.map(\.open) { #expect(!unknown.visible.contains(m)) }
        // No name, no braces.
        for bad in ["<|tool_call>call:{}<tool_call|>", "<|tool_call>weather city Paris<tool_call|>", "<|tool_call><tool_call|>"] {
            let r = Self.parse(bad, tools: tools)
            #expect(r.calls.isEmpty, "\(bad)")
            for m in ToolFormat.rawMarkers.map(\.open) { #expect(!r.visible.contains(m), "\(bad) → \(r.visible)") }
        }
        // Leniencies the parser repairs: a bare value for a string parameter, an escaped key.
        let bare = Self.parse("<|tool_call>call:weather{city:Paris}<tool_call|>", tools: tools)
        #expect(bare.calls.first?.function.arguments["city"] == .string("Paris"))
        let keyed = Self.parse("<|tool_call>call:weather{\(q)city\(q):\(q)Paris\(q)}<tool_call|>", tools: tools)
        #expect(keyed.calls.first?.function.arguments["city"] == .string("Paris"))
    }

    // MARK: Table: the forty-tool fixture

    @Test func everyFixtureToolBuildsWalksAndParses() async throws {
        let url = ScriptFixtures.repoRoot.appendingPathComponent("fixtures/tools/forty-tools.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let tools = try rows.map { r in
            ToolSchema(name: try #require(r["name"] as? String), description: r["description"] as? String ?? "",
                       parametersJSON: String(decoding: try JSONSerialization.data(withJSONObject: r["parameters"] ?? [:], options: [.sortedKeys]), as: UTF8.self))
        }
        #expect(tools.count == 40)
        #expect(GrammarBuilder.structuralTag(format: .gemma4, tools: tools) != nil, "all forty in one tag")
        let t = try await Self.tokenizer()
        for tool in tools {
            #expect(GrammarBuilder.structuralTag(format: .gemma4, tools: [tool]) != nil, "\(tool.name)")
            let (body, keys) = Gemma4Sample.call(tool)
            let r = Self.parse("<|tool_call>" + body, tools: tools)
            #expect(r.calls.map(\.function.name) == [tool.name], "\(tool.name): \(body)")
            #expect(r.calls.first?.function.arguments.keys.sorted() == keys, "\(tool.name): \(body)")
            guard let t else { continue }
            // Offered alone (a forced call's scope) and forced.
            let w = try Self.walk(t, tools: [tool], body: body, forced: true)
            #expect(w.openedAlone && w.firstMasked && w.allowed && w.completed == 1, "\(tool.name) refused after: \(w.refusedAfter ?? "-")")
        }
        guard let t else { return }
        // Offered together (tool_choice auto): every one of the forty walks under the one combined grammar (compiled
        // once per tool set, as ToolGrammarCache does for a chat).
        let cache = ToolGrammarCache()
        let tag = try #require(GrammarBuilder.structuralTag(format: .gemma4, tools: tools))
        let clock = ContinuousClock.now
        #expect(cache.prepare(modelKey: "t", tokenizer: t.tok, tag: tag), "\(cache.lastError ?? "")")
        print("gemma4 grammar: forty tools compiled in \(ContinuousClock.now - clock) (real tokenizer: \(t.real))")
        for tool in tools {
            let w = try Self.walk(t, tools: tools, body: Gemma4Sample.call(tool).body, cache: cache)
            #expect(w.allowed && w.completed == 1, "\(tool.name) among forty, refused after: \(w.refusedAfter ?? "-")")
        }
    }

    // MARK: The model's own template (needs the real tokenizer files)

    /// Tool definitions, a past call and its result are rendered by the model's own chat template (swift-jinja through
    /// the tokenizer, as MLXAdapter does): the declarations the model was trained on, and a call in the exact layout
    /// the grammar admits.
    @Test(.enabled(if: Gemma4Files.dir != nil)) func theModelsTemplateRendersToolsAndCallsInTheGrammarsLayout() async throws {
        let t = try #require(try await Self.tokenizer())
        let q = Gemma4Sample.q
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "Be brief."],
            ["role": "user", "content": "Weather in Paris?"],
            ["role": "assistant", "content": "", "tool_calls": [[
                "id": "call_1", "type": "function",
                "function": ["name": "weather", "arguments": ["city": "Paris"] as [String: any Sendable]] as [String: any Sendable],
            ] as [String: any Sendable]]],
            ["role": "tool", "tool_call_id": "call_1", "name": "weather", "content": "sunny"],
        ]
        let ids = try t.tok.applyChatTemplate(messages: messages, tools: MLXAdapter.toolSpecs([Self.weather, Self.time]),
                                              additionalContext: ["enable_thinking": false])
        let text = t.tok.decode(tokenIds: ids, skipSpecialTokens: false)
        #expect(text.contains("<|tool>declaration:weather{description:\(q)Weather\(q),parameters:{properties:{city:{type:\(q)STRING\(q)}},required:[\(q)city\(q)],type:\(q)OBJECT\(q)}}<tool|>"), "\(text)")
        #expect(text.contains("<|tool>declaration:get_time{"))
        let call = "call:weather{city:\(q)Paris\(q)}"
        #expect(text.contains("<|tool_call>\(call)<tool_call|><|tool_response>response:weather{value:\(q)sunny\(q)}<tool_response|>"), "\(text)")
        // The rendered call is one the grammar admits, token for token, and the special tokens are single tokens.
        let w = try Self.walk(t, tools: [Self.weather, Self.time], body: call + "<tool_call|>")
        #expect(w.allowed && w.completed == 1)
        for s in ["<|tool_call>", "<tool_call|>", q, "<|channel>", "<channel|>", "<turn|>"] {
            #expect(t.tok.encode(text: s, addSpecialTokens: false).count == 1, "\(s)")
        }
        // A first turn with tools and reasoning off ends in the model turn with the empty thought channel.
        let first = try t.tok.applyChatTemplate(messages: Array(messages.prefix(2)), tools: MLXAdapter.toolSpecs([Self.weather]),
                                                additionalContext: ["enable_thinking": false])
        #expect(t.tok.decode(tokenIds: first, skipSpecialTokens: false).hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"))
    }
}
