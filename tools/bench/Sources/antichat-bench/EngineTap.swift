// AT-273 round 65: the bench's engine event log. The fileout-golden path runs the helper over XPC and writes no
// engine log, so a turn that ended in `engine.stalled` left no trace of what the engine did. `EngineTap` wraps the
// bench's engine and records, per request, the tool_choice and token budget and every event with its time since the
// request went out (deltas folded into runs), so a report shows whether tokens were flowing during a silence.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation

final class EngineTap: EngineService, @unchecked Sendable {
    private let inner: any EngineService
    private let lock = NSLock()
    private var log: [@Sendable () -> [String: Any]] = []

    init(_ inner: any EngineService) { self.inner = inner }

    /// The requests since the last `drain()` with their event timelines.
    func drain() -> [[String: Any]] { lock.withLock { defer { log = [] }; return log.map { $0() } } }

    private final class Request: @unchecked Sendable {
        let lock = NSLock()
        let start = ContinuousClock.now
        var events: [[String: Any]] = []
        var lastKind = ""
        func secs() -> Double {
            let c = (ContinuousClock.now - start).components
            return Double(c.seconds) + Double(c.attoseconds) * 1e-18
        }
        func add(_ kind: String, _ extra: [String: Any] = [:]) {
            lock.withLock {
                let t = (secs() * 1000).rounded() / 1000
                // Runs of the same delta kind are one row (first, last time, count, characters).
                if kind == lastKind, kind.hasSuffix("Delta") || kind == "generating", var last = events.popLast() {
                    last["t_last"] = t
                    last["n"] = (last["n"] as? Int ?? 1) + 1
                    if let c = extra["chars"] as? Int { last["chars"] = (last["chars"] as? Int ?? 0) + c }
                    if let tk = extra["tokens"] { last["tokens"] = tk }
                    events.append(last)
                    return
                }
                lastKind = kind
                var row: [String: Any] = ["k": kind, "t": t]
                row.merge(extra) { a, _ in a }
                if let tk = extra["tokens"] { row["tokens_first"] = tk }
                events.append(row)
            }
        }
    }

    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let r = Request()
        let choice = request.toolChoice.map { String(describing: $0) } ?? "nil"
        // The tool loop so far as this request carries it: the calls (name, argument size and start) and results.
        let loop: [String] = request.messages.compactMap { item in
            guard case .message(let m) = item else { return nil }
            if m.role == .tool { return "tool[\(m.toolName ?? "")]: \(m.content.prefix(300))" }
            if m.role == .assistant, !m.toolCalls.isEmpty {
                return "call " + m.toolCalls.map { "\($0.name)(\($0.argumentsJSON.count) chars) \($0.argumentsJSON.prefix(300))" }.joined(separator: " | ")
            }
            return nil
        }
        let entry: @Sendable () -> [String: Any] = {
            r.lock.withLock { ["request": request.requestID.uuidString, "tool_choice": choice,
                               "max_tokens": request.sampling.maxTokens, "tools": request.tools.count, "events": r.events,
                               "loop": loop] }
        }
        let tapLifecycle: @Sendable (LifecycleEvent) -> Void = { l in
            switch l {
            case .generating(let n): r.add("generating", ["tokens": n])
            case .prefillProgress(let f): r.add("prefill", ["f": f])
            default: r.add("lifecycle", ["e": String(describing: l)])
            }
            onLifecycle?(l)
        }
        lock.withLock { log.append(entry) }
        let upstream = inner.chat(request, onLifecycle: tapLifecycle)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await e in upstream {
                        switch e {
                        case .textDelta(let s): r.add("textDelta", ["chars": s.count])
                        case .reasoningDelta(let s): r.add("reasoningDelta", ["chars": s.count])
                        case .toolCallDelta(_, let name, let a): r.add("toolCallDelta", ["name": name ?? "", "chars": a.count])
                        case .toolCallDone(_, let name, let a): r.add("toolCallDone", ["name": name, "chars": a.count])
                        case .usage(let u):
                            r.add("usage", ["completion": u.completionTokens, "prompt": u.promptTokens, "tok_s": u.tokPerSec,
                                            "generate_s": u.generateTime])
                        case .done(let why): r.add("done", ["why": why.rawValue])
                        case .error(let err): r.add("error", ["code": err.code])
                        }
                        cont.yield(e)
                    }
                    cont.finish()
                } catch {
                    r.add("thrown", ["e": "\(error)"])
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { @Sendable why in
                if case .cancelled = why {
                    task.cancel()
                    r.add("consumer_cancelled")
                }
            }
        }
    }

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? {
        await inner.warmup(slot, onLifecycle: onLifecycle)
    }
    func cancel(_ requestID: UUID) { inner.cancel(requestID) }
    func capabilities() async -> EngineCapabilities? { await inner.capabilities() }
    func hint(_ warmup: Warmup) async { await inner.hint(warmup) }
    func countTokens(_ texts: [String], slot: ModelSlot) async -> [Int] { await inner.countTokens(texts, slot: slot) }
    func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> { inner.voiceStream(message) }
    func voiceSend(_ message: VoiceMessage) -> Bool { inner.voiceSend(message) }
}
