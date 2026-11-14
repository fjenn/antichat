// ChatMessageAdapter (M1.T18 step 2, P-shell-08; DoD "maps our records to the vendored types without patching
// vendored code"): the bridge between AntiChat's message tree and the compaction core.
//   - `ContextTurn`: one user/assistant message of a path as the budget and the summariser see it (Osaurus'
//     `ChatTurn` role). Tool and system_note rows are not turns.
//   - Summary nodes: a `message` row (role `system_note`, `summary_of_ids` = the covered turn ids, one text part =
//     the summary) ⇄ the vendored Osaurus `ConversationSummary` (ids are our UUIDv7 strings, so the mapping is
//     lossless). The node is appended at the tip of the active path when it is created; the prompt builder uses the
//     latest summary node of the chat whose covered ids are exactly a prefix of the request's turns (Osaurus
//     `summaryIsValid`), so regenerate / edit / version switches never misuse a summary and the originals are
//     never touched.
//   - Prompt: the covered turns are dropped and the summary's byte-stable `contextMessageText` is prepended to the
//     first kept user turn. It is not a system message (Qwen templates reject a system turn after the first one,
//     Gemma requires user/assistant alternation) and not a prompt layer (the stable prefix and `promptHash` stay as
//     they are, D-022): it changes the conversation part once per compaction and stays byte-stable after that.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB
import OsaurusVendored

/// One user or assistant message of a path (what the budget counts and the summariser reads).
public struct ContextTurn: Sendable, Hashable {
    public var id: String
    public var role: ChatMessage.Role
    /// The prompt text: user text + paste cards, assistant text (reasoning is not resent).
    public var content: String

    public init(id: String, role: ChatMessage.Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    public var message: ChatMessage { ChatMessage(role: role, content: content) }
}

/// A summary node as stored, with its vendored model.
public struct SummaryNode: Sendable, Equatable {
    public var record: MessageRecord
    public var summary: ConversationSummary
    public var id: String { record.id }
    public var coveredIDs: [String] { record.summaryOfIDs ?? [] }
}

public enum ChatMessageAdapter {
    // MARK: - Turns

    /// The user/assistant turns of `path` (root first). `pasted(messageID)` returns a user message's paste-card
    /// texts in paste order (the prompt reads them as their own paragraphs, A-M1-W2-wire). An empty assistant
    /// (interrupted before any text) is skipped, as in the prompt.
    public static func turns(
        _ path: [MessageRecord], db: Database, pasted: (String) throws -> [String] = { _ in [] }
    ) throws -> [ContextTurn] {
        var out: [ContextTurn] = []
        for m in path {
            let role: ChatMessage.Role
            switch m.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool, .systemNote: continue
            }
            var text = try MessageRepository.parts(of: m.id, db: db).filter { $0.kind == .text }.map(\.body).joined()
            if role == .user {
                let cards = try pasted(m.id)
                if !cards.isEmpty { text = ((text.isEmpty ? [] : [text]) + cards).joined(separator: "\n\n") }
                // M6.T02: the documents the turn used (budgets and summaries see what the model saw).
                text = DocumentContextAssembler.userContent(text, documents: try DocumentContextAssembler.blocks(messageID: m.id, db: db))
            }
            if role == .assistant, text.isEmpty { continue }
            out.append(ContextTurn(id: m.id, role: role, content: text))
        }
        return out
    }

    /// A user message's paste-card texts in paste order (same rows `TurnController` puts into the prompt).
    public static func pastedTexts(
        _ messageID: String, db: Database, attachmentText: (FileBlobRecord) -> String?
    ) throws -> [String] {
        let cards = try AttachmentRecord
            .filter(Column("message_id") == messageID && PastedTextAttachmentStore.isPasteCard)
            .order(Column("created_at")).fetchAll(db)
        return try cards.compactMap { card in
            try FileBlobRecord.fetchOne(db, key: card.blobID).flatMap(attachmentText)
        }
    }

    /// The turns a request would send, before anything is written: `.send` = the path to the (summary-descended)
    /// parent + the new user turn; `.retry` = the path to the reply's prompt; `.edit` = the path to the original's
    /// parent + the edited text. `tip` = where a summary made for this request is appended (the send's parent, or
    /// the chat's leaf for retry/edit, whose new sibling is written afterwards; validity is by prefix, so it applies).
    public static func plannedTurns(
        _ request: TurnRequest, chatID: String, db: Database, attachmentText: (FileBlobRecord) -> String?
    ) throws -> (turns: [ContextTurn], tip: String?) {
        let pasted: (String) throws -> [String] = { try pastedTexts($0, db: db, attachmentText: attachmentText) }
        func path(_ id: String?) throws -> [MessageRecord] {
            guard let id else { return [] }
            return try MessageTree.ancestry(of: id, db: db)
        }
        let leaf = try ChatRecord.fetchOne(db, key: chatID)?.leafMessageID
        switch request {
        case .send(let userID, let text, let parentID, let attachmentIDs):
            let parent = try sendParent(parentID, db: db)
            var newText = text
            if !attachmentIDs.isEmpty {
                let cards = try AttachmentRecord.filter(attachmentIDs.contains(Column("id")) && PastedTextAttachmentStore.isPasteCard)
                    .order(Column("created_at")).fetchAll(db)
                let texts = try cards.compactMap { try FileBlobRecord.fetchOne(db, key: $0.blobID).flatMap(attachmentText) }
                newText = ((text.isEmpty ? [] : [text]) + texts).joined(separator: "\n\n")
            }
            return (try turns(path(parent), db: db, pasted: pasted) + [ContextTurn(id: userID, role: .user, content: newText)],
                    parent)
        case .retry(let assistantID, _), .continueTools(let assistantID):
            // M1.T16 [Continue] resumes the same reply on the same prompt: planned like a retry.
            let old = try MessageTree.message(assistantID, db: db)
            return (try turns(path(old.parentID), db: db, pasted: pasted), leaf)
        case .edit(let original, let newUserID, let text, _):
            let o = try MessageTree.message(original, db: db)
            return (try turns(path(o.parentID), db: db, pasted: pasted) + [ContextTurn(id: newUserID, role: .user, content: text)],
                    leaf)
        }
    }

    // MARK: - Summary nodes ⇄ ConversationSummary

    public static func uuid(_ id: String) -> UUID? { UUID(uuidString: id) }
    public static func storageID(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    /// The vendored summary of a summary node (nil for any other row, or ids that are not UUIDs).
    public static func summary(of record: MessageRecord, text: String) -> ConversationSummary? {
        guard record.role == .systemNote, let ids = record.summaryOfIDs, !ids.isEmpty,
              let id = uuid(record.id) else { return nil }
        let covered = ids.compactMap(uuid)
        guard covered.count == ids.count else { return nil }
        return ConversationSummary(
            id: id, summaryText: text, coveredTurnIds: covered, createdAt: record.createdAt,
            modelIdentifier: record.modelID ?? "", savedTokensEstimate: record.usage?.promptTokens ?? 0)
    }

    /// Every summary node of `chatID`, newest first.
    public static func summaryNodes(chatID: String, db: Database) throws -> [SummaryNode] {
        let rows = try MessageRecord
            .filter(MessageRecord.Columns.chatID == chatID && Column("role") == MessageRole.systemNote.rawValue
                    && Column("summary_of_ids") != nil)
            .order(Column("created_at").desc, MessageRecord.Columns.id.desc)
            .fetchAll(db)
        return try rows.compactMap { r in
            let text = try MessageRepository.parts(of: r.id, db: db).filter { $0.kind == .text }.map(\.body).joined()
            return summary(of: r, text: text).map { SummaryNode(record: r, summary: $0) }
        }
    }

    /// The latest summary of the chat that is valid for `turns` (its covered ids are exactly `turns`' prefix).
    public static func latestValidSummary(for turns: [ContextTurn], chatID: String, db: Database) throws -> SummaryNode? {
        let ids = turns.map(\.id)
        return try summaryNodes(chatID: chatID, db: db).first { isValid($0.coveredIDs, for: ids) }
    }

    /// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/ContextCompactionService.swift
    /// `summaryIsValid(_:for:)`: the covered ids must be exactly the transcript's prefix, in order (covering the
    /// whole transcript is legal).
    public static func isValid(_ covered: [String], for turnIDs: [String]) -> Bool {
        guard !covered.isEmpty, covered.count <= turnIDs.count else { return false }
        return zip(covered, turnIDs).allSatisfy { $0 == $1 }
    }

    /// Writes a summary node under `tip` (the end of the active path when the summary is made). The originals are
    /// not touched. `savedTokens` is kept in `usage_json.prompt_tokens` (the vendored `savedTokensEstimate`).
    @discardableResult
    public static func appendSummary(
        _ summary: ConversationSummary, chatID: String, under tip: String?, db: Database
    ) throws -> MessageRecord {
        try MessageTree.append(
            chatID: chatID, parentID: tip, role: .systemNote, status: .done, parts: [.text(summary.summaryText)],
            configure: {
                $0.id = storageID(summary.id)
                $0.summaryOfIDs = summary.coveredTurnIds.map(storageID)
                $0.modelID = summary.modelIdentifier.isEmpty ? nil : summary.modelIdentifier
                $0.usage = MessageUsage(promptTokens: summary.savedTokensEstimate)
                $0.createdAt = summary.createdAt
            }, db: db)
    }

    /// A send under `parentID` continues below the summary nodes that hang off it on the active path (a summary
    /// made at the tip after the previous reply), so the new user message is that summary's child.
    public static func sendParent(_ parentID: String?, db: Database) throws -> String? {
        guard var current = parentID else { return nil }
        while let child = try MessageRecord.fetchOne(db, key: current)?.activeChildID,
              let node = try MessageRecord.fetchOne(db, key: child), node.role == .systemNote {
            current = node.id
        }
        return current
    }

    // MARK: - Prompt

    /// The conversation a request sends: `turns` without the ones `summary` covers; the summary's context text
    /// leads the first kept user turn (or stands alone as a user turn when nothing user-shaped follows it).
    public static func messages(_ turns: [ContextTurn], summary: ConversationSummary?) -> [ChatMessage] {
        guard let summary else { return turns.map(\.message) }
        let covered = Set(summary.coveredTurnIds.map(storageID))
        return leading(summary, turns.filter { !covered.contains($0.id) }.map(\.message))
    }

    /// `kept` (the conversation after the covered turns) with the summary's context text leading the first kept
    /// user turn, or standing alone as a user turn when the kept part does not start with one.
    public static func leading(_ summary: ConversationSummary, _ kept: [ChatMessage]) -> [ChatMessage] {
        var kept = kept
        let lead = summary.contextMessageText
        if let first = kept.first, first.role == .user {
            kept[0].content = lead + "\n\n" + first.content
        } else {
            kept.insert(ChatMessage(role: .user, content: lead), at: 0)
        }
        return kept
    }
}
