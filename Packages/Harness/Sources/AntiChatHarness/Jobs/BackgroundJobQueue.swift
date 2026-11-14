// M2.T16 step 4 (R-247 AC1; M2 card "the only door for title/index/embed/memory jobs"). Every background job that
// derives data from a chat — auto title, search index, embeddings, memory — is enqueued here with the chat it is
// for. A job for an incognito chat is dropped before it runs (and counted, the IncognitoNoIndexTests hook), so no
// title call, chunk, vector or memory write ever starts from an incognito session. Jobs run at `.utility`.
import AntiChatFoundation
import Foundation
import Synchronization

public final class BackgroundJobQueue: Sendable {
    public enum Kind: String, Sendable, CaseIterable { case title, index, embedding, memory }

    public struct Counts: Sendable, Equatable {
        public var enqueued: [Kind: Int] = [:]
        /// Jobs refused because their chat is incognito.
        public var droppedIncognito: [Kind: Int] = [:]
    }

    public static let shared = BackgroundJobQueue()

    private let counts = Mutex(Counts())

    public init() {}

    /// Runs `work` at `.utility` unless the chat is incognito. Returns the task (nil = dropped).
    @discardableResult
    public func enqueue(_ kind: Kind, for chat: ChatEnvironment,
                        _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        enqueue(kind, incognito: chat.isIncognito, work)
    }

    @discardableResult
    public func enqueue(_ kind: Kind, incognito: Bool, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        if incognito {
            counts.withLock { $0.droppedIncognito[kind, default: 0] += 1 }
            return nil
        }
        counts.withLock { $0.enqueued[kind, default: 0] += 1 }
        return Task(priority: .utility) { await work() }
    }

    /// Test hook (IncognitoNoIndexTests).
    public var snapshot: Counts { counts.withLock { $0 } }
    public func resetCounts() { counts.withLock { $0 = Counts() } }
}
