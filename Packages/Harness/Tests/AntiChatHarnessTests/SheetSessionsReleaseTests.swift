// M6 review #5 (P1): per-chat DuckDB stores and query results are released on chat delete and incognito end, at most
// `SheetSessions.maxOpenChats` chats keep a store, and a chat keeps its last `DataRefStore.maxRefsPerChat` results.
// M6 review #16: ending an incognito session drops its extracted text from memory.
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct SheetSessionsReleaseTests {
    static var csv: URL { SheetIntakeTests.fixtures.appendingPathComponent("docs/office/notes.csv") }

    static func load(_ chat: String, into sessions: SheetSessions = .shared) async throws {
        let store = try SheetIntake.store(chatID: chat, tier: "T0")
        let l = try await SheetIntake.load(url: csv, kind: .csv, into: store, tier: "T0")
        // The shared instance is not admitted into (its LRU would close other tests' chats running in parallel).
        if sessions !== SheetSessions.shared { sessions.admit(chatID: chat) }
        sessions.record(chatID: chat, attachmentID: "att-\(chat)", l)
        DataRefStore.shared.put(chatID: chat, DataRef(id: DataRefStore.newID(), sql: "SELECT 1", columns: ["a"],
                                                      types: ["BIGINT"], rows: [["1"]], truncated: false))
    }

    @Test func leastRecentlyUsedChatIsClosedBeyondTheCap() async throws {
        let sessions = SheetSessions()
        let chats = (0...SheetSessions.maxOpenChats).map { "lru-\($0)-\(UUID().uuidString)" }
        defer { sessions.close(chatIDs: chats) }
        for c in chats { try await Self.load(c, into: sessions) }
        let first = chats[0]
        #expect(!DuckDBStore.isOpen(chatID: first) && !sessions.hasTables(chatID: first), "the oldest chat was released")
        #expect(DataRefStore.shared.get(chatID: first, id: "qr_") == nil)
        for c in chats.dropFirst() { #expect(DuckDBStore.isOpen(chatID: c) && sessions.hasTables(chatID: c)) }
    }

    @Test func deletingChatsReleasesTheirStores() async throws {
        let db = try AppDatabase.inMemory()
        let a = try ChatRepository(db).create(title: "a", mode: .normal).id
        let e = try ChatRepository(db).create(title: "e", mode: .evil).id
        let b = try ChatRepository(db).create(title: "b", mode: .normal).id
        defer { SheetSessions.shared.close(chatIDs: [a, b, e]) }
        for c in [a, b, e] { try await Self.load(c) }
        try ChatListService(database: db).delete([a])
        #expect(!DuckDBStore.isOpen(chatID: a) && !SheetSessions.shared.hasTables(chatID: a))
        #expect(SheetSessions.shared.hasTables(chatID: b))
        _ = try EvilModeManager(database: db, termsVersion: "t", defaults: UserDefaults.inMemory()).deleteAllEvilChats()
        #expect(!DuckDBStore.isOpen(chatID: e) && !SheetSessions.shared.hasTables(chatID: e))
        // deleteAll closes every chat's store (SheetSessions.closeAll); shown on a private instance so tests running
        // in parallel keep theirs.
        let own = SheetSessions()
        let c = "all-\(UUID().uuidString)"
        try await Self.load(c, into: own)
        own.closeAll()
        #expect(!DuckDBStore.isOpen(chatID: c) && !own.hasTables(chatID: c))
        _ = try ChatListService(database: db).deleteAll()  // closes this database's chats only
        #expect(!DuckDBStore.isOpen(chatID: b) && !SheetSessions.shared.hasTables(chatID: b))
    }

    @Test func refsPerChatAreCapped() {
        let store = DataRefStore()
        let chat = "refs-\(UUID().uuidString)"
        let ids = (0..<(DataRefStore.maxRefsPerChat + 5)).map { _ in DataRefStore.newID() }
        for id in ids { store.put(chatID: chat, DataRef(id: id, sql: "", columns: [], types: [], rows: [], truncated: false)) }
        #expect(ids.prefix(5).allSatisfy { store.get(chatID: chat, id: $0) == nil })
        #expect(ids.suffix(DataRefStore.maxRefsPerChat).allSatisfy { store.get(chatID: chat, id: $0)?.id == $0 })
    }

    @Test func incognitoEndReleasesSheetsAndExtractedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = InProcessScriptedEngine(script: try EngineScript(text: words(2, delayMs: 1)))
        let app = try AppDatabase.inMemory()
        let env = ChatEnvironment(database: app, engine: engine,
                                  tools: ToolRuntime(registry: .m1(scriptedTools: false), permissions: ToolPermissionStore(app)),
                                  slot: { .scripted("inline") })
        let s = try IncognitoSession(app: env, tempRoot: root)
        let chat = try s.createChat()
        try await Self.load(chat)
        let output = FileOutTools.Stores.shared.store(for: s.store)
        #expect(output.mediaRoot == s.tempDirectory)
        let generated = try output.save(chatID: chat, kind: "md", filename: "secret.md", data: Data("secret".utf8),
                                        specJSON: nil, messageID: nil)
        #expect(generated.path.hasPrefix(s.tempDirectory.path))
        let sha = "incognito-\(UUID().uuidString)"
        try s.store.write { db in
            try FileBlobRecord(sha256: sha, size: 1, path: s.tempDirectory.appendingPathComponent("\(sha).pdf").path, origin: .upload).insert(db)
        }
        ExtractedTextStore.shared.putMemory(sha, "secret text")
        s.discard()
        #expect(!DuckDBStore.isOpen(chatID: chat) && !SheetSessions.shared.hasTables(chatID: chat))
        #expect(ExtractedTextStore.shared.memory(sha) == nil, "incognito text outlived the session")
        #expect(!FileManager.default.fileExists(atPath: generated.path), "generated output outlived the session")
        #expect(!FileManager.default.fileExists(atPath: s.tempDirectory.path))
    }
}
