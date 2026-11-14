// AT-231 tool-calling eval (M1.T13 step 5), shared by `antichat-bench tools` and the `ToolEval` integration test:
// runs every row of antichat-tools-200.jsonl through the real helper and scores
//   parse_valid_rate   emitted calls whose arguments parse as a JSON object, over all call attempts (parsed calls
//                      + calls the native parser rejected + raw-syntax leaks in text)
//   schema_valid_rate  calls that parse, name a declared tool and satisfy its parameter schema, over call attempts
//   correct_tool_rate  rows whose emitted tool set equals expected_tool (one name, or the BFCL parallel list)
//   raw_syntax_leaks   rows whose delivered textDelta contains tool-call syntax (RawToolSyntax) — must be 0
//   constrained        every emitted call ran under the grammar constraint (Usage.toolCallsConstrained == calls)
// Thinking off, greedy, fixed seed (same as the conformance tool cases).
import AntiChatEngineProtocol
import Foundation

public enum ToolEvalRunner {
    public struct Options: Sendable {
        public var maxTokens = 1536
        public var limit: Int?
        /// Decode-overhead leg (M1.T13 failure mode "grammar slows decode > 5 %"): the first N rows run again with
        /// `tool_choice: none` (no tools in the template, no grammar processor) next to `auto` (tools offered, lazy
        /// grammar installed), and the decode rates are compared.
        public var overheadRows: Int
        /// M1.T16: run the harness' `ToolSelection` in front of every row, as the app does (`.off` = the M1.T13 eval).
        public var selection: ToolSelection.Variant
        public init(maxTokens: Int = 1536, limit: Int? = nil, overheadRows: Int = 0, selection: ToolSelection.Variant = .off) {
            self.selection = selection
            self.maxTokens = maxTokens
            self.limit = limit
            self.overheadRows = overheadRows
        }
    }

    public static func loadRows(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    static func messages(_ raw: Any?) -> [ChatMessage] {
        (raw as? [[String: Any]] ?? []).compactMap { m in
            guard let r = (m["role"] as? String).flatMap(ChatMessage.Role.init(rawValue:)) else { return nil }
            return ChatMessage(role: r, content: m["content"] as? String ?? "")
        }
    }

    static func tools(_ raw: Any?) -> [ToolSchema] {
        guard let arr = raw as? [Any], let d = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return ToolSchema.fromOpenAI(String(decoding: d, as: UTF8.self))
    }

    /// Collects one request's events (no cancel; a 900 s guard cancels a stuck stream).
    static func collect(_ client: EngineClient, _ req: ChatRequest) async -> ToolStreamTrace {
        let guardTask = Task {
            try? await Task.sleep(for: .seconds(900))
            if !Task.isCancelled { client.cancel(req.requestID) }
        }
        defer { guardTask.cancel() }
        var t = ToolStreamTrace()
        for await b in client.chatBatches(req) { t.events += b.events }
        return t
    }

    public static func run(
        client: EngineClient, slot: ModelSlot, rows all: [[String: Any]], options: Options = Options(),
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> [String: Any] {
        let rows = options.limit.map { Array(all.prefix($0)) } ?? all
        var attempts = 0, parsed = 0, schemaValid = 0, correct = 0, leakRows = 0, calls = 0, constrained = 0, rejected = 0
        var scrubbed = 0, orderingBad = 0
        var perCat: [String: (n: Int, ok: Int)] = [:]
        var out: [[String: Any]] = []
        var tps: [Double] = []
        let t0 = ContinuousClock.now
        for (i, row) in rows.enumerated() {
            let tools = tools(row["tools"])
            let msgs = messages(row["messages"])
            let plan = ToolSelection.plan(tools: tools, userText: ToolSelection.newestUserText(msgs), variant: options.selection)
            let req = ChatRequest(
                modelSlot: slot, messages: ToolSelection.items(msgs, clause: plan.clause), tools: plan.tools,
                toolChoice: plan.toolChoice, reasoning: .off,
                sampling: Sampling(temperature: 0, topP: 1, maxTokens: options.maxTokens, seed: 7))
            let tr = await collect(client, req)
            let checks = tr.checkCalls(tools)
            let leaks = RawToolSyntax.leaks(in: tr.text)
            let rej = tr.usage?.toolCallsRejected ?? 0
            let rowAttempts = checks.count + rej + (leaks.isEmpty ? 0 : 1)
            attempts += rowAttempts
            parsed += checks.filter(\.parses).count
            schemaValid += checks.filter(\.schemaValid).count
            calls += checks.count
            rejected += rej
            constrained += min(checks.count, tr.usage?.toolCallsConstrained ?? 0)
            scrubbed += tr.usage?.rawToolSyntaxScrubbed ?? 0
            if !leaks.isEmpty { leakRows += 1 }
            if !EventOrdering.violations(tr.events).isEmpty { orderingBad += 1 }
            let names = checks.map(\.name)
            let expected: [String] = (row["expected_tool"] as? [String]) ?? [(row["expected_tool"] as? String) ?? ""]
            let ok = names.sorted() == expected.sorted()
            if ok { correct += 1 }
            let cat = row["category"] as? String ?? "?"
            perCat[cat, default: (0, 0)].n += 1
            if ok { perCat[cat, default: (0, 0)].ok += 1 }
            let argsOK = checks.first.map { ArgsMatch.matches($0.args, row["expected_args_contains"] as? [String: String] ?? [:]) }
            if let u = tr.usage, u.tokPerSec > 0 { tps.append(u.tokPerSec) }
            out.append([
                "id": row["id"] as? String ?? "?", "category": cat, "expected": expected, "calls": names, "correct": ok,
                "schema_valid": checks.map(\.schemaValid), "problems": checks.flatMap(\.schemaProblems).prefix(4).map { $0 },
                "args_contains_ok": argsOK ?? false, "leaks": leaks, "rejected": rej,
                "constrained": tr.usage?.toolCallsConstrained ?? -1,
                "finish": tr.terminal.map { "\($0)" } ?? "none", "text_head": String(tr.text.prefix(100)),
                "args": checks.first.map { $0.args.mapValues(\.description) } ?? [:],
            ])
            progress?("\(i + 1)/\(rows.count) \(row["id"] ?? "?") \(ok ? "ok" : "MISS") calls=\(names) expected=\(expected)")
        }
        func rate(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }
        func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
        var overhead: [String: Any] = [:]
        if options.overheadRows > 0 {
            var with: [Double] = [], without: [Double] = []
            for row in rows.prefix(options.overheadRows) {
                for choice in [ToolChoice.auto, .none] {
                    let req = ChatRequest(
                        modelSlot: slot, messages: messages(row["messages"]), tools: tools(row["tools"]), toolChoice: choice,
                        reasoning: .off, sampling: Sampling(temperature: 0, topP: 1, maxTokens: 160, seed: 7))
                    let tr = await collect(client, req)
                    if let u = tr.usage, u.tokPerSec > 0, u.completionTokens >= 16 {
                        if choice == .auto { with.append(u.tokPerSec) } else { without.append(u.tokPerSec) }
                    }
                }
            }
            let w = median(with), wo = median(without)
            overhead = [
                "rows": options.overheadRows, "decode_tok_per_s_p50_grammar": w, "decode_tok_per_s_p50_no_tools": wo,
                "slowdown": wo > 0 ? 1 - w / wo : 0, "n_with": with.count, "n_without": without.count,
                "note": "same prompts; tool_choice none drops the tools block from the template and installs no processor",
            ]
        }
        let secs: Double = {
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }()
        return [
            "model": slot.key, "rows": rows.count, "runtime_s": secs,
            "metrics": [
                "parse_valid_rate": rate(parsed, attempts), "schema_valid_rate": rate(schemaValid, attempts),
                "correct_tool_rate": rate(correct, rows.count), "raw_syntax_leaks": leakRows,
                "constrained_rate": rate(constrained, calls),
            ],
            "counts": [
                "call_attempts": attempts, "calls": calls, "parsed": parsed, "schema_valid": schemaValid, "rejected": rejected,
                "constrained": constrained, "correct_rows": correct, "scrubbed_spans": scrubbed, "ordering_violations": orderingBad,
            ],
            "decode_tok_per_s_p50": median(tps), "grammar_overhead": overhead,
            "per_category": perCat.mapValues { ["n": $0.n, "correct": $0.ok, "rate": rate($0.ok, $0.n)] },
            "cases": out,
        ]
    }
}
