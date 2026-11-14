// M1.T13 step 4 — cancel-10.jsonl: Cancel{requestID} during prefill, mid-reasoning, mid-tool-args and mid-text.
// Pass: the stream ends with done(cancelled) ≤ 300 ms after the Cancel left the app (measured app-side to the
// arrival of the terminal batch, through the real helper; NFR-U6 / architecture §4.3) and no event follows it.
// `phase_hit` records whether the cancel really landed in the named phase (e.g. no reasoning/tool call had
// finished yet); a miss is reported, and the row's verdict uses the latency/ordering rules only.
// Tool-args on MLX: mlx-swift-lm emits a call only once complete, so the cancel fires a fixed time after prefill
// ended (the model starts the call at its first token with thinking off); on llama-server at the first
// toolCallDelta, which streams the argument fragments.
import AntiChatFoundation
import AntiChatHarness
import Foundation

enum CancelCases {
    static func run(_ client: EngineClient, _ row: ConformanceRow, _ c: [String: Any]) async -> [String: Any] {
        let at = c["cancel_at"] as? [String: Any] ?? [:]
        let phase = c["phase"] as? String ?? "?"
        let tools = Conformance.tools(c["tools"])
        let req = ChatRequest(
            modelSlot: row.slot, messages: [ChatMessage(role: .user, content: c["prompt"] as? String ?? "")], tools: tools,
            toolChoice: tools.isEmpty ? nil : .auto, reasoning: ReasoningOptions(on: c["reasoning"] as? Bool ?? false),
            sampling: Sampling(temperature: 0.6, topP: 0.95, maxTokens: 4000, seed: 11))
        var r: Conformance.Run
        if let ms = at["after_ms"] as? Int {
            r = await Conformance.run(client, req, cancelAfter: .milliseconds(max(ms, 1)))
        } else if let kind = at["on_event"] as? String {
            let skip = at["skip"] as? Int ?? 0
            r = await Conformance.run(client, req, cancelWhen: { run, _ in
                run.trace.events.filter { EventOrdering.kind($0) == kind }.count > skip
            })
        } else if at["on_lifecycle"] != nil {
            r = await Conformance.run(client, req, cancelWhen: { run, b in
                !b.lifecycle.isEmpty || !run.lifecycle.isEmpty || !run.trace.events.isEmpty
            })
        } else {
            let span = at["in_tool_span_ms"] as? Int ?? 150
            // llama-server streams argument fragments: cancel at the first one. MLX emits a call only when complete:
            // arm a timer `span` ms after prefill ended (last prefillProgress = 1, or the first event).
            r = await Conformance.run(
                client, req,
                cancelWhen: { run, _ in run.trace.events.contains { if case .toolCallDelta = $0 { true } else { false } } },
                armTimer: { run, b in
                    let ended = b.lifecycle.contains { if case .prefillProgress(let p) = $0 { p >= 1 } else { false } }
                    return ended || !run.trace.events.isEmpty ? .milliseconds(span) : nil
                })
        }
        var why: [String] = []
        let v = EventOrdering.violations(r.trace.events)
        if !v.isEmpty { why.append("ordering: \(v.map(\.description).joined(separator: "; "))") }
        if r.trailing > 0 { why.append("\(r.trailing) events after done") }
        if r.trace.terminal != .done(.cancelled) { why.append("terminal \(r.trace.terminal.map(Conformance.eventSummary) ?? "none") ≠ done(cancelled)") }
        let lat = r.cancelLatencyMs ?? -1
        if lat < 0 || lat > 300 { why.append("cancel → done \(lat) ms (> 300 or missing)") }
        let finishedCall = r.trace.events.contains { if case .toolCallDone = $0 { true } else { false } }
        let phaseHit: Bool = switch phase {
        case "prefill": !r.trace.events.contains { $0.isDelta }
        case "reasoning": !r.trace.reasoning.isEmpty && r.trace.text.isEmpty
        case "tool_args": !finishedCall
        default: !r.trace.text.isEmpty
        }
        return [
            "id": c["id"] as? String ?? "?", "phase": phase, "pass": why.isEmpty, "why": why, "cancel_ms": lat,
            "phase_hit": phaseHit, "events_before_cancel": r.trace.events.count - 1,
        ]
    }
}
