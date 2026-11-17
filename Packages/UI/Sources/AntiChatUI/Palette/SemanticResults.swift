// M2.T16 (R-244, R-295): the app's semantic index service. Chat search (sidebar Search, ⌘K) lists word matches only
// (titles, then message text): the hybrid "similar meaning" rows returned unrelated chats for any query and are not shown.
// `SemanticSearch` is the app's one index service: the composition root installs it with the helper embedder, the
// chat sessions enqueue an index pass after every finished turn through BackgroundJobQueue (incognito dropped, R-247).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation

public final class SemanticSearch: Sendable {
    public nonisolated(unsafe) static var shared: SemanticSearch?

    public let indexer: BackgroundIndexer
    public let retriever: HybridRetriever
    public let embedder: (any Embedder)?

    public init(database: AppDatabase, embedder: (any Embedder)?) {
        indexer = BackgroundIndexer(database: database)
        retriever = HybridRetriever(database: database, embedder: embedder)
        self.embedder = embedder
    }

    /// Launch self-test (M2.T16 DoD): sqlite-vec is registered with the vendored version.
    public static func selfTest(_ database: AppDatabase) -> Bool { VecLoader.selfTest(database) }

    /// After a finished turn: chunk new messages, then embed what has no vector (resumable; quiet on failure).
    public func indexAfterTurn(_ chat: ChatEnvironment, queue: BackgroundJobQueue = .shared) {
        let indexer = indexer, embedder = embedder
        queue.enqueue(.index, for: chat) {
            do { try await indexer.catchUp(limit: 200) } catch { AppLog.log(.ui, .error, "index: \(error)") }
            guard let embedder, FeatureFlag.semanticSearch.isEnabled() else { return }
            queue.enqueue(.embedding, for: chat) {
                _ = try? await indexer.embedPending(with: embedder)
            }
        }
    }
}
