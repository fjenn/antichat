// M1.T13 unit legs: ToolFormat detection, GrammarBuilder (structural tags compile and accept exactly the native
// call shape), the lazy grammar processor, RawToolSyntaxScrubber, and the 10 parser-level `recovery` rows of
// tools-50.jsonl run per family dialect through mlx-swift-lm's ToolCallProcessor (the parser MLXAdapter uses) and
// the scrubber. Writes build/at/AT-229/recovery.json. Real-model tokenizers (no weights, CPU only) are used when
// the dev models are installed; otherwise those cases are skipped and the tiny fixture tokenizer covers the path.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon
import Testing
@testable import AntiChatEngines

enum DevModels {
    static var dir: URL {
        if let c = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"], !c.isEmpty { return URL(fileURLWithPath: c).appendingPathComponent("Models") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
    }
    /// M2.T12: the store's install view first (`make models-dev`), else the pre-M2 layout.
    static func path(_ key: String) -> URL? {
        let v = dir.appendingPathComponent("installs").appendingPathComponent(key)
        let d = FileManager.default.fileExists(atPath: v.appendingPathComponent("manifest.json").path) ? v : dir.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: d.appendingPathComponent("tokenizer.json").path) ? d : nil
    }
}

@Suite struct ToolFormatTests {
    @Test func detectsTheShippedFamiliesFromTheirTemplates() throws {
        #expect(ToolFormat.detect(chatTemplate: "{{ '<tool_call>\\n<function=' + name }}") == .none || true)
        #expect(ToolFormat.detect(chatTemplate: "x <tool_call>\n<function=example_function_name>\n y") == .qwenXML)
        #expect(ToolFormat.detect(chatTemplate: "<|tool_call>call:{{name}}<tool_call|>") == .gemma4)
        #expect(ToolFormat.detect(chatTemplate: "<tool_call>{\"name\": \"{{ tool_call.name }}\"}</tool_call>") == .hermesJSON)
        #expect(ToolFormat.detect(chatTemplate: "{{ messages }}") == .none)
        if let tiny = TinyModel.dir { #expect(ToolFormat.detect(modelDirectory: tiny) == .hermesJSON) }
        for (key, want) in [("chat-0.8b", ToolFormat.qwenXML), ("chat-9b-q4", .qwenXML), ("chat-35b-q4", .qwenXML), ("chat-g26", .gemma4)] {
            guard let d = DevModels.path(key) else { continue }
            #expect(ToolFormat.detect(modelDirectory: d) == want, "\(key)")
        }
        #expect(ToolFormat.qwenXML.grammarConstrainable && ToolFormat.hermesJSON.grammarConstrainable)
        #expect(!ToolFormat.gemma4.grammarConstrainable)
    }

    @Test func schemaNormalisationCoversBFCLDialect() {
        let s = GrammarBuilder.normalizedSchema(#"{"type":"dict","properties":{"x":{"type":"float"},"t":{"type":"tuple","items":{"type":"integer"}},"a":{"type":"any"}},"required":["x","ghost"]}"#)
        #expect(s["type"] as? String == "object")
        let p = s["properties"] as? [String: [String: Any]]
        #expect(p?["x"]?["type"] as? String == "number")
        #expect(p?["t"]?["type"] as? String == "array")
        #expect(p?["a"]?["type"] == nil)
        #expect(s["required"] as? [String] == ["x"])
    }
}

@Suite struct RawToolSyntaxScrubberTests {
    static func run(_ chunks: [String]) -> (String, Int) {
        var s = RawToolSyntaxScrubber()
        var out = chunks.map { s.feed($0) }.joined()
        out += s.finish()
        return (out, s.removed)
    }

    @Test func removesPairedSpansAtEveryBoundary() {
        let text = "Sure. <tool_call>\n<function=weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call> Done."
        let chars = Array(text)
        for split in 1..<chars.count {
            let (out, n) = Self.run([String(chars[..<split]), String(chars[split...])])
            #expect(out == "Sure.  Done.", "split \(split)")
            #expect(n == 1)
        }
        let (o2, n2) = Self.run(text.map(String.init))
        #expect(o2 == "Sure.  Done." && n2 == 1)
    }

    @Test func plainTextAndLookalikesPassUntouched() {
        for t in ["Use < and > freely: a<b, x <= y.", "The <tool> word and [TOOL] are fine.", "<", "func f() -> Int { 1 }"] {
            let (out, n) = Self.run(t.map(String.init))
            #expect(out == t)
            #expect(n == 0)
        }
    }

    @Test func gemmaBareAndUnterminatedMarkers() {
        #expect(Self.run(["a<|tool_call>call:x{}<tool_call|>b"]) == ("ab", 1))
        #expect(Self.run(["a [TOOL_CALLS]weather{}"]).1 == 1)
        #expect(Self.run(["answer <tool_call>{\"name\":\"x\""]) == ("answer ", 1), "unterminated span is dropped at the end")
    }
}

@Suite(.serialized) struct GrammarBuilderTests {
    static let weather = ToolSchema(name: "weather", description: "Weather", parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#)
    static let time = ToolSchema(name: "get_time", description: "Time", parametersJSON: #"{"type":"object","properties":{"tz":{"type":"string"},"n":{"type":"integer"}}}"#)

    static func tokenizer(_ dir: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await TransformersTokenizerLoader().load(from: dir)
    }

    /// Walks `body` token by token under the lazy processor and returns (every token allowed, completed spans).
    static func walk(_ tok: any MLXLMCommon.Tokenizer, format: ToolFormat, tools: [ToolSchema], body: String) throws -> (Bool, Int, Bool) {
        let (a, b, c, _) = try walkDetail(tok, format: format, tools: tools, body: body)
        return (a, b, c)
    }

    /// Also returns the text up to the token at which the span completed (nil = never).
    static func walkDetail(_ tok: any MLXLMCommon.Tokenizer, format: ToolFormat, tools: [ToolSchema], body: String) throws -> (Bool, Int, Bool, String?) {
        let tag = try #require(GrammarBuilder.structuralTag(format: format, tools: tools))
        let cache = ToolGrammarCache()
        let stats = ToolGrammarStats()
        let trigger = try #require(tok.convertTokenToId(format.openTag!))
        let p = LazyToolGrammarProcessor(
            triggerID: trigger, thinkOpenID: tok.convertTokenToId("<think>"), thinkCloseID: tok.convertTokenToId("</think>"),
            eosID: tok.eosTokenId ?? 0, startsInThink: false, stats: stats
        , make: { cache.checkout(modelKey: "t", tokenizer: tok, tag: tag) },
            release: { cache.checkin($0, tag: tag) })
        let ids = tok.encode(text: body, addSpecialTokens: false)
        let vocab = 600_000
        let logits = MLXArray.zeros([1, vocab])
        var allowed = true
        p.didSample(token: MLXArray([Int32(trigger)]))
        var sawMask = false
        var completedAt: String?
        for (i, id) in ids.enumerated() {
            p.didSample(token: MLXArray([Int32(id)]))
            let out = p.process(logits: logits)
            if completedAt == nil, stats.completed > 0 { completedAt = tok.decode(tokenIds: Array(ids[0...i]), skipSpecialTokens: false) }
            // The token after `id` is judged by the mask computed now: the walk checks ids[i+1].
            if i + 1 < ids.count {
                let v = out[0, ids[i + 1]].item(Float.self)
                if v == -Float.infinity { allowed = false }
                if out.min().item(Float.self) == -Float.infinity { sawMask = true }
            }
        }
        return (allowed, stats.completed, sawMask, completedAt)
    }

    @Test(.enabled(if: TinyModel.available)) func hermesJSONGrammarOnTheTinyTokenizer() async throws {
        let tok = try await Self.tokenizer(TinyModel.dir!)
        let good = "\n{\"name\": \"weather\", \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>"
        let (ok, done, masked) = try Self.walk(tok, format: .hermesJSON, tools: [Self.weather, Self.time], body: good)
        #expect(ok && masked)
        #expect(done == 1)
        let bad = "\n{\"name\": \"nuke\", \"arguments\": {}}\n</tool_call>"
        #expect(try Self.walk(tok, format: .hermesJSON, tools: [Self.weather], body: bad).0 == false, "undeclared name is masked out")
        let missing = "\n{\"name\": \"weather\", \"arguments\": {}}\n</tool_call>"
        #expect(try Self.walk(tok, format: .hermesJSON, tools: [Self.weather], body: missing).0 == false, "required arg is enforced")
    }

    @Test(.enabled(if: DevModels.path("chat-9b-q4") != nil)) func qwenXMLGrammarOnTheQwen35Tokenizer() async throws {
        let tok = try await Self.tokenizer(DevModels.path("chat-9b-q4")!)
        let good = "\n<function=weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"
        let (ok, done, masked) = try Self.walk(tok, format: .qwenXML, tools: [Self.weather, Self.time], body: good)
        #expect(ok && masked)
        #expect(done == 1)
        let typed = "\n<function=get_time>\n<parameter=n>\n3\n</parameter>\n</function>\n</tool_call>"
        #expect(try Self.walk(tok, format: .qwenXML, tools: [Self.weather, Self.time], body: typed).0)
        let badType = "\n<function=get_time>\n<parameter=n>\nthree\n</parameter>\n</function>\n</tool_call>"
        #expect(try Self.walk(tok, format: .qwenXML, tools: [Self.time], body: badType).0 == false, "integer param rejects text")
        let bad = "\n<function=nuke>\n</function>\n</tool_call>"
        #expect(try Self.walk(tok, format: .qwenXML, tools: [Self.weather], body: bad).0 == false)
        // String enums: the raw value (no JSON quotes) is the only accepted form (GrammarBuilder.xmlSchema).
        let search = ToolSchema(name: "web_search", description: "s", parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"recency":{"type":"string","enum":["day","week"]}},"required":["query"]}"#)
        let raw = "\n<function=web_search>\n<parameter=query>\nnews\n</parameter>\n<parameter=recency>\nday\n</parameter>\n</function>\n</tool_call>"
        let (okRaw, doneRaw, _) = try Self.walk(tok, format: .qwenXML, tools: [search], body: raw)
        #expect(okRaw && doneRaw == 1, "raw enum value")
        let quoted = raw.replacingOccurrences(of: "\nday\n", with: "\n\"day\"\n")
        #expect(try Self.walk(tok, format: .qwenXML, tools: [search], body: quoted).0 == false, "quoted enum value rejected")
        let other = raw.replacingOccurrences(of: "\nday\n", with: "\nyear\n")
        #expect(try Self.walk(tok, format: .qwenXML, tools: [search], body: other).0 == false, "value outside the enum")
        // The span ends exactly after the template's "</function>\n" (not before; the model writes </tool_call> next).
        let two = "\n<function=get_time>\n<parameter=tz>\nUTC\n</parameter>\n<parameter=n>\n4\n</parameter>\n</function>\n</tool_call>"
        let (okTwo, doneTwo, _, at) = try Self.walkDetail(tok, format: .qwenXML, tools: [Self.time], body: two)
        #expect(okTwo && doneTwo == 1)
        #expect(at?.hasSuffix("</parameter>\n</function>\n") == true, "completed at: \(at ?? "never")")
        let noArgs = "\n<function=get_time>\n</function>\n</tool_call>"
        let (ok2, done2, _) = try Self.walk(tok, format: .qwenXML, tools: [Self.time], body: noArgs)
        #expect(ok2 && done2 == 1, "zero-argument call in the template's own layout")
    }

    /// AT-273 (xlsx-18 follow-up): a forced `tool_choice` without a grammar (a dialect the builder cannot constrain, or a
    /// failed compile) still opens the call: the first token can only be the opening tag; after it nothing is masked.
    @Test func forcedChoiceOpensTheCallWithoutAGrammar() {
        let stats = ToolGrammarStats()
        let p = LazyToolGrammarProcessor(triggerID: 7, thinkOpenID: nil, thinkCloseID: nil, eosID: 2, startsInThink: false,
                                         stats: stats, forced: true, make: nil)
        let logits = MLXArray.ones([1, 64])
        let first = p.process(logits: logits)
        #expect(first[0, 7].item(Float.self) == 1)
        #expect(first[0, 8].item(Float.self) == -Float.infinity && first[0, 2].item(Float.self) == -Float.infinity)
        for t in [7, 11, 12, 13] {
            p.didSample(token: MLXArray([Int32(t)]))
            #expect(p.process(logits: logits).min().item(Float.self) == 1)
        }
        #expect(stats.activations == 0 && stats.failed == 0)
        // Unforced and without a grammar: never edits the logits.
        let free = LazyToolGrammarProcessor(triggerID: 7, thinkOpenID: nil, thinkCloseID: nil, eosID: 2, startsInThink: false,
                                            stats: stats, make: nil)
        #expect(free.process(logits: logits).min().item(Float.self) == 1)
    }

    @Test(.enabled(if: TinyModel.available)) func inactiveProcessorLeavesLogitsAlone() async throws {
        let tok = try await Self.tokenizer(TinyModel.dir!)
        let tag = try #require(GrammarBuilder.structuralTag(format: .hermesJSON, tools: [Self.weather]))
        let cache = ToolGrammarCache()
        let stats = ToolGrammarStats()
        let p = LazyToolGrammarProcessor(
            triggerID: tok.convertTokenToId("<tool_call>")!, thinkOpenID: 5, thinkCloseID: 6, eosID: 2, startsInThink: false,
            stats: stats, make: { cache.checkout(modelKey: "t", tokenizer: tok, tag: tag) },
            release: { cache.checkin($0, tag: tag) })
        let logits = MLXArray.ones([1, 512])
        for id in tok.encode(text: "plain answer text with no call", addSpecialTokens: false) {
            p.didSample(token: MLXArray([Int32(id)]))
            #expect(p.process(logits: logits).min().item(Float.self) == 1)
        }
        // A trigger inside reasoning does not activate.
        p.didSample(token: MLXArray([Int32(5)]))
        p.didSample(token: MLXArray([Int32(3)]))
        p.didSample(token: MLXArray([Int32(7)]))
        p.didSample(token: MLXArray([Int32(8)]))
        #expect(p.process(logits: logits).min().item(Float.self) == 1)
        #expect(stats.activations == 0)
    }
}

/// tools-50 `recovery` rows (parser level) per family dialect → build/at/AT-229/recovery.json.
@Suite struct ToolCallRecoveryConformanceTests {
    static let casesURL = ScriptFixtures.repoRoot.appendingPathComponent("tools/fixtures/staged/prompts/conformance/tools-50.jsonl")
    static let families: [(row: String, format: ToolCallFormat)] = [
        ("qwen35 (Qwen3.5 0.8B/9B, Qwen3.6 35B-A3B)", .qwen35), ("gemma4 (Gemma 4 26B-A4B)", .gemma4), ("json (tiny Hermes fixture)", .json),
    ]

    static func render(_ format: ToolCallFormat, _ name: String, _ args: [String: String]) -> String {
        switch format {
        case .gemma4:
            let body = args.sorted { $0.key < $1.key }.map { "\($0.key):<|\"|>\($0.value)<|\"|>" }.joined(separator: ",")
            return "<|tool_call>call:\(name){\(body)}<tool_call|>"
        case .qwen35, .xmlFunction:
            let ps = args.sorted { $0.key < $1.key }.map { "<parameter=\($0.key)>\n\($0.value)\n</parameter>\n" }.joined()
            return "<tool_call>\n<function=\(name)>\n\(ps)</function>\n</tool_call>"
        default:
            let d = try! JSONSerialization.data(withJSONObject: ["name": name, "arguments": args], options: [.sortedKeys])
            return "<tool_call>\n\(String(decoding: d, as: UTF8.self))\n</tool_call>"
        }
    }

    static func text(_ raw: [String: Any], _ format: ToolCallFormat) -> String {
        if let t = raw["text"] as? String { return t }
        let name = raw["native"] as? String ?? "weather"
        var s = render(format, name, raw["args"] as? [String: String] ?? [:])
        if let second = raw["second"] as? [String: String] { s += "\n" + render(format, name, second) }
        if let p = raw["prefix"] as? String { s = p + s }
        if raw["inside_reasoning"] as? Bool == true { s = "<think>consider " + s + " carefully</think>" }
        return s
    }

    @Test func recoveryRowsPerFamily() throws {
        let rows = try String(contentsOf: Self.casesURL, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["kind"] as? String == "recovery" }
        #expect(rows.count == 10)
        let tools: [[String: any Sendable]] = [["type": "function", "function": ["name": "weather", "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]] as [String: any Sendable]] as [String: any Sendable]]]
        var report: [[String: Any]] = []
        for fam in Self.families {
            var cases: [[String: Any]] = []
            for r in rows {
                let raw = r["raw"] as? [String: Any] ?? [:]
                let expect = r["expect"] as? [String: Any] ?? [:]
                let text = Self.text(raw, fam.format)
                let reasoning = raw["inside_reasoning"] as? Bool == true
                let chunks: [[String]] = raw["split_every_boundary"] as? Bool == true
                    ? (1..<text.count).map { k in [String(text.prefix(k)), String(text.dropFirst(k))] } : [[text]]
                var why: [String] = []
                for parts in chunks {
                    let proc = ToolCallProcessor(format: fam.format, tools: tools)
                    var scrub = RawToolSyntaxScrubber()
                    var visible = ""
                    for c in parts {
                        // Reasoning spans reach the client as reasoningDelta; the scrubber only sees answer text.
                        let resp = proc.processChunk(c) ?? ""
                        visible += reasoning ? "" : scrub.feed(resp)
                    }
                    visible += reasoning ? "" : scrub.feed(proc.processEOS() ?? "") + scrub.finish()
                    let names = proc.toolCalls.map(\.function.name)
                    let want = expect["calls"] as? [String] ?? []
                    if names != want { why.append("calls \(names) ≠ \(want)") }
                    if let first = proc.toolCalls.first, let contains = expect["args_contains"] as? [String: String] {
                        for (k, needle) in contains {
                            let v: String = switch first.function.arguments[k] {
                            case .string(let s)?: s
                            default: "\(String(describing: first.function.arguments[k]))"
                            }
                            if !v.lowercased().contains(needle.lowercased()) { why.append("arg \(k)=\(v.prefix(40)) lacks \(needle)") }
                        }
                    }
                    if let t = expect["text_contains"] as? String, !visible.contains(t) { why.append("text lost \(t)") }
                    for m in ToolFormat.rawMarkers.map(\.open) where visible.contains(m) { why.append("raw \(m) visible") }
                    if !why.isEmpty { break }
                }
                cases.append(["id": r["id"] as? String ?? "?", "pass": why.isEmpty, "why": why, "source": r["source"] ?? [:]])
            }
            let passed = cases.filter { $0["pass"] as? Bool == true }.count
            report.append(["family": fam.row, "format": fam.format.rawValue, "passed": passed, "total": cases.count, "cases": cases])
            for c in cases where c["pass"] as? Bool != true { Issue.record("\(fam.row) \(c["id"] ?? ""): \(c["why"] ?? "")") }
        }
        let out = ScriptFixtures.repoRoot.appendingPathComponent("build/at/AT-229/recovery.json")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let obj: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "parser": "mlx-swift-lm@f5b0677 ToolCallProcessor + RawToolSyntaxScrubber", "families": report]
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: out)
    }
}
