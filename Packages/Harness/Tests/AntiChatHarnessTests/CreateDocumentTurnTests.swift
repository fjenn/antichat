// M6.T09 (R-273 AC1/AC2) through the tool loop with the ScriptedEngine: a valid `create_document` call writes the file
// on the chat's store (artifact + version 1, created by the reply) and its activity carries the summary the FileCard
// reads; an invalid spec gets exactly one repair turn (`{"repair": true, "errors": […]}`), and a second invalid spec
// ends the loop (text-only step) with a failed activity — the error card (`file.createFailed` + [Try again]).
//   make test-unit FILTER=CreateDocumentTurnTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct CreateDocumentTurnTests {
    static func literal(_ args: String) throws -> String { String(decoding: try JSONEncoder().encode(args), as: UTF8.self) }

    @Test func validCallCreatesTheFile() async throws {
        let args = try Self.literal(##"{"format":"pdf","title":"Trip Plan","markdown":"# Trip Plan\n\n- Day 1\n- Day 2"}"##)
        // The harness store is in memory, so the file goes to an incognito temp dir (ArtifactStore.forDatabase).
        let tool = FileOutTools.createDocument()
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"create_document","args":\(args),"delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Here is your plan.","delayMs":1}
            """, tools: [tool])
        let (_, a) = await h.send("make a pdf")
        let r = try await h.log.waitFinished(a, timeout: .seconds(60))
        #expect(r.text == "Here is your plan.")
        let act = try #require(try h.activities(a).first)
        #expect(act.tool == "create_document" && act.state == .done, "\(act.state): \(act.result ?? "")")
        let res = try #require(act.result.flatMap(CreateDocumentTool.result(ofText:)))
        #expect(res.file == "Trip Plan.pdf" && res.format == "pdf" && res.pages == 1 && res.version == 1)
        #expect(FileManager.default.fileExists(atPath: res.path) && res.path.contains("AntiChat-incognito-out-"))
        let v = try h.database.read { try ArtifactVersionRecord.filter(Column("artifact_id") == res.artifact_id).fetchOne($0) }
        #expect(v?.n == 1 && v?.createdByMessageID == a, "created by the reply")
        let art = try h.database.read { try ArtifactRecord.fetchOne($0, key: res.artifact_id) }
        #expect(art?.chatID == h.chatID && art?.kind == "pdf")
        try? FileManager.default.removeItem(atPath: res.path)
    }

    @Test func invalidSpecGetsOneRepairThenTheErrorCard() async throws {
        // AT-273: a web image is no longer an error (it becomes a visible "[Image not available]" line); an unknown
        // `revises` still is. Round 65 (5bbce1edb): a forced file-tool repair gets two forced tries
        // (RepairRetry.maxForcedRepairs), so the third malformed call is the one that ends the turn text-only.
        let bad = try Self.literal(##"{"format":"pdf","title":"X","markdown":"# X","revises":"no-such-file"}"##)
        let worse = try Self.literal(##"{"format":"pdf","title":"X","markdown":"   "}"##)
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"create_document","args":\(bad),"delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_2","name":"create_document","args":\(worse),"delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_3","name":"create_document","args":\(worse),"delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Sorry, I could not make the file.","delayMs":1}
            """, tools: [FileOutTools.createDocument()])
        let (_, a) = await h.send("make a pdf")
        let r = try await h.log.waitFinished(a, timeout: .seconds(60))
        #expect(r.text == "Sorry, I could not make the file.")
        let acts = try h.activities(a)
        #expect(acts.count == 3 && acts.allSatisfy { $0.tool == "create_document" && $0.state == .failed })
        let results = try h.parts(a, .toolResult).map(\.body)
        #expect(results.count == 3)
        #expect(results.first?.contains(#"\"repair\":true"#) == true || results.first?.contains(#""repair":true"#) == true,
                "repair text: \(results.first ?? "")")
        #expect(results.first?.contains("$.revises: no file with artifact_id") == true)
        let reqs = await h.controller.requests
        #expect(reqs.count == 4 && reqs[1].toolChoice == .function("create_document") && reqs[2].toolChoice == .function("create_document"),
                "AT-273: both repair steps must call the tool")
        #expect(acts.last?.result?.contains("$.markdown: empty") == true, "the activity line shows the validator error")
        #expect(try h.database.read { try ArtifactRecord.fetchCount($0) } == 0, "nothing was rendered")
    }
}

/// M6.T10 (R-273 AC4): a later call with `revises` makes version 2 of the same artifact on the chat's store; a
/// `revises` naming another chat's file is a validation problem (→ the repair turn).
@Suite(.serialized) struct FileVersionToolTests {
    @Test func revisesMakesVersionTwo() async throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "a"), other = try ChatRepository(db).create(title: "b")
        let tool = FileOutTools.createSpreadsheet()
        let v1args = #"{"filename":"Plan","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}],"rows":[[1],[2]]}]}"#
        func call(_ args: String, chat id: String) async throws -> (problems: [String], text: String?) {
            try await ToolCallStore.$database.withValue(db) {
                try await TurnContext.$chatID.withValue(id) {
                    let p = tool.validate?(args) ?? []
                    return (p, p.isEmpty ? try await tool.run(args) : nil)
                }
            }
        }
        let r1 = try #require(try await call(v1args, chat: chat.id).text.flatMap(FileOutResult.parse))
        #expect(r1.version == 1 && r1.file == "Plan.xlsx")
        let v2args = #"{"filename":"Plan","revises":""# + r1.artifact_id + #"","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}],"rows":[[3]]}]}"#
        let foreign = try await call(v2args, chat: other.id)
        #expect(foreign.problems == ["$.revises: that file belongs to another chat"] && foreign.text == nil)
        let r2 = try #require(try await call(v2args, chat: chat.id).text.flatMap(FileOutResult.parse))
        #expect(r2.artifact_id == r1.artifact_id && r2.version == 2 && r2.versions?.map(\.n) == [1, 2])
        #expect(FileManager.default.fileExists(atPath: r1.path), "version 1 still opens")
    }
}
