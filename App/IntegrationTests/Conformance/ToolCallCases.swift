// M1.T13 step 4 — the 40 model-level tool cases of tools-50.jsonl (single, multiple, parallel, no_call); the 10
// `recovery` rows are parser-level and run in the Engines unit suite (ToolCallRecoveryConformanceTests).
// A case passes when the stream conforms (EventOrdering), every emitted call is structurally valid (parses,
// declared name, schema-valid arguments), the expected tool set is called (or nothing for no_call), and no raw
// tool syntax reached textDelta. Thinking off, greedy (temperature 0), seed fixed.
import AntiChatFoundation
import AntiChatHarness
import Foundation

enum ToolCallCases {
    struct Result {
        var id: String
        var kind: String
        var pass: Bool
        var why: [String]
        var notes: [String] = []
        var calls: [String]
        var constrained: Int?
        var wallS: Double
        var tokPerSec: Double
        var textHead = ""
        var json: [String: Any] {
            ["id": id, "kind": kind, "pass": pass, "why": why, "notes": notes, "calls": calls, "constrained": constrained ?? -1,
             "wall_s": wallS, "tok_per_s": tokPerSec, "text_head": textHead]
        }
    }

    /// M1.T16 / D-023 (b): the harness' tool selection (`ToolSelection`) runs in front of every case, as it does in
    /// front of every app turn; `ANTICHAT_TOOL_SELECTION=off|abstain|standard` (default `standard`) picks the
    /// variant (`off` = the M1.T13 measurement).
    static var variant: ToolSelection.Variant {
        Conformance.env["ANTICHAT_TOOL_SELECTION"].flatMap(ToolSelection.Variant.init(rawValue:)) ?? .standard
    }

    static func run(_ client: EngineClient, _ row: ConformanceRow, _ c: [String: Any]) async -> Result {
        let offered = Conformance.tools(c["tools"])
        let messages = Conformance.messages(c["messages"])
        let forcedNone = (c["tool_choice"] as? String) == "none"
        let plan = ToolSelection.plan(
            tools: offered, userText: ToolSelection.newestUserText(messages), variant: variant)
        // Tuning runs only (build/at/AT-229/tuning/): a candidate clause in place of the shipped one.
        let clause = plan.clause.map { _ in Conformance.env["ANTICHAT_TOOL_CLAUSE"].flatMap { $0.isEmpty ? nil : $0 } ?? ToolSelection.clause }
        let req = ChatRequest(
            modelSlot: row.slot, messages: ToolSelection.items(messages, clause: forcedNone ? nil : clause),
            tools: forcedNone ? offered : plan.tools, toolChoice: forcedNone ? ToolChoice.none : plan.toolChoice,
            reasoning: .off, sampling: Sampling(temperature: 0, topP: 1, maxTokens: 400, seed: 7))
        let r = await Conformance.run(client, req)
        return judge(c, r, tools: offered)
    }

    static func judge(_ c: [String: Any], _ r: Conformance.Run, tools: [ToolSchema]) -> Result {
        let expect = c["expect"] as? [String: Any] ?? [:]
        let want = expect["calls"] as? [String] ?? []
        let contains = expect["args_contains"] as? [String: String] ?? [:]
        var why: [String] = []
        var notes: [String] = []
        let v = EventOrdering.violations(r.trace.events)
        if !v.isEmpty { why.append("ordering: \(v.map(\.description).joined(separator: "; "))") }
        if r.trailing > 0 { why.append("\(r.trailing) events after the terminal") }
        if case .error(let e)? = r.trace.terminal { why.append("error: \(e)") }
        // Nothing here cancels: a done(cancelled) means the run hit the suite's 240 s watchdog (stall or sleep).
        if r.trace.terminal == .done(.cancelled) { why.append("cancelled by the 240 s guard (stalled stream)") }
        let checks = r.trace.checkCalls(tools)
        for ch in checks where !ch.schemaValid {
            why.append("invalid call \(ch.name): parses=\(ch.parses) declared=\(ch.declared) \(ch.schemaProblems.prefix(3))")
        }
        let names = checks.map(\.name)
        if want.isEmpty {
            if !names.isEmpty { why.append("expected no call, got \(names)") }
        } else {
            if names.sorted() != want.sorted() {
                why.append("expected calls \(want), got \(names)")
            }
            // Argument VALUES are reported, not gated: R-229 asks for structurally valid calls (AT-231 scores choice).
            if let first = checks.first, !ArgsMatch.matches(first.args, contains) {
                notes.append("args \(first.args.mapValues(\.description)) miss \(contains)")
            }
        }
        let leaks = RawToolSyntax.leaks(in: r.trace.text)
        if !leaks.isEmpty { why.append("raw tool syntax in text: \(leaks)") }
        if (r.trace.usage?.rawToolSyntaxScrubbed ?? 0) > 0 { why.append("scrubber removed \(r.trace.usage!.rawToolSyntaxScrubbed!) raw span(s) (tool.parseLeak)") }
        return Result(
            id: c["id"] as? String ?? "?", kind: c["kind"] as? String ?? "?", pass: why.isEmpty, why: why,
            notes: notes, calls: names, constrained: r.trace.usage?.toolCallsConstrained, wallS: r.wallS, tokPerSec: r.trace.usage?.tokPerSec ?? 0,
            textHead: String(r.trace.text.prefix(160)))
    }
}
