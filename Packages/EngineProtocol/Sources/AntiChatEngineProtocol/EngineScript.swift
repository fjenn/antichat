// ScriptedEngine scripts (M1.T05 step 6): a JSONL file replayed as engine events, so UI and harness work runs
// without a model. Foundation-only and here (not in AntiChatEngines) because the app replays scripts
// in-process (`-UseScriptedEngine <path>`) and must never link AntiChatEngines (architecture §3 rule 1);
// the helper wraps the same player as an `EngineAdapter` (Engines/LLM/ScriptedEngine.swift). A-M1-T05a.
//
// Format (one JSON object per line; `#` lines and blank lines are ignored):
//   {"t":"caps","reasoning":false,"toolCalls":true,"vision":false,"contextTokens":4096}   optional, first line
//   {"t":"textDelta","v":"Hello","delayMs":20}            "repeat":N emits it N times; "n":k tokens per emit
//   {"t":"reasoningDelta","v":"…","delayMs":20}
//   {"t":"toolCallDelta","id":"call_1","name":"echo","v":"{\"te"}   name optional after the first fragment
//   {"t":"toolCallDone","id":"call_1","name":"echo","args":"{\"text\":\"hi\"}"}
//   {"t":"usage","prompt":12,"completion":3,"cached":0}  every field optional (auto: chars/4 and delta count);
//                                                        "rejected":"tool" = that call was cut off (incomplete_output)
//                                                        "repeating":true = the engine stopped it as a runaway (AT-273)
//   {"t":"done","reason":"stop"}                          stop | length | toolCalls | cancelled
//   {"t":"error","code":"engine.restarted"}               any AntiChatError.Code raw value
//   {"t":"crash"}                                         helper: the process dies; in-process: engine.restarted
//   {"t":"load","ms":4000,"steps":20}                     loadState loading → loadProgress → ready (first time only)
//   {"t":"prefill","ms":500,"steps":5}                    prefillProgress 0…1
//   {"t":"generating","ms":3000,"steps":30}               generating(tokens: 1…steps): tokens of a call being written
//   {"t":"wait","ms":6000}                                silence (TTFT tests)
//   {"t":"turn"}                                          starts the next turn's segment
//   {"t":"title","v":"Harbour town morning","delayMs":400}  M1.T19: the answer to a title request (anywhere)
// Turn selection: a request plays segment k = number of assistant messages in its prompt (turn 1 → segment 0,
// a tool-loop step adds one assistant message → next segment); past the last segment the last one repeats.
// `"when": "<text>"` on a step: played only when the last user message contains <text> (case-insensitive).
// `{{n}}` in any string = k + 1 (fresh tool arguments per step, tool-loop-runaway.jsonl).
// `{{v}}` = how many times this player has played segment k so far, this request included (1, 2, …): a regenerated
// or edited turn gets a distinguishable reply (M1.T10 regen.jsonl, J03EditVersionsTests).
// `{{artifact}}` = the newest `artifact_id` a tool result in the prompt names (file-out `revises`, R-273 AC4).
// `{{image}}` = the picture id the turn's context line names (`image_id "<id>"`, M4.T13), as a model would copy it into
// `edit_image`'s `source_image_id`; a forced `edit_image` gets it too.
// Title requests (M1.T19 TitleService: the first prompt item is the layer `titleLayerID`) never play a segment and
// never count as a play: they get the script's `title` line (after its delayMs) + done(stop), or an empty done(stop)
// when the script has none (the chat keeps its temporary title).
// A segment without a terminal step ends with auto usage + done(stop), or done(toolCalls) after a tool call.
import AntiChatFoundation
import Foundation

public struct EngineScript: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case text(String, tokens: Int)
            case reasoning(String, tokens: Int)
            case toolCallDelta(id: String, name: String?, fragment: String)
            case toolCallDone(id: String, name: String, args: String)
            case usage(prompt: Int?, completion: Int?, cached: Int?, tokPerSec: Double?, rejected: String? = nil, repeating: Bool? = nil)
            case done(FinishReason)
            case error(String)
            case crash
            case load(ms: Int, steps: Int)
            case prefill(ms: Int, steps: Int)
            /// AT-273 round 65: liveness pulses with nothing visible (MLX writing a long tool call).
            case generating(ms: Int, steps: Int)
            case wait(ms: Int)
        }

        public var kind: Kind
        public var delayMs: Int
        public var repeatCount: Int
        /// Q-015 r5: `"when": "<text>"` plays the step only when the request's last user message contains `text`
        /// (case-insensitive). A turn's tool step and the next user turn both play segment 1 (one stored assistant
        /// message per turn), so a later turn's own tool call needs this to differ from the tool step's answer.
        public var when: String? = nil

        public init(kind: Kind, delayMs: Int, repeatCount: Int, when: String? = nil) {
            self.kind = kind; self.delayMs = delayMs; self.repeatCount = repeatCount; self.when = when
        }
    }

    public var capabilities: EngineCapabilities
    /// `{"t":"caps"}` was present.
    public var hasCapsHeader: Bool
    public var segments: [[Step]]
    /// M1.T19: the answer to a title request (`{"t":"title"}`).
    public var title: Title?

    public struct Title: Sendable, Hashable {
        public var text: String
        public var delayMs: Int
    }

    /// The first layer id of a TitleService request (M1.T19).
    public static let titleLayerID = "title"

    /// A TitleService request: its first prompt item is the `titleLayerID` layer.
    public static func isTitleRequest(_ request: ChatRequest) -> Bool {
        if case .layer(let l)? = request.messages.first { return l.id == titleLayerID }
        return false
    }

    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public var line: Int
        public var reason: String
        public var description: String { "script line \(line): \(reason)" }
    }

    public static let defaultCapabilities = EngineCapabilities(
        engines: [.scripted], reasoning: true, toolCalls: true, vision: false, contextTokens: 32_768)

    public init(contentsOf url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }

    public init(text: String) throws {
        var caps = Self.defaultCapabilities
        var hasCaps = false
        var segments: [[Step]] = [[]]
        var title: Title?
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                let t = obj["t"] as? String
            else { throw ParseError(line: i + 1, reason: "not a JSON object with \"t\"") }
            func str(_ k: String) throws -> String {
                guard let v = obj[k] as? String else { throw ParseError(line: i + 1, reason: "\(t): missing string \"\(k)\"") }
                return v
            }
            func int(_ k: String) -> Int? { (obj[k] as? NSNumber)?.intValue }
            let kind: Step.Kind
            switch t {
            case "caps":
                guard segments.count == 1, segments[0].isEmpty, !hasCaps else {
                    throw ParseError(line: i + 1, reason: "caps must be the first line")
                }
                hasCaps = true
                if let b = obj["reasoning"] as? Bool { caps.reasoning = b }
                if let b = obj["toolCalls"] as? Bool { caps.toolCalls = b }
                if let b = obj["vision"] as? Bool { caps.vision = b }
                if let b = obj["grammar"] as? Bool { caps.grammar = b }
                if let n = int("contextTokens") { caps.contextTokens = n }
                continue
            case "title":
                title = Title(text: try str("v"), delayMs: max(0, int("delayMs") ?? 0))
                continue
            case "turn":
                segments.append([])
                continue
            case "textDelta": kind = .text(try str("v"), tokens: max(1, int("n") ?? 1))
            case "reasoningDelta": kind = .reasoning(try str("v"), tokens: max(1, int("n") ?? 1))
            case "toolCallDelta": kind = .toolCallDelta(id: try str("id"), name: obj["name"] as? String, fragment: try str("v"))
            case "toolCallDone": kind = .toolCallDone(id: try str("id"), name: try str("name"), args: try str("args"))
            case "usage":
                kind = .usage(prompt: int("prompt"), completion: int("completion"), cached: int("cached"),
                              tokPerSec: (obj["tokPerSec"] as? NSNumber)?.doubleValue, rejected: obj["rejected"] as? String,
                              repeating: obj["repeating"] as? Bool)
            case "done":
                let r = obj["reason"] as? String ?? "stop"
                guard let reason = FinishReason(rawValue: r) else { throw ParseError(line: i + 1, reason: "unknown reason \(r)") }
                kind = .done(reason)
            case "error": kind = .error(try str("code"))
            case "crash": kind = .crash
            case "load": kind = .load(ms: max(0, int("ms") ?? 0), steps: max(1, int("steps") ?? 10))
            case "prefill": kind = .prefill(ms: max(0, int("ms") ?? 0), steps: max(1, int("steps") ?? 5))
            case "generating": kind = .generating(ms: max(0, int("ms") ?? 0), steps: max(1, int("steps") ?? 10))
            case "wait": kind = .wait(ms: max(0, int("ms") ?? 0))
            default: throw ParseError(line: i + 1, reason: "unknown step \"\(t)\"")
            }
            segments[segments.count - 1].append(Step(kind: kind, delayMs: max(0, int("delayMs") ?? 0), repeatCount: max(1, int("repeat") ?? 1),
                                                     when: obj["when"] as? String))
        }
        if segments.count > 1, segments.last?.isEmpty == true { segments.removeLast() }
        capabilities = caps
        hasCapsHeader = hasCaps
        self.segments = segments
        self.title = title
    }

    /// Segment index for a request: number of assistant messages in its prompt.
    public static func turnIndex(for request: ChatRequest) -> Int {
        request.messages.reduce(0) { n, item in
            if case .message(let m) = item, m.role == .assistant { return n + 1 }
            return n
        }
    }

    public func segment(for request: ChatRequest) -> (steps: [Step], n: Int) {
        let k = Self.turnIndex(for: request)
        let steps = segments[min(k, segments.count - 1)]
        guard steps.contains(where: { $0.when != nil }) else { return (steps, k + 1) }
        let user = (request.flattenedMessages.last(where: { $0.role == .user })?.content ?? "").lowercased()
        return (steps.filter { $0.when.map { user.contains($0.lowercased()) } ?? true }, k + 1)
    }
}

/// What the player hands its host, in order.
public enum ScriptOutput: Sendable, Hashable {
    case engine(EngineEvent)
    case lifecycle(LifecycleEvent)
    /// `{"t":"crash"}`: the helper host kills its process; the in-process host reports `engine.restarted`.
    case crash
}

/// Replays one request's segment. Stateful only for `load` (and the `{{v}}` play counter): the first `load` step (from `warmup` or a chat)
/// runs once, in the background like a real model load; requests that arrive meanwhile report `loading`, get the
/// remaining progress and wait (cancellably) until it is `ready`.
public actor EngineScriptPlayer {
    public typealias Emit = @Sendable (ScriptOutput) async -> Void

    public nonisolated let script: EngineScript
    public private(set) var loaded = false
    private var loadTask: Task<Void, Never>?
    private var loadObservers: [UUID: Emit] = [:]
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Plays per segment index (`{{v}}`).
    private var plays: [Int: Int] = [:]

    public init(script: EngineScript, sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.script = script
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    }

    /// Composer-focus warmup: plays the first segment's `load` step (if any) and returns when ready.
    public func warmup(emit: @escaping Emit) async throws {
        for step in script.segments[0] {
            if case .load(let ms, let k) = step.kind { try await load(ms: ms, steps: k, emit: emit) }
        }
    }

    private func load(ms: Int, steps k: Int, emit: @escaping Emit) async throws {
        guard !loaded else { return }
        let id = UUID()
        loadObservers[id] = emit
        defer { loadObservers[id] = nil }
        await emit(.lifecycle(.loadState(.loading)))
        if loadTask == nil {
            let sleep = self.sleep
            loadTask = Task {
                for i in 1...k {
                    try? await sleep(.milliseconds(ms / k))
                    await self.broadcast(.lifecycle(.loadProgress(Double(i) / Double(k))))
                }
                await self.loadFinished()
            }
        }
        while !loaded { try await sleep(.milliseconds(10)) }
        await emit(.lifecycle(.loadState(.ready)))
    }

    private func broadcast(_ o: ScriptOutput) async {
        for e in loadObservers.values { await e(o) }
    }

    private func loadFinished() {
        loaded = true
        loadTask = nil
    }

    /// Plays the request's segment, calling `emit` for each output. Always ends with exactly one terminal
    /// engine event (or `.crash`). Task cancellation → `done(.cancelled)` within one sleep slice.
    public func play(_ request: ChatRequest, emit: @escaping Emit) async {
        if EngineScript.isTitleRequest(request) {
            // M1.T19: no segment, no play count (`{{v}}` stays stable for the chat's own turns).
            do {
                if let t = script.title {
                    if t.delayMs > 0 { try await sleep(.milliseconds(t.delayMs)) }
                    await emit(.engine(.textDelta(t.text)))
                }
                await emit(.engine(.usage(Usage(promptTokens: 1, completionTokens: script.title == nil ? 0 : 1, cachedTokens: 0,
                                                tokPerSec: 0, ttftMs: Double(script.title?.delayMs ?? 0), generateTime: 0))))
                await emit(.engine(.done(.stop)))
            } catch {
                await emit(.engine(.done(.cancelled)))
            }
            return
        }
        var (steps, n) = script.segment(for: request)
        // M2.T22: a forced tool_choice (`required` / a function) is honoured like the real engines' constrained
        // decoding: a segment that would answer in text calls the forced tool instead (`{"prompt": <user text>}`).
        if let forced = Self.forcedTool(request),
           !steps.contains(where: { if case .toolCallDone = $0.kind { return true }; return false }) {
            let user = request.flattenedMessages.last(where: { $0.role == .user })?.content ?? ""
            var forcedArgs: [String: String] = ["prompt": user]
            // M4.T13: a forced edit_image names the picture in focus, as a model reading the turn's context line does.
            if forced == "edit_image", let image = Self.focusImage(request) { forcedArgs["source_image_id"] = image }
            let args = (try? JSONSerialization.data(withJSONObject: forcedArgs, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            steps = steps.filter {
                switch $0.kind { case .text, .reasoning, .done: false; default: true }
            } + [EngineScript.Step(kind: .toolCallDone(id: "call_forced_{{n}}", name: forced, args: args), delayMs: 0, repeatCount: 1)]
        }
        let started = ContinuousClock.now
        var firstContent: ContinuousClock.Instant?
        var completion = 0
        var sawToolCall = false
        var usageSent = false
        var deltaIDs: Set<String> = []
        plays[n - 1, default: 0] += 1
        let v = plays[n - 1] ?? 1
        let image = Self.focusImage(request) ?? ""
        let artifact = Self.lastArtifact(request) ?? ""
        func sub(_ s: String) -> String {
            s.replacingOccurrences(of: "{{n}}", with: String(n)).replacingOccurrences(of: "{{v}}", with: String(v))
                .replacingOccurrences(of: "{{image}}", with: image).replacingOccurrences(of: "{{artifact}}", with: artifact)
        }
        func pause(_ ms: Int) async throws {
            if ms > 0 { try await sleep(.milliseconds(ms)) } else { try Task.checkCancellation() }
        }
        func autoUsage(prompt: Int? = nil, completionOverride: Int? = nil, cached: Int? = nil, tokPerSec: Double? = nil) -> Usage {
            let promptChars = request.flattenedMessages.reduce(0) { $0 + $1.content.count }
            let ttft = firstContent.map { Self.ms($0 - started) } ?? Self.ms(ContinuousClock.now - started)
            let gen = firstContent.map { Self.secs(ContinuousClock.now - $0) } ?? 0
            let c = completionOverride ?? completion
            return Usage(
                promptTokens: prompt ?? max(1, promptChars / 4), completionTokens: c, cachedTokens: cached ?? 0,
                tokPerSec: tokPerSec ?? (gen > 0 ? Double(c) / gen : 0), ttftMs: ttft, generateTime: gen)
        }
        do {
            for step in steps {
                for _ in 0..<step.repeatCount {
                    try await pause(step.delayMs)
                    switch step.kind {
                    case .text(let s, let k):
                        if firstContent == nil { firstContent = .now }
                        completion += k
                        await emit(.engine(.textDelta(sub(s))))
                    case .reasoning(let s, let k):
                        if firstContent == nil { firstContent = .now }
                        completion += k
                        await emit(.engine(.reasoningDelta(sub(s))))
                    case .toolCallDelta(let id, let name, let f):
                        if firstContent == nil { firstContent = .now }
                        deltaIDs.insert(sub(id))
                        await emit(.engine(.toolCallDelta(id: sub(id), name: name.map(sub), argsFragment: sub(f))))
                    case .toolCallDone(let id, let name, let args):
                        if firstContent == nil { firstContent = .now }
                        sawToolCall = true
                        // R-229 ordering (M1.T13): a call's done follows at least one delta carrying its name.
                        if !deltaIDs.contains(sub(id)) {
                            deltaIDs.insert(sub(id))
                            await emit(.engine(.toolCallDelta(id: sub(id), name: sub(name), argsFragment: sub(args))))
                        }
                        await emit(.engine(.toolCallDone(id: sub(id), name: sub(name), argsJSON: sub(args))))
                    case .usage(let p, let c, let ca, let tps, let rejected, let repeating):
                        usageSent = true
                        var u = autoUsage(prompt: p, completionOverride: c, cached: ca, tokPerSec: tps)
                        if let rejected {  // M6.T21: a call the engine dropped, cut off at the output limit
                            (u.toolCallsRejected, u.rejectedToolName, u.rejectedToolReason) = (1, rejected, "incomplete_output")
                            u.stoppedRepeating = repeating
                        }
                        await emit(.engine(.usage(u)))
                    case .done(let r):
                        if !usageSent { await emit(.engine(.usage(autoUsage()))) }
                        await emit(.engine(.done(r)))
                        return
                    case .error(let code):
                        let e = AntiChatError.Code(rawValue: code).map { AntiChatError($0, detail: "scripted") }
                            ?? AntiChatError.engine(code, "scripted")
                        await emit(.engine(.error(e)))
                        return
                    case .crash:
                        await emit(.crash)
                        return
                    case .load(let ms, let k):
                        try await load(ms: ms, steps: k, emit: emit)
                    case .prefill(let ms, let k):
                        for i in 1...k {
                            try await pause(ms / k)
                            await emit(.lifecycle(.prefillProgress(Double(i) / Double(k))))
                        }
                    case .generating(let ms, let k):
                        for i in 1...k {
                            try await pause(ms / k)
                            await emit(.lifecycle(.generating(tokens: i)))
                        }
                    case .wait(let ms):
                        try await pause(ms)
                    }
                }
            }
            if !usageSent { await emit(.engine(.usage(autoUsage()))) }
            await emit(.engine(.done(sawToolCall ? .toolCalls : .stop)))
        } catch {
            await emit(.engine(.done(.cancelled)))
        }
    }

    /// The tool a forced `tool_choice` names (`required` = the first offered tool); nil for auto / none / no tools.
    /// M4.T13: the picture id the turn's context line names (`image_id "<id>"`; `{{image}}` in a script), nil = none.
    public static func focusImage(_ request: ChatRequest) -> String? {
        guard let ctx = request.turnContext, let r = ctx.range(of: #"image_id "[^"]+""#, options: .regularExpression) else { return nil }
        return String(ctx[r].dropFirst(10).dropLast())
    }

    /// Q-015 r5: the newest `"artifact_id":"<id>"` a file-out tool result in the prompt names (`{{artifact}}` in a
    /// script), as a model copies it into `revises` to make version 2 (R-273 AC4); nil = none.
    public static func lastArtifact(_ request: ChatRequest) -> String? {
        // The turn context's "Files made in this chat: … artifact_id "<id>" …" line (newest first), as a model reads it.
        if let ctx = request.turnContext, let r = ctx.range(of: #"artifact_id "[^"]+""#, options: .regularExpression) {
            return String(ctx[r].dropFirst(13).dropLast())
        }
        for m in request.flattenedMessages.reversed() {
            var found: Range<String.Index>?
            var from = m.content.startIndex
            while let r = m.content.range(of: #""artifact_id"\s*:\s*"[^"]+""#, options: .regularExpression, range: from..<m.content.endIndex) {
                found = r
                from = r.upperBound
            }
            guard let r = found else { continue }
            let hit = m.content[r]
            guard let q = hit.dropLast().lastIndex(of: "\"") else { continue }
            return String(hit[hit.index(after: q)..<hit.index(before: hit.endIndex)])
        }
        return nil
    }

    public static func forcedTool(_ request: ChatRequest) -> String? {
        switch request.toolChoice {
        case .function(let n)?: n
        case .required?: request.tools.first?.name
        default: nil
        }
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    static func ms(_ d: Duration) -> Double { secs(d) * 1000 }
}
