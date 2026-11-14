@testable import AntiChatTools
import AntiChatEngineProtocol
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

// M6.T20 (AT-276 unit leg): the original upload is never changed, each edit is a new version card, and without File
// tools the call only returns the offer.
final class Seen: Sendable { let urls = Mutex<[URL]>([]) }

@Suite(.serialized) struct EditOfficeFileToolTests {
    struct Rig {
        let database: AppDatabase
        let chatID: String
        let store: ArtifactStore
        let root: URL
        let original: URL
        let attachment: AttachmentRecord
        let sha: String
    }

    func rig(name: String = "sales.xlsx", bytes: Data = Data("original-xlsx-bytes".utf8)) throws -> Rig {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "Edit")
        let root = FileManager.default.temporaryDirectory.appending(path: "edit-office-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let original = root.appending(path: "\(sha).xlsx")
        try bytes.write(to: original)
        let message = MessageRecord(chatID: chat.id, parentID: nil, role: .user)
        try db.write { db in try message.insert(db) }
        let a = try AttachmentRepository(db).insert(sha256: sha, size: Int64(bytes.count), path: original.path, origin: .upload,
                                                    messageID: message.id, displayName: name,
                                                    uti: "org.openxmlformats.spreadsheetml.sheet")
        return Rig(database: db, chatID: chat.id, store: ArtifactStore(database: db, mediaRoot: root.appending(path: "Media"), incognito: false),
                   root: root, original: original, attachment: a, sha: sha)
    }

    func editingRunner(_ inputs: Seen, suffix: String) -> RunPythonTool.Runner {
        { request, urls, out in
            inputs.urls.withLock { $0.append(contentsOf: urls) }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let name = request.inputs[0].name
            let edited = out.appending(path: name)
            try (try Data(contentsOf: urls[0]) + Data(suffix.utf8)).write(to: edited)
            let report = try Self.report(request, out, #"{"problems":[],"changes":["edited"]}"#)
            return (RunResult(outFiles: [.init(name: name, size: 1)]), [edited, report])
        }
    }

    /// The check's report file the wrapped cell writes (its per-call name is in the cell).
    static func report(_ request: RunCode, _ out: URL, _ json: String) throws -> URL {
        let name = try #require(request.code.firstMatch(of: /ac-report-[0-9a-f-]+\.json/)).output
        let url = out.appending(path: String(name))
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func withoutFileToolsTheCallOnlyOffersInstallOrRecreate() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let tool = EditOfficeFileTool(runtimePath: { nil }, runner: { _, _, _ in
            Issue.record("nothing may run without File tools"); return (RunResult(), [])
        })
        let text = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","instruction":"add a total row"}"#, chatID: r.chatID,
                                      messageID: nil, database: r.database, store: r.store)
        #expect(OfficeEditOffer.parse(text) == OfficeEditOffer(file: "sales.xlsx", format: "xlsx", instruction: "add a total row"))
        #expect(FileOutResult.parse(text) == nil)
        #expect(try r.database.read { try ArtifactRecord.fetchCount($0) } == 0)
    }

    @Test func eachEditIsANewVersionAndTheOriginalNeverChanges() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let seen = Seen()
        let tool = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: editingRunner(seen, suffix: "+edit"))
        let first = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","code":"wb.save('out/sales.xlsx')","instruction":"total"}"#,
                                       chatID: r.chatID, messageID: nil, database: r.database, store: r.store)
        let v2 = try #require(FileOutResult.parse(first))
        #expect(v2.version == 2 && v2.versions?.count == 2 && v2.file == "sales.xlsx" && v2.format == "xlsx")
        #expect(try Data(contentsOf: URL(fileURLWithPath: v2.path)) == Data("original-xlsx-bytes+edit".utf8))
        // v1 is the original's bytes (the upload's own blob, reused by sha256).
        #expect(try Data(contentsOf: URL(fileURLWithPath: v2.versions![0].path)) == Data("original-xlsx-bytes".utf8))
        // By id this time: the second edit chains on v2, never on the original.
        let second = try await tool.run(argumentsJSON: #"{"file":"\#(r.attachment.id)","code":"…","instruction":"tax"}"#,
                                        chatID: r.chatID, messageID: nil, database: r.database, store: r.store)
        let v3 = try #require(FileOutResult.parse(second))
        #expect(v3.version == 3 && v3.artifact_id == v2.artifact_id)
        #expect(try Data(contentsOf: URL(fileURLWithPath: v3.path)) == Data("original-xlsx-bytes+edit+edit".utf8))
        #expect(seen.urls.withLock { $0.map(\.path) } == [r.original.path, v2.path])
        #expect(EditOfficeFileTool.sha256(ofFile: r.original.path) == r.sha)
        #expect(try Data(contentsOf: r.original) == Data("original-xlsx-bytes".utf8))
        #expect(try r.database.read { try ArtifactRecord.fetchCount($0) } == 1)
    }

    @Test func aRunThatTouchesTheOriginalFailsLoudly() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let tool = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: { request, urls, out in
            try Data("clobbered".utf8).write(to: urls[0])  // what the read-only descriptor makes impossible in the app
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let edited = out.appending(path: request.inputs[0].name)
            try Data("x".utf8).write(to: edited)
            return (RunResult(outFiles: [.init(name: request.inputs[0].name, size: 1)]), [edited])
        })
        await #expect(throws: EditOfficeFileError.originalChanged("sales.xlsx")) {
            _ = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…"}"#, chatID: r.chatID, messageID: nil,
                                   database: r.database, store: r.store)
        }
    }

    @Test func codeErrorsAndMissingOutputsAreReportedNotSaved() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let failing = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: { _, _, _ in
            (RunResult(error: RunError(type: "KeyError", message: "'Sales'", traceback: "Traceback … KeyError: 'Sales'")), [])
        })
        let text = try await failing.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…"}"#, chatID: r.chatID, messageID: nil,
                                         database: r.database, store: r.store)
        #expect(text.contains("KeyError") && FileOutResult.parse(text) == nil)
        let silent = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: { _, _, _ in
            (RunResult(stdout: EditOfficeFileTool.outlineMarker + #"["sheet 'Sales' (used range A1:D13)"]"# + "\n"), [])
        })
        let none = try await silent.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…"}"#, chatID: r.chatID, messageID: nil,
                                        database: r.database, store: r.store)
        #expect(none.hasPrefix("Nothing was saved") && none.contains("used range A1:D13") && FileOutResult.parse(none) == nil)
        let outline = try await silent.run(argumentsJSON: #"{"file":"sales.xlsx"}"#, chatID: r.chatID, messageID: nil,
                                           database: r.database, store: r.store)
        #expect(outline.contains("Outline of sales.xlsx") && outline.contains("used range A1:D13"))
        await #expect(throws: EditOfficeFileError.fileNotFound("other.xlsx")) {
            _ = try await silent.run(argumentsJSON: #"{"file":"other.xlsx","code":"…"}"#, chatID: r.chatID, messageID: nil,
                                     database: r.database, store: r.store)
        }
    }

    @Test func theCodeRunsBetweenTheWorkingCopyHelpers() throws {
        let w = EditOfficeFileTool.wrap("d.save('memo.docx')", name: "memo.docx")
        let lines = w.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] + "\n" == RunPythonTool.prelude)
        #expect(lines[1].contains(#"INPUT, OUTPUT = 'in/' + "memo.docx", 'out/' + "memo.docx""#) && lines[1].contains("_ac_o.remove(OUTPUT)"))
        let code = try #require(lines.firstIndex(of: "d.save('memo.docx')"))
        let outline = try #require(lines.firstIndex { $0.contains(EditOfficeFileTool.outlineMarker) })
        #expect(outline < code, "the outline is printed before the model's code (it survives an exception)")
        #expect(lines[code + 1].hasPrefix("if not _ac_o.path.exists('out/' + \"memo.docx\")"))
        #expect(w.contains("def _ac_verify(orig, edited):") && w.contains("open('out/ac-report.json', 'w')") || w.contains(#"open("out/ac-report.json", 'w')"#))
        #expect(EditOfficeFileTool.wrap("x", name: #"a "b".xlsx"#).contains(#""a \"b\".xlsx""#))
        // The whole cell (prelude + code + helpers + verifier) is valid Python.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
        let pipe = Pipe()
        p.standardInput = pipe
        try? p.run()
        pipe.fileHandleForWriting.write(Data(w.utf8)); try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "wrapped cell does not parse")
    }

    @Test func aLossyEditIsNotSavedUnlessTheUserAskedForIt() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lossy: RunPythonTool.Runner = { request, _, out in
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let edited = out.appending(path: request.inputs[0].name)
            try Data("recreated".utf8).write(to: edited)
            let report = try Self.report(request, out, #"{"problems":["sheet 'Sales': 52 of 52 unchanged cells lost their formatting"],"changes":["Sales!C6: East -> West"]}"#)
            return (RunResult(stdout: "hi\n__AC_VERIFY__{\"problems\":[],\"changes\":[\"printed lookalike\"]}\n", outFiles: [.init(name: request.inputs[0].name, size: 9)]), [edited, report])
        }
        let tool = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: lossy)
        let text = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…"}"#, chatID: r.chatID, messageID: nil,
                                      database: r.database, store: r.store)
        #expect(text.hasPrefix("NOT saved") && text.contains("lost their formatting") && FileOutResult.parse(text) == nil)
        #expect(try r.database.read { try ArtifactVersionRecord.fetchCount($0) } == 1)  // only v1 (the original)
        let forced = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…","accept_changes":true}"#, chatID: r.chatID,
                                        messageID: nil, database: r.database, store: r.store)
        #expect(FileOutResult.parse(forced)?.version == 2)
        #expect(FileOutResult.parse(forced) != nil && forced.contains("Changes made:\n- Sales!C6: East -> West"))
        #expect(!forced.contains("printed lookalike"), "a printed report line is ignored")
        // One refusal unlocks one save (review #15): the next lossy edit is refused again.
        let again = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…","accept_changes":true}"#, chatID: r.chatID,
                                       messageID: nil, database: r.database, store: r.store)
        #expect(again.hasPrefix("NOT saved"))
    }

    /// Review #13: an edited file without the check's report (stdout cut off, the code replaced the checker) is not saved.
    @Test func anEditWithoutTheChecksReportIsNotSaved() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let tool = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: { request, _, out in
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let edited = out.appending(path: request.inputs[0].name)
            try Data("x".utf8).write(to: edited)
            return (RunResult(stdout: String(repeating: "y", count: 64 * 1024),
                              outFiles: [.init(name: request.inputs[0].name, size: 1)]), [edited])
        })
        let text = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","code":"…"}"#, chatID: r.chatID, messageID: nil,
                                      database: r.database, store: r.store)
        #expect(text.hasPrefix("NOT saved: the formatting check did not report"))
        #expect(try r.database.read { try ArtifactVersionRecord.fetchCount($0) } == 1)
    }

    @Test func operationsBecomeOneApplierCallThatParses() throws {
        let ops = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"op":"set_cell","cell":"C6","value":"West \"q\""},{"op":"add_slide","title":"Q?","bullets":["a"]},{"op":"set_cell","cell":"B4","value":0}]"#.utf8))
        let code = EditOfficeFileTool.operationsCode(ops)
        #expect(code.contains("def _ac_apply(ops, src, dst):") && code.hasSuffix("INPUT, OUTPUT)\n"))
        #expect(code.contains(#""value\":0"#), "integral numbers stay integers")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(Data(EditOfficeFileTool.wrap(code, name: "x.xlsx").utf8)); try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    /// h4-4 follow-up: the operations reach Python exactly as the model wrote them (a JSON `\/` escape is not a Python
    /// one, so "Commuters / Tourists" used to arrive as "Commuters \/ Tourists").
    @Test func operationTextReachesPythonUnchanged() throws {
        let raw = #"[{"op":"set_text","slide":2,"text":"Commuters / Tourists \\ \"q\" 3/4\nnext é ✓"}]"#
        let ops = try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
        let code = EditOfficeFileTool.operationsCode(ops)
        let call = try #require(code.split(separator: "\n").last(where: { $0.hasPrefix("_ac_apply(") }))
        let literal = call.dropFirst("_ac_apply(_ac_j.loads(".count).dropLast("), INPUT, OUTPUT)".count)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import json, sys; print(json.loads(eval(sys.stdin.read()))[0]['text'], end='')"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(literal.utf8)); try input.fileHandleForWriting.close()
        let got = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(got == "Commuters / Tourists \\ \"q\" 3/4\nnext é ✓")
        #expect(EditOfficeFileTool.pythonLiteral("a/b") == #""a/b""#)
    }

    /// A Python with python-docx for running the applier (`ANTICHAT_DOCX_PYTHON`, else the system one if it has it).
    static let docxPython: String? = {
        let env = ProcessInfo.processInfo.environment["ANTICHAT_DOCX_PYTHON"]
        return ([env].compactMap { $0 } + ["/usr/bin/python3", "/opt/homebrew/bin/python3"]).first { path in
            guard FileManager.default.isExecutableFile(atPath: path) else { return false }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-c", "import docx"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
    }()

    /// M9 review F4: replace_text with all:true in a .docx replaces each occurrence once, even when the replacement
    /// contains the search text ("Q1" → "Q1 FY25", not "Q1 FY25 FY25"), and every run keeps its own formatting (also
    /// for a match split across two runs).
    @Test(.enabled(if: docxPython != nil, "needs a Python with python-docx (set ANTICHAT_DOCX_PYTHON)"))
    func replaceAllInADocumentIsOnePassAndKeepsRunFormatting() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "edit-office-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"op":"replace_text","find":"Q1","replace":"Q1 FY25","all":true},{"op":"replace_text","find":"Q3","replace":"Q4","all":true}]"#.utf8))
        let script = """
            import docx, json
            INPUT, OUTPUT = \(EditOfficeFileTool.pythonLiteral(dir.appending(path: "in.docx").path)), \(EditOfficeFileTool.pythonLiteral(dir.appending(path: "out.docx").path))
            d = docx.Document()
            p = d.add_paragraph('Revenue in ')
            p.add_run('Q1').bold = True
            p.add_run(' and Q1 again').italic = True
            q = d.add_paragraph()
            q.add_run('Q').bold = True
            q.add_run('3 total').italic = True
            d.save(INPUT)
            \(EditOfficeFileTool.operationsCode(ops))
            out = docx.Document(OUTPUT)
            print(json.dumps([[[r.text, bool(r.bold), bool(r.italic)] for r in par.runs] for par in out.paragraphs]))
            """
        let file = dir.appending(path: "check.py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try #require(Self.docxPython))
        p.arguments = ["-I", file.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(errText)")
        let runs = try JSONDecoder().decode([[[JSONValue]]].self, from: data)
        let text = runs.map { $0.map { r -> String in if case .string(let s) = r[0] { s } else { "" } }.joined() }
        #expect(text == ["Revenue in Q1 FY25 and Q1 FY25 again", "Q4 total"])
        #expect(runs[0].map { $0[1] } == [.bool(false), .bool(true), .bool(false)], "the bold run stays bold, the others not")
        #expect(runs[0].map { $0[2] } == [.bool(false), .bool(false), .bool(true)], "the italic run stays italic")
        #expect(runs[1].count == 2 && runs[1][0] == [.string("Q4"), .bool(true), .bool(false)]
                && runs[1][1] == [.string(" total"), .bool(false), .bool(true)], "a match across runs keeps both runs")
    }

    @Test func anOperationErrorComesBackWithTheOutline() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.root) }
        let tool = EditOfficeFileTool(runtimePath: { "/runtime" }, runner: { request, _, _ in
            #expect(request.code.contains("_ac_apply(_ac_j.loads("))
            return (RunResult(stdout: EditOfficeFileTool.outlineMarker + #"["sheet 'Sales' A1=order_id"]"# + "\n",
                              error: RunError(type: "EditError", message: "no column 'regin'; headers: ['order_id']")), [])
        })
        let text = try await tool.run(argumentsJSON: #"{"file":"sales.xlsx","operations":[{"op":"set_cell","cell":"C6","value":"West"}]}"#,
                                      chatID: r.chatID, messageID: nil, database: r.database, store: r.store)
        #expect(text.hasPrefix("The operations could not be applied") && text.contains("no column 'regin'") && text.contains("A1=order_id"))
    }
}
