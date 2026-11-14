// M1.T10 AT-005 (unit leg, R-005 AC2–3): regenerate inserts sibling versions (‹ 3/3 › after two regenerates),
// stepping ‹ › moves the visible path and restores the original text, the Versions list has every version with
// its timestamp, the steering text is volatile (in that one request, never stored), Think harder turns reasoning
// on for that request only. TurnController + in-process ScriptedEngine + in-memory database (`Harness`).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

/// `{{v}}` = the n-th play of that turn: version 1, 2, 3 get different replies.
let versionedReply = #"{"t":"textDelta","v":"Answer v{{v}}.","delayMs":1}"#

@Suite("RegenerateServiceTests") struct RegenerateServiceTests {
    /// Sends "go", then regenerates the reply `count` times; returns (user, [assistant ids by version]).
    func turnWithVersions(_ h: Harness, count: Int, options: RegenerateOptions = RegenerateOptions()) async throws -> (String, [String]) {
        let (u, a) = await h.send("go")
        _ = try await h.log.waitFinished(a)
        var ids = [a]
        for _ in 0..<count {
            let next = StorageID.make()
            await h.controller.start(RegenerateService.request(ids.last!, options: options), assistantID: next)
            _ = try await h.log.waitFinished(next)
            ids.append(next)
        }
        return (u, ids)
    }

    @Test func twoRegeneratesGiveThreeVersions() async throws {
        let h = try Harness(script: versionedReply)
        let (u, ids) = try await turnWithVersions(h, count: 2)
        let tree = MessageTree(h.database)
        #expect(try tree.versionInfo(ids[2]) == (3, 3))
        #expect(try tree.visiblePath(h.chatID).map(\.id) == [u, ids[2]])
        #expect(try h.persistedText(ids[0]) == "Answer v1.")
        #expect(try h.persistedText(ids[2]) == "Answer v3.")

        let service = RegenerateService(h.database)
        let versions = try service.versions(of: ids[0])
        #expect(versions.map(\.id) == ids)
        #expect(versions.map(\.index) == [1, 2, 3])
        #expect(versions.allSatisfy { $0.total == 3 && $0.role == .assistant })
        #expect(versions.map(\.text) == ["Answer v1.", "Answer v2.", "Answer v3."])
        #expect(versions.map(\.isActive) == [false, false, true])
        #expect(zip(versions, versions.dropFirst()).allSatisfy { $0.createdAt <= $1.createdAt })

        // ‹ → 2/3, ‹ → 1/3 (the original text), ‹ at the first does nothing.
        #expect(try service.step(from: ids[2], by: -1) == ids[1])
        #expect(try tree.visiblePath(h.chatID).map(\.id) == [u, ids[1]])
        #expect(try service.step(from: ids[1], by: -1) == ids[0])
        #expect(try tree.visiblePath(h.chatID).last.map { try h.persistedText($0.id) } == "Answer v1.")
        #expect(try service.step(from: ids[0], by: -1) == nil)
        #expect(try service.versions(of: ids[2]).map(\.isActive) == [true, false, false])
        // Versions viewer "Use this version" on 3.
        try service.select(ids[2])
        #expect(try tree.visiblePath(h.chatID).map(\.id) == [u, ids[2]])
        #expect(try service.step(from: ids[2], by: 1) == nil)
    }

    @Test func steeringIsVolatileAndNeverStored() async throws {
        let h = try Harness(script: versionedReply)
        let (u, ids) = try await turnWithVersions(h, count: 1, options: RegenerateOptions(steering: "  make it shorter "))
        let req = try #require(await h.controller.lastRequest)
        let last = try #require(req.flattenedHistory.last)
        #expect(last.role == .user)
        #expect(last.content == "go\n\n" + RegenerateService.steeringInstruction("make it shorter"))
        // Stored: one user message with its own text, two assistant versions; no steering anywhere in the DB.
        let path = try MessageTree(h.database).visiblePath(h.chatID)
        #expect(path.map(\.id) == [u, ids[1]])
        #expect(try h.persistedText(u) == "go")
        let all = try h.database.read { db in try MessagePartRecord.fetchAll(db) }
        #expect(!all.contains { $0.body.contains("make it shorter") })
        #expect(try h.database.read { db in try MessageRecord.fetchCount(db) } == 3)
        // The next plain regenerate carries no steering.
        let next = StorageID.make()
        await h.controller.start(RegenerateService.request(ids[1]), assistantID: next)
        _ = try await h.log.waitFinished(next)
        #expect(try #require(await h.controller.lastRequest).flattenedHistory.last?.content == "go")
    }

    @Test func thinkHarderTurnsReasoningOnForThatRequestOnly() async throws {
        let h = try Harness(script: versionedReply)
        let (_, ids) = try await turnWithVersions(h, count: 1, options: RegenerateOptions(thinkHarder: true))
        #expect(try #require(await h.controller.lastRequest).reasoning.on)
        let next = StorageID.make()
        await h.controller.start(RegenerateService.request(ids[1]), assistantID: next)
        _ = try await h.log.waitFinished(next)
        #expect(try #require(await h.controller.lastRequest).reasoning.on == false)
    }

    @Test func steerAppendsToTheLastUserTurn() {
        let line = RegenerateService.steeringInstruction("in French")
        let a = RegenerateService.steer([ChatMessage(role: .user, content: "hi")], with: "in French")
        #expect(a.map(\.content) == ["hi\n\n" + line])
        let b = RegenerateService.steer([ChatMessage(role: .assistant, content: "x")], with: "in French")
        #expect(b.map(\.role) == [.assistant, .user] && b.last?.content == line)
        #expect(RegenerateService.steer([ChatMessage(role: .user, content: "hi")], with: nil).map(\.content) == ["hi"])
        #expect(RegenerateOptions(steering: "   ").steering == nil)
    }

    @Test func userVersionsCarryTheirReplies() async throws {
        let h = try Harness(script: versionedReply)
        let (u, a) = await h.send("first")
        _ = try await h.log.waitFinished(a)
        let u2 = StorageID.make()
        let a2 = StorageID.make()
        await h.controller.start(EditService.request(userID: u, newUserID: u2, text: "second"), assistantID: a2)
        _ = try await h.log.waitFinished(a2)
        let versions = try RegenerateService(h.database).versions(of: u)
        #expect(versions.map(\.id) == [u, u2])
        #expect(versions.map(\.text) == ["first", "second"])
        #expect(versions.map(\.replyText) == ["Answer v1.", "Answer v2."])
        #expect(versions.map(\.isActive) == [false, true])
    }
}
