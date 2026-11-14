@testable import AntiChatHarness
import AntiChatEngineProtocol
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing

// M6.T20 (R-276): `edit_office_file` is offered only for an edit request on an attached DOCX / XLSX / PPTX.
struct OfficeEditIntentTests {
    @Test func editRequestsMatchAndQuestionsDoNot() {
        for t in ["Add a Total row to my sheet", "change the title of slide 2", "In the title, replace the word Draft with Final.",
                  "Please update the doc with a final paragraph", "add a column E called Tax"] {
            #expect(OfficeEditIntent.matches(t), "\(t)")
        }
        for t in ["What is the total of the Amount column?", "Summarise this document", "hello", "add 2 and 3"] {
            #expect(!OfficeEditIntent.matches(t), "\(t)")
        }
    }

    @Test func offeredOnlyWithAnAttachedOfficeFile() throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "Edit")
        let text = "Add a Total row to my sheet"
        #expect(!OfficeEditIntent.offers(userText: text, database: db, chatID: chat.id))
        let message = MessageRecord(chatID: chat.id, parentID: nil, role: .user)
        try db.write { db in try message.insert(db) }
        _ = try AttachmentRepository(db).insert(sha256: "a", size: 1, path: "/x.csv", origin: .upload, messageID: message.id,
                                                displayName: "notes.csv", uti: "public.comma-separated-values-text")
        #expect(!OfficeEditIntent.offers(userText: text, database: db, chatID: chat.id))
        _ = try AttachmentRepository(db).insert(sha256: "b", size: 1, path: "/y.xlsx", origin: .upload, messageID: message.id,
                                                displayName: "Sales.XLSX", uti: "org.openxmlformats.spreadsheetml.sheet")
        #expect(OfficeEditIntent.offers(userText: text, database: db, chatID: chat.id))
        #expect(!OfficeEditIntent.offers(userText: "what is in it?", database: db, chatID: chat.id))
    }
    /// Review #14: an edit request forces edit_office_file on the first step; [Re-create the file] (a regenerate
    /// with recreateSteering) neither forces nor offers it, so it cannot loop back to the offer card.
    @Test func recreateNeverForcesTheEditTool() async throws {
        let edit = RegisteredTool(name: EditOfficeFileTool.name, description: "edit", parametersJSON: #"{"type":"object","properties":{}}"#,
                                  sideEffect: .read) { _ in "offer" }
        let h = try ToolLoopHarness(script: #"{"t":"textDelta","v":"ok","delayMs":0}"#, tier: .t1,
                                    tools: [edit, ScriptedTools.echo()], selection: .standard)
        let (u0, a0) = await h.send("hello")
        _ = try await h.log.waitFinished(a0)
        _ = try AttachmentRepository(h.database).insert(sha256: "b", size: 1, path: "/y.xlsx", origin: .upload, messageID: u0,
                                                        displayName: "Sales.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet")
        let (_, a1) = await h.send("Add a Total row to my sheet", parent: a0)
        _ = try await h.log.waitFinished(a1)
        var reqs = await h.controller.requests
        #expect(reqs.first?.toolChoice == .function(EditOfficeFileTool.name))  // `requests` = this turn's steps
        let regen = StorageID.make()
        await h.controller.start(.retry(assistantID: a1, options: RegenerateOptions(steering: OfficeEditIntent.recreateSteering)),
                                 assistantID: regen)
        _ = try await h.log.waitFinished(regen)
        reqs = await h.controller.requests
        #expect(!reqs.isEmpty)
        for r in reqs {
            #expect(r.toolChoice != .function(EditOfficeFileTool.name))
            #expect(!r.tools.contains { $0.name == EditOfficeFileTool.name })
        }
    }
}
