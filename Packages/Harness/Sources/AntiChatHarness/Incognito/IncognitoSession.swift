// IncognitoSession (M1.T20, R-090, P-shell-14, architecture §5.4): one incognito chat. It owns
//   - an in-memory `AppDatabase` (`StoreRouter.makeEphemeralStore`: `DatabaseQueue`, same migrations,
//     `PRAGMA temp_store=MEMORY`); the chat is routed there through the app's `StoreRouter`;
//   - a `ChatEnvironment` over that store: the app's engine wrapped in `IncognitoEngine` (every request carries
//     `incognito: true`), read-only prompt settings (Personalized = the app's, Unpersonalized = without custom
//     instructions and memory, R-062 AC2), tool permissions written in memory (the app's read through, H8), paste blobs in memory;
//   - its own media job queue (M5.T14 review P1-1: in-memory `media_job`, the temp dir as xfer root);
//   - `NSTemporaryDirectory()/AntiChat-incognito-<uuid>/` (0700) for xfer files (M4+); deleted on `discard()` and,
//     if the app died, by `sweepStaleTempDirectories()` at the next launch;
//   - an `AppLog` incognito session (process-wide log redaction while it is open).
// Nothing here ever opens a file under the data folder. `discard()` is idempotent.
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Synchronization

public enum IncognitoPersonalization: String, Sendable, Hashable, CaseIterable {
    case personalized, unpersonalized

    /// The prompt inputs an incognito turn uses: Personalized reads the user's layers (never writes them),
    /// Unpersonalized drops custom instructions and the memory snapshot.
    public func inputs(from base: PromptInputs) -> PromptInputs {
        guard self == .unpersonalized else { return base }
        var i = base
        i.personalization = .none
        i.memorySnapshot = ""
        return i
    }
}

public final class IncognitoSession: Sendable {
    public static let tempPrefix = IncognitoTemp.prefix
    static let ownerFile = IncognitoTemp.ownerFile

    public let id: UUID
    /// The session's store (in memory).
    public let store: AppDatabase
    public let environment: ChatEnvironment
    public let engine: IncognitoEngine
    public let tempDirectory: URL
    /// The session's media job queue (nil = the app has no media tools).
    public let mediaQueue: MediaJobQueue?
    private let router: StoreRouter
    private let state: Mutex<State>
    private let choice: Choice

    struct State {
        var chatID: String?
        var closed = false
    }

    /// The personalization choice, read by the derived prompt settings at every turn.
    final class Choice: Sendable {
        let value: Mutex<IncognitoPersonalization>
        init(_ v: IncognitoPersonalization) { value = Mutex(v) }
    }

    /// - Parameter tempRoot: `NSTemporaryDirectory()` (tests pass their own).
    public init(app: ChatEnvironment, personalization: IncognitoPersonalization = .personalized,
                tempRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) throws {
        id = UUID()
        router = app.stores
        let store = try StoreRouter.makeEphemeralStore()
        self.store = store
        // 0700, owned by this pid: the launch sweep of another AntiChat process leaves a live session's directory alone.
        let temp = IncognitoTemp.make(id.uuidString, in: tempRoot)
        tempDirectory = temp
        guard FileManager.default.fileExists(atPath: temp.path) else { throw CocoaError(.fileWriteUnknown) }
        let choice = Choice(personalization)
        self.choice = choice
        state = Mutex(State())
        let engine = IncognitoEngine(base: app.engine)
        self.engine = engine
        let settings = PromptSettings(derivedFrom: app.promptSettings) { base in
            choice.value.withLock { $0 }.inputs(from: base)
        }
        // M5.T14 review P1-1: media jobs of this chat run on the session's own queue — its in-memory store (no
        // `media_job` row, no prompt on disk) and this temp dir as the xfer root (the gated MP4 / PNG land here) — never
        // on the app's persistent queue. The shared media tools pick it by the call's store being this session's (`MediaJobQueue.serving`).
        MediaJobQueue.markIncognito(store)  // even without a derived queue: its media calls then fail closed
        let queue = app.tools?.mediaQueue?.ephemeral(database: store, xferRoot: temp)
        mediaQueue = queue
        if let queue { MediaJobQueue.register(queue, for: store) }
        let tools = app.tools.map { t in
            // M9 review H8: the user's tool decisions apply here as in every chat. Permissions read through to the
            // app's store (Block / Ask / Always) and are written only to this session's store; the MCP filter (disabled
            // servers and tools, Blocked tools, Offline only) is the app's, which only reads the app's stores.
            let permissions = ToolPermissionStore(store, readThrough: t.permissions?.database)
            var r = ToolRuntime(registry: t.registry, permissions: permissions, policy: t.policy, selection: t.selection,
                                router: t.router, tier: t.tier)
            r.chatFilter = t.chatFilter
            r.imageCaption = t.imageCaption
            r.videoCaption = t.videoCaption
            r.deniedReply = t.deniedReply
            r.mediaQueue = queue
            return r
        }
        environment = ChatEnvironment(
            database: store, engine: engine, mediaRoot: temp, recovery: LaunchRecovery.Report(),
            promptSettings: settings, contextPolicy: app.contextPolicy, tools: tools, stores: app.stores,
            isIncognito: true, evilSlot: app.evilSlot, tone: app.tone, packs: app.packs, slot: app.slot)
        // Generated files and their named copies live in this session's directory, not a separate temp root (#4).
        _ = FileOutTools.Stores.shared.store(for: store, mediaRoot: temp)
        AppLog.beginIncognitoSession()
    }

    deinit { discard() }

    // MARK: Personalization (step 2)

    public var personalization: IncognitoPersonalization { choice.value.withLock { $0 } }

    /// The choice is offered before the first message only; returns false once the chat has a message.
    @discardableResult
    public func setPersonalization(_ p: IncognitoPersonalization) -> Bool {
        guard !hasContent, !isClosed else { return false }
        choice.value.withLock { $0 = p }
        return true
    }

    // MARK: The chat

    /// The incognito chat's id once its row exists (first send).
    public var chatID: String? { state.withLock { $0.chatID } }

    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Creates the chat row in the session's store (first send) and routes it there. Title stays `title.incognito`
    /// (no title model call; the row's title is empty and never pending).
    public func createChat() throws -> String {
        if let id = chatID { return id }
        let chat = try ChatRepository(store).create(title: "", mode: .normal)
        try router.route(chat.id, to: store)
        state.withLock { $0.chatID = chat.id }
        return chat.id
    }

    /// The chat row disappeared (a cancelled held first send): the next send creates it again.
    public func chatRemoved() {
        guard let id = chatID else { return }
        router.release(id)
        state.withLock { $0.chatID = nil }
    }

    /// Owns `chatID`.
    public func owns(_ chatID: String) -> Bool { self.chatID == chatID }

    /// The chat has at least one message (closing it asks first, step 5).
    public var hasContent: Bool {
        guard !isClosed else { return false }
        return ((try? store.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }) ?? 0) > 0
    }

    // MARK: Close (step 5)

    /// This session still holds its share of the process-wide log redaction (begun at init, ended once by `discard`).
    public var holdsLogRedaction: Bool { state.withLock { !$0.closed } }

    /// Ends the session: forgets the routing, empties the store, deletes the temp directory, ends log redaction.
    public func discard() {
        let (wasOpen, chat) = state.withLock { s -> (Bool, String?) in
            defer { s.closed = true; s.chatID = nil }
            return (!s.closed, s.chatID)
        }
        guard wasOpen else { return }
        router.release(store: store)
        FileOutTools.Stores.shared.close(store)
        MediaJobQueue.unregister(database: store)
        // M4 review P1-2: the session's queue closes — every job is cancelled, no new one starts, and once the running
        // one has ended its files (this temp dir, should a late helper write recreate it) are removed.
        if let q = mediaQueue { Task { await q.close() } }
        // M6 review #5/#16: the session's sheet DuckDB + query results and its extracted text (memory only) go too.
        if let chat { SheetSessions.shared.close(chatID: chat); FileToolsClient.release(chatIDs: [chat]) }
        let shas = (try? store.read { db in try String.fetchAll(db, sql: "SELECT sha256 FROM file_blob") }) ?? []
        ExtractedTextStore.shared.forget(shas)
        _ = try? store.write { db in try db.execute(sql: "DELETE FROM chat") }
        try? FileManager.default.removeItem(at: tempDirectory)
        AppLog.endIncognitoSession()
    }

    /// At most this many stale directories are removed per sweep (the rest go at the next launch).
    public static let sweepLimit = 64

    /// Removes `AntiChat-incognito-*` directories a crashed or killed run left behind (architecture §5.4). Only our
    /// prefix is read from the directory stream (`IncognitoTemp.matchingNames`: nothing is built for the other entries
    /// of a shared $TMPDIR), only real directories owned by this user whose owner process is gone are removed, and at
    /// most `limit` per call. Blocking: the app calls `scheduleLaunchSweep()`, never this, on its launch path.
    @discardableResult
    public static func sweepStaleTempDirectories(
        in root: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true), keeping live: Set<URL> = [],
        limit: Int = sweepLimit
    ) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        for name in IncognitoTemp.matchingNames(in: root, prefix: tempPrefix) {
            guard removed.count < limit else { break }
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard !live.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { continue }
            guard IncognitoTemp.isOurs(url) else { continue }  // a symlink, a file, another user's: not ours to remove
            if IncognitoTemp.isLive(url) { continue }  // a running AntiChat's (or this process's) open directory
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    /// Launch: runs `sweepStaleTempDirectories` (and `then`, e.g. the dictation sweep) on a background utility task and
    /// returns at once — a slow or huge $TMPDIR never delays the first window (fix/selection-hang).
    public static func scheduleLaunchSweep(
        in root: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        then: (@Sendable () -> Void)? = nil, done: (@Sendable ([URL]) -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .utility).async {
            let removed = sweepStaleTempDirectories(in: root)
            then?()
            done?(removed)
        }
    }
}
