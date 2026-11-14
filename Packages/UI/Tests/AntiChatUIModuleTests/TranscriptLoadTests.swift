// M9.T05 (NFR-U11): `TranscriptLoad` reads the visible path's parts, ‹n/m› versions, ratings and attachments with one
// query per table; what it returns must be exactly what the per-message reads returned (MessageRepository.parts,
// MessageTree.versionInfo, FeedbackRepository.rating, EditService.attachments), on a chat with regenerated replies,
// an edited first prompt (sibling roots), ratings, reasoning parts and paste-card attachments.
//   make test-unit FILTER=TranscriptLoadTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct TranscriptLoadTests {
    @Test func batchedReadsEqualThePerMessageReads() throws {
        let db = try AppDatabase.inMemory()
        let env = ChatEnvironment(database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok"}"#)),
                                  slot: { .scripted("inline") })
        let chatID = try ChatRepository(db).create(title: "load").id
        var userIDs: [String] = []
        var replyIDs: [String] = []
        try db.write { d in
            // An edited first prompt: two sibling roots, the second active.
            let first = try MessageTree.append(chatID: chatID, parentID: nil, role: .user, parts: [.text("hello")], db: d)
            _ = try MessageTree.append(chatID: chatID, parentID: first.id, role: .assistant, parts: [.text("old")], db: d)
            var parent: String? = try MessageTree.insertSibling(of: first.id, parts: [.text("hello again")], db: d).id
            userIDs.append(parent!)
            for turn in 0..<30 {
                if turn > 0 {
                    let u = try MessageTree.append(chatID: chatID, parentID: parent, role: .user,
                                                   parts: [.text("question \(turn)"), .text(" more")], db: d)
                    userIDs.append(u.id)
                    parent = u.id
                }
                var reply = try MessageTree.append(chatID: chatID, parentID: parent, role: .assistant,
                                                   parts: [PartContent(kind: .reasoning, body: "think \(turn)"), .text("answer \(turn)")], db: d)
                if turn % 7 == 3 {  // a regenerated reply: three versions, the middle one active
                    let v2 = try MessageTree.insertSibling(of: reply.id, parts: [.text("answer \(turn) v2")], db: d)
                    _ = try MessageTree.insertSibling(of: reply.id, parts: [.text("answer \(turn) v3")], db: d)
                    try MessageTree.setActive(v2.id, db: d)
                    reply = v2
                }
                replyIDs.append(reply.id)
                parent = reply.id
            }
        }
        let feedback = FeedbackRepository(db)
        try feedback.setRating(replyIDs[2], .liked)
        try feedback.setRating(replyIDs[5], .disliked)
        try feedback.flag(replyIDs[5], .refused)  // not a rating
        for (i, id) in userIDs.enumerated() where i % 4 == 1 {
            _ = try env.pastes.save(text: "pasted \(i)", displayName: "Pasted text", messageID: id)
            _ = try env.pastes.save(text: "pasted \(i) b", displayName: "Pasted text", messageID: id)
        }

        try db.read { d in
            let load = try TranscriptLoad(chatID: chatID, db: d)
            let path = try MessageTree.visiblePath(chatID, db: d)
            #expect(load.path.map(\.id) == path.map(\.id))
            #expect(path.count == 60)
            for m in path {
                #expect(load.parts(of: m.id) == (try MessageRepository.parts(of: m.id, db: d)), "parts of \(m.id)")
                let v = try MessageTree.versionInfo(m.id, db: d)
                #expect(load.versionInfo(m.id) == v, "versions of \(m.id)")
                #expect(load.rating(m.id) == (try FeedbackRepository.rating(m.id, db: d)), "rating of \(m.id)")
                if m.role == .user {
                    let a = try EditService.attachments(of: m.id, db: d)
                    let b = load.attachments(of: m.id)
                    #expect(b.map(\.0) == a.map(\.0) && b.map(\.1) == a.map(\.1), "attachments of \(m.id)")
                }
            }
            #expect(path.contains { (try? MessageTree.versionInfo($0.id, db: d).total) == 3 }, "the fixture has versions")
            #expect(userIDs.contains { !load.attachments(of: $0).isEmpty }, "the fixture has attachments")
        }
        // And the model shows the same transcript as before the batching (ratings, versions, attachments).
        let model = ConversationModel(environment: env, chatID: chatID)
        #expect(model.messages.count == 60)
        #expect(model.messages.first { $0.id == replyIDs[2] }?.rating == .liked)
        #expect(model.messages.first { $0.id == replyIDs[3] }.map { ($0.version, $0.versionCount) } ?? (0, 0) == (2, 3))
        #expect(model.messages.first?.versionCount == 2)
        #expect(model.messages.first { $0.id == userIDs[1] }?.attachments.count == 2)
    }
}
