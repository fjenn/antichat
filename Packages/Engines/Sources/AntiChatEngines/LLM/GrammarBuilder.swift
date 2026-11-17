// GrammarBuilder (M1.T13 step 2; P-shell-09): JSON Schema → grammar constraint for the TOOL-CALL SPAN ONLY.
//   - MLX: an xgrammar structural tag (MLXGuidedGeneration / MLXCXGrammar at mlx-swift-lm f5b0677, xgrammar
//     v0.1.30 `structural_tag.cc`): one `tag` per offered tool — Qwen3.5/3.6: an EBNF parameter list in any order
//     with typed values (`qwenXMLParameters`); Hermes JSON: the tool's `json_schema`; Gemma 4: an EBNF argument
//     list in any order with typed values (`gemma4Arguments`). `LazyToolGrammarProcessor`
//     activates it only after the model itself sampled the dialect's opening token (`<tool_call>`) and drops it
//     when the call's closing `</function>\n` / `}\n` / `}` is reached, so answer text and reasoning are never touched
//     (R-241: no logit edits in answer generation; the "lazy grammar" fallback of M1.T13 is the default).
//   - llama-server: no grammar from us. With `--jinja` and `tools`, llama.cpp builds its own lazy tool grammar
//     triggered by the template's call marker (`Binaries/llama.cpp@620d222:common/chat-auto-parser-generator.cpp:
//     65-90`, `grammar_lazy` for tool_choice auto); a `grammar` field would constrain the whole answer instead.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import Synchronization

public enum GrammarBuilder {
    /// Tool name → its parameters schema with BFCL/OpenAI dialect quirks normalised (`dict` → `object`,
    /// `float` → `number`, `tuple` → `array`, `any` → no constraint) so xgrammar accepts every schema we offer.
    public static func normalizedSchema(_ parametersJSON: String) -> [String: Any] {
        let obj = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) as? [String: Any] ?? [:]
        var out = normalize(obj) as? [String: Any] ?? [:]
        if out["type"] == nil { out["type"] = "object" }
        if out["properties"] == nil { out["properties"] = [String: Any]() }
        return out
    }

    static func normalize(_ v: Any) -> Any {
        if var d = v as? [String: Any] {
            if let t = d["type"] as? String {
                switch t {
                case "dict": d["type"] = "object"
                case "float", "double": d["type"] = "number"
                case "tuple", "list": d["type"] = "array"
                case "int", "long": d["type"] = "integer"
                case "bool": d["type"] = "boolean"
                case "str", "char": d["type"] = "string"
                case "any", "Any": d["type"] = nil
                default: break
                }
            }
            // Keys xgrammar's converter does not need (descriptions, defaults, examples) are kept; only the
            // value-level fields are walked.
            for k in ["properties", "patternProperties", "$defs", "definitions"] {
                if let p = d[k] as? [String: Any] { d[k] = p.mapValues(normalize) }
            }
            for k in ["items", "additionalProperties", "not"] {
                if let p = d[k], !(p is Bool) { d[k] = normalize(p) }
            }
            for k in ["anyOf", "oneOf", "allOf", "prefixItems"] {
                if let a = d[k] as? [Any] { d[k] = a.map(normalize) }
            }
            if d["required"] != nil, let props = d["properties"] as? [String: Any], let req = d["required"] as? [String] {
                d["required"] = req.filter { props[$0] != nil }  // BFCL lists a few required keys it never declares
            }
            return d
        }
        return v
    }

    /// EBNF for a Qwen XML parameter list in ANY order (xgrammar's `qwen_xml_parameter` fixes the order to the
    /// schema's — sorted keys here — while Qwen writes parameters in its own order; a forced early `</function>`
    /// made the model emit a second, broken closing and the parser rejected the call). Each parameter: a declared
    /// name and a value of its type (string enum → one of the raw values; integer / number / boolean → their
    /// literals; other strings, arrays, objects → raw text up to `</parameter>`). Not enforced by the grammar:
    /// presence of `required` parameters and duplicates (the parser and the schema check still see them).
    static func qwenXMLParameters(_ schema: [String: Any]) -> String {
        let props = (schema["properties"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
        var rules = [
            "root ::= (ws param (ws param)*)?",
            #"ws ::= [ \n\t]*"#,
            #"text ::= TagDispatch(stop_eos=true, stop_str=(), loop_after_dispatch=false, excludes=("</parameter>"))"#,
            #"int ::= "-"? [0-9]+"#,
            #"num ::= "-"? [0-9]+ ("." [0-9]+)? ([eE] [-+]? [0-9]+)?"#,
            #"bool ::= "true" | "false""#,
        ]
        guard !props.isEmpty else { return "root ::= ws\nws ::= [ \\n\\t]*" }
        var alts: [String] = []
        for (i, (name, raw)) in props.enumerated() {
            let ps = raw as? [String: Any] ?? [:]
            let value: String
            let strings = (ps["enum"] as? [Any])?.compactMap { $0 as? String }
            if let e = strings, !e.isEmpty, e.count == (ps["enum"] as? [Any])?.count {
                value = "(" + e.map(ebnfLiteral).joined(separator: " | ") + ")"
            } else if let c = ps["const"] as? String {
                value = ebnfLiteral(c)
            } else {
                switch ps["type"] as? String {
                case "integer": value = "int"
                case "number": value = "num"
                case "boolean": value = "bool"
                default: value = "text"
                }
            }
            rules.append("p\(i) ::= \(ebnfLiteral("<parameter=\(name)>")) ws \(value) ws \(ebnfLiteral("</parameter>"))")
            alts.append("p\(i)")
        }
        rules.append("param ::= " + alts.joined(separator: " | "))
        return rules.joined(separator: "\n")
    }

    /// EBNF for the argument list of a Gemma 4 call, i.e. what stands between `call:NAME{` and the closing `}`, in the
    /// layout the model's own template renders (mlx-community/gemma-4-26b-a4b-it-4bit@0d77464 `chat_template.jinja`,
    /// `format_argument(…, escape_keys=False)`): `key:value` pairs joined by `,` with no whitespace; a string is wrapped
    /// in the escape token `<|"|>`, numbers / booleans / null are bare, an object is `{key:value,…}` with unquoted keys,
    /// an array `[value,…]`. Top-level parameters: declared names only, in any order, each with a value of its type
    /// (string enum → one of its values; nested objects and arrays follow their `properties` / `items`; an untyped
    /// value is any of the above). As for Qwen, the grammar does not enforce `required` or forbid duplicates (the
    /// parser and the schema check still see them).
    static func gemma4Arguments(_ schema: [String: Any]) -> String {
        var b = Gemma4Rules()
        let fields = b.fields(schema, depth: 0)
        return (["root ::= " + fields] + b.rules + Gemma4Rules.shared).joined(separator: "\n")
    }

    struct Gemma4Rules {
        /// The escape token, and the call / turn end tokens no string value may contain (a string that ran into one
        /// would end the call or the generation mid-argument).
        static let quote = "<|\"|>"
        static let shared = [
            "q ::= " + ebnfLiteral(quote),
            "text ::= TagDispatch(stop_eos=true, stop_str=(), loop_after_dispatch=false, excludes=("
                + [quote, "<tool_call|>", "<turn|>"].map(ebnfLiteral).joined(separator: ", ") + "))",
            "str ::= q text q",
            #"int ::= "-"? [0-9]+"#,
            #"num ::= "-"? [0-9]+ ("." [0-9]+)? ([eE] [-+]? [0-9]+)?"#,
            #"bool ::= "true" | "false""#,
            #"key ::= [a-zA-Z0-9_.\-]+ | str"#,
            #"any ::= str | num | bool | "null" | arr | obj"#,
            #"arr ::= "[" (any ("," any)*)? "]""#,
            #"obj ::= "{" (key ":" any ("," key ":" any)*)? "}""#,
        ]
        var rules: [String] = []

        private mutating func rule(_ prefix: String, _ body: String) -> String {
            let name = "\(prefix)\(rules.count)"
            rules.append("\(name) ::= \(body)")
            return name
        }

        /// `key:value` pairs of an object schema (without the braces): its declared properties; any pairs when it
        /// declares none but allows additional ones; nothing otherwise.
        mutating func fields(_ schema: [String: Any], depth: Int) -> String {
            let props = (schema["properties"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            if props.isEmpty {
                let extra = schema["additionalProperties"]
                let open = extra is [String: Any] || (extra as? Bool) == true
                return open ? #"(key ":" any ("," key ":" any)*)?"# : "\"\""
            }
            let alts = props.map { name, raw in
                rule("p", "\(ebnfLiteral(name + ":")) \(value(raw as? [String: Any] ?? [:], depth: depth + 1))")
            }
            let field = rule("f", alts.joined(separator: " | "))
            return "(\(field) (\",\" \(field))*)?"
        }

        /// The expression for one value of `schema`.
        mutating func value(_ schema: [String: Any], depth: Int) -> String {
            guard depth < 8, schema["$ref"] == nil else { return "any" }
            if let e = schema["enum"] as? [Any], !e.isEmpty {
                return "(" + e.map(literal).joined(separator: " | ") + ")"
            }
            if let c = schema["const"] { return literal(c) }
            for k in ["anyOf", "oneOf"] {
                if let a = schema[k] as? [[String: Any]], !a.isEmpty {
                    return "(" + a.map { value($0, depth: depth + 1) }.joined(separator: " | ") + ")"
                }
            }
            let types = (schema["type"] as? String).map { [$0] } ?? schema["type"] as? [String] ?? []
            guard !types.isEmpty else { return "any" }
            let alts = types.map { t -> String in
                switch t {
                case "string": return "str"
                case "integer": return "int"
                case "number": return "num"
                case "boolean": return "bool"
                case "null": return "\"null\""
                case "array":
                    guard let items = schema["items"] as? [String: Any] else { return "arr" }
                    let item = value(items, depth: depth + 1)
                    return rule("a", "\"[\" (\(item) (\",\" \(item))*)? \"]\"")
                case "object":
                    guard !(schema["properties"] as? [String: Any] ?? [:]).isEmpty else { return "obj" }
                    return rule("o", "\"{\" \(fields(schema, depth: depth + 1)) \"}\"")
                default: return "any"
                }
            }
            return alts.count == 1 ? alts[0] : "(" + alts.joined(separator: " | ") + ")"
        }

        /// An enum / const member as the template writes it: a string in the escape token, anything else bare.
        func literal(_ v: Any) -> String {
            if let s = v as? String { return "q \(ebnfLiteral(s)) q" }
            if v is NSNull { return "\"null\"" }
            if let n = v as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return ebnfLiteral(n.boolValue ? "true" : "false") }
                return ebnfLiteral("\(n)")
            }
            return "any"
        }
    }

    static func ebnfLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// The structural tag for the body of ONE call, i.e. what follows the opening token. nil when the dialect is
    /// not constrainable (A-M1-T13a) or no tool is offered.
    public static func structuralTag(format: ToolFormat, tools: [ToolSchema]) -> String? {
        guard format.grammarConstrainable, !tools.isEmpty else { return nil }
        let tags: [[String: Any]] = tools.map { t in
            let schema = normalizedSchema(t.parametersJSON)
            switch format {
            case .qwenXML:
                return [
                    // The template's newlines sit in begin/end: `<function=N>` ws params `\n</function>\n`.
                    "type": "tag", "begin": "\n<function=\(t.name)>",
                    "content": ["type": "grammar", "grammar": qwenXMLParameters(schema)], "end": "\n</function>\n",
                ]
            case .gemma4:
                // `<|tool_call>` is followed at once by `call:NAME{`; the closing `<tool_call|>` is the model's own.
                return [
                    "type": "tag", "begin": "call:\(t.name){",
                    "content": ["type": "grammar", "grammar": gemma4Arguments(schema)], "end": "}",
                ]
            default:  // hermesJSON
                return [
                    "type": "tag", "begin": "\n{\"name\": \"\(t.name)\", \"arguments\": ",
                    "content": ["type": "json_schema", "json_schema": schema], "end": "}\n",
                ]
            }
        }
        let format: [String: Any] = tags.count == 1 ? tags[0] : ["type": "or", "elements": tags]
        let root: [String: Any] = ["type": "structural_tag", "format": format]
        guard let d = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Counters of one generation (read after the stream ended; written on the generation thread).
public final class ToolGrammarStats: Sendable {
    struct Counts { var activations = 0, completed = 0, failed = 0 }
    private let c = Mutex(Counts())
    public init() {}
    func update(_ f: (inout Counts) -> Void) { c.withLock { f(&$0) } }
    /// Calls whose span opened the constraint.
    public var activations: Int { c.withLock { $0.activations } }
    /// Calls whose span ran to the grammar's end under the constraint.
    public var completed: Int { c.withLock { $0.completed } }
    /// Activations dropped because the token right after the opening tag left the grammar (unconstrained).
    public var failed: Int { c.withLock { $0.failed } }
}

/// Per-model grammar state: the xgrammar tokenizer (vocab extraction once per load) and compiled tags per tool set.
public final class ToolGrammarCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tokenizer: GrammarTokenizer?
    private var tokenizerKey: String?
    /// Idle matchers per tag, each at its start state. xgrammar v0.1.30 has no matcher fork (`clone()` throws
    /// forkFailed), so a matcher is reset with `rollback(n)` after a span and returned here for reuse.
    private var idle: [String: [GrammarConstraint]] = [:]
    /// The last compile error (diagnostics for tests and logs).
    public private(set) var lastError: String?

    public init() {}

    /// Makes sure the tokenizer info for `modelKey` exists and one matcher for `tag` is compiled (done before the
    /// generation starts, so the first trigger does not stall the token loop). False when compilation fails.
    @discardableResult
    func prepare(modelKey: String, tokenizer host: any MLXLMCommon.Tokenizer, tag: String) -> Bool {
        guard let c = checkout(modelKey: modelKey, tokenizer: host, tag: tag) else { return false }
        checkin(c, tag: tag)
        return true
    }

    /// A matcher for `tag` at its start state (from the pool, else freshly compiled); nil when compilation fails.
    func checkout(modelKey: String, tokenizer host: any MLXLMCommon.Tokenizer, tag: String) -> GrammarConstraint? {
        lock.lock()
        defer { lock.unlock() }
        if tokenizerKey != modelKey {
            tokenizer = nil
            idle = [:]
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: host)
            tokenizer = try? GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(host.eosTokenId ?? 0))
            tokenizerKey = modelKey
        }
        guard let tok = tokenizer else { return nil }
        if let c = idle[tag]?.popLast() { return c }
        do {
            return try GrammarConstraint(tokenizer: tok, structuralTag: tag)
        } catch {
            AppLog.log(.engine, .error, "tool grammar compile failed: \(error)")
            lastError = "\(error)"
            return nil
        }
    }

    /// Returns a matcher that is back at its start state.
    func checkin(_ c: GrammarConstraint, tag: String) {
        lock.lock()
        defer { lock.unlock() }
        if idle[tag] == nil, idle.count >= 32 { idle.removeAll() }  // bound: tool sets change rarely within a chat
        idle[tag, default: []].append(c)
    }
}

/// Lazy tool-call grammar as a `LogitProcessor` (`GenerationComponents.logitProcessorFactory`).
/// Inactive it never edits logits and never waits on the GPU: it scans tokens two steps behind the sampler (those
/// are already evaluated). When it sees the opening token outside reasoning, it commits the one token sampled
/// since (the only unconstrained token of the span: "\n" for Qwen / Hermes, `call` for Gemma 4), then masks every
/// step until the grammar's end string is accepted, and goes inactive again (parallel calls re-trigger).
final class LazyToolGrammarProcessor: LogitProcessor {
    let triggerID: Int
    let thinkOpenID: Int?
    let thinkCloseID: Int?
    let eosID: Int
    /// nil: no grammar for this model's dialect — a forced request still opens the call (the body is unconstrained).
    let make: (() -> GrammarConstraint?)?
    let release: (GrammarConstraint) -> Void
    let stats: ToolGrammarStats
    private var inThink: Bool
    private var history: [MLXArray] = []
    private var scanned = 0
    private var active: GrammarConstraint?
    /// Tokens the active matcher accepted (rolled back when the span ends, so the matcher can be reused).
    private var committed: Int32 = 0
    /// The mask (words, stop token cleared) computed right after the last commit; nil = compute anew.
    private var nextMask: [Int32]?
    private let bitmask = BitmaskExpander()
    /// M2.T22: a forced `tool_choice` (chip / fallback re-ask): the first token outside reasoning is the opening tag
    /// (the only logit edit outside a call span, and only on a request that asked for a call).
    let forced: Bool
    private var forcedDone = false
    /// The history index the forced opening tag lands at (set when its mask is handed out).
    private var forcedAt: Int?

    init(
        triggerID: Int, thinkOpenID: Int?, thinkCloseID: Int?, eosID: Int, startsInThink: Bool, stats: ToolGrammarStats,
        forced: Bool = false,
        make: (() -> GrammarConstraint?)?, release: @escaping (GrammarConstraint) -> Void = { _ in }
    ) {
        self.forced = forced
        self.triggerID = triggerID
        self.thinkOpenID = thinkOpenID
        self.thinkCloseID = thinkCloseID
        self.eosID = eosID
        self.inThink = startsInThink
        self.stats = stats
        self.make = make
        self.release = release
    }

    deinit {
        if active != nil { end() }  // generation stopped mid-span (cancel / max tokens)
    }

    /// Ends the span: rolls the matcher back to its start state and returns it to the pool.
    private func end() {
        guard let c = active else { return }
        active = nil
        nextMask = nil
        if (try? c.rollback(committed)) != nil { release(c) }
        committed = 0
    }

    func copy() -> LazyToolGrammarProcessor {
        LazyToolGrammarProcessor(
            triggerID: triggerID, thinkOpenID: thinkOpenID, thinkCloseID: thinkCloseID, eosID: eosID, startsInThink: inThink,
            stats: stats, forced: forced, make: make, release: release)
    }

    func prompt(_ prompt: MLXArray) {}

    func didSample(token: MLXArray) {
        history.append(token)
    }

    func process(logits: MLXArray) -> MLXArray {
        if let at = forcedAt {
            // The forced opening tag was just sampled (nothing else was admitted): its body is constrained from its
            // first token on, so a forced call cannot start as another tool's (no unconstrained token after the tag).
            forcedAt = nil
            if active == nil, history.count == at + 1 {
                scanned = history.count
                activate()
            }
        }
        if active == nil {
            // Tokens up to count-2 are evaluated: the sampler only has the newest one in flight.
            while scanned + 1 < history.count {
                let t = history[scanned].item(Int.self)
                scanned += 1
                if t == thinkOpenID { inThink = true }
                if t == thinkCloseID { inThink = false }
                if t == triggerID, !inThink { activate() }
                if active != nil { break }
            }
        } else if scanned < history.count {
            commit(history[scanned].item(Int.self))
            scanned += 1
        }
        if scanned > 256 {  // release scanned token arrays
            history.removeFirst(scanned)
            scanned = 0
        }
        if forced, !forcedDone, active == nil, !inThink {
            // The in-flight token (one GPU sync, once per forced request): the model may have opened the call (or a
            // reasoning block) itself.
            let inFlight = scanned < history.count ? history[history.count - 1].item(Int.self) : nil
            if inFlight == triggerID {
                forcedDone = true
            } else if inFlight != thinkOpenID || thinkOpenID == nil {
                forcedDone = true
                forcedAt = history.count
                var words = [Int32](repeating: 0, count: (logits.dim(-1) + 31) / 32)
                words[triggerID / 32] = Int32(bitPattern: UInt32(1) << UInt32(triggerID % 32))
                return logits + bitmask.array(words, logitDim: logits.dim(-1))
            }
        }
        guard let c = active else { return logits }
        // The mask computed right after the last commit (matcher state unchanged since), else a fresh one.
        var words: [Int32]
        if let m = nextMask {
            words = m
        } else {
            guard let m = try? c.computeMask() else { return logits }
            words = m.mask
            Self.clear(&words, eosID)
        }
        nextMask = nil
        if words.isEmpty { return logits }
        return logits + bitmask.array(words, logitDim: logits.dim(-1))
    }

    private func activate() {
        guard let make else { return }  // no grammar: the call (opened, perhaps forced) runs unconstrained
        stats.update { $0.activations += 1 }
        guard let c = make() else {
            stats.update { $0.failed += 1 }
            return
        }
        active = c
        committed = 0
        // The token sampled after the trigger (still in flight): commit it now, before masking the next one.
        if scanned < history.count {
            commit(history[scanned].item(Int.self))
            scanned += 1
        }
    }

    private func commit(_ token: Int) {
        guard let c = active else { return }
        do {
            _ = try c.commitToken(Int32(token))
            committed += 1
        } catch {
            end()
            stats.update { $0.failed += 1 }
            return
        }
        // The grammar has nothing after the call's end string: the span is complete when the stop token is the ONLY
        // token left. (xgrammar's TagDispatch text rule also admits the stop token inside a value; there it is
        // masked out below, so a call can never end mid-argument.)
        guard let m = try? c.computeMask() else { return }
        if Self.allows(m.mask, eosID), Self.popcount(m.mask) == 1 {
            end()
            stats.update { $0.completed += 1 }
        } else {
            var words = m.mask
            Self.clear(&words, eosID)
            nextMask = words
        }
    }

    static func popcount(_ mask: [Int32]) -> Int {
        mask.reduce(0) { $0 + UInt32(bitPattern: $1).nonzeroBitCount }
    }

    static func clear(_ mask: inout [Int32], _ id: Int) {
        let w = id / 32
        guard w >= 0, w < mask.count else { return }
        mask[w] = Int32(bitPattern: UInt32(bitPattern: mask[w]) & ~(UInt32(1) << UInt32(id % 32)))
    }

    static func allows(_ mask: [Int32], _ id: Int) -> Bool {
        let w = id / 32
        guard w >= 0, w < mask.count else { return false }
        return (UInt32(bitPattern: mask[w]) >> UInt32(id % 32)) & 1 == 1
    }

    static func maskArray(_ mask: [Int32], logitDim: Int) -> MLXArray {
        BitmaskExpander().array(mask, logitDim: logitDim)
    }
}

/// xgrammar's packed bitmask (LSB first, 32 tokens per word) → additive logit mask (0 allowed, -inf not), expanded on
/// the GPU so a 248K vocabulary costs one small upload per step instead of a CPU loop over every token.
final class BitmaskExpander {
    private var dim = -1
    private var wordIndex: MLXArray?
    private var bitShift: MLXArray?

    func array(_ mask: [Int32], logitDim: Int) -> MLXArray {
        if dim != logitDim {
            let idx = MLXArray(Int32(0)..<Int32(logitDim))
            wordIndex = MLX.floorDivide(idx, MLXArray(Int32(32)))
            bitShift = MLX.remainder(idx, MLXArray(Int32(32)))
            dim = logitDim
        }
        // Positions past the mask (logit dim > tokenizer vocab) read word index clamped to the last word and are
        // then forced off.
        let words = MLXArray(mask)
        let wi = MLX.minimum(wordIndex!, Int32(max(0, mask.count - 1)))
        let bits = (MLX.take(words, wi) >> bitShift!) & 1
        let inRange = wordIndex! .< Int32(mask.count)
        return MLX.which((bits .== 1) .&& inRange, MLXArray(Float(0)), MLXArray(-Float.infinity))
    }
}
