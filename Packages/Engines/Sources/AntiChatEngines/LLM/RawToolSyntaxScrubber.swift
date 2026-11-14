// RawToolSyntaxScrubber (M1.T13 step 3): when tools are offered, raw tool-call syntax that the native parser did
// not consume (a recovered or half-emitted call) must not reach the transcript as answer text. The scrubber sits
// on the adapter stream in the helper (EngineCore.runChat), so it covers MLX, llama-server and scripted engines
// alike. It removes a paired span `<open> … <close>` (or the bare marker when the dialect has no closer), holds
// back a trailing prefix of a marker until the next delta decides it, counts every removal in
// `Usage.rawToolSyntaxScrubbed` and logs it as the `tool.parseLeak` counter: a removal is never silent, and the
// conformance suite fails on any (AT-229/AT-231 `raw_syntax_leaks == 0` counts what the user would have seen).
// Only tool syntax is touched, and only when the request offered tools; answer content is never rewritten (R-241).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public struct RawToolSyntaxScrubber: Sendable {
    public private(set) var removed = 0
    private var pending = ""
    /// Inside a paired span: the closer we wait for.
    private var waitingFor: String?
    private let markers: [(open: String, close: String?)]
    private let maxMarker: Int

    public init(markers: [(open: String, close: String?)] = ToolFormat.rawMarkers) {
        self.markers = markers
        maxMarker = markers.map(\.open.count).max() ?? 1
    }

    /// Feeds one text delta; returns the text that is safe to emit now (possibly empty).
    public mutating func feed(_ s: String) -> String {
        pending += s
        var out = ""
        while true {
            if let close = waitingFor {
                guard let r = pending.range(of: close) else {
                    // Keep only what could still be the start of the closer.
                    pending = String(pending.suffix(close.count - 1))
                    return out
                }
                pending = String(pending[r.upperBound...])
                waitingFor = nil
                continue
            }
            // Earliest marker occurrence.
            var best: (Range<String.Index>, String?)?
            for m in markers {
                if let r = pending.range(of: m.open), best == nil || r.lowerBound < best!.0.lowerBound
                    || (r.lowerBound == best!.0.lowerBound && r.upperBound > best!.0.upperBound)
                {
                    best = (r, m.close)
                }
            }
            if let (r, close) = best {
                out += pending[..<r.lowerBound]
                removed += 1
                AppLog.log(.engine, .info, "tool.parseLeak: removed raw tool syntax from textDelta")
                pending = String(pending[r.upperBound...])
                waitingFor = close
                continue
            }
            // No full marker: emit all but a suffix that is a prefix of some marker.
            let keep = holdBack(pending)
            out += pending.dropLast(keep)
            pending = String(pending.suffix(keep))
            return out
        }
    }

    /// End of stream: flush held text (an unterminated span is dropped).
    public mutating func finish() -> String {
        defer { pending = "" }
        return waitingFor == nil ? pending : ""
    }

    private func holdBack(_ s: String) -> Int {
        let n = min(s.count, maxMarker - 1)
        guard n > 0 else { return 0 }
        for k in stride(from: n, through: 1, by: -1) {
            let tail = s.suffix(k)
            if markers.contains(where: { $0.open.hasPrefix(tail) }) { return k }
        }
        return 0
    }
}

/// The adapter stream with raw tool syntax removed from `textDelta` and the counter added to `usage`.
public enum ToolSyntaxFilterStream {
    /// `nativeLazyGrammar`: the engine constrains tool-call spans itself (llama-server `--jinja` + tools, see
    /// GrammarBuilder), so every call it streams counts as constrained when the adapter did not report a number.
    public static func wrap(
        _ upstream: AsyncStream<AdapterOutput>, toolsOffered: Bool, nativeLazyGrammar: Bool = false
    ) -> AsyncStream<AdapterOutput> {
        guard toolsOffered else { return upstream }
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            let task = Task {
                var s = RawToolSyntaxScrubber()
                var callIDs: Set<String> = []
                for await out in upstream {
                    switch out {
                    case .event(.toolCallDelta(let id, _, _)):
                        callIDs.insert(id)
                        cont.yield(out)
                    case .event(.textDelta(let t)):
                        let e = s.feed(t)
                        if !e.isEmpty { cont.yield(.event(.textDelta(e))) }
                    case .event(.usage(var u)):
                        let rest = s.finish()
                        if !rest.isEmpty { cont.yield(.event(.textDelta(rest))) }
                        u.rawToolSyntaxScrubbed = s.removed
                        if nativeLazyGrammar, u.toolCallsConstrained == nil { u.toolCallsConstrained = callIDs.count }
                        cont.yield(.event(.usage(u)))
                    case .event(let e) where e.isTerminal:
                        let rest = s.finish()
                        if !rest.isEmpty { cont.yield(.event(.textDelta(rest))) }
                        cont.yield(out)
                    default:
                        cont.yield(out)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
