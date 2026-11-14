// M2.T17 (R-210): the per-chat mode. `ChatMode` (normal / evil) is the Storage enum on `chat.mode`; it is set when
// the chat is created (from the ModeSwitch, default the last used) and immutable once the chat has a message
// (v1 trigger `chat_mode_locked`, ModeLockTests). Every ChatRequest / media spec of the chat carries it.
import AntiChatStorage
import Foundation

extension ChatMode {
    public var other: ChatMode { self == .normal ? .evil : .normal }
}

public enum ChatModeLock {
    /// True once the chat has a message (the switch shows the lock glyph; a change would abort in the database).
    public static func isLocked(_ chatID: String, database: AppDatabase) -> Bool {
        (try? database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE chat_id = ?", arguments: [chatID]) ?? 0
        }) ?? 0 > 0
    }

    /// Sets the mode of a chat that has no message yet; throws (`mode locked`) after the first one.
    public static func set(_ chatID: String, _ mode: ChatMode, database: AppDatabase) throws {
        try ChatRepository(database).setMode(chatID, mode)
    }
}
