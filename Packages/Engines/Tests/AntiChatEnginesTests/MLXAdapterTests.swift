// M1.T05 step 2 gate: `make test-unit FILTER=MLXAdapterTests` — Generation → EngineEvent mapping (pure) and the
// real adapter on `tiny-mlx-llm` (environment §5 stub model; MLX runs on the GPU, the Swift Build test bundle
// carries mlx-swift's default.metallib).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import MLXLMCommon
import Synchronization
import Testing
@testable import AntiChatEngines

enum TinyModel {
    static var dir: URL? {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { roots.append(URL(fileURLWithPath: env)) }
        roots.append(ScriptFixtures.repoRoot.appendingPathComponent("fixtures"))
        for r in roots {
            let d = r.appendingPathComponent("stub-models/tiny-mlx-llm")
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("config.json").path) { return d }
        }
        return nil
    }

    static var available: Bool { dir != nil }

    static var slot: ModelSlot { ModelSlot(engine: .mlx, key: "tiny-mlx-llm", path: dir?.path ?? "/missing") }
}

@Suite struct MLXEventMappingTests {
    @Test func mapsEveryGenerationCase() {
        var m = MLXEventMapper(receivedAt: .now, loadTime: 1.5)
        #expect(m.map(.reasoning("hmm")) == [.reasoningDelta("hmm")])
        #expect(m.map(.chunk("Hi")) == [.textDelta("Hi")])
        let call = ToolCall(function: .init(name: "echo", arguments: ["text": .string("hi")]))
        let args = #"{"text":"hi"}"#
        #expect(m.map(.toolCall(call)) == [
            .toolCallDelta(id: "call_1", name: "echo", argsFragment: args),
            .toolCallDone(id: "call_1", name: "echo", argsJSON: args),
        ])
        let info = GenerateCompletionInfo(
            promptTokenCount: 10, cachedPromptTokenCount: 30, generationTokenCount: 20, promptTime: 0.5, generationTime: 2,
            stopReason: .stop)
        let ev = m.map(.info(info))
        guard case .usage(let u)? = ev.first else { Issue.record("no usage"); return }
        #expect(u.promptTokens == 40)
        #expect(u.cachedTokens == 30)
        #expect(u.completionTokens == 20)
        #expect(u.tokPerSec == 10)
        #expect(u.loadTime == 1.5)
        #expect(u.ttftMs >= 0)
        #expect(m.finish(cancelled: false) == .done(.toolCalls))
    }

    @Test func finishReasons() {
        var m = MLXEventMapper()
        _ = m.map(.chunk("x"))
        #expect(m.finish(cancelled: false) == .done(.stop))
        #expect(m.finish(cancelled: true) == .done(.cancelled))
        _ = m.map(.info(GenerateCompletionInfo(promptTokenCount: 1, generationTokenCount: 4, promptTime: 0, generationTime: 0, stopReason: .length)))
        #expect(m.finish(cancelled: false) == .done(.length))
        // M9.T09: mlx-swift-lm #608 added `.steered` (a step ended to apply steering); AntiChat never steers, so it
        // ends like `.stop`.
        var s = MLXEventMapper()
        _ = s.map(.info(GenerateCompletionInfo(promptTokenCount: 1, generationTokenCount: 2, promptTime: 0, generationTime: 0, stopReason: .steered)))
        #expect(s.finish(cancelled: false) == .done(.stop))
    }

    /// M6.T21: a dropped (cut-off) call keeps its tool name and reason for `usage`; the name is read from the raw text
    /// when the parser did not name it.
    @Test func rejectedCallNameAndReason() {
        var m = MLXEventMapper()
        let raw = "<tool_call>\n<function=create_chart>\n<parameter=title>\nT\n</parameter>\n<parameter=vega_lite_spec>\n{\"mark\": {"
        #expect(m.map(.rejectedToolCall(RejectedToolCall(reason: .incompleteOutput, format: .json, rawText: raw))).isEmpty)
        #expect(m.lastRejected?.name == "create_chart" && m.lastRejected?.reason == "incomplete_output")
        #expect(MLXEventMapper.toolName(inPreview: #"<tool_call>{"name": "query_data", "arguments": {"sql"#) == "query_data")
        #expect(MLXEventMapper.toolName(inPreview: "<tool_call>{") == nil)
    }

    /// AT-273 round 65: every token is a pulse; `generating` goes out once a second of no content event, with the
    /// running token count (the tokens of a tool call, which MLX hands over only when the call is complete). No token,
    /// no pulse: a real hang stays silent for the stall watchdog.
    @Test func generationPulseReportsTokensDuringSilence() {
        let t0 = ContinuousClock.now
        let pulse = GenerationPulse(interval: .seconds(1))
        let got = Mutex<[Int]>([])
        pulse.onPulse = { n in got.withLock { $0.append(n) } }
        pulse.contentSent(now: t0)
        for i in 1...10 { pulse.tick(now: t0 + .milliseconds(90 * i)) }  // 0.9 s: quiet, but not for a second yet
        #expect(got.withLock { $0 }.isEmpty)
        pulse.tick(now: t0 + .milliseconds(1000))  // token 11 at 1.0 s
        #expect(got.withLock { $0 } == [11])
        pulse.tick(now: t0 + .milliseconds(1500))  // within a second of the last pulse
        #expect(got.withLock { $0 } == [11])
        pulse.contentSent(now: t0 + .milliseconds(1900))  // visible content restarts the quiet clock
        pulse.tick(now: t0 + .milliseconds(2500))
        #expect(got.withLock { $0 } == [11])
        pulse.tick(now: t0 + .milliseconds(2900))
        #expect(got.withLock { $0 } == [11, 14])
        #expect(pulse.count == 14)
        pulse.onPulse = nil  // the stream ended: later ticks send nothing
        pulse.tick(now: t0 + .seconds(10))
        #expect(got.withLock { $0 } == [11, 14])
    }

    /// AT-273 round 65 (T05 csv-16 retry): the same four rows of prices written over and over is a loop; a long table
    /// whose rows differ (an id or a date counting up) and prose are not.
    @Test func repetitionGuardFindsExactLoopsOnly() {
        // ~28 tokens per row, 4 rows repeating (period 112), after a 200-token preamble.
        let preamble = Array(1000..<1200)
        let rows = (0..<4).flatMap { r in (0..<28).map { 5000 + r * 100 + $0 } }
        var looping = RepetitionGuard()
        var stoppedAt: Int?
        for (i, t) in (preamble + Array(repeating: rows, count: 20).flatMap { $0 }).enumerated() where looping.append(t) {
            stoppedAt = i
            break
        }
        #expect(looping.period == 112, "\(String(describing: looping.period))")
        // Found within a few hundred tokens of the loop's start (3 × 112 = 336 repeated ≥ minRun 384 … + check step).
        #expect((stoppedAt ?? .max) < preamble.count + 112 + 384 + RepetitionGuard.checkEvery + 1, "\(String(describing: stoppedAt))")

        // A 40-row table (the size a file call may hold): the same row shape, the item number differs in every row (digit
        // tokens, as Qwen tokenises numbers) → not a loop, not a runaway.
        func row(_ n: Int) -> [Int] {
            let digits: [Int] = [10 + n / 100 % 10, 10 + n / 10 % 10, 10 + n % 10]
            var out: [Int] = []
            for k in 0..<6 {  // 42 tokens
                out.append(contentsOf: [100 + k, 200 + k, 300 + k])
                out.append(contentsOf: digits)
                out.append(400 + k)
            }
            return out
        }
        var table = RepetitionGuard()
        #expect(!(1...40).flatMap(row).contains { table.append($0) })
        #expect(table.period == nil)
        // Prose-like tokens (no fixed lag repeats): never.
        var prose = RepetitionGuard()
        var x = 12345
        let words = (0..<6000).map { _ in x = (x &* 1103515245 &+ 12345) & 0x7fffffff; return x % 30_000 }
        #expect(!words.contains { prose.append($0) })

        // T05 csv-06 "Item 1 … Item 220": the same row with a counter, far past 40 rows → a runaway, stopped long before
        // the 8,192-token budget.
        var runaway = RepetitionGuard()
        let inventory = (1...500).flatMap(row)
        let at = inventory.indices.first { runaway.append(inventory[$0]) }
        #expect(runaway.period == 42, "\(String(describing: runaway.period))")
        #expect(at.map { $0 < RepetitionGuard.nearWindow + RepetitionGuard.maxPeriod + 200 } == true, "\(String(describing: at))")

        // A short repeated line (period 2) needs the minimum run, not just 3 × 2 tokens.
        #expect(RepetitionGuard.loopPeriod(Array(0..<500) + Array(repeating: [1, 2], count: 10).flatMap { $0 }) == nil)
        #expect(RepetitionGuard.loopPeriod(Array(0..<500) + Array(repeating: [1, 2], count: 200).flatMap { $0 }) == 2)
    }

    /// S3 review: the runaway guard watches tool-call spans only. A plain-chat answer that is a long uniform Markdown
    /// table (500 rows, the same row shape with a counter: what the guard calls a runaway inside a file call) is never
    /// cut, whether tools were offered or not; the same rows inside a call are, and the guard starts fresh per call.
    @Test func repetitionGuardWatchesToolCallsOnly() {
        func row(_ n: Int) -> [Int] {  // "| Item 123 | 4 | 5.00 |" as tokens: a fixed shape, a counter in each row
            let digits: [Int] = [10 + n / 100 % 10, 10 + n / 10 % 10, 10 + n % 10]
            var out: [Int] = []
            for k in 0..<6 {  // 42 tokens
                out.append(contentsOf: [100 + k, 200 + k, 300 + k])
                out.append(contentsOf: digits)
                out.append(400 + k)
            }
            return out
        }
        let table = (1...500).flatMap(row)
        let open = 9001, close = 9002
        // Plain chat (no tools offered → no tag ids): never watched, never cut.
        var plain = ToolCallRepetitionGuard(openID: nil, closeID: nil)
        #expect(!plain.watches)
        #expect(!table.contains { plain.append($0) })
        // Tools offered, but the answer is text (no opening tag): not cut either.
        var text = ToolCallRepetitionGuard(openID: open, closeID: close)
        #expect(text.watches)
        #expect(!table.contains { text.append($0) })
        #expect(text.period == nil)
        // A long table before a call, then a short call: the text does not count against the call.
        var mixed = ToolCallRepetitionGuard(openID: open, closeID: close)
        let short: [Int] = (1...10).flatMap(row)
        let mixedTokens: [Int] = table + [open] + short + [close]
        #expect(!mixedTokens.contains { mixed.append($0) })
        #expect(!mixed.inCall)
        // The same rows inside a call: a runaway, stopped as before (round 66).
        var call = ToolCallRepetitionGuard(openID: open, closeID: close)
        let inCall = [open] + table
        let at = inCall.indices.first { call.append(inCall[$0]) }
        #expect(call.period == 42, "\(String(describing: call.period))")
        #expect(at.map { $0 < RepetitionGuard.nearWindow + RepetitionGuard.maxPeriod + 200 } == true, "\(String(describing: at))")
        let stays = call.append(1)
        #expect(stays)  // stays stopped
    }
}

@Suite(.serialized, .enabled(if: TinyModel.available, "fixtures/stub-models/tiny-mlx-llm missing (set ANTICHAT_FIXTURES or init the fixtures submodule)"))
struct MLXAdapterTests {
    static func collect(_ a: MLXAdapter, _ req: ChatRequest, stopAfter: Int? = nil) async throws -> [AdapterOutput] {
        var out: [AdapterOutput] = []
        for await o in try await a.generate(req, context: GenerationContext()) {
            out.append(o)
            if let n = stopAfter, out.count >= n { break }
        }
        return out
    }

    static func events(_ o: [AdapterOutput]) -> [EngineEvent] {
        o.compactMap { if case .event(let e) = $0 { e } else { nil } }
    }

    @Test func mapsATinyModelGenerationToTheContract() async throws {
        let a = MLXAdapter()
        let t = try await a.load(TinyModel.slot)
        #expect(t > 0)
        #expect(try await a.load(TinyModel.slot) == 0, "second load of the same slot is a no-op")
        let req = ChatRequest(
            modelSlot: TinyModel.slot, messages: [.layer(PromptLayer(id: "base", content: "You are AntiChat.")), .message(ChatMessage(role: .user, content: "Hello there"))],
            sampling: Sampling(temperature: 0, maxTokens: 12, seed: 1))
        let out = try await Self.collect(a, req)
        let ev = Self.events(out)
        #expect(ev.filter(\.isTerminal).count == 1)
        #expect(ev.last == .done(.stop) || ev.last == .done(.length))
        guard let ui = ev.firstIndex(where: { if case .usage = $0 { true } else { false } }), case .usage(let u) = ev[ui] else {
            Issue.record("no usage event"); return
        }
        #expect(ui == ev.count - 2, "usage comes right before done")
        #expect(u.promptTokens > 0)
        #expect(u.completionTokens > 0)
        #expect(u.completionTokens <= 12)
        let deltas = ev.filter(\.isDelta).count
        #expect(deltas > 0 && deltas <= u.completionTokens)
        // Lifecycle (prefill progress) only before the first content event.
        if let firstContent = out.firstIndex(where: { if case .event(let e) = $0 { e.isDelta } else { false } }) {
            #expect(!out[firstContent...].contains { if case .lifecycle = $0 { true } else { false } })
        }
        await a.unload()
        #expect(await a.loadedKey == nil)
    }

    /// R2 review P1-2: the prefix-cache prefill (the stable system prefix, run inside the adapter before the prompt's
    /// own suffix) reports progress too, over the whole uncached prompt, in order and before the first token. Before,
    /// only the suffix's own prefill reported (here a few tokens: 0 or 1, nothing in between).
    @Test func prefixCachePrefillReportsProgressBeforeTheFirstToken() async throws {
        let a = MLXAdapter()
        try await a.load(TinyModel.slot)
        let system = Array(repeating: "You are AntiChat, a careful local assistant.", count: 40).joined(separator: " ")
        let req = ChatRequest(
            modelSlot: TinyModel.slot, messages: [.layer(PromptLayer(id: "base", content: system)), .message(ChatMessage(role: .user, content: "Hi"))],
            sampling: Sampling(temperature: 0, maxTokens: 4, seed: 1))
        let out = try await Self.collect(a, req)
        let progress = out.compactMap { if case .lifecycle(.prefillProgress(let f)) = $0 { f } else { nil } }
        #expect(progress.contains { $0 > 0 && $0 < 0.99 }, "no partial prefill progress: \(progress)")
        #expect(progress == progress.sorted() && progress.allSatisfy { (0...1).contains($0) }, "\(progress)")
        if let firstContent = out.firstIndex(where: { if case .event(let e) = $0 { e.isDelta } else { false } }) {
            #expect(!out[firstContent...].contains { if case .lifecycle = $0 { true } else { false } })
        }
        #expect(Self.events(out).filter(\.isTerminal).count == 1)
        await a.unload()
    }

    @Test func consumerCancellationEndsTheGeneration() async throws {
        let a = MLXAdapter()
        try await a.load(TinyModel.slot)
        let req = ChatRequest(modelSlot: TinyModel.slot, messages: [ChatMessage(role: .user, content: "Count")], sampling: Sampling(temperature: 0.8, maxTokens: 4000, seed: 3))
        let stream = try await a.generate(req, context: GenerationContext())
        let task = Task { () -> Int in
            var n = 0
            for await _ in stream { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        // The stream ended because of the cancel (progress, not wall time: on a loaded host the tiny model may emit
        // only a few tokens either way): far fewer events than the 4000-token budget.
        let n = await task.value
        #expect(n < 4000, "\(n) events: the generation ran to its budget")
        // The adapter is usable right after a cancelled turn.
        let ev = Self.events(try await Self.collect(a, ChatRequest(modelSlot: TinyModel.slot, messages: [ChatMessage(role: .user, content: "Hi")], sampling: Sampling(temperature: 0, maxTokens: 4))))
        #expect(ev.filter(\.isTerminal).count == 1)
    }

    @Test func generateBeforeLoadThrowsAndMissingModelIsModelMissing() async throws {
        let a = MLXAdapter()
        await #expect(throws: AntiChatError.self) {
            _ = try await a.generate(ChatRequest(modelSlot: TinyModel.slot, messages: [ChatMessage(role: .user, content: "x")]), context: GenerationContext())
        }
        do {
            try await a.load(ModelSlot(engine: .mlx, key: "nope", path: "/nonexistent/model"))
            Issue.record("load of a missing model must throw")
        } catch let e as AntiChatError {
            #expect(e.is(.modelMissing))
        }
    }

    @Test func toolSchemasReachTheTemplate() async throws {
        let a = MLXAdapter()
        try await a.load(TinyModel.slot)
        let req = ChatRequest(
            modelSlot: TinyModel.slot, messages: [ChatMessage(role: .user, content: "Use echo")],
            tools: [ToolSchema(name: "echo", description: "Echo text", parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)],
            sampling: Sampling(temperature: 0, maxTokens: 8, seed: 1))
        let ev = Self.events(try await Self.collect(a, req))
        #expect(ev.filter(\.isTerminal).count == 1)
        guard case .usage(let u)? = ev.dropLast().last else { Issue.record("no usage"); return }
        // The tool block makes the prompt longer than the same turn without tools.
        let plain = Self.events(try await Self.collect(a, ChatRequest(modelSlot: TinyModel.slot, messages: [ChatMessage(role: .user, content: "Use echo")], sampling: Sampling(temperature: 0, maxTokens: 8, seed: 1))))
        guard case .usage(let p)? = plain.dropLast().last else { Issue.record("no usage"); return }
        #expect(u.promptTokens > p.promptTokens)
    }
}
