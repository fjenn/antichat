// AT-210 (R-210 AC1/AC2; M2.T17 step 3): `chat.mode` is set at creation and immutable once the chat has a message
// (v1 trigger `chat_mode_locked` aborts the UPDATE); the mode reaches every request of the chat (Evil slot + Evil
// prompt; never a Normal stand-in); "Continue in a new … chat" copies the active path into a chat of the other mode.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ModeLockTests") struct ModeLockTests {
    func seeded(_ mode: ChatMode) throws -> (AppDatabase, String) {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(mode: mode)
        let tree = MessageTree(db)
        let u = try tree.append(chatID: chat.id, parentID: nil, role: .user, parts: [.text("hello")])
        _ = try tree.append(chatID: chat.id, parentID: u.id, role: .assistant, parts: [.text("hi")])
        return (db, chat.id)
    }

    @Test func triggerAbortsModeChangeAfterFirstMessage() throws {
        let db = try AppDatabase.inMemory()
        let empty = try ChatRepository(db).create(mode: .normal)
        try ChatModeLock.set(empty.id, .evil, database: db)  // no message yet: allowed
        #expect(try ChatRepository(db).chat(empty.id)?.mode == .evil)
        #expect(!ChatModeLock.isLocked(empty.id, database: db))
        let (db2, id) = try seeded(.evil)
        #expect(ChatModeLock.isLocked(id, database: db2))
        #expect(throws: (any Error).self) { try ChatModeLock.set(id, .normal, database: db2) }
        #expect(try ChatRepository(db2).chat(id)?.mode == .evil)
    }

    @Test func continueInNewChatCopiesActivePathWithOtherMode() throws {
        let (db, id) = try seeded(.evil)
        let m = EvilModeManager(database: db, termsVersion: "v", defaults: UserDefaults.inMemory())
        let newID = try m.continueInNewChat(from: id, mode: .normal)
        #expect(newID != id)
        #expect(try ChatRepository(db).chat(newID)?.mode == .normal)
        let copied = try MessageTree(db).visiblePath(newID).map(\.role)
        #expect(copied == [.user, .assistant])
        #expect(try ChatRepository(db).chat(id)?.mode == .evil, "the original stays")
    }

    @Test func modePropagatesToTheChatsRequests() throws {
        let db = try AppDatabase.inMemory()
        let engine = InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"x"}"#))
        let normal = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: "/x")
        let evil = ModelSlot(engine: .llama, key: "evil-9b", path: "/y")
        let env = ChatEnvironment(database: db, engine: engine, evilSlot: { evil },
                                  tone: FixedToneSentence("Be direct."), slot: { normal })
        #expect(env.controller(chatID: "a", mode: .evil).currentSlotKey == "evil-9b")
        #expect(env.controller(chatID: "b", mode: .normal).currentSlotKey == "chat-9b-q4")
        let none = ChatEnvironment(database: db, engine: engine, slot: { normal })
        #expect(none.controller(chatID: "c", mode: .evil).currentSlotKey == ChatEnvironment.evilUnavailableKey,
                "no Evil model: never the Normal model as a stand-in")
        #expect(env.controller(chatID: "d", mode: .evil).promptModeForTests == .evil(toneSentence: "Be direct."))
        #expect(env.controller(chatID: "e", mode: .normal).promptModeForTests == .normal)
    }
}
