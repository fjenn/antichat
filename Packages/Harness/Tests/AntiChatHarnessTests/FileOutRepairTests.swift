// AT-273 / AT-275 (M9.T05 Phase B round 60) through the real tool loop (scripted engine, the app's file-out tools):
// near-valid calls are normalised before any check and make the file; what was changed reaches the model; a call that
// is still wrong gets the repair turn with a valid example and a forced retry; a format the tool cannot write is an error
// (repair to the right tool), never a file of another format; file steps get room for the whole file; the user's sent
// photos and their ids are in the turn context.
import AntiChatEngineProtocol
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite("FileOutRepairTests") struct FileOutRepairTests {
    static func call(_ id: String, _ name: String, _ args: String) -> String {
        let o: [String: Any] = ["t": "toolCallDone", "id": id, "name": name, "args": args, "delayMs": 1]
        return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    static let turn = "{\"t\":\"turn\"}"
    static let done = #"{"t":"textDelta","v":"Done.","delayMs":1}"#
    static var tools: [RegisteredTool] {
        [FileOutTools.createSpreadsheet(refs: DataRefStore()), FileOutTools.createDocument()]
    }

    static func artifacts(_ h: ToolLoopHarness) throws -> [String] {
        try h.database.read { try ArtifactRecord.fetchAll($0).map(\.kind) }
    }

    /// T05 csv-14: `sheets` sent as a JSON string → the CSV is made on the first call (no repair).
    @Test func sheetsAsAStringMakeTheFile() async throws {
        let args = #"{"filename":"Timesheet.csv","format":"csv","sheets":"[{\"name\": \"Weekly Timesheet\", \"columns\": [{\"header\": \"Day\", \"type\": \"text\"}, {\"header\": \"Hours\", \"type\": \"number\"}], \"rows\": [[\"Monday\", 8], [\"Tuesday\", 8], [\"Total\", 16]]}]"}"#
        let h = try ToolLoopHarness(script: [Self.call("call_1", "create_spreadsheet", args), Self.turn, Self.done].joined(separator: "\n"),
                                    tools: Self.tools)
        let (_, a) = await h.send(#"Make me a CSV file named "Timesheet": a weekly timesheet with hours and a total."#)
        #expect(try await h.log.waitFinished(a).status == .done)
        #expect(try h.activities(a).map(\.state) == [.done])
        #expect(try Self.artifacts(h) == ["csv"])
    }

    /// T05 csv-24 (a silent .xlsx for a CSV request): the requested format wins and the model is told why.
    @Test func requestedFormatWinsAndIsNoted() async throws {
        let args = #"{"filename":"Sales","format":"xlsx","sheets":[{"name":"Sales","columns":[{"header":"Month","type":"text"},{"header":"Total","type":"number"}],"rows":[["Jan",3],["Feb",4]]}]}"#
        let h = try ToolLoopHarness(script: [Self.call("call_1", "create_spreadsheet", args), Self.turn, Self.done].joined(separator: "\n"),
                                    tools: Self.tools)
        let (_, a) = await h.send(#"Make me a CSV file named "Sales": monthly sales."#)
        #expect(try await h.log.waitFinished(a).status == .done)
        #expect(try Self.artifacts(h) == ["csv"])
        let result = await h.controller.requests[1].flattenedMessages.last { $0.role == .tool }?.content ?? ""
        #expect(result.contains("Adjusted to make this file") && result.contains("You asked for a CSV file"), "\(result)")
        #expect(FileOutResult.parse(result)?.format == "csv")
    }

    /// T05 xlsx-18 (a sheet with only a name): the repair turn carries the error and a valid example, and the next step
    /// must call the tool (round 60: every repair turn ended in a text answer).
    @Test func repairCarriesAnExampleAndForcesTheRetry() async throws {
        let bad = #"{"filename":"Fixed Column Widths","format":"xlsx","sheets":[{"column_widths":["auto"],"name":"Sheet1"}]}"#
        let good = #"{"filename":"Fixed Column Widths","sheets":[{"name":"Sheet1","columns":[{"header":"Item","type":"text"}],"rows":[["a"]],"column_widths":[30]}]}"#
        let h = try ToolLoopHarness(script: [Self.call("call_1", "create_spreadsheet", bad), Self.turn,
                                             Self.call("call_2", "create_spreadsheet", good), Self.turn, Self.done].joined(separator: "\n"),
                                    tools: Self.tools)
        let (_, a) = await h.send(#"Make me a Excel spreadsheet named "Fixed Column Widths": a table with explicit column widths."#)
        #expect(try await h.log.waitFinished(a).status == .done)
        let reqs = await h.controller.requests
        #expect(reqs.map(\.toolChoice) == [.auto, .function("create_spreadsheet"), .auto], "\(reqs.map(\.toolChoice))")
        let repair = reqs[1].flattenedMessages.last { $0.role == .tool }?.content ?? ""
        #expect(repair.contains("every sheet is empty") && repair.contains("A minimal valid call looks like this"), "\(repair)")
        #expect(!repair.contains("or answer without it"))
        #expect(try h.activities(a).map(\.state) == [.failed, .done])
        #expect(try Self.artifacts(h) == ["xlsx"])
    }

    /// The user asked for a Markdown file and the model wrote a spreadsheet: no .xlsx is made; the repair names
    /// create_document and forces it.
    @Test func wrongToolIsAnErrorNotAFileOfAnotherFormat() async throws {
        let sheet = #"{"filename":"Notes","sheets":[{"name":"Notes","columns":[{"header":"Item","type":"text"}],"rows":[["a"]]}]}"#
        let doc = #"{"format":"md","title":"Notes","markdown":"Notes\n\n- a"}"#
        let h = try ToolLoopHarness(script: [Self.call("call_1", "create_spreadsheet", sheet), Self.turn,
                                             Self.call("call_2", "create_document", doc), Self.turn, Self.done].joined(separator: "\n"),
                                    tools: Self.tools)
        let (_, a) = await h.send(#"Make me a Markdown file titled "Notes": my notes."#)
        #expect(try await h.log.waitFinished(a).status == .done)
        let reqs = await h.controller.requests
        #expect(reqs.map(\.toolChoice) == [.auto, .function("create_document"), .auto])
        let repair = reqs[1].flattenedMessages.last { $0.role == .tool }?.content ?? ""
        #expect(repair.contains("call create_document instead"), "\(repair)")
        #expect(try Self.artifacts(h) == ["md"])
    }

    /// T05 csv-16 / md-16 / pdf-16 / xlsx-16 (cut off at the output limit): a step that may write a file for a file
    /// request gets 8192 tokens; other turns keep the window's answer budget (OutputBudget: 4096 at 16K).
    @Test func fileStepsGetRoomForTheWholeFile() async throws {
        let h = try ToolLoopHarness(script: Self.done + "\n" + Self.turn + "\n" + Self.done, tools: Self.tools)
        let (_, a) = await h.send(#"Make me a PDF titled "Annual Inventory": a long inventory table."#)
        _ = try await h.log.waitFinished(a)
        let first = await h.controller.requests.map(\.sampling.maxTokens)
        let (_, b) = await h.send("Hi, how are you?", parent: a)
        _ = try await h.log.waitFinished(b)
        let second = await h.controller.requests.map(\.sampling.maxTokens)
        #expect(first == [8192], "\(first)")
        #expect(second.last == OutputBudget.target(window: 16_384), "\(second)")
        #expect(ToolLoopPolicy.cutOffNotice("create_spreadsheet").contains("at most 40 rows"))
    }

    /// AT-275: the photos sent with the message are the chat's (the composer's `.send(attachmentIDs:)`), the turn context
    /// names them with their ids, and an invented ref ("photo1") becomes the sent photo.
    @Test func sentPhotosAreNamedAndUsed() async throws {
        let args = ##"{"format":"md","title":"Garden","markdown":"# Garden\n\n![Garden](photo1)","images":[{"ref":"photo1"}]}"##
        let h = try ToolLoopHarness(script: [Self.call("call_1", "create_document", args), Self.turn, Self.done].joined(separator: "\n"),
                                    tools: Self.tools)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("001.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: jpg)
        let blob = FileBlobRecord(sha256: UUID().uuidString, size: 4, path: jpg.path, origin: .upload)
        let att = AttachmentRecord(messageID: nil, blobID: blob.id, displayName: "001.jpg", uti: "public.jpeg")
        try h.database.write { d in try blob.insert(d); try att.insert(d) }
        let a = StorageID.make()
        await h.controller.start(.send(userID: StorageID.make(), text: #"Make me a Markdown file titled "Garden" with the attached photo."#,
                                       parentID: nil, attachmentIDs: [att.id]), assistantID: a)
        #expect(try await h.log.waitFinished(a).status == .done)
        let reqs = await h.controller.requests
        let context = reqs[0].turnContext ?? ""
        #expect(context.contains("Pictures attached in this chat: 1. \"001.jpg\" id \"\(att.id)\""), "\(context)")
        #expect(try h.activities(a).map(\.state) == [.done])
        let spec = try h.database.read { try ArtifactVersionRecord.fetchOne($0)?.specJSON } ?? ""
        #expect(spec.contains(att.id) && !spec.contains("photo1"), "\(spec)")
    }

    /// AT-273 round 65 (T05 csv-06 "500 items"): a message asking for a file gets the size a file call can have in its
    /// turn context (before the first call, not only after a cut-off); a message that asks for no file does not.
    @Test func fileAskCarriesTheSizePlan() async throws {
        let h = try ToolLoopHarness(script: [Self.done].joined(separator: "\n"), tools: Self.tools)
        let (_, a) = await h.send(#"Make me a CSV file named "Inventory 500": an inventory list of 500 items."#)
        _ = try await h.log.waitFinished(a)
        let fileAsk = await h.controller.requests.first?.turnContext ?? ""
        #expect(fileAsk.contains("at most 40 table rows per sheet") && fileAsk.contains("500 items"), "\(fileAsk)")
        let (_, b) = await h.send("How are you today?")
        _ = try await h.log.waitFinished(b)
        let chat = await h.controller.requests.first?.turnContext ?? ""
        #expect(!chat.contains("40 table rows"), "\(chat)")
    }
}
