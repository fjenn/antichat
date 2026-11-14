// Branch in new chat (M1.T10 step 7; R-006 AC3; ChatGPT F-022c "Branch conversation › Branch in new chat"): a new
// chat holding every turn of the visible path up to and including the chosen reply, titled `chat.branchTitle`
// ("{title} (branch)"); the original chat is not touched (row count, leaf and title unchanged). The copy is
// `MessageTree.branchCopy` (M1.T04, one transaction): parts and attachment rows (same blobs) are copied too.
import AntiChatStorage
import Foundation
import GRDB

public struct BranchService: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) { self.database = database }

    /// Copies the path up to `messageID` into a new chat; returns its id.
    /// - Parameter title: the localized branch title for the source chat's title (empty while the auto title is
    ///   pending; the caller substitutes its "New chat" label). Storage and Harness have no copy deck.
    @discardableResult
    public func branch(upTo messageID: String, title: @Sendable (String) -> String) throws -> String {
        try database.write { db in
            let source = try MessageTree.message(messageID, db: db)
            let chatTitle = try ChatRecord.fetchOne(db, key: source.chatID)?.title ?? ""
            return try MessageTree.branchCopy(upTo: messageID, title: title(chatTitle), db: db)
        }
    }
}
