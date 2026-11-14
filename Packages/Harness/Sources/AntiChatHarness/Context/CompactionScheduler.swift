// CompactionScheduler (M1.T18 steps 3, 4, 6; R-233 AC2, R-009 AC2): when a chat's summaries are made.
//   - Idle: after a turn ends, once the engine has been idle `idleDelay` (2 s), if the chat's context (what the
//     next request would carry) is ≥ 75 %, summarise the older turns at `.utility` priority on the resident model
//     and append the summary node at the tip of the active path.
//   - Synchronous fallback: a request that would exceed 85 % compacts before it is sent (`TurnController`); the
//     turn is counted as having waited (the R-233 5 % bound). A send that arrives while an idle compaction is still
//     running waits for it and is counted the same way.
//   - Failure (truncated / empty summary, engine error, timeout) keeps the originals and nothing is written; the
//     next idle retries (Osaurus truncated-summary guard).
// One per chat (owned by its `TurnController`). Turn generations order the start/end signals, which arrive from
// the controller's actor through separate hops.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import OsaurusVendored

/// What compaction did, for the UI (indicator, status line) and the soak (AT-233).
public enum ContextEvent: Sendable, Hashable {
    /// The chat's context as the next request would carry it.
    case usage(ContextUsage)
    /// A synchronous compaction runs before the send (`status.thinking`).
    case compacting(Bool)
    /// A summary node was written.
    case summarised(summaryID: String, covered: Int)
}

public actor CompactionScheduler {
    public enum Trigger: String, Sendable, Codable { case idle, sync }

    /// One compaction attempt (AT-233 soak log).
    public struct Run: Sendable, Hashable, Codable {
        public var trigger: Trigger
        /// Context fill when it started (0…1+).
        public var fractionBefore: Double
        public var fractionAfter: Double?
        public var coveredTurns: Int
        public var ok: Bool
        public var error: String?
        public var seconds: Double
    }

    public nonisolated let chatID: String
    private let database: AppDatabase
    private let engine: any EngineService
    private let slot: @Sendable () -> ModelSlot
    public nonisolated let policy: ContextPolicy
    private let attachmentText: @Sendable (FileBlobRecord) -> String?
    /// The system turn the next request would carry (for the estimate).
    private let prompt: @Sendable () -> ComposedPrompt
    private let onEvent: @Sendable (ContextEvent) -> Void
    private let summariserSession: UUID

    private var latestStarted = 0
    private var active: Int?
    private var idleTimer: Task<Void, Never>?
    private var inFlight: Task<Bool, Never>?
    public private(set) var runs: [Run] = []
    /// Turns that waited on a compaction before their request (sync fallback or an idle run still in flight).
    public private(set) var waitedTurns = 0
    public private(set) var turns = 0
    /// True from an idle run's start until `idleFired` has cleared it (the summary row is written slightly earlier).
    public var idleRunInFlight: Bool { inFlight != nil }

    public init(
        chatID: String, database: AppDatabase, engine: any EngineService, policy: ContextPolicy = .standard,
        attachmentText: @escaping @Sendable (FileBlobRecord) -> String?,
        prompt: @escaping @Sendable () -> ComposedPrompt,
        onEvent: @escaping @Sendable (ContextEvent) -> Void = { _ in },
        slot: @escaping @Sendable () -> ModelSlot
    ) {
        self.chatID = chatID
        self.database = database
        self.engine = engine
        self.policy = policy
        self.attachmentText = attachmentText
        self.prompt = prompt
        self.onEvent = onEvent
        self.slot = slot
        summariserSession = UUID.session(forChat: chatID + "#compaction")
    }

    // MARK: - Measuring

    /// The turns and summary the chat's next request would carry from its leaf (no new user turn).
    private func leafState(_ db: Database) throws -> (turns: [ContextTurn], summary: SummaryNode?, leaf: String?) {
        guard let leaf = try ChatRecord.fetchOne(db, key: chatID)?.leafMessageID else { return ([], nil, nil) }
        let path = try MessageTree.ancestry(of: leaf, db: db)
        let at = attachmentText
        let turns = try ChatMessageAdapter.turns(
            path, db: db, pasted: { try ChatMessageAdapter.pastedTexts($0, db: db, attachmentText: at) })
        return (turns, try ChatMessageAdapter.latestValidSummary(for: turns, chatID: chatID, db: db), leaf)
    }

    public func usage(turns: [ContextTurn], summary: SummaryNode?) -> ContextUsage {
        let conversation = ChatMessageAdapter.messages(turns, summary: summary?.summary)
        return ContextBudget.usage(prompt: prompt(), conversation: conversation, window: policy.window(for: slot()))
    }

    /// The chat's current usage (what the indicator shows when the chat opens).
    public func currentUsage() -> ContextUsage {
        guard let state = try? database.read({ try leafState($0) }) else { return .empty }
        return usage(turns: state.turns, summary: state.summary)
    }

    // MARK: - Turn signals (from TurnController)

    /// A turn is about to build its request: stop the idle timer and, if an idle compaction is running, wait for it.
    /// Returns true when the turn waited.
    public func turnStarting(generation: Int) async -> Bool {
        latestStarted = max(latestStarted, generation)
        active = generation
        turns += 1
        idleTimer?.cancel()
        idleTimer = nil
        guard let running = inFlight else { return false }
        waitedTurns += 1
        _ = await running.value
        return true
    }

    /// Stop during the pre-request wait: the running compaction is cancelled (nothing is written).
    public func cancelInFlight() { inFlight?.cancel() }

    /// The turn `generation` ended (done, stopped or failed): report the usage and arm the idle timer.
    public func turnEnded(generation: Int) {
        guard generation >= latestStarted else { return }
        if active == generation { active = nil }
        onEvent(.usage(currentUsage()))
        idleTimer?.cancel()
        let delay = policy.idleDelay
        idleTimer = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.idleFired(generation: generation)
        }
    }

    private func idleFired(generation: Int) async {
        idleTimer = nil
        guard active == nil, latestStarted == generation, inFlight == nil else { return }
        guard let state = try? database.read({ try leafState($0) }), let leaf = state.leaf else { return }
        let before = usage(turns: state.turns, summary: state.summary)
        guard before.fraction >= policy.idleThreshold else { return }
        let task = Task(priority: .utility) { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.compact(turns: state.turns, existing: state.summary, tip: leaf, trigger: .idle,
                                      before: before.fraction, expectLeaf: leaf)
        }
        inFlight = task
        _ = await task.value
        inFlight = nil
    }

    // MARK: - Synchronous fallback

    /// Called by `TurnController` with the request's planned turns when the request would exceed `syncThreshold`.
    /// Returns true when a summary was written (the caller rebuilds its prompt).
    public func compactBeforeSend(turns: [ContextTurn], existing: SummaryNode?, tip: String?, fraction: Double) async -> Bool {
        waitedTurns += 1
        onEvent(.compacting(true))
        defer { onEvent(.compacting(false)) }
        return await compact(turns: turns, existing: existing, tip: tip, trigger: .sync, before: fraction, expectLeaf: nil)
    }

    // MARK: - Run

    private func compact(
        turns: [ContextTurn], existing: SummaryNode?, tip: String?, trigger: Trigger, before: Double, expectLeaf: String?
    ) async -> Bool {
        let slot = slot()
        let service = ContextCompactionService(
            engine: engine, slot: slot, window: policy.window(for: slot), sessionID: summariserSession)
        let start = ContinuousClock.now
        func seconds() -> Double {
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        do {
            let summary = try await service.summarize(turns: turns, existingSummary: existing?.summary)
            let written: MessageRecord? = try database.write { db in
                // An idle summary is stale if a turn moved the leaf meanwhile (the turn waited, so this is rare).
                if let expectLeaf, try ChatRecord.fetchOne(db, key: chatID)?.leafMessageID != expectLeaf { return nil }
                return try ChatMessageAdapter.appendSummary(summary, chatID: chatID, under: tip, db: db)
            }
            guard let written else {
                runs.append(Run(trigger: trigger, fractionBefore: before, coveredTurns: 0, ok: false, error: "stale", seconds: seconds()))
                return false
            }
            let node = SummaryNode(record: written, summary: summary)
            let after = usage(turns: turns, summary: node).fraction
            runs.append(Run(trigger: trigger, fractionBefore: before, fractionAfter: after,
                            coveredTurns: summary.coveredTurnIds.count, ok: true, seconds: seconds()))
            onEvent(.summarised(summaryID: written.id, covered: summary.coveredTurnIds.count))
            if trigger == .idle { onEvent(.usage(currentUsage())) }
            return true
        } catch {
            let e = (error as? ContextCompactionError).map { "\($0)" } ?? "\(error)"
            if (error as? ContextCompactionError) != .nothingToCompact {
                AppLog.log(.harness, .error, "compaction (\(trigger.rawValue)) failed: \(e)")
            }
            runs.append(Run(trigger: trigger, fractionBefore: before, coveredTurns: 0, ok: false, error: e, seconds: seconds()))
            return false
        }
    }
}
