// M1.T13 step 4 — thinking-20.jsonl: 10 prompts × reasoning {on, off}. On: the model's reasoning arrives as
// reasoningDelta (non-empty) and never as raw `<think>` text; off (`enable_thinking: false`): no reasoningDelta,
// and no think tags in textDelta either way. A finished turn also needs answer text unless it hit max tokens.
import AntiChatFoundation
import AntiChatHarness
import Foundation

enum ThinkingCases {
    static let thinkTags = ["<think>", "</think>", "<|channel>", "<channel|>", "<|think|>"]

    static func run(_ client: EngineClient, _ row: ConformanceRow, _ c: [String: Any]) async -> [String: Any] {
        let on = c["reasoning"] as? Bool ?? false
        let req = ChatRequest(
            modelSlot: row.slot, messages: Conformance.messages(c["messages"]), reasoning: ReasoningOptions(on: on),
            sampling: Sampling(temperature: 0, topP: 1, maxTokens: on ? 1536 : 384, seed: 7))
        let r = await Conformance.run(client, req)
        var why: [String] = []
        let v = EventOrdering.violations(r.trace.events)
        if !v.isEmpty { why.append("ordering: \(v.map(\.description).joined(separator: "; "))") }
        if r.trailing > 0 { why.append("\(r.trailing) events after the terminal") }
        if case .error(let e)? = r.trace.terminal { why.append("error: \(e)") }
        // Nothing here cancels: a done(cancelled) means the run hit the suite's 240 s watchdog (stall or sleep).
        if r.trace.terminal == .done(.cancelled) { why.append("cancelled by the 240 s guard (stalled stream)") }
        let reasoning = r.trace.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if on, reasoning.isEmpty { why.append("reasoning on but no reasoningDelta") }
        if !on, !reasoning.isEmpty { why.append("reasoning off but \(reasoning.count) chars of reasoningDelta") }
        let text = r.trace.text
        let tags = thinkTags.filter { text.contains($0) }
        if !tags.isEmpty { why.append("think tags in textDelta: \(tags)") }
        if r.trace.terminal != .done(.length), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            why.append("finished without answer text")
        }
        return [
            "id": c["id"] as? String ?? "?", "reasoning": on, "pass": why.isEmpty, "why": why,
            "reasoning_chars": reasoning.count, "text_chars": text.count, "finish": "\(r.trace.terminal.map(Conformance.eventSummary) ?? "-")",
            "wall_s": r.wallS, "text_head": String(text.prefix(120)),
        ]
    }
}
