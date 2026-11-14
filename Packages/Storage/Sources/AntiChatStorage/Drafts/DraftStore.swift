// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Managers/Chat/ChatDraftStore.swift
// (P-shell-15, MIT): the Draft {text, attachments} model, the Key {session, newChat} shape and the isEmpty rule
// (whitespace-only text and no attachments = nothing to bring back). Upstream keeps drafts in memory only; R-302 needs
// them on disk, so this store writes the `draft` table (M1.T04, `DraftRepository`) 500 ms after the last change
// (swift-async-algorithms 1.1.7 `debounce`), i.e. ≤ 1 s after the last keystroke (AT-302).
//
// M1.T21 rules (R-302):
//   - `update` records the composer's state as pending; the debounced pass writes every pending draft (an empty one
//     deletes its row). `flush()` writes them synchronously (app termination: `applicationWillTerminate` /
//     `NSApplication.willTerminateNotification`, DraftBinding); `flushSoon()` enqueues the same write on the database's
//     writer without waiting (a chat switch on the main thread).
//   - `draft(for:)` restores (a pending draft wins, then one whose write is in flight, then the stored row);
//     `clear(_:)` runs on send: it forgets the draft at once and enqueues the row's delete.
//   - Main-thread rule (AT-NFR-S3: no main-thread stall > 2 s): only `flush()` waits for the writer. The writer is one
//     serial queue that background work (streaming saves, indexing) also holds, so a synchronous write from the main
//     thread waits behind it; `clear` and `flushSoon` never do. Ordering is the writer queue's: a pass takes the
//     pending drafts inside its own transaction, so a write enqueued later (a send's delete) always lands after it,
//     and an older snapshot can never land after a newer one.
//   - Incognito (R-090, M1.T20): a draft of an incognito chat never reaches the `draft` table. It is kept in this
//     store's process memory only (`memoryDrafts`) and dropped with `discardIncognito`. The chat is incognito when the
//     caller says so (`update(…, incognito: true)`, from `ComposerModel.isIncognito`) or when the `isIncognito` seam
//     says so — the hook M1.T20's `StoreRouter` binds (`DraftStore(router:)`).
//     
//   - Rows of a deleted chat go with it (`chat_draft_cleanup` trigger, v1_core); the `new` row moves to the chat its
//     first send created (`DraftRepository.adoptNewDraft`, unused by the composer, which clears on send).
import AntiChatFoundation
import AsyncAlgorithms
import Foundation
import GRDB
import Synchronization

public final class DraftStore: Sendable {
    /// Which composer the draft belongs to (upstream `Key`: `.session(UUID)` / `.newChat(agentId:)`).
    public enum Key: Hashable, Sendable {
        case chat(String)
        /// The window's new chat (no row until its first send): `draft.chat_id = 'new'`.
        case newChat

        public init(chatID: String?) { self = chatID.map(Key.chat) ?? .newChat }

        /// The `draft.chat_id` value.
        public var storageKey: String {
            switch self {
            case .chat(let id): id
            case .newChat: DraftRecord.newChatKey
            }
        }
    }

    /// One composer attachment as the draft keeps it (`draft.attachments_json`, an array of these). Paste cards keep
    /// their text (restored as the same card); file tiles keep their path (M1 does not read them, M6).
    public struct Attachment: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case pastedText, file }
        public var kind: Kind
        public var text: String?
        public var path: String?

        public static func pastedText(_ text: String) -> Attachment { Attachment(kind: .pastedText, text: text, path: nil) }
        public static func file(_ path: String) -> Attachment { Attachment(kind: .file, text: nil, path: path) }
    }

    /// Everything the composer was holding (upstream `Draft`).
    public struct Draft: Equatable, Sendable {
        public var text: String
        public var attachments: [Attachment]

        public init(text: String, attachments: [Attachment] = []) {
            self.text = text
            self.attachments = attachments
        }

        /// True when there is nothing worth bringing back: no attachments and no text beyond whitespace.
        public var isEmpty: Bool {
            attachments.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public static let empty = Draft(text: "")
    }

    /// The debounce (P-shell-15: 500 ms, so the row is written ≤ 1 s after the last change).
    public static let debounceInterval: Duration = .milliseconds(500)

    public let repository: DraftRepository
    private let isIncognito: @Sendable (Key) -> Bool
    private let now: @Sendable () -> Date

    private struct State {
        var pending: [Key: Draft] = [:]
        /// Incognito drafts: process memory only, never the `draft` table.
        var memoryDrafts: [Key: Draft] = [:]
        /// Taken by a pass whose transaction has not committed yet (still restorable).
        var inFlight: [Key: Draft] = [:]
        /// Sent: the row's delete is enqueued, not yet committed (restores nothing meanwhile).
        var deleting: [Key: Int] = [:]
        var writes = 0
    }

    private let state = Mutex(State())
    private let changes: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>

    /// - Parameters:
    ///   - clock: the debounce clock (tests pass a manual clock: AT-302's virtual-clock leg).
    ///   - now: `draft.updated_at` (tests tie it to the manual clock).
    ///   - isIncognito: M1.T20's StoreRouter seam; true keeps the chat's draft in memory only.
    public init<C: Clock>(
        database: AppDatabase, debounce: Duration = DraftStore.debounceInterval, clock: C,
        now: @escaping @Sendable () -> Date = { Date() },
        isIncognito: @escaping @Sendable (Key) -> Bool = { _ in false }
    ) where C.Duration == Duration {
        repository = DraftRepository(database)
        self.isIncognito = isIncognito
        self.now = now
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = continuation
        let box = WeakBox<DraftStore>()
        task = Task.detached(priority: .utility) {
            for await _ in stream.debounce(for: debounce, clock: clock) {
                box.value?.flush()
            }
        }
        box.value = self
    }

    public convenience init(
        database: AppDatabase, isIncognito: @escaping @Sendable (Key) -> Bool = { _ in false }
    ) {
        self.init(database: database, clock: ContinuousClock(), isIncognito: isIncognito)
    }

    /// M1.T20 wiring: drafts go to the router's disk store, and a chat routed to memory (incognito) never gets a row.
    public convenience init(router: StoreRouter) {
        self.init(database: router.disk, isIncognito: { [router] key in
            if case .chat(let id) = key { return !router.persistsDrafts(for: id) }
            return false
        })
    }

    deinit {
        changes.finish()
        task.cancel()
    }

    // MARK: Composer → store

    /// The composer changed. Incognito: kept in memory only. Otherwise pending until the debounce writes it.
    public func update(_ draft: Draft, for key: Key, incognito: Bool = false) {
        if incognito || isIncognito(key) {
            state.withLock {
                $0.pending[key] = nil
                if draft.isEmpty { $0.memoryDrafts[key] = nil } else { $0.memoryDrafts[key] = draft }
            }
            return
        }
        state.withLock { $0.pending[key] = draft }
        changes.yield()
    }

    /// The draft to restore for `key` (pending first, then the stored row; incognito: memory only).
    public func draft(for key: Key, incognito: Bool = false) -> Draft? {
        if incognito || isIncognito(key) { return state.withLock { $0.memoryDrafts[key] } }
        enum Local { case draft(Draft), none, stored }
        let local: Local = state.withLock { s in
            if let p = s.pending[key] { return p.isEmpty ? .none : .draft(p) }
            if s.deleting[key] != nil { return .none }
            if let f = s.inFlight[key] { return f.isEmpty ? .none : .draft(f) }
            return .stored
        }
        switch local {
        case .draft(let d): return d
        case .none: return nil
        case .stored: break
        }
        do {
            guard let row = try repository.draft(chatID: key.storageKey) else { return nil }
            let d = Draft(text: row.text, attachments: Self.decode(row.attachmentsJSON))
            return d.isEmpty ? nil : d
        } catch {
            return nil
        }
    }

    /// The draft was sent: forget it everywhere (pending, memory, the row). Never waits for the writer: the row's
    /// delete is enqueued behind any pass already holding or waiting for it, so a draft that pass writes is deleted.
    public func clear(_ key: Key, incognito: Bool = false) {
        let persisted = !incognito && !isIncognito(key)
        state.withLock { s in
            s.pending[key] = nil
            s.memoryDrafts[key] = nil
            if persisted { s.deleting[key, default: 0] += 1 }
        }
        guard persisted else { return }
        let storageKey = key.storageKey
        repository.database.writer.asyncWrite({ db in
            _ = try DraftRecord.deleteOne(db, key: storageKey)
        }, completion: { [weak self] _, result in
            if case .failure(let error) = result { AppLog.log(.store, .error, "draft delete failed: \(error)") }
            self?.state.withLock { s in
                let n = (s.deleting[key] ?? 1) - 1
                s.deleting[key] = n > 0 ? n : nil
            }
        })
    }

    /// The incognito chat closed: its in-memory draft is gone (M1.T20 step 5).
    public func discardIncognito(_ key: Key) {
        state.withLock { _ = $0.memoryDrafts.removeValue(forKey: key) }
    }

    /// Writes every pending draft now and returns when it is committed (debounced pass, app termination).
    public func flush() {
        do {
            let batch = try repository.database.write { db in try writePending(db) }
            committed(batch)
        } catch {
            // `writePending` already put the batch back; the next pass retries.
        }
    }

    /// Enqueues the same write as `flush()` on the writer and returns at once (a chat switch on the main thread).
    /// Until it commits, `draft(for:)` restores the drafts it took from memory.
    public func flushSoon() {
        guard state.withLock({ !$0.pending.isEmpty }) else { return }
        repository.database.writer.asyncWrite({ [weak self] db in
            try self?.writePending(db) ?? [:]
        }, completion: { [weak self] _, result in
            if case .success(let batch) = result { self?.committed(batch) }
        })
    }

    /// Waits until every write enqueued so far has committed (tests, probes).
    public func settle() {
        _ = try? repository.database.writer.write { _ in }
    }

    /// Inside a write transaction: takes the pending drafts (they stay restorable as in flight) and writes them. A
    /// failure puts the batch back unless a newer change replaced it; the next pass retries.
    private func writePending(_ db: Database) throws -> [Key: Draft] {
        let batch = state.withLock { s -> [Key: Draft] in
            let b = s.pending
            s.pending.removeAll()
            for (k, d) in b { s.inFlight[k] = d }
            return b
        }
        guard !batch.isEmpty else { return batch }
        let stamp = now()
        do {
            for (key, draft) in batch {
                if draft.isEmpty {
                    _ = try DraftRecord.deleteOne(db, key: key.storageKey)
                } else {
                    try DraftRecord(chatID: key.storageKey, text: draft.text,
                                    attachmentsJSON: Self.encode(draft.attachments), updatedAt: stamp).save(db)
                }
            }
        } catch {
            state.withLock { s in
                for (k, d) in batch {
                    if s.pending[k] == nil { s.pending[k] = d }
                    if s.inFlight[k] == d { s.inFlight[k] = nil }
                }
            }
            throw error
        }
        return batch
    }

    /// The pass that took `batch` committed: its drafts are the stored rows now.
    private func committed(_ batch: [Key: Draft]) {
        state.withLock { s in
            guard !batch.isEmpty else { return }
            for (k, d) in batch where s.inFlight[k] == d { s.inFlight[k] = nil }
            s.writes += 1
        }
    }

    // MARK: Test / probe support

    /// Drafts waiting for the debounce.
    public var pendingCount: Int { state.withLock { $0.pending.count } }
    /// Completed write transactions (tests).
    public var writeCount: Int { state.withLock { $0.writes } }
    /// Keys held in memory only (incognito).
    public var memoryKeys: Set<Key> { state.withLock { Set($0.memoryDrafts.keys) } }

    // MARK: attachments_json

    public static func encode(_ attachments: [Attachment]) -> String? {
        guard !attachments.isEmpty, let data = try? JSONEncoder().encode(attachments) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String?) -> [Attachment] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Attachment].self, from: data)) ?? []
    }
}

/// Lets the debounce task reach the store without keeping it alive.
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}
