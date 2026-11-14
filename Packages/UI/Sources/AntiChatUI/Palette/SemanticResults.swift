// M2.T16 step 6 (R-244, R-295): the ⌘K semantic section. FTS rows render first exactly as in M1 (NFR-U10 path
// unchanged); hybrid hits for chats the FTS list does not already show merge in under the same list when they arrive
// within the 300 ms budget. No embed model → no extra rows and no error (R-244 AC3).
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

enum SemanticResults {
    /// Hybrid rows for chats not in `shown`, at most `limit`; nil when cancelled.
    static func items(_ query: String, excluding shown: Set<String>, search: SemanticSearch, limit: Int = 5)
        async -> [PaletteItem]?
    {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hits = await search.retriever.search(q, limit: limit + shown.count)
        if Task.isCancelled { return nil }
        let titles = (try? search.retriever.database.read { db in
            try [String: String](uniqueKeysWithValues: hits.map { h in
                (h.chatID, try String.fetchOne(db, sql: "SELECT title FROM chat WHERE id = ?", arguments: [h.chatID]) ?? "")
            })
        }) ?? [:]
        return hits.filter { $0.semantic && !shown.contains($0.chatID) }.prefix(limit).map { h in
            let title = titles[h.chatID].flatMap { $0.isEmpty ? nil : $0 } ?? CopyKey("side.untitled").string()
            let excerpt = String(h.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
            return PaletteItem(id: "chat.\(h.chatID)", kind: .chat(h.chatID, messageID: nil), group: .chats, title: title,
                               subtitle: excerpt, symbol: "sparkle.magnifyingglass")
        }
    }
}
