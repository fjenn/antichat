// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/ContextCompactionService.swift
//
// LLM context compaction for a chat (M1.T18 steps 2, 6; P-shell-08; R-009 AC2, R-233 AC1). The resident chat
// model summarises the oldest turns; the result is a `ConversationSummary` (vendored) that replaces the covered
// turns in the OUTBOUND prompt only — the transcript is never rewritten (stored as a summary node by
// `ChatMessageAdapter.appendSummary`; LibreChat danny-avila/LibreChat@8d3da9b:packages/api/src/agents/compaction.ts
// checkpoint design: last summary wins, a failed summary changes nothing).
//
// Kept from upstream (same names): the boundary rule `compactionCutIndex` (cut on a user turn, keep the current
// and one prior exchange, size gate, an existing summary only grows, whole-transcript last resort),
// `summaryIsValid` (as `ChatMessageAdapter.isValid`), the summariser prompts (verbatim), `renderTranscript`
// (role-labelled, per-turn clip, head/tail clip to a char budget, an earlier summary standing in for its turns),
// temperature 0.2, the 180 s deadline and the truncated-summary guard (#3036: a summary that hit the output limit is
// never applied; the originals stay and the next idle retries).
// Changed for AntiChat: no model routing / configured compaction model / Insights (the summary runs on the resident
// chat model through `EngineService`, at `.utility`, under its own session id so the chat's prefix cache stays);
// the size gates scale with the window (upstream's 4,000-token gate assumes ≥ 32K windows: at 4K or 16K a chat
// would never qualify) and the summary is capped at min(1024, window / 8) tokens (the "cap summary length"
// fallback, G-008 risk); tool turns and attachments do not exist as turns here (paste cards are in the user text).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import OsaurusVendored

public enum ContextCompactionError: Error, Equatable, Sendable {
    /// The conversation is too short (or already covered) for compaction to reclaim anything.
    case nothingToCompact
    /// The model returned an empty / blank summary.
    case emptySummary
    /// The summary hit the output limit before it finished; a partial summary is never applied (#3036).
    case truncatedSummary(model: String)
    case timedOut
    case cancelled
    /// The summarize request failed (engine error code).
    case requestFailed(model: String, message: String)
}

public struct ContextCompactionService: Sendable {
    /// Recent user turns that stay verbatim (the current exchange plus one full prior exchange).
    public static let recentUserTurnsToKeep = 2
    /// A covered span is worth an inference call with at least this many turns…
    public static let minimumCoveredTurns = 4
    /// …or this many estimated tokens (upstream's constant; scaled down for small windows, see `minimumCoveredTokens(window:)`).
    public static let upstreamMinimumCoveredTokens = 4_000
    static let summaryMaxTokens = 1024
    static let summaryTemperature: Float = 0.2
    public static let timeout: Duration = .seconds(180)

    public let engine: any EngineService
    public let slot: ModelSlot
    public let window: Int
    /// The summariser's session (not the chat's: its prefix cache must survive a compaction request).
    public let sessionID: UUID

    public init(engine: any EngineService, slot: ModelSlot, window: Int, sessionID: UUID = UUID()) {
        self.engine = engine
        self.slot = slot
        self.window = window
        self.sessionID = sessionID
    }

    /// The token gate for a short-but-heavy span: upstream's 4,000, or a fifth of the window when that is smaller.
    public static func minimumCoveredTokens(window: Int) -> Int { min(upstreamMinimumCoveredTokens, max(1, window / 5)) }

    /// The summary's output cap: upstream's 1,024 tokens, or an eighth of the window when that is smaller.
    public static func summaryTokenCap(window: Int) -> Int { min(summaryMaxTokens, max(64, window / 8)) }

    // MARK: Boundary selection (upstream `compactionCutIndex`)

    /// Index into `turns` such that `turns[0..<cut]` is the span a new summary would cover, or nil when compaction
    /// has nothing useful to do. See upstream's doc comment: the cut lands on a user turn (the second-from-last,
    /// else the last when that covers nothing), the span must pass the size gate, an existing summary only grows,
    /// and as a last resort the whole transcript (ending in a completed reply) is coverable when its uncovered part
    /// is token-heavy.
    public static func compactionCutIndex(
        turns: [ContextTurn], existingSummary: ConversationSummary?, minimumCoveredTokens: Int = upstreamMinimumCoveredTokens
    ) -> Int? {
        let userIndices = turns.enumerated().filter { $0.element.role == .user }.map(\.offset)
        guard let lastUserIndex = userIndices.last else { return nil }
        let preferred: Int? =
            userIndices.count >= recentUserTurnsToKeep ? userIndices[userIndices.count - recentUserTurnsToKeep] : nil
        let cut: Int
        if let preferred, preferred > 0 {
            cut = preferred
        } else {
            cut = lastUserIndex
        }
        let alreadyCovered = existingSummary?.coveredTurnIds.count ?? 0
        if cut > 0, cut > alreadyCovered,
           cut >= minimumCoveredTurns || ContextBudget.tokens(Array(turns[0 ..< cut])) >= minimumCoveredTokens {
            return cut
        }
        guard turns.last?.role == .assistant, turns.count > alreadyCovered,
              ContextBudget.tokens(Array(turns[alreadyCovered...])) >= minimumCoveredTokens
        else { return nil }
        return turns.count
    }

    // MARK: Run

    /// One compaction pass over `turns` (the request's path, oldest first). Throws `.nothingToCompact` when the
    /// conversation is too short, `.truncatedSummary` when the model hit the output cap (nothing is applied).
    public func summarize(turns: [ContextTurn], existingSummary: ConversationSummary?) async throws -> ConversationSummary {
        guard let cut = Self.compactionCutIndex(
            turns: turns, existingSummary: existingSummary,
            minimumCoveredTokens: Self.minimumCoveredTokens(window: window))
        else { throw ContextCompactionError.nothingToCompact }
        let covered = Array(turns[0 ..< cut])
        let coveredIDs = covered.compactMap { ChatMessageAdapter.uuid($0.id) }
        guard coveredIDs.count == covered.count else { throw ContextCompactionError.nothingToCompact }

        // Prompt budget: leave room for the response + instructions inside the window (upstream: window / 2,
        // 8,000…240,000 chars; the 8,000 floor would overflow a 4K window, so it scales here too).
        let cap = Self.summaryTokenCap(window: window)
        let transcriptCharBudget = max(
            min(8_000, (window / 2) * TokenEstimator.charsPerToken),
            min(((window - cap) / 2) * TokenEstimator.charsPerToken, 240_000))
        let transcript = Self.renderTranscript(covered: covered, existingSummary: existingSummary, charBudget: transcriptCharBudget)
        let request = ChatRequest(
            sessionID: sessionID, modelSlot: slot,
            messages: [.layer(PromptLayer(id: "compaction", content: Self.systemPrompt)),
                       .message(ChatMessage(role: .user, content: Self.userPrompt(transcript: transcript)))],
            reasoning: .off, sampling: Sampling(temperature: Self.summaryTemperature, maxTokens: cap))
        let model = slot.key
        let raw = try await run(request, model: model)
        var summaryText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summaryText.isEmpty else { throw ContextCompactionError.emptySummary }
        // An engine that ignores maxTokens (the ScriptedEngine) may return more than the cap with `stop`: clip on a
        // word boundary so the cap holds either way (a real engine reports `length` → the guard above).
        let capChars = cap * TokenEstimator.charsPerToken
        if summaryText.utf8.count > capChars {
            var clipped = String(summaryText.prefix(capChars))
            if let space = clipped.lastIndex(where: \.isWhitespace) { clipped = String(clipped[..<space]) }
            summaryText = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let coveredTokens = ContextBudget.tokens(covered)
        let draft = ConversationSummary(summaryText: summaryText, coveredTurnIds: coveredIDs, modelIdentifier: model,
                                        savedTokensEstimate: 0)
        let summaryTokens = TokenEstimator.estimate(draft.contextMessageText)
        let summary = ConversationSummary(
            id: ChatMessageAdapter.uuid(StorageID.make()) ?? draft.id, summaryText: summaryText,
            coveredTurnIds: coveredIDs, createdAt: draft.createdAt, modelIdentifier: model,
            savedTokensEstimate: max(0, coveredTokens - summaryTokens))
        AppLog.log(.harness, .notice, "compacted \(coveredIDs.count) turns via \(model): ~\(summary.savedTokensEstimate) tokens reclaimed")
        return summary
    }

    /// Streams the summary (text deltas only: reasoning is off and never kept) under the 180 s deadline.
    /// Cancelling the caller cancels the request (the stream's termination sends `Cancel{requestID}`).
    private func run(_ request: ChatRequest, model: String) async throws -> String {
        let engine = engine
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    var text = ""
                    var finish: FinishReason?
                    for try await event in engine.chat(request) {
                        switch event {
                        case .textDelta(let s): text += s
                        case .done(let r): finish = r
                        case .error(let e): throw ContextCompactionError.requestFailed(model: model, message: e.fullCode)
                        default: break
                        }
                    }
                    switch finish {
                    case .length: throw ContextCompactionError.truncatedSummary(model: model)
                    case .cancelled: throw ContextCompactionError.cancelled
                    case nil: throw ContextCompactionError.requestFailed(model: model, message: "stream ended without done")
                    default: return text
                    }
                }
                group.addTask {
                    try await Task.sleep(for: Self.timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let text = first else {
                    engine.cancel(request.requestID)
                    throw ContextCompactionError.timedOut
                }
                return text
            }
        } catch let e as ContextCompactionError {
            throw e
        } catch {
            if Task.isCancelled { throw ContextCompactionError.cancelled }
            throw ContextCompactionError.requestFailed(model: model, message: "\(error)")
        }
    }

    // MARK: Prompt (verbatim from upstream)

    static let systemPrompt = """
        You are a conversation compaction engine. You produce a dense, factual summary of \
        the older portion of a chat between a user and an AI assistant so that the \
        conversation can continue with the summary in place of those messages.

        Requirements:
        - Preserve the user's original task/request and any explicit constraints verbatim where possible.
        - Record key facts, decisions, and answers established so far.
        - Record important tool activity as outcomes (what was searched/read/written and what was found), not step-by-step logs.
        - Record the current state of any in-progress work and what remains to be done.
        - Do NOT invent details. If something was truncated or unclear, say so.
        - Write in compact prose or terse bullet points. No preamble, no closing remarks — output only the summary.
        """

    static func userPrompt(transcript: String) -> String {
        """
        Summarize the following conversation excerpt (oldest part of an ongoing chat):

        ---
        \(transcript)
        ---

        Output only the summary.
        """
    }

    /// Role-labelled transcript of the covered turns; an earlier summary stands in for the turns it covers. Per-turn
    /// clip 4,000 chars; the whole transcript is head/tail clipped to `charBudget` (head = original task).
    public static func renderTranscript(covered: [ContextTurn], existingSummary: ConversationSummary?, charBudget: Int) -> String {
        let previouslyCovered = Set((existingSummary?.coveredTurnIds ?? []).map(ChatMessageAdapter.storageID))
        var lines: [String] = []
        if let existing = existingSummary {
            lines.append("[Summary of even earlier conversation]:\n\(existing.summaryText)")
        }
        for turn in covered where !previouslyCovered.contains(turn.id) {
            switch turn.role {
            case .user: lines.append("[User]: \(clip(turn.content, to: 4_000))")
            case .assistant:
                if !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("[Assistant]: \(clip(turn.content, to: 4_000))")
                }
            case .tool: lines.append("[Tool result]: \(clip(turn.content, to: 1_200))")
            case .system: continue
            }
        }
        let transcript = lines.joined(separator: "\n\n")
        guard transcript.count > charBudget else { return transcript }
        let headBudget = charBudget / 4
        let tailBudget = charBudget - headBudget
        return String(transcript.prefix(headBudget)) + "\n\n[… middle of excerpt omitted for length …]\n\n"
            + String(transcript.suffix(tailBudget))
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… [truncated]"
    }
}
