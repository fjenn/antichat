// MLX prefix reuse (M1.T14 step 4; R-230, R-269; G-010): the session's KV cache, kept between turns, keyed by
// the stable-prefix hash. mlx-swift-lm @f5b0677 `generate(input:cache:state:…)` (Evaluate.swift:2129) continues
// a cache that already holds a token prefix; this file decides which prefix that is.
//
// Two kinds of snapshot (copies of `[KVCache]` that hold an exact token prefix of an earlier prompt):
//   - prefix:  the stable system prefix (template tool slot + layers 1-5 + the day's date line), keyed by (model,
//              stable text, tools, thinking flag). Survives a new chat, a new minute and an edited history.
//   - session: the session's last prompt up to (not including) its ephemeral part — the generation prompt and the
//              newest user turn's `turnContext` (the time line, D-022) — so the next turn of the same chat, whose
//              history renders that user turn without it, prefills only the new assistant reply + user message.
// Only exact prefixes are reused (no trim), which is what hybrid caches (Qwen3.5 Gated-DeltaNet layers are not
// trimmable) allow; MLX arrays are immutable, so a snapshot is unaffected by the live cache's later updates.
// Requests with images skip reuse (a media placeholder renders the same tokens for different pixels).
import AntiChatEngineProtocol
import AntiChatFoundation
import CryptoKit
import Foundation
import MLX
import MLXLMCommon

final class MLXPrefixCache: @unchecked Sendable {
    struct Entry {
        var tokens: [Int]
        var cache: [KVCache]
        var state: LMOutput.State?
        var used: UInt64
        /// M6.T03: a pinned document prefix (ChatRequest.prefixPin) and when it was last used.
        var pin: PrefixPin? = nil
        var usedAt = Date()
        /// M9.T05: a stable prefix first built by an incognito request is never written to disk (PromptCacheSnapshot).
        var incognito = false
    }

    /// What one request reused and prefilled outside `generate` (merged into its `usage`).
    struct Plan: Sendable {
        var totalTokens: Int
        var reusedTokens: Int
        var extraPrefillSeconds: Double
        var source: String
    }

    private let lock = NSLock()
    private var prefixes: [String: Entry] = [:]
    private var sessions: [UUID: Entry] = [:]
    /// Tokens of the generation prompt (`<|im_start|>assistant\n<think>\n\n</think>\n\n` …) per (model, thinking).
    private var generationSuffix: [String: Int] = [:]
    private var clock: UInt64 = 0
    let maxPrefixes: Int
    let maxSessions: Int

    /// M6.T03: pinned-vs-LRU eviction (keep-alive, pressure, budget).
    var policy: PrefixCachePolicy

    init(maxPrefixes: Int = 4, maxSessions: Int = 2, policy: PrefixCachePolicy? = nil) {
        self.maxPrefixes = maxPrefixes
        self.maxSessions = maxSessions
        self.policy = policy ?? PrefixCachePolicy(maxSessions: maxSessions)
    }

    /// The policy's view of the session snapshots (caller holds the lock).
    private func policyEntries() -> [PrefixCachePolicy.Entry] {
        sessions.map { id, e in
            PrefixCachePolicy.Entry(id: id, pinned: e.pin != nil, priority: e.pin?.priority ?? 0, lastUsed: e.usedAt,
                                    incognito: incognito.contains(id))
        }
    }

    /// Pinned sessions (tests, the probe).
    var pinnedSessions: [UUID] { lock.withLock { sessions.filter { $0.value.pin != nil }.map(\.key) } }

    /// (b) keep-alive sweep; also runs on every store.
    func sweepIdle(now: Date = Date()) {
        lock.withLock { for id in policy.evictIdle(policyEntries(), now: now) { sessions.removeValue(forKey: id) } }
    }

    func clear() {
        lock.withLock {
            prefixes.removeAll()
            sessions.removeAll()
            generationSuffix.removeAll()
        }
    }

    /// Memory-pressure trim: session snapshots go first (they are the large ones), pinned document prefixes first of
    /// all (M6.T03, PrefixCachePolicy.evictOnPressure).
    func dropSessions() {
        lock.withLock { for id in policy.evictOnPressure(policyEntries()) { sessions.removeValue(forKey: id) } }
    }

    var counts: (prefixes: Int, sessions: Int) { lock.withLock { (prefixes.count, sessions.count) } }

    static func prefixKey(model: String, request: ChatRequest) -> String? {
        var stable: [String] = []
        for item in request.messages {
            guard case .layer(let l) = item, l.stable else { break }
            stable.append(l.content)
        }
        guard !stable.isEmpty || !request.tools.isEmpty else { return nil }
        let tools = request.tools.map { "\($0.name)\u{1}\($0.description)\u{1}\($0.parametersJSON)" }.joined(separator: "\u{2}")
        let raw = [model, request.reasoning.on ? "think" : "nothink", stable.joined(separator: "\n\n"), tools].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The stable system text of a request (its leading stable layers), as the template's system turn starts.
    static func stableSystemText(_ request: ChatRequest) -> String {
        var stable: [String] = []
        for item in request.messages {
            guard case .layer(let l) = item, l.stable else { break }
            stable.append(l.content)
        }
        return stable.joined(separator: "\n\n")
    }

    static func hasMedia(_ request: ChatRequest) -> Bool {
        !request.images.isEmpty || request.flattenedMessages.contains { !$0.imagePaths.isEmpty }
    }

    static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    // MARK: - Lookup / store (called inside ModelContainer.perform, serialised by the container)

    func bestSnapshot(tokens: [Int], session: UUID, prefixKey: String?) -> (entry: Entry, source: String)? {
        lock.withLock {
            var best: (Entry, String)?
            for id in policy.evictIdle(policyEntries()) where id != session { sessions.removeValue(forKey: id) }
            for (e, src) in [(sessions[session], "session"), (prefixKey.flatMap { prefixes[$0] }, "prefix")] {
                guard let e else { continue }
                let have = e.tokens.count, bestCount = best?.0.tokens.count ?? 0
                guard have < tokens.count, have > bestCount, tokens.starts(with: e.tokens) else { continue }
                best = (e, src)
            }
            guard var b = best else { return nil }
            clock += 1
            b.0.used = clock
            b.0.usedAt = Date()
            if b.1 == "session" { sessions[session] = b.0 } else if let k = prefixKey { prefixes[k] = b.0 }
            return b
        }
    }

    func hasPrefix(_ key: String) -> Bool { lock.withLock { prefixes[key] != nil } }

    func storePrefix(_ key: String, tokens: [Int], cache: [KVCache], state: LMOutput.State?, incognito: Bool = false) {
        lock.withLock {
            clock += 1
            prefixes[key] = Entry(tokens: tokens, cache: cache.map { $0.copy() }, state: state, used: clock, incognito: incognito)
            while prefixes.count > maxPrefixes, let old = prefixes.min(by: { $0.value.used < $1.value.used })?.key {
                prefixes.removeValue(forKey: old)
            }
        }
    }

    func storeSession(_ id: UUID, tokens: [Int], cache: [KVCache], state: LMOutput.State?, pin: PrefixPin? = nil,
                      now: Date = Date()) {
        lock.withLock {
            clock += 1
            let keptPin = pin ?? sessions[id]?.pin
            sessions[id] = Entry(tokens: tokens, cache: cache.map { $0.copy() }, state: state, used: clock, pin: keptPin,
                                 usedAt: now)
            for old in policy.evictAfterStore(policyEntries(), now: now) where old != id { sessions.removeValue(forKey: old) }
        }
    }

    // MARK: - M2.T13 KV snapshot (PromptCacheSnapshot)

    /// Sessions of incognito chats (never written to disk, M2.T13 DoD).
    private var incognito: Set<UUID> = []

    func markIncognito(_ id: UUID) { _ = lock.withLock { incognito.insert(id) } }

    /// The non-incognito session snapshots (id, tokens, cache, state), newest first.
    func persistableSessions() -> [(UUID, Entry)] {
        lock.withLock { sessions.filter { !incognito.contains($0.key) }.sorted { $0.value.used > $1.value.used }.map { ($0.key, $0.value) } }
    }

    func restoreSession(_ id: UUID, tokens: [Int], cache: [KVCache], state: LMOutput.State?) {
        storeSession(id, tokens: tokens, cache: cache, state: state)
    }

    /// M9.T05 (AT-236 AC3 IMAGE_TURN_OVERHEAD): the stable system prefixes (key, entry) that may go to disk — never one
    /// an incognito request built — newest first. Their tokens are the system turn + tool schemas + the day's date line.
    func persistablePrefixes() -> [(String, Entry)] {
        lock.withLock { prefixes.filter { !$0.value.incognito }.sorted { $0.value.used > $1.value.used }.map { ($0.key, $0.value) } }
    }

    /// A stable prefix read back from disk after a reload (reused only when a request's tokens start with it exactly).
    func restorePrefix(_ key: String, tokens: [Int], cache: [KVCache], state: LMOutput.State?) {
        storePrefix(key, tokens: tokens, cache: cache, state: state)
    }

    func generationSuffix(_ key: String) -> Int? { lock.withLock { generationSuffix[key] } }
    func setGenerationSuffix(_ key: String, _ n: Int) { lock.withLock { generationSuffix[key] = n } }

    // MARK: - Planning

    /// Fills `cache` up to the longest reusable prefix plus the new stable/session boundaries, and returns the
    /// tokens still to feed `generate` (≥ 1). Runs inside `ModelContainer.perform`.
    func prepare(
        request: ChatRequest, tokens: [Int], context: ModelContext, parameters: GenerateParameters,
        chat: [Chat.Message], tools: [ToolSpec]?, extra: [String: any Sendable],
        progress: (@Sendable (_ processed: Int, _ whole: Int) -> Void)? = nil
    ) async throws -> (cache: [KVCache], state: LMOutput.State?, suffix: [Int], plan: Plan) {
        let n = tokens.count
        if request.incognito { markIncognito(request.sessionID) }
        let model = context.model
        let key = Self.prefixKey(model: request.modelSlot.key, request: request)
        var cache: [KVCache]
        var state: LMOutput.State?
        var k = 0
        var source = "cold"
        if let (e, src) = bestSnapshot(tokens: tokens, session: request.sessionID, prefixKey: key) {
            cache = e.cache.map { $0.copy() }
            state = e.state
            k = e.tokens.count
            source = src
        } else {
            cache = try model.newCache(parameters: parameters)
        }
        let reused = k
        var prefillSeconds = 0.0
        // R2 review P1-2: each prefix prefill reports its chunks as progress over the whole uncached prompt
        // (n − reused tokens), so a long prefix prefill is not silence to the turn's stall watchdog.
        func step(from k: Int) -> PrefillParameters {
            var pp = PrefillParameters()
            if let progress {
                let whole = n - reused, base = k - reused
                pp.progress = { done, _ in progress(base + done, whole) }
            }
            return pp
        }

        // Stable boundary: the common prefix with a render of the stable system text alone (BPE merges at the
        // boundary only move it earlier, never past a differing token).
        if let key, !hasPrefix(key) {
            let probe = try await context.processor.prepare(
                input: UserInput(chat: [.system(Self.stableSystemText(request)), .user(".")], tools: tools, additionalContext: extra))
            let s = Self.commonPrefix(tokens, probe.text.tokens.asArray(Int.self))
            if s > k, s < n {
                let t0 = ContinuousClock.now
                state = try Self.prefill(tokens[k..<s], cache: cache, state: state, model: model, prefill: step(from: k))
                prefillSeconds += EngineTime.secs(ContinuousClock.now - t0)
                k = s
                storePrefix(key, tokens: Array(tokens[0..<s]), cache: cache, state: state, incognito: request.incognito)
            }
        }

        // Session boundary: everything the next turn's prompt starts with. `chat` is the history view (no
        // turnContext). With a turnContext the boundary sits inside the newest user turn, before the time line, and
        // depends on its text, so it is probed per request; without one it is n − (the generation prompt's length).
        if let ctx = request.turnContext, !ctx.isEmpty, chat.contains(where: { $0.role == .user }) {
            let probe = try await context.processor.prepare(
                input: UserInput(chat: chat + [.assistant("x"), .user("y")], tools: tools, additionalContext: extra))
            let b = Self.commonPrefix(tokens, probe.text.tokens.asArray(Int.self))
            if b > k, b < n {
                let t0 = ContinuousClock.now
                state = try Self.prefill(tokens[k..<b], cache: cache, state: state, model: model, prefill: step(from: k))
                prefillSeconds += EngineTime.secs(ContinuousClock.now - t0)
                k = b
            }
            if b == k, b > 0 { storeSession(request.sessionID, tokens: Array(tokens[0..<b]), cache: cache, state: state, pin: request.prefixPin) }
            return (cache, state, Array(tokens[k...]),
                    Plan(totalTokens: n, reusedTokens: reused, extraPrefillSeconds: prefillSeconds, source: source))
        }
        let gKey = "\(request.modelSlot.key)|\(request.reasoning.on)"
        var g = generationSuffix(gKey)
        if g == nil, chat.contains(where: { $0.role == .user }) {
            let probe = try await context.processor.prepare(
                input: UserInput(chat: chat + [.assistant("x"), .user("y")], tools: tools, additionalContext: extra))
            let b = Self.commonPrefix(tokens, probe.text.tokens.asArray(Int.self))
            if b < n {
                g = n - b
                setGenerationSuffix(gKey, n - b)
            }
        }
        if let g {
            let b = n - g
            if b > k, b < n {
                let t0 = ContinuousClock.now
                state = try Self.prefill(tokens[k..<b], cache: cache, state: state, model: model, prefill: step(from: k))
                prefillSeconds += EngineTime.secs(ContinuousClock.now - t0)
                k = b
            }
            if b == k, b > 0 { storeSession(request.sessionID, tokens: Array(tokens[0..<b]), cache: cache, state: state, pin: request.prefixPin) }
        }
        return (cache, state, Array(tokens[k...]),
                Plan(totalTokens: n, reusedTokens: reused, extraPrefillSeconds: prefillSeconds, source: source))
    }

    /// Runs `tokens` through the model into `cache` (mlx-swift-lm's own chunked prefill inside `TokenIterator`'s
    /// init) and returns the post-prefill model state. The sampled next token is discarded.
    static func prefill(_ tokens: ArraySlice<Int>, cache: [KVCache], state: LMOutput.State?, model: any LanguageModel,
                        prefill: PrefillParameters = .init()) throws
        -> LMOutput.State?
    {
        let it = try TokenIterator(
            input: LMInput(tokens: MLXArray(Array(tokens))), model: model, cache: cache, state: state, processor: nil,
            sampler: ArgMaxSampler(), prefill: prefill, maxTokens: 0)
        eval(cache.flatMap(\.state))
        return it.state
    }
}
