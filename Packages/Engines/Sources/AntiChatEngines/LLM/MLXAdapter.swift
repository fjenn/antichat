// MLXAdapter (M0.T04 step 3; P-shell-09 mlx-swift-lm @ f5b0677).
// APIs used at f5b0677 (recorded for the S-3 report):
//   - load: `LLMModelFactory.shared.loadContainer(from: URL, using: any TokenizerLoader)` and
//     `VLMModelFactory.shared.loadContainer(from:using:)` (Libraries/MLXLMCommon/ModelFactory.swift:206).
//     The PRD's `loadContainer(configuration: ModelConfiguration(directory:))` is the 2.x shape; 3.x
//     takes the directory plus a TokenizerLoader (A-M0-13).
//   - prepare: `ModelContainer.prepare(input: UserInput)` → `LMInput` (ModelContainer.swift:166).
//   - generate: `generate(input:cache:state:parameters:context:components:wiredMemoryTicket:tools:)
//     -> AsyncStream<Generation>` (Evaluate.swift:2129) inside `ModelContainer.perform(_:)`.
//   - `Generation {.chunk, .reasoning, .info, .toolCall, .rejectedToolCall}` (Evaluate.swift:3171).
//   - tier cap: `Memory.memoryLimit` / `Memory.cacheLimit` (mlx-swift Memory.swift:290) and a
//     `WiredMemoryTicket(size:policy: WiredFixedPolicy(limit:), manager: .shared, kind: .active)`
//     passed as `wiredMemoryTicket` (mlx-swift WiredMemory.swift:250, MLXLMCommon WiredMemoryPolicies.swift:101).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Metal
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// swift-transformers → MLXLMCommon tokenizer bridge (same shape as mlx-swift-lm's
/// `#adaptHuggingFaceTokenizer` macro, Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift:68).
struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

public struct TransformersTokenizerLoader: TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

public enum MemoryProbe {
    /// `MTLCreateSystemDefaultDevice()!.recommendedMaxWorkingSetSize` (K-002).
    public static var recommendedMaxWorkingSetSize: UInt64 {
        MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0
    }

    public static var mtlAllocatedBytes: UInt64 {
        UInt64(MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0)
    }
}


/// Generation → EngineEvent mapping (M1.T05 step 2), a value type so it is unit-testable without a GPU:
/// `.chunk` → textDelta, `.reasoning` → reasoningDelta, `.toolCall` → toolCallDelta + toolCallDone, `.info` →
/// usage (+ the finish reason for the terminal `done`). `.rejectedToolCall` is dropped (counted in `info`).
public struct MLXEventMapper: Sendable {
    public let receivedAt: ContinuousClock.Instant
    public let loadTime: Double?
    public private(set) var firstContentAt: ContinuousClock.Instant?
    public private(set) var toolCalls = 0
    public private(set) var stopReason: GenerateStopReason?
    /// M6.T21: the last rejected call (tool name, reason), reported in `usage` (`rejectedToolName/Reason`).
    public private(set) var lastRejected: (name: String?, reason: String)?
    /// M1.T14 prefix reuse: the whole prompt's token count, the tokens served from a kept cache, and the prefill
    /// seconds spent outside `generate` (stable/session boundaries). nil = `generate` saw the whole prompt.
    public var prefix: (totalTokens: Int, reusedTokens: Int, extraPrefillSeconds: Double)?

    public init(receivedAt: ContinuousClock.Instant = .now, loadTime: Double? = nil) {
        self.receivedAt = receivedAt
        self.loadTime = loadTime
    }

    public mutating func map(
        _ g: Generation, now: ContinuousClock.Instant = .now, gpuPeakBytes: UInt64 = 0, mtlAllocatedBytes: UInt64 = 0
    ) -> [EngineEvent] {
        switch g {
        case .chunk(let s):
            if firstContentAt == nil { firstContentAt = now }
            return [.textDelta(s)]
        case .reasoning(let s):
            if firstContentAt == nil { firstContentAt = now }
            return [.reasoningDelta(s)]
        case .toolCall(let call):
            if firstContentAt == nil { firstContentAt = now }
            toolCalls += 1
            let id = "call_\(toolCalls)"
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            let args = (try? enc.encode(call.function.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            // mlx-swift-lm parses a call only once it is complete, so the one delta carries the whole argument text.
            return [
                .toolCallDelta(id: id, name: call.function.name, argsFragment: args),
                .toolCallDone(id: id, name: call.function.name, argsJSON: args),
            ]
        case .rejectedToolCall(let r):
            // Counted in `usage.toolCallsRejected`; the reason (no argument text) goes to the engine log.
            lastRejected = (r.toolName ?? Self.toolName(inPreview: r.rawTextPreview), r.reason.rawValue)
            AppLog.log(.engine, .info, "tool.rejected reason=\(r.reason.rawValue) tool=\(r.toolName ?? "-") detail=\(r.detail ?? "-")")
            #if DEBUG
                AppLog.content(.engine, .debug, "tool.rejected preview=\(r.rawTextPreview.prefix(600))")
                // AT-273 round 65: the end too — a call cut at the budget shows there whether the model looped.
                AppLog.content(.engine, .debug, "tool.rejected tail=\(r.rawTextPreview.suffix(600)) bytes=\(r.rawTextByteCount)")
            #endif
            return []
        case .steering:
            return []  // mid-turn steering (mlx-swift-lm #608, ChatSession only): AntiChat does not steer
        case .info(let info):
            stopReason = info.stopReason
            let ttft = firstContentAt.map { EngineTime.ms($0 - receivedAt) } ?? EngineTime.ms(now - receivedAt)
            return [
                .usage(
                    Usage(
                        promptTokens: prefix?.totalTokens ?? info.totalPromptTokenCount,
                        completionTokens: info.generationTokenCount,
                        cachedTokens: prefix?.reusedTokens ?? info.cachedPromptTokenCount, ttftMs: ttft,
                        promptTime: info.promptTime + (prefix?.extraPrefillSeconds ?? 0),
                        generateTime: info.generateTime, loadTime: loadTime, gpuPeakBytes: gpuPeakBytes,
                        mtlAllocatedBytes: mtlAllocatedBytes))
            ]
        }
    }

    /// The function name in a rejected call's raw text (`<function=name>` or `"name": "name"`), nil when absent.
    static func toolName(inPreview text: String) -> String? {
        for pattern in [#"<function=([A-Za-z0-9_.\-]+)>"#, #""name"\s*:\s*"([A-Za-z0-9_.\-]+)""#] {
            if let r = text.range(of: pattern, options: .regularExpression) {
                let m = String(text[r])
                if let q = m.range(of: #"[A-Za-z0-9_.\-]+(?=>$|"$)"#, options: .regularExpression) { return String(m[q]) }
            }
        }
        return nil
    }

    /// The terminal event once the generation stream ended.
    public func finish(cancelled: Bool) -> EngineEvent {
        if cancelled { return .done(.cancelled) }
        switch stopReason {
        case .length: return .done(.length)
        case .cancelled: return .done(.cancelled)
        case .stop, .steered, nil: return .done(toolCalls > 0 ? .toolCalls : .stop)
        }
    }
}

/// mlx-swift-lm adapter (M1.T05 step 2), promoted from the M0.T04 spike. Cancellation = cancelling the consumer:
/// the stream's termination cancels the generation task, which ends mlx-swift-lm's token loop. API churn at a
/// pin bump stays in this file (K-NEW-ENG-7); bumps go through M1.T13's conformance suite.
public actor MLXAdapter: EngineAdapter {
    public nonisolated let kind = EngineKind.mlx
    /// The model of the last load or generation (the "current" one; M2.T15 may keep a second one warm).
    public private(set) var loadedKey: String?
    /// M2.T15 (E.2.7 "warm if fits"): up to `maxResident` containers stay loaded (2 on T3+ with the warm second
    /// variant, else 1). The scheduler decides which go; `load` only enforces the cap.
    private var containers: [String: ModelContainer] = [:]
    private var loadOrder: [String] = []
    public private(set) var maxResident = 1
    private var container: ModelContainer? { loadedKey.flatMap { containers[$0] } }
    private var budgetB: UInt64 = 0
    private var ticket: WiredMemoryTicket?
    /// M1.T14: per-session / per-stable-prefix KV snapshots (MLXPrefixCache.swift).
    let prefixCache = MLXPrefixCache()
    /// Off = every request prefills its whole prompt (the M0/T05 behaviour; A-M0-11 baseline runs).
    public var prefixReuse = true
    /// M1.T13: compiled tool-call grammars per (model, tool set).
    private let grammarCache = ToolGrammarCache()

    public init() {}

    public func setPrefixReuse(_ on: Bool) {
        prefixReuse = on
        if !on { prefixCache.clear() }
    }

    /// MLX's freed-buffer pool cap for budget B: 10 % of B (M2.md T12 step 3). fix/soak-engine: it was B/4 (the M0 spike
    /// value): 2.4 GB of freed buffers at the T1 cap could stay in the helper's footprint beside the chat model (NFR-R1).
    public static func cacheLimit(budget bytes: UInt64) -> Int { Int(bytes / 10) }

    /// The cache limit this adapter set (bytes; -1 = none set yet), for the usage diagnostics.
    private var cacheLimitInForce = -1

    /// Tier cap (M0.md C5): MLX allocation limit and wired limit = B; cache limit B/10 (M2 step 3). 0 = no cap.
    public func setBudget(_ bytes: UInt64) {
        budgetB = bytes
        guard bytes > 0 else { return }
        Memory.memoryLimit = Int(bytes)
        Memory.cacheLimit = Self.cacheLimit(budget: bytes)
        cacheLimitInForce = Self.cacheLimit(budget: bytes)
        ticket = WiredMemoryTicket(size: Int(bytes), policy: WiredFixedPolicy(limit: Int(bytes)), manager: .shared, kind: .active)
    }

    public var isLoaded: Bool { !containers.isEmpty }

    /// M2.T15: whether `key` is one of the resident containers.
    public func holds(_ key: String) -> Bool { containers[key] != nil }
    public var residentKeys: [String] { loadOrder }

    /// M2.T15 WarmVariant: 2 on T3+ when the second chat variant may stay warm, else 1.
    public func setMaxResident(_ n: Int) {
        maxResident = max(1, n)
        while containers.count > maxResident, let oldest = loadOrder.first(where: { $0 != loadedKey }) ?? loadOrder.first {
            unloadNow(key: oldest)
        }
    }

    /// Identity of the loaded `ModelContainer` (M0.T06 step 6: "container unchanged" = no reload).
    public var containerID: String {
        container.map { String(describing: ObjectIdentifier($0)) } ?? "none"
    }

    /// M2.T13: the open chats' KV prefixes to disk before this model steps aside (PromptCacheSnapshot).
    @discardableResult
    public func snapshotSessions(model: String, to dir: URL) -> Int {
        guard containers[model] != nil else { return 0 }
        // M9.T05: the stable system prefixes too (written once per prefix; a new chat after the reload reuses them).
        PromptCacheSnapshot.savePrefixes(prefixCache, model: model, to: dir)
        return PromptCacheSnapshot.save(prefixCache, model: model, to: dir).count
    }

    /// M2.T13: after a reload, the snapshots written for this model come back (others are discarded).
    /// M9.T05: and its stable system prefixes (kept on disk for the next reload).
    @discardableResult
    public func restoreSnapshots(model: String, from dir: URL) -> Int {
        if prefixReuse { PromptCacheSnapshot.restorePrefixes(into: prefixCache, model: model, from: dir, limit: prefixCache.maxPrefixes) }
        return PromptCacheSnapshot.restore(into: prefixCache, model: model, from: dir).count
    }

    /// Drop MLX's freed-buffer pool (memory-pressure warning tier, ResidencyHost.trimCaches).
    /// M6.T03: pinned document prefixes held now.
    public var pinnedPrefixCount: Int { prefixCache.pinnedSessions.count }

    public func trimCache() {
        prefixCache.dropSessions()
        Memory.clearCache()
    }

    /// fix/soak-engine: only MLX's freed-buffer pool (before a load on T0–T2); the prefix-cache sessions stay.
    public func clearBufferPool() {
        Memory.clearCache()
    }

    @discardableResult
    public func load(_ slot: ModelSlot) async throws -> Double {
        if containers[slot.key] != nil {
            loadedKey = slot.key  // warm second variant: the swap is a pointer change (NFR-C7 T3 ≤ 1.5 s)
            return 0
        }
        while containers.count >= maxResident, let oldest = loadOrder.first { unloadNow(key: oldest) }
        let url = URL(fileURLWithPath: slot.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
            throw AntiChatError(.modelMissing, detail: slot.key)
        }
        let start = ContinuousClock.now
        let loader = TransformersTokenizerLoader()
        let loaded: ModelContainer
        do {
            if slot.vision {
                loaded = try await VLMModelFactory.shared.loadContainer(from: url, using: loader)
            } else {
                loaded = try await LLMModelFactory.shared.loadContainer(from: url, using: loader)
            }
        } catch {
            throw AntiChatError(.modelCorrupt, detail: "\(slot.key): \(error)")
        }
        containers[slot.key] = loaded
        loadOrder.append(slot.key)
        loadedKey = slot.key
        return EngineTime.secs(ContinuousClock.now - start)
    }

    public func unload() async { unloadNow() }

    /// M2.T15: unloads one container (the scheduler's eviction of one MLX model); the other stays warm.
    public func unload(key: String) async { unloadNow(key: key) }

    private func unloadNow() {
        prefixCache.clear()
        containers.removeAll()
        loadOrder.removeAll()
        loadedKey = nil
        Memory.clearCache()
    }

    private func unloadNow(key: String) {
        guard containers[key] != nil else { return }
        // Prefix entries are keyed by model, but a session snapshot is not: drop all (as a full unload did).
        prefixCache.clear()
        containers[key] = nil
        loadOrder.removeAll { $0 == key }
        if loadedKey == key { loadedKey = loadOrder.last }
        Memory.clearCache()
    }

    /// `history: true` renders the request without `turnContext` (the next turn's view of this prompt, D-022).
    static func chat(_ request: ChatRequest, history: Bool = false) -> [Chat.Message] {
        let msgs = history ? request.flattenedHistory : request.flattenedMessages
        if !history, case let n = msgs.reduce(0, { $0 + $1.imagePaths.count }), n > 0 {
            AppLog.log(.engine, .info, "vision_parts=\(n) model=\(request.modelSlot.key)")  // M6.T05 (AT-021 check 1)
        }
        return msgs.map { m in
            let images = m.imagePaths.map { UserInput.Image.url(URL(fileURLWithPath: $0)) }
            switch m.role {
            case .system: return .system(m.content)
            // M1.T16: a tool-loop step's calls go to the template's native `tool_calls` slot; results carry their
            // call id and tool name (`tool_call_id` / `name`).
            case .assistant:
                return .assistant(m.content, toolCalls: m.toolCalls.isEmpty ? nil : m.toolCalls.map(Self.toolCall))
            case .tool: return .tool(m.content, id: m.toolCallID, name: m.toolName)
            case .user: return .user(m.content, images: images)
            }
        }
    }

    static func toolCall(_ c: ToolCallRef) -> ToolCall {
        let args = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(c.argumentsJSON.utf8))) ?? [:]
        return ToolCall(function: .init(name: c.name, arguments: args), id: c.id)
    }

    static func toolSpecs(_ tools: [ToolSchema]) -> [ToolSpec]? {
        tools.isEmpty ? nil : tools.map { sendableDict($0.openAIObject) }
    }

    public func generate(_ request: ChatRequest, context: GenerationContext) async throws -> AsyncStream<AdapterOutput> {
        guard let container = containers[request.modelSlot.key] else {
            throw AntiChatError.model("notLoaded", request.modelSlot.key)
        }
        loadedKey = request.modelSlot.key
        // tool_choice none = no tools offered to the template (OpenAI semantics).
        let offered = request.toolChoice == ToolChoice.none ? [] : request.tools
        let tools = Self.toolSpecs(offered)
        var extra: [String: any Sendable] = ["enable_thinking": request.reasoning.on]
        if let b = request.reasoning.budget { extra["thinking_budget"] = b }
        let chat = Self.chat(request)
        let input = UserInput(chat: chat, tools: tools, additionalContext: extra)
        let (progress, progressCont) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(64))
        var params = GenerateParameters(
            maxTokens: request.sampling.maxTokens, temperature: request.sampling.temperature,
            topP: request.sampling.topP, topK: request.sampling.topK, seed: request.sampling.seed)
        // R2 review P1-2: after a prefix-cache prefill the suffix's progress continues the whole uncached prompt's.
        let scale = PrefillScale()
        params.prefill.progress = { done, total in
            progressCont.yield(scale.fraction(done, of: total))
        }
        let ticket = self.ticket
        let cacheLimitNow = self.cacheLimitInForce  // M9.T05 diagnostics (read inside the generation task)
        let p = params
        let lmInput: LMInput
        do {
            lmInput = try await container.prepare(input: input)
        } catch {
            progressCont.finish()
            throw AntiChatError.engine("mlxPrepare", "\(error)")
        }
        let reuse = prefixReuse && !MLXPrefixCache.hasMedia(request) && lmInput.image == nil && lmInput.video == nil
        let templateContext = extra
        let prefixCache = self.prefixCache
        // The prefix snapshot is keyed by the tools the template actually rendered (none under tool_choice none).
        var cacheRequest = request
        cacheRequest.tools = offered
        let keyedRequest = cacheRequest
        // M1.T13 step 2: lazy grammar over the tool-call span (GrammarBuilder; nil for unconstrainable dialects).
        // The processor ignores the prompt tokens, so it composes with the M1.T14 prefix reuse (suffix-only input).
        let grammarStats = ToolGrammarStats()
        let grammarCache = self.grammarCache
        let modelKey = request.modelSlot.key
        let slotPath = request.modelSlot.path
        let thinking = request.reasoning.on
        // M2.T22: `tool_choice` = a function (chip, fallback re-ask) / `required` → the call opens at once and its
        // grammar admits only the named tool (all offered tools for `required`). The template still renders every tool.
        let forced: Bool
        let grammarTools: [ToolSchema]
        switch request.toolChoice {
        case .function(let n)?:
            let only = offered.filter { $0.name == n }
            (forced, grammarTools) = (!only.isEmpty, only.isEmpty ? offered : only)
        case .required?: (forced, grammarTools) = (!offered.isEmpty, offered)
        default: (forced, grammarTools) = (false, offered)
        }
        // R2 review P1-2: the prefill (the prefix cache's and the prompt's own, both inside `perform`) runs inside the
        // returned stream, so its progress reaches the turn live; before, `generate` returned only after the whole
        // prefill and its progress arrived at once, so a long prefill was silence to the turn's stall watchdog.
        // A failure there is the stream's terminal error (the adapter contract: throws only before streaming).
        let ctx = context
        let lmBox = UncheckedSendableBox(lmInput)
        // AT-273 round 65: every generated token is a pulse; a `generating` lifecycle event goes out when nothing else
        // did for a second (the tokens of a tool call, which mlx-swift-lm hands over only once the call is complete).
        let pulse = GenerationPulse()
        return AsyncStream<AdapterOutput>(bufferingPolicy: .unbounded) { cont in
            pulse.onPulse = { n in cont.yield(.lifecycle(.generating(tokens: n))) }
            let task = Task {
                // Prefill progress precedes the first token; forwarding stops at the first content event so
                // no lifecycle item lands after content it preceded.
                let progressTask = Task {
                    for await v in progress { cont.yield(.lifecycle(.prefillProgress(v))) }
                }
                let stream: AsyncStream<Generation>, plan: MLXPrefixCache.Plan?, constrained: Bool
                do {
                    (stream, plan, constrained) = try await container.perform(nonSendable: lmBox.value) { ctx, lmInput in
                        let components = Self.toolGrammarComponents(
                            tools: grammarTools, context: ctx, modelKey: modelKey, modelPath: slotPath, startsInThink: thinking,
                            cache: grammarCache, stats: grammarStats, forced: forced)
                        let eos = ctx.tokenizer.eosTokenId
                        // S3 review: the runaway guard watches tool-call spans only (a file call's table is capped at 40
                        // rows); a plain answer, however long and uniform (a several-hundred-row table), is never cut.
                        let span: (open: Int?, close: Int?) = offered.isEmpty ? (nil, nil) : Self.toolCallTagIDs(context: ctx, modelPath: slotPath)
                        let pulsed = (components ?? .init()).appendingLogitProcessor {
                            GenerationPulse.Processor(pulse: pulse, eosID: eos, callOpenID: span.open, callCloseID: span.close)
                        }
                        guard reuse else {
                            let s = try MLXLMCommon.generate(
                                input: lmInput, parameters: p, context: ctx, components: pulsed,
                                wiredMemoryTicket: ticket, tools: tools)
                            return (s, nil, components != nil)
                        }
                        let r = try await prefixCache.prepare(
                            request: keyedRequest, tokens: lmInput.text.tokens.asArray(Int.self), context: ctx, parameters: p,
                            chat: Self.chat(keyedRequest, history: true), tools: tools, extra: templateContext,
                            progress: { done, whole in progressCont.yield(whole > 0 ? min(1, Double(done) / Double(whole)) : 1) })
                        scale.set(offset: r.plan.totalTokens - r.plan.reusedTokens - r.suffix.count,
                                  whole: r.plan.totalTokens - r.plan.reusedTokens)
                        let s = try MLXLMCommon.generate(
                            input: LMInput(tokens: MLXArray(r.suffix)), cache: r.cache, state: r.state, parameters: p, context: ctx,
                            components: pulsed, wiredMemoryTicket: ticket, tools: tools)
                        return (s, r.plan, components != nil)
                    }
                } catch {
                    progressCont.finish()
                    await progressTask.value
                    cont.yield(.event(Task.isCancelled ? .done(.cancelled)
                        : .error((error as? AntiChatError) ?? AntiChatError.engine("internal", "\(error)"))))
                    cont.finish()
                    return
                }
                Memory.peakMemory = 0  // the setter resets the peak (mlx_reset_peak_memory)
                let (cacheAtStart, activeAtStart) = (Memory.cacheMemory, Memory.activeMemory)  // M9.T05 diagnostics
                var mapper = MLXEventMapper(receivedAt: ctx.receivedAt, loadTime: ctx.loadTime)
                if let plan { mapper.prefix = (plan.totalTokens, plan.reusedTokens, plan.extraPrefillSeconds) }
                for await g in stream {
                    if Task.isCancelled { break }
                    var alloc: UInt64 = 0
                    if case .info = g { alloc = MemoryProbe.mtlAllocatedBytes }
                    var events = mapper.map(g, gpuPeakBytes: UInt64(max(0, Memory.peakMemory)), mtlAllocatedBytes: alloc)
                    if case .info = g {
                        let limit = cacheLimitNow
                        events = events.map { e in
                            guard case .usage(var u) = e else { return e }
                            (u.mlxCacheBytesStart, u.mlxActiveBytesStart) = (cacheAtStart, activeAtStart)
                            (u.mlxCacheBytesEnd, u.mlxActiveBytesEnd, u.mlxCacheLimitBytes) = (Memory.cacheMemory, Memory.activeMemory, limit)
                            return .usage(u)
                        }
                    }
                    if !offered.isEmpty, case .info(let info) = g {
                        events = events.map { e in
                            guard case .usage(var u) = e else { return e }
                            u.toolCallsConstrained = constrained ? min(grammarStats.completed, mapper.toolCalls) : 0
                            u.toolCallsRejected = info.rejectedToolCallCount
                            if info.rejectedToolCallCount > 0, let r = mapper.lastRejected {
                                (u.rejectedToolName, u.rejectedToolReason) = (r.name, r.reason)
                            }
                            return .usage(u)
                        }
                    }
                    if case .info = g, pulse.stoppedLooping {  // AT-273 round 65: the length end below is a runaway
                        events = events.map { e in
                            guard case .usage(var u) = e else { return e }
                            u.stoppedRepeating = true
                            return .usage(u)
                        }
                    }
                    if !events.isEmpty, mapper.firstContentAt != nil || alloc > 0 {
                        progressCont.finish()
                        await progressTask.value
                    }
                    if !events.isEmpty { pulse.contentSent() }
                    for e in events { cont.yield(.event(e)) }
                }
                pulse.onPulse = nil
                progressCont.finish()
                await progressTask.value
                // AT-273 round 65: a generation the repetition guard ended was cut off, not finished.
                cont.yield(.event(pulse.stoppedLooping && !Task.isCancelled && mapper.toolCalls == 0
                    ? .done(.length) : mapper.finish(cancelled: Task.isCancelled)))
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// The token ids that open and close a tool call in this model's dialect (nil when the tag is not one token).
    static func toolCallTagIDs(context ctx: ModelContext, modelPath: String) -> (open: Int?, close: Int?) {
        var format = ToolFormat(upstream: ctx.configuration.toolCallFormat)
        if format == .none || format == .other { format = ToolFormat.detect(modelDirectory: URL(fileURLWithPath: modelPath)) }
        return (format.openTag.flatMap { ctx.tokenizer.convertTokenToId($0) },
                format.closeTag.flatMap { ctx.tokenizer.convertTokenToId($0) })
    }

    /// The lazy tool grammar for this request, or nil (no tools, dialect not constrainable, ids not in the vocab).
    static func toolGrammarComponents(
        tools: [ToolSchema], context ctx: ModelContext, modelKey: String, modelPath: String, startsInThink: Bool,
        cache: ToolGrammarCache, stats: ToolGrammarStats, forced: Bool = false
    ) -> GenerationComponents? {
        guard !tools.isEmpty else { return nil }
        var format = ToolFormat(upstream: ctx.configuration.toolCallFormat)
        if format == .none || format == .other { format = ToolFormat.detect(modelDirectory: URL(fileURLWithPath: modelPath)) }
        guard let open = format.openTag, let trigger = ctx.tokenizer.convertTokenToId(open), let eos = ctx.tokenizer.eosTokenId
        else { return nil }
        let tokenizer = ctx.tokenizer
        let thinkOpen = tokenizer.convertTokenToId("<think>"), thinkClose = tokenizer.convertTokenToId("</think>")
        // Build the compiled grammar now (vocab extraction once per model), not on the first trigger.
        let tag = GrammarBuilder.structuralTag(format: format, tools: tools)
            .flatMap { cache.prepare(modelKey: modelKey, tokenizer: tokenizer, tag: $0) ? $0 : nil }
        // AT-273 (xlsx-18 follow-up): a forced `tool_choice` is enforced even without a grammar (a dialect the builder
        // cannot constrain, e.g. Gemma 4, or a failed compile): the opening tag is still the first token outside
        // reasoning, so the step is a call, not a text answer; only the body is unconstrained.
        guard tag != nil || forced else { return nil }
        let make = tag.map { tag in { @Sendable in cache.checkout(modelKey: modelKey, tokenizer: tokenizer, tag: tag) } }
        return GenerationComponents(logitProcessorFactory: {
            LazyToolGrammarProcessor(
                triggerID: trigger, thinkOpenID: thinkOpen, thinkCloseID: thinkClose, eosID: eos,
                startsInThink: startsInThink && thinkOpen != nil, stats: stats, forced: forced,
                make: make, release: { c in if let tag { cache.checkin(c, tag: tag) } })
        })
    }

    static func sendableDict(_ d: [String: Any]) -> [String: any Sendable] {
        var out: [String: any Sendable] = [:]
        for (k, v) in d { out[k] = sendableValue(v) }
        return out
    }

    static func sendableValue(_ v: Any) -> any Sendable {
        switch v {
        case let d as [String: Any]: return sendableDict(d)
        case let a as [Any]: return a.map { sendableValue($0) }
        case let s as String: return s
        case let n as NSNumber:
            // JSONSerialization numbers: keep booleans and integers (tool schemas use both).
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if CFNumberIsFloatType(n) { return n.doubleValue }
            return n.intValue
        default: return "\(v)"
        }
    }
}

/// AT-273 round 65: generation liveness. `Processor` (appended to the request's logit processors, a no-op on the
/// logits) counts every sampled token — also the ones inside a tool call, which mlx-swift-lm's tool-call handler keeps
/// until the call is complete — and `onPulse` gets the running count when no content event went out for `interval`.
/// A real hang (no token at all) sends nothing, so the turn's stall watchdog still ends it.
final class GenerationPulse: @unchecked Sendable {
    static let interval: Duration = .seconds(1)
    private let lock = NSLock()
    private var tokens = 0
    private var quietSince: ContinuousClock.Instant = .now
    private var callback: (@Sendable (Int) -> Void)?
    private let interval: Duration

    init(interval: Duration = GenerationPulse.interval) { self.interval = interval }

    var onPulse: (@Sendable (Int) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }

    var count: Int { lock.withLock { tokens } }

    /// One generated token.
    func tick(now: ContinuousClock.Instant = .now) {
        let fire: (@Sendable (Int) -> Void, Int)? = lock.withLock {
            tokens += 1
            guard let callback, now - quietSince >= interval else { return nil }
            quietSince = now
            return (callback, tokens)
        }
        if let fire { fire.0(fire.1) }
    }

    /// A content event (delta, tool call, usage) went out: that is liveness already.
    func contentSent(now: ContinuousClock.Instant = .now) { lock.withLock { quietSince = now } }

    /// AT-273 round 65: the generation was stopped because it looped (`RepetitionGuard`); the stream then ends as cut
    /// off (`done(length)`), so the turn's cut-off retry asks for a shorter call instead of waiting for the token budget.
    var stoppedLooping: Bool { lock.withLock { looped } }
    private var looped = false
    func markLooped() { lock.withLock { looped = true } }

    /// Counts tokens for the pulse (every generation) and watches tool-call spans for a degenerate loop
    /// (`ToolCallRepetitionGuard`). Logits are untouched until a loop is found; then the end-of-sequence token is the
    /// only choice, which ends the generation on the next step.
    final class Processor: LogitProcessor {
        let pulse: GenerationPulse
        let eosID: Int?
        let callOpenID: Int?
        let callCloseID: Int?
        private var history: [MLXArray] = []
        private var guardrail: ToolCallRepetitionGuard
        private var stopping = false

        init(pulse: GenerationPulse, eosID: Int?, callOpenID: Int? = nil, callCloseID: Int? = nil) {
            self.pulse = pulse
            self.eosID = eosID
            self.callOpenID = callOpenID
            self.callCloseID = callCloseID
            guardrail = ToolCallRepetitionGuard(openID: callOpenID, closeID: callCloseID)
        }

        func copy() -> Processor { Processor(pulse: pulse, eosID: eosID, callOpenID: callOpenID, callCloseID: callCloseID) }

        func prompt(_ prompt: MLXArray) {}

        func process(logits: MLXArray) -> MLXArray {
            if !guardrail.watches {
                // No tool call can open (plain chat, or a dialect without a one-token tag): the guard is off.
                if history.count > 1 { history.removeFirst(history.count - 1) }
                return logits
            }
            // Tokens up to count-2 are evaluated already (the sampler only has the newest one in flight): reading them
            // costs no GPU sync.
            while history.count > 1 {
                if guardrail.append(history.removeFirst().item(Int.self)) { stopping = true }
            }
            guard stopping, let eosID, eosID < logits.dim(-1) else { return logits }
            if !pulse.stoppedLooping {
                pulse.markLooped()
                AppLog.log(.engine, .notice, "generation.loop period=\(guardrail.period ?? 0) tokens=\(pulse.count): stopped")
            }
            let idx = MLXArray(Int32(0)..<Int32(logits.dim(-1)))
            let only = MLX.which(idx .== Int32(eosID), MLXArray(Float(0)), MLXArray(-Float.infinity))
            return MLX.broadcast(only, to: logits.shape).asType(logits.dtype)
        }

        func didSample(token: MLXArray) {
            history.append(token)
            pulse.tick()
        }
    }
}

/// S3 review (round 66 follow-up): `RepetitionGuard` over tool-call spans only. The runaways it exists for (T05 csv-06,
/// csv-16, csv-25, md-16) were all file calls, whose content is capped at 40 rows; in a plain answer a long uniform
/// table (several hundred rows the user asked for) is legitimate and must not end as `done(.length)`. The guard starts
/// fresh at each opening tag and stops watching at the closing tag; with no opening tag id it never watches.
struct ToolCallRepetitionGuard {
    let openID: Int?
    let closeID: Int?
    private(set) var inCall = false
    private(set) var guardrail = RepetitionGuard()
    private var looped = false

    init(openID: Int?, closeID: Int?) {
        self.openID = openID
        self.closeID = closeID
    }

    /// Whether any token can matter (a call can open).
    var watches: Bool { openID != nil }

    var period: Int? { guardrail.period }

    /// Adds one generated token; true once a loop inside a call span is found (and from then on).
    mutating func append(_ t: Int) -> Bool {
        if looped { return true }
        guard let openID else { return false }
        if t == openID {
            (inCall, guardrail) = (true, RepetitionGuard())
            return false
        }
        guard inCall else { return false }
        if t == closeID {
            inCall = false
            return false
        }
        looped = guardrail.append(t)
        return looped
    }
}

/// AT-273 round 65: degenerate output that can only run into the token budget. Two kinds, both seen on T1 in T05:
/// - an exact loop (csv-16 after its cut-off notice: the same four rows of prices again and again until the 8,192-token
///   file budget ran out, 232 s of GPU for a call that could never be complete): the last `max(3 × period, minRun)`
///   tokens equal the tokens one `period` earlier;
/// - a runaway near-loop (csv-06 "Item 1 … Item 220", the same row with a counter; csv-25 numbers growing by ",000" per
///   row; md-16 a table at row 1,170): over the last `nearWindow` tokens, at least `nearRatio` of them equal the token
///   one `period` earlier. That many tokens of one repeating shape is a table far past the 40 rows a file call may
///   hold (FileOutContext.sizeLine), never prose or code.
/// Real content does not repeat hundreds of tokens verbatim, and a table of up to 40 rows stays under `nearWindow`
/// (T05 csv-06: its 40-row retry, 9 columns, was 1,800 tokens).
struct RepetitionGuard {
    static let maxPeriod = 400
    static let minRun = 384
    static let nearWindow = 3072
    static let nearRatio = 0.7
    static let window = 4096
    static let checkEvery = 16
    private(set) var tokens: [Int] = []
    private(set) var period: Int?
    private var sinceCheck = 0
    private var sinceNear = 0

    /// Adds one token; true once a loop is found (and from then on).
    mutating func append(_ t: Int) -> Bool {
        if period != nil { return true }
        tokens.append(t)
        if tokens.count > Self.window * 2 { tokens.removeFirst(tokens.count - Self.window) }
        sinceCheck += 1
        sinceNear += 1
        guard sinceCheck >= Self.checkEvery, tokens.count > Self.minRun else { return false }
        sinceCheck = 0
        period = Self.loopPeriod(tokens)
        if period == nil, sinceNear >= Self.checkEvery * 4 {
            sinceNear = 0
            period = Self.nearLoopPeriod(tokens)
        }
        return period != nil
    }

    /// The period of an exact loop at the end of `t`, or nil.
    static func loopPeriod(_ t: [Int]) -> Int? {
        let n = t.count
        guard n > minRun else { return nil }
        for p in 1...max(1, min(maxPeriod, n / 3)) {
            let need = max(3 * p, minRun)
            guard need + p <= n else { break }
            var k = 0
            while k < need, t[n - 1 - k] == t[n - 1 - k - p] { k += 1 }
            if k == need { return p }
        }
        return nil
    }

    /// The period of a runaway near-loop at the end of `t` (see the type's note), or nil.
    static func nearLoopPeriod(_ t: [Int]) -> Int? {
        let n = t.count
        guard n >= nearWindow + maxPeriod else { return nil }
        let need = Int((Double(nearWindow) * nearRatio).rounded(.up))
        for p in 1...maxPeriod {
            var same = 0, left = nearWindow
            var i = n - 1
            while left > 0 {
                if t[i] == t[i - p] { same += 1 }
                if same >= need { return p }
                if same + left - 1 < need { break }  // cannot reach the ratio any more
                left -= 1
                i -= 1
            }
        }
        return nil
    }
}

/// R2 review P1-2: maps the prompt's own prefill progress (`done` of the suffix `generate` sees) onto the whole
/// uncached prompt once a prefix-cache prefill did the first part (`offset` of `whole` tokens).
final class PrefillScale: @unchecked Sendable {
    private let lock = NSLock()
    private var offset = 0
    private var whole: Int?

    func set(offset: Int, whole: Int) { lock.withLock { (self.offset, self.whole) = (max(0, offset), whole) } }

    func fraction(_ done: Int, of total: Int) -> Double {
        let (o, w) = lock.withLock { (offset, whole) }
        guard let w, w > 0 else { return total > 0 ? min(1, Double(done) / Double(total)) : 1 }
        return min(1, Double(o + done) / Double(w))
    }
}

/// Carries the prepared (non-Sendable) `LMInput` into the stream's task, which alone uses it (handed on to
/// `ModelContainer.perform(nonSendable:)`, as `generate` did before).
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
