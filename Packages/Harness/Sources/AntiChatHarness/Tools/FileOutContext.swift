// R-273 AC4 (M6.T10 step 5; Q-015 r5): a later turn changes a produced file by calling its create_* tool with
// `revises: <artifact_id>`, but a past turn's tool results are not in the prompt history, so a model never saw the id
// and could only make a new file (FileVersionTests: "Add a total row" made a second Budget.xlsx v1). Like the picture in
// focus (ImageEditFlow.contextLine), the turn context names the chat's newest produced files and their ids whenever a
// file-out tool is offered.
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import UniformTypeIdentifiers

enum FileOutContext {
    /// The file-out tools whose results can be revised.
    static let tools: Set<String> = [CreateDocumentTool.name, CreateSpreadsheetTool.name, CreatePresentationTool.name]
    /// Artifact kinds those tools write.
    static let kinds = ["pdf", "docx", "md", "xlsx", "csv", "pptx"]
    static let limit = 5

    /// "Files made in this chat: …" (newest first) and "Pictures attached in this chat: …" (AT-273 / AT-275), or nil
    /// when there is neither.
    static func contextLine(chatID: String, db: Database) throws -> String? {
        [try filesLine(chatID: chatID, db: db), try picturesLine(chatID: chatID, db: db)].compactMap { $0 }
            .joined(separator: "\n").nilIfEmpty
    }

    static func filesLine(chatID: String, db: Database) throws -> String? {
        let marks = kinds.map { _ in "?" }.joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.title, (SELECT MAX(n) FROM artifact_version v WHERE v.artifact_id = a.id) AS n
            FROM artifact a WHERE a.chat_id = ? AND a.kind IN (\(marks))
            ORDER BY a.created_at DESC LIMIT \(limit)
            """, arguments: StatementArguments([chatID] + kinds))
        guard !rows.isEmpty else { return nil }
        let files = rows.map { r -> String in
            let id: String = r["id"], title: String = r["title"], n: Int = r["n"] ?? 1
            return "\"\(title)\" artifact_id \"\(id)\" (version \(n))"
        }
        return "Files made in this chat: " + files.joined(separator: "; ")
            + ". To change one, call its create tool again with revises set to its artifact_id."
    }

    /// AT-273 / AT-275: a model never saw the ids of the user's attached photos, so "a deck with the attached photo" could
    /// only invent refs ("photo1"). The pictures sent in this chat (oldest first) and their ids.
    static func picturesLine(chatID: String, db: Database) throws -> String? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id, t.display_name, t.uti FROM attachment t JOIN message m ON m.id = t.message_id
            WHERE m.chat_id = ? ORDER BY t.created_at, t.id LIMIT 200
            """, arguments: [chatID])
        let pictures = rows.filter { (UTType($0["uti"] as String? ?? "")?.conforms(to: .image)) == true }.prefix(pictureLimit)
        guard !pictures.isEmpty else { return nil }
        let list = pictures.enumerated().map { i, r -> String in
            let id: String = r["id"], name: String = r["display_name"] ?? "picture"
            return "\(i + 1). \"\(name)\" id \"\(id)\""
        }
        return "Pictures attached in this chat: " + list.joined(separator: "; ")
            + ". To put one in a file, use its id (create_document: ![caption](id) and images [{\"ref\": id}]; create_presentation: image_ref)."
    }

    static let pictureLimit = 10

    /// AT-273 round 65: what fits in one file call (the file step's output budget is ≤ 8,192 tokens; a call cut at the
    /// budget makes nothing). The same sizes as the cut-off notice's, said before the first call.
    static let sizeLine = "File size: one file call must fit in one reply. Write at most 40 table rows per sheet and at most "
        + "about 2,000 words. If the user asks for more (for example 500 items or a year of daily values), make a "
        + "representative 40-row sample and say in your reply that they can ask for more."
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
