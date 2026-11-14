// M8.T03 step 3 + 7 (R-060 AC2, R-246 AC1): the model behind Settings → Personalization → Memory. Every user write
// (edit, delete, add, reset, Save on a suggestion) goes through MemoryStore / MemoryReviewService with its event, so
// it is undoable and the memory-write-paths audit sees exactly this caller.
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Defaults
import Foundation
import Observation

@MainActor @Observable
public final class MemorySettingsViewModel {
    public static let resetWord = "RESET"
    public struct TopicGroup: Identifiable, Equatable {
        public var name: String
        public var scope: MemoryScope
        public var entries: [MemoryEntry]
        public var id: String { "\(scope.rawValue)/\(name.lowercased())" }
    }

    public let store: MemoryStore
    private let database: AppDatabase
    public let review: MemoryReviewService
    public private(set) var groups: [TopicGroup] = []
    public private(set) var suggestions: [MemorySuggestion] = []
    public var query = "" { didSet { reload() } }
    /// The last delete, for the 5 s "Memory deleted. Undo" toast.
    public private(set) var lastDeletedEvent: String?

    public init(database: AppDatabase) {
        self.database = database
        store = MemoryStore(database: database)
        review = MemoryReviewService(store: store, model: nil, embedder: MemoryRuntime.for(database).embedder)
        reload()
    }

    public var mode: MemoryPolicy.Mode {
        get { MemoryPolicy.Mode(rawValue: Defaults[.memoryMode]) ?? .on }
        set { Defaults[.memoryMode] = newValue.rawValue }
    }

    public var count: Int { groups.reduce(0) { $0 + $1.entries.count } }

    public func reload() {
        let all = (try? store.allActive()) ?? []  // review fix: project-scoped memories too (global first, then projects)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? all : all.filter { $0.item.text.lowercased().contains(q) || $0.topic.name.lowercased().contains(q) }
        var byTopic: [String: TopicGroup] = [:]
        for e in hits {
            let key = "\(e.topic.scope.rawValue)/\(e.item.projectID ?? "")/\(e.topic.name.lowercased())"
            byTopic[key, default: TopicGroup(name: e.topic.name, scope: e.topic.scope, entries: [])].entries.append(e)
        }
        // Global first, then projects; topics A–Z.
        groups = byTopic.values.sorted { ($0.scope == .global ? 0 : 1, $0.name.lowercased()) < ($1.scope == .global ? 0 : 1, $1.name.lowercased()) }
        suggestions = (try? review.pending()) ?? []
    }

    public func edit(_ id: String, text: String) throws {
        try store.update(id: id, text: text)
        reload()
        fillVectors()
    }

    /// Review fix (M8.T16): edited, added and saved memories get their vectors now (cosine dedupe and snapshot
    /// ranking read them), not only when ⌘K semantic search next runs the backlog.
    func fillVectors() {
        guard let embedder = MemoryRuntime.for(database).embedder, !database.isInMemory else { return }
        let db = database
        Task.detached(priority: .utility) { _ = try? await BackgroundIndexer(database: db).embedPending(with: embedder, limit: 64) }
    }

    public func delete(_ id: String) throws {
        lastDeletedEvent = try store.delete(id: id).id
        reload()
    }

    public func undoDelete() throws {
        guard let e = lastDeletedEvent else { return }
        try store.undo(eventID: e)
        lastDeletedEvent = nil
        reload()
    }

    public func add(topic: String, text: String) throws {
        try store.insert(topic: topic, key: MemoryToolExecutorKey.make(text), text: text, origin: .user)
        reload()
        fillVectors()
    }

    public static func resetEnabled(_ typed: String) -> Bool { typed == resetWord }  // case-sensitive, untranslated

    public func reset(typed: String) throws {
        guard Self.resetEnabled(typed) else { return }
        try store.resetAll()
        reload()
    }

    public func saveSuggestion(_ id: String) throws {
        try review.save(id)
        reload()
        fillVectors()
    }

    public func dismissSuggestion(_ id: String) throws {
        try review.dismiss(id)
        reload()
    }
}

/// The key a user-added fact gets (its first words), same rule as the tool's.
enum MemoryToolExecutorKey {
    static func make(_ text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(4).map { $0.lowercased() }
        let key = String(words.joined(separator: "_").prefix(MemoryStore.maxKey))
        return key.isEmpty ? "fact" : key
    }
}
