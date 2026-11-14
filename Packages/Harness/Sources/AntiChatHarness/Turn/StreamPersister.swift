// Mid-generation autosave (M1.T06 step 4; NFR-S2 "persisted every ≤ 1 s or 50 tokens", architecture §5.1/§6
// "batched ≤ 500 ms"). The persister accumulates the streaming parts of one assistant message and decides when
// to upsert them: as soon as 50 tokens are unwritten, or 500 ms after the oldest unwritten delta (the owner
// arms a timer at `deadline`). Time is passed in (`at:`), so tests drive it with a virtual clock.
//
// Parts are kept in arrival order of their kind (a reasoning part first if reasoning arrived first, then the
// text part); a `tool_call` part is appended per finished call.
import AntiChatStorage
import Foundation

public struct StreamFlushPolicy: Sendable, Hashable {
    public var maxInterval: Duration
    public var maxTokens: Int

    public init(maxInterval: Duration = .milliseconds(500), maxTokens: Int = 50) {
        self.maxInterval = maxInterval
        self.maxTokens = maxTokens
    }

    public static let standard = StreamFlushPolicy()
}

/// Token estimate for a delta when the engine does not say (≈ 3 UTF-8 bytes per token, rounded up, ≥ 1).
/// Over-counting only flushes earlier, which keeps the 50-token bound safe [ASSUMPTION: BPE averages ≥ 3 bytes
/// per token for English prose; the 0.8B–9B Qwen tokenizers average ≈ 4].
public enum TokenEstimate {
    public static func count(_ s: String) -> Int { max(1, (s.utf8.count + 2) / 3) }
}

public struct StreamPersister {
    public typealias Instant = ContinuousClock.Instant
    /// Writes a snapshot of all parts (the message stays `streaming`).
    public typealias Sink = (_ parts: [(idx: Int, part: PartContent)]) throws -> Void

    public let policy: StreamFlushPolicy
    private let sink: Sink

    public private(set) var parts: [PartContent] = []
    private var textIndex: Int?
    private var reasoningIndex: Int?
    /// Indices changed since the last flush.
    private var dirty: Set<Int> = []
    private var unflushedTokens = 0
    private var oldestUnflushed: Instant?

    /// Flush log for diagnostics and the NFR-S2 test: (time, tokens written by that flush).
    public private(set) var flushes: [(at: Instant, tokens: Int)] = []
    public private(set) var lastError: Error?

    /// M1.T16: activity part index per tool call id; a separator owed before the next text delta (new loop step).
    private var activityIndex: [String: Int] = [:]
    private var pendingSeparator = false

    public init(policy: StreamFlushPolicy = .standard, sink: @escaping Sink) {
        self.policy = policy
        self.sink = sink
    }

    /// M1.T16 [Continue]: resumes a finished reply's parts (the text keeps growing in its part; activities update in
    /// place), so the final write rewrites the same indices.
    public init(policy: StreamFlushPolicy = .standard, existing: [PartContent], sink: @escaping Sink) {
        self.init(policy: policy, sink: sink)
        parts = existing
        textIndex = existing.firstIndex { $0.kind == .text }
        reasoningIndex = existing.firstIndex { $0.kind == .reasoning }
        for (i, p) in existing.enumerated() where p.kind == .activity {
            if let a = ToolActivity(partBody: p.body) { activityIndex[a.id] = i }
        }
    }

    /// M2.T24 step 4: the reply's text is dropped when a pack-missing media call turns the turn into an InstallCard
    /// (a preamble such as "Here is your poster" would otherwise claim media that was never made).
    public mutating func clearText() {
        guard let i = textIndex, !parts[i].body.isEmpty else { return }
        parts[i].body = ""
        dirty.insert(i)
    }

    /// AT-250 attempt 2: the finished reply's text after CitationGrounding (markers of unsupported sentences removed).
    public mutating func replaceText(_ text: String) {
        guard let i = textIndex, parts[i].body != text else { return }
        parts[i].body = text
        dirty.insert(i)
    }

    public var text: String { textIndex.map { parts[$0].body } ?? "" }
    public var reasoning: String { reasoningIndex.map { parts[$0].body } ?? "" }
    public var hasContent: Bool { !text.isEmpty || !reasoning.isEmpty }
    public var isDirty: Bool { !dirty.isEmpty }

    /// When the owner must call `tick` at the latest (nil = nothing unwritten).
    public var deadline: Instant? { oldestUnflushed.map { $0 + policy.maxInterval } }

    /// Appends a text delta; flushes when the token bound is reached. Returns true if it flushed.
    @discardableResult
    public mutating func appendText(_ delta: String, tokens: Int? = nil, at now: Instant) -> Bool {
        let i = index(for: .text)
        if pendingSeparator {
            parts[i].body += "\n\n"
            pendingSeparator = false
        }
        parts[i].body += delta
        return mark(i, tokens: tokens ?? TokenEstimate.count(delta), at: now)
    }

    @discardableResult
    public mutating func appendReasoning(_ delta: String, tokens: Int? = nil, at now: Instant) -> Bool {
        let i = index(for: .reasoning)
        parts[i].body += delta
        return mark(i, tokens: tokens ?? TokenEstimate.count(delta), at: now)
    }

    /// A finished tool call (`{"id","name","arguments"}` JSON); written with the next flush.
    @discardableResult
    public mutating func appendToolCall(id: String, name: String, argsJSON: String, at now: Instant) -> Bool {
        let body = (try? JSONSerialization.data(
            withJSONObject: ["id": id, "name": name, "arguments": argsJSON], options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        parts.append(PartContent(kind: .toolCall, body: body))
        return mark(parts.count - 1, tokens: 0, at: now)
    }

    /// M1.T16: a tool result (`{"id","name","result"}` JSON), stored `untrusted` (tool output is never instructions).
    /// M9 review H2: `activity` = the call's activity key (`call_1#2` when an engine reused the call id in a later step),
    /// stored as `"activity"` so a later rewrite (image Restart) finds exactly this result.
    @discardableResult
    public mutating func appendToolResult(id: String, name: String, result: String, activity: String? = nil,
                                          at now: Instant) -> Bool {
        var object: [String: String] = ["id": id, "name": name, "result": result]
        if let activity { object["activity"] = activity }
        let body = (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        parts.append(PartContent(kind: .toolResult, body: body, untrusted: true))
        return mark(parts.count - 1, tokens: 0, at: now)
    }

    /// M1.T16: an `activity` part keyed by `key` (a tool call id): the first call appends it, later calls update it
    /// in place (running → done).
    @discardableResult
    public mutating func upsertActivity(key: String, body: String, at now: Instant) -> Bool {
        let i: Int
        if let existing = activityIndex[key] {
            i = existing
            parts[i].body = body
        } else {
            parts.append(PartContent(kind: .activity, body: body))
            i = parts.count - 1
            activityIndex[key] = i
        }
        return mark(i, tokens: 0, at: now)
    }

    /// M1.T16: a new tool-loop step starts; its text continues the reply's one text part after a paragraph break.
    /// Returns true when a separator is owed (the reply already has text).
    @discardableResult
    public mutating func beginStep() -> Bool {
        if let i = textIndex, !parts[i].body.isEmpty { pendingSeparator = true }
        return pendingSeparator
    }

    /// Flushes if the oldest unwritten delta is `maxInterval` old. Returns true if it flushed.
    @discardableResult
    public mutating func tick(at now: Instant) -> Bool {
        guard let d = deadline, now >= d else { return false }
        return flush(at: now)
    }

    /// Writes every changed part now (no-op when clean). Returns true if a write happened.
    @discardableResult
    public mutating func flush(at now: Instant) -> Bool {
        guard !dirty.isEmpty else { return false }
        let changed = dirty.sorted().map { (idx: $0, part: parts[$0]) }
        do {
            try sink(changed)
            lastError = nil
        } catch {
            // Keep the parts dirty: the next tick or the final write retries (the final write rewrites all).
            lastError = error
            return false
        }
        flushes.append((now, unflushedTokens))
        dirty.removeAll()
        unflushedTokens = 0
        oldestUnflushed = nil
        return true
    }

    /// Every part with its index (the final write).
    public var allParts: [(idx: Int, part: PartContent)] { parts.enumerated().map { (idx: $0.offset, part: $0.element) } }

    private mutating func index(for kind: PartKind) -> Int {
        if let i = kind == .text ? textIndex : reasoningIndex { return i }
        parts.append(PartContent(kind: kind, body: ""))
        if kind == .text { textIndex = parts.count - 1 } else { reasoningIndex = parts.count - 1 }
        return parts.count - 1
    }

    private mutating func mark(_ i: Int, tokens: Int, at now: Instant) -> Bool {
        dirty.insert(i)
        unflushedTokens += tokens
        if oldestUnflushed == nil { oldestUnflushed = now }
        if unflushedTokens >= policy.maxTokens { return flush(at: now) }
        if let d = deadline, now >= d { return flush(at: now) }
        return false
    }
}
