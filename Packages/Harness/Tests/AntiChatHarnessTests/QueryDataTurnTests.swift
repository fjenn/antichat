// M6.T08 (R-272 AC1/AC2): a sheet attached to a send loads into the chat's DuckDB before the prompt is built; the
// user turn carries the profile block (never the table), `query_data` is offered only then, the ScriptedEngine's
// `query_data` call runs on that chat's store (TurnContext.chatID) and its activity line holds the summary + rows.
//   make test-unit FILTER=QueryDataTurnTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct QueryDataTurnTests {
    static let budget = SheetIntakeTests.fixtures.appendingPathComponent("docs/office/budget-20k.xlsx")

    static func attach(_ db: AppDatabase, url: URL, name: String) throws -> String {
        let blob = FileBlobRecord(sha256: String(repeating: "a", count: 64), size: 1, path: url.path, origin: .upload)
        let a = AttachmentRecord(messageID: nil, blobID: blob.id, displayName: name, uti: "org.openxmlformats.spreadsheetml.sheet",
                                 extractState: .ready)
        try db.write { db in try blob.insert(db); try a.insert(db) }
        return a.id
    }

    @Test func sheetTurnRunsQueryData() async throws {
        let sql = #"SELECT region, round(sum(amount), 2) AS total FROM Transactions GROUP BY region ORDER BY region"#
        let args = String(decoding: try JSONEncoder().encode(["sql": sql]), as: UTF8.self)
        let argsLiteral = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"query_data","args":\(argsLiteral),"delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"East leads.","delayMs":1}
            """, tools: [SheetTools.queryData()])
        defer { SheetSessions.shared.close(chatID: h.chatID) }
        #expect(!SheetSessions.shared.hasTables(chatID: h.chatID), "no sheet yet → query_data not offered")
        let att = try Self.attach(h.database, url: Self.budget, name: "budget-20k.xlsx")
        let u = StorageID.make(), a = StorageID.make()
        await h.controller.start(.send(userID: u, text: "Total by region?", parentID: nil, attachmentIDs: [att]), assistantID: a)
        let r = try await h.log.waitFinished(a, timeout: .seconds(60))
        #expect(r.text == "East leads.")
        #expect(SheetSessions.shared.hasTables(chatID: h.chatID))
        // The prompt block is the profile.
        let blocks = try h.database.read { try DocumentContextAssembler.blocks(messageID: u, db: $0) }
        let profile = try #require(blocks.first)
        #expect(profile.hasPrefix("<sheet_tables untrusted=\"true\">") && profile.contains("Transactions"))
        // The step ran on this chat's store.
        let act = try #require(try h.activities(a).first)
        #expect(act.tool == "query_data" && act.state == .done)
        let s = try #require(act.result.flatMap(QueryDataTool.summary(ofResult:)))
        #expect(s.row_count == 4 && s.file == "budget-20k.xlsx" && !s.truncated)
        #expect(DataRefStore.shared.get(chatID: h.chatID, id: s.data_ref)?.rows.count == 4)
        #expect(act.result?.contains("| East |") == true)
    }

    @Test func queryRetainsTheLoadedStoreAcrossRegistryEviction() async throws {
        let sessions = SheetSessions()
        let refs = DataRefStore()
        let chat = "evicted-\(UUID().uuidString)"
        defer { sessions.close(chatID: chat); refs.drop(chatID: chat) }
        let db = try AppDatabase.inMemory()
        let att = try Self.attach(db, url: SheetIntakeTests.fixtures.appendingPathComponent("docs/office/notes.csv"), name: "notes.csv")
        await sessions.ensureLoaded(chatID: chat, extraIDs: [att], database: db, tier: "T1")
        DuckDBStore.close(chatID: chat)  // the LRU dropped the registry entry; an in-flight query still owns its store
        let tool = SheetTools.queryData(sessions: sessions, refs: refs)
        let ok = try await TurnContext.$chatID.withValue(chat) { try await tool.run(#"{"sql":"SELECT count(*) AS n FROM notes"}"#) }
        #expect(QueryDataTool.summary(ofResult: ok)?.row_count == 1 && ok.contains("| 24 |"))
    }

    @Test func noChatNoTables() async throws {
        let tool = SheetTools.queryData()
        await #expect(throws: ToolRunError.self) { _ = try await tool.run(#"{"sql":"SELECT 1"}"#) }
        await #expect(throws: ToolRunError.self) {
            _ = try await TurnContext.$chatID.withValue("nobody") { try await tool.run(#"{"sql":"SELECT 1"}"#) }
        }
    }

    @Test func badSQLIsAToolErrorTheModelSees() async throws {
        let chat = "bad-\(UUID().uuidString)"
        defer { SheetSessions.shared.close(chatID: chat) }
        let db = try AppDatabase.inMemory()
        let att = try Self.attach(db, url: SheetIntakeTests.fixtures.appendingPathComponent("docs/office/notes.csv"), name: "notes.csv")
        await SheetSessions.shared.ensureLoaded(chatID: chat, extraIDs: [att], database: db, tier: "T1")
        #expect(SheetSessions.shared.tables(chatID: chat).map(\.name) == ["notes"])
        let tool = SheetTools.queryData()
        do {
            _ = try await TurnContext.$chatID.withValue(chat) { try await tool.run(#"{"sql":"DELETE FROM notes"}"#) }
            Issue.record("DELETE ran")
        } catch let e as ToolRunError {
            #expect(e.message.contains("read-only"))
        }
        let ok = try await TurnContext.$chatID.withValue(chat) { try await tool.run(#"{"sql":"SELECT count(*) AS n FROM notes"}"#) }
        #expect(QueryDataTool.summary(ofResult: ok)?.row_count == 1 && ok.contains("| 24 |"))
    }
}
