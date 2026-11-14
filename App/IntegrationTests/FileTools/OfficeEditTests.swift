// M6.T20 (AT-276, R-276 AC1) through the real signed File tools slot services (AntiChatFileTools[Net]Slot<k>.xpc) and the real runtime:
//   OfficeEditServiceTests (stub tier): the 9 instructions of fixtures/docs/office/edit-inplace/edit-inplace.jsonl
//     with hand-written reference code — every result is version 2 of the file's artifact, the uploaded original's
//     sha256 never changes, and tools/at/office-style-diff.py passes 9/9 (proves the edit path keeps styles when the
//     code is right; build/at/AT-276/<date>/reference/).
//   OfficeEditRealTests (TIER=T1): the model writes the code for the same 9 instructions (edit_office_file as the only
//     tool; build/at/AT-276/<date>/out/ + style.json). Pass: change + style invariants >= 8/9, original 9/9 unchanged.
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import CryptoKit
import Foundation
import XCTest

enum OfficeEditIT {
    struct Row { let id: String; let file: String; let instruction: String }

    /// ANTICHAT_OFFICE_SET=holdout runs the held-out set (fixtures/docs/office/edit-inplace/holdout, never tuned on).
    static var variant: String { ProcessInfo.processInfo.environment["ANTICHAT_OFFICE_SET"] ?? "main" }

    static func fixtures() throws -> URL {
        guard let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] else { throw XCTSkip("ANTICHAT_FIXTURES not set") }
        let base = URL(fileURLWithPath: f).appending(path: "docs/office/edit-inplace")
        return variant == "main" ? base : base.appending(path: variant)
    }

    static var specName: String { variant == "main" ? "edit-inplace.jsonl" : "\(variant).jsonl" }

    static func rows() throws -> [Row] {
        try String(contentsOf: fixtures().appending(path: specName), encoding: .utf8).split(separator: "\n").compactMap { line in
            guard let j = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = j["id"] as? String, let file = j["file"] as? String, let ins = j["instruction"] as? String else { return nil }
            return Row(id: id, file: file, instruction: ins)
        }
    }

    /// A fresh chat whose user message carries the fixture as an uploaded attachment (real intake: media store copy +
    /// extraction), as the app does on drop.
    static func chat(_ file: String, linked: Bool = false) async throws -> (AppDatabase, ArtifactStore, String, String, URL, String) {
        let db = try AppDatabase.inMemory()
        // A plain temp media root, not an incognito one: AntiChat-incognito-* folders are swept while the app runs,
        // and the original must outlive the turn so its sha256 can be re-checked.
        let root = FileManager.default.temporaryDirectory.appending(path: "ft-officeedit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let intake = AttachmentIntake(database: db, mediaRoot: root, incognito: false)
        let item = await intake.ingest(AttachmentIntake.admit([try fixtures().appending(path: file)]).items[0])
        let attachment = try XCTUnwrap(item.attachmentID, "intake failed for \(file): \(item.state)")
        let chat = try ChatRepository(db).create(title: "Edit \(file)")
        if linked {  // the service test has no send: attach it to a user message of the chat, as a send does
            let message = MessageRecord(chatID: chat.id, parentID: nil, role: .user)
            try db.write { db in
                try message.insert(db)
                try db.execute(sql: "UPDATE attachment SET message_id = ? WHERE id = ?", arguments: [message.id, attachment])
            }
        }
        let (path, sha) = try db.read { db -> (String, String) in
            let a = try XCTUnwrap(try AttachmentRecord.fetchOne(db, key: attachment))
            let b = try XCTUnwrap(try FileBlobRecord.fetchOne(db, key: a.blobID))
            return (b.path, b.sha256)
        }
        return (db, ArtifactStore(database: db, mediaRoot: root.appending(path: "out", directoryHint: .isDirectory), incognito: false),
                chat.id, attachment, URL(fileURLWithPath: path), sha)
    }

    static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs tools/at/office-style-diff.py (tools venv) and returns its JSON.
    static func styleDiff(edited: URL, out: URL) throws -> [String: Any] {
        let py = FileToolsIT.repo.appending(path: "tools/.venv/bin/python3")
        // A missing prerequisite is a failure, never a skip (make's tools-venv prerequisite bootstraps it).
        guard FileManager.default.fileExists(atPath: py.path) else {
            XCTFail("tools/.venv missing: run `make tools-venv` (cd tools && uv sync --frozen)"); throw CancellationError()
        }
        let p = Process()
        p.executableURL = py
        p.arguments = ["-I", FileToolsIT.repo.appending(path: "tools/at/office-style-diff.py").path, "--orig", try fixtures().path,
                       "--edited", edited.path, "--spec", try fixtures().appending(path: specName).path, "--out", out.path]
        try p.run(); p.waitUntilExit()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
    }

    static let reference: [String: String] = [
        "ei-1": "import openpyxl\nwb = openpyxl.load_workbook('in/sales.xlsx')\nws = wb['Sales']\nws['A14'] = 'Total'\nws['D14'] = '=SUM(D2:D13)'\nwb.save('out/sales.xlsx')",
        "ei-2": "import openpyxl\nwb = openpyxl.load_workbook('in/sales.xlsx')\nws = wb['Sales']\nfor r in range(2, ws.max_row + 1):\n    if ws.cell(r, 1).value == 1005: ws.cell(r, 3).value = 'West'\nwb.save('out/sales.xlsx')",
        "ei-3": "import openpyxl\nwb = openpyxl.load_workbook('in/sales.xlsx')\nws = wb['Sales']\nws['E1'] = 'Tax'\nfor r in range(2, 14): ws[f'E{r}'] = f'=D{r}*0.1'\nwb.save('out/sales.xlsx')",
        // ei-4 edits the working copy in place (no out/): the tool's postlude hands it out.
        "ei-4": "import docx\nd = docx.Document('memo.docx')\nd.add_paragraph('Approved by the board on 3 March.')\nd.save('memo.docx')",
        "ei-5": "import docx\nd = docx.Document('in/memo.docx')\nfor r in d.paragraphs[0].runs: r.text = r.text.replace('Draft', 'Final')\nd.save('out/memo.docx')",
        "ei-6": "import docx\nd = docx.Document('in/memo.docx')\nd.add_paragraph('Next steps', style='Heading 1')\nfor t in ['Book the venue', 'Send the invites']: d.add_paragraph(t, style='List Bullet')\nd.save('out/memo.docx')",
        "ei-7": "from pptx import Presentation\np = Presentation('in/pitch.pptx')\np.slides[1].shapes.title.text = 'Market size'\np.save('out/pitch.pptx')",
        "ei-8": "from pptx import Presentation\np = Presentation('in/pitch.pptx')\ns = p.slides.add_slide(p.slide_layouts[5])\ns.shapes.title.text = 'Questions?'\np.save('out/pitch.pptx')",
        "ei-9": "from pptx import Presentation\np = Presentation('in/pitch.pptx')\np.slides[2].placeholders[1].text_frame.add_paragraph().text = 'Launch in Q3'\np.save('out/pitch.pptx')",
    ]
}

extension OfficeEditIT {
    /// The same 9 edits as structured operations (the preferred path; applied by the bundled applier).
    static let referenceOps: [String: String] = [
        "ei-1": #"[{"op":"add_total_row","sum_columns":["amount"]}]"#,
        "ei-2": #"[{"op":"set_cell","match":{"column":"order_id","equals":1005},"column":"region","value":"West"}]"#,
        "ei-3": #"[{"op":"add_column","header":"Tax","formula":"={amount}*0.1"}]"#,
        "ei-4": #"[{"op":"append_paragraph","text":"Approved by the board on 3 March."}]"#,
        "ei-5": #"[{"op":"replace_text","find":"Draft","replace":"Final"}]"#,
        "ei-6": #"[{"op":"append_heading","text":"Next steps"},{"op":"append_bullets","items":["Book the venue","Send the invites"]}]"#,
        "ei-7": #"[{"op":"set_title","slide":2,"text":"Market size"}]"#,
        "ei-8": #"[{"op":"add_slide","title":"Questions?"}]"#,
        "ei-9": #"[{"op":"add_bullet","slide":3,"text":"Launch in Q3"}]"#,
    ]
}

final class OfficeEditServiceTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    func testReferenceEditsAreNewVersionsKeepStylesAndNeverTouchTheOriginal() async throws {
        let runtime = try await FileToolsIT.runtime()
        let client = FileToolsClient(network: false)
        let outRoot = FileToolsIT.repo.appending(path: "build/at/AT-276/\(FileToolsIT.date)/reference")
        try? FileManager.default.removeItem(at: outRoot)
        var evidence: [[String: Any]] = []
        for row in try OfficeEditIT.rows() {
            let (db, store, chatID, attachment, original, sha) = try await OfficeEditIT.chat(row.file, linked: true)
            let tool = EditOfficeFileTool(runtimePath: { runtime.path }, client: client)
            let code = try XCTUnwrap(OfficeEditIT.reference[row.id])
            let args = String(decoding: try JSONSerialization.data(withJSONObject: ["file": row.file, "code": code, "instruction": row.instruction]), as: UTF8.self)
            let text = try await tool.run(argumentsJSON: args, chatID: chatID, messageID: nil, database: db, store: store)
            let result = try XCTUnwrap(FileOutResult.parse(text), "\(row.id): \(text)")
            XCTAssertEqual(result.version, 2, row.id)
            XCTAssertEqual(result.versions?.count, 2, row.id)
            XCTAssertEqual(try OfficeEditIT.sha(original), sha, "\(row.id): the uploaded original changed")
            XCTAssertNotEqual(try OfficeEditIT.sha(URL(fileURLWithPath: result.path)), sha, "\(row.id): no change saved")
            let dir = outRoot.appending(path: row.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: result.path), to: dir.appending(path: row.file))
            evidence.append(["id": row.id, "version": result.version, "original_sha_unchanged": true, "attachment": attachment])
            try await client.reset(chatID: chatID)
        }
        let style = try OfficeEditIT.styleDiff(edited: outRoot, out: outRoot.deletingLastPathComponent().appending(path: "reference-style.json"))
        XCTAssertEqual(style["passed"] as? Int, 9, "reference edits must keep every style: \(style)")
        // The structured-operations path on the same 9 edits.
        let opsRoot = outRoot.deletingLastPathComponent().appending(path: "reference-ops")
        try? FileManager.default.removeItem(at: opsRoot)
        for row in try OfficeEditIT.rows() {
            let (db, store, chatID, _, original, sha) = try await OfficeEditIT.chat(row.file, linked: true)
            let tool = EditOfficeFileTool(runtimePath: { runtime.path }, client: client)
            let ops = try XCTUnwrap(OfficeEditIT.referenceOps[row.id])
            let args = #"{"file":"\#(row.file)","operations":\#(ops)}"#
            let text = try await tool.run(argumentsJSON: args, chatID: chatID, messageID: nil, database: db, store: store)
            let result = try XCTUnwrap(FileOutResult.parse(text), "\(row.id) ops: \(text)")
            XCTAssertEqual(try OfficeEditIT.sha(original), sha)
            let dir = opsRoot.appending(path: row.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: result.path), to: dir.appending(path: row.file))
            try await client.reset(chatID: chatID)
        }
        let opsStyle = try OfficeEditIT.styleDiff(edited: opsRoot, out: opsRoot.deletingLastPathComponent().appending(path: "reference-ops-style.json"))
        XCTAssertEqual(opsStyle["passed"] as? Int, 9, "structured operations must make the change and keep every style: \(opsStyle)")
        FileToolsIT.evidence("AT-276", "reference.json", String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    /// h4-4 (holdout4 runs 2 and 3): a title edit next to the slide's body restated as it is (the outline's ' / '
    /// join, or the title + bullets as lines) saves on the first call, changes only the title, and keeps each bullet
    /// its own paragraph. A body whose bullets really are merged is refused with that reason.
    func testATitleEditWithTheBodyRestatedChangesOnlyTheTitle() async throws {
        let runtime = try await FileToolsIT.runtime()
        let client = FileToolsClient(network: false)
        let restated = [
            #"[{"op":"set_title","slide":2,"text":"Audience"},{"op":"set_text","slide":2,"text":"Commuters / Tourists / Freight"}]"#,
            #"[{"op":"set_title","slide":2,"text":"Audience"},{"op":"replace_text","slide":2,"text":"Market\nCommuters\nTourists\nFreight"}]"#,
        ]
        for ops in restated {
            let (db, store, chatID, _, _, _) = try await OfficeEditIT.chat("pitch.pptx", linked: true)
            let tool = EditOfficeFileTool(runtimePath: { runtime.path }, client: client)
            let text = try await tool.run(argumentsJSON: #"{"file":"pitch.pptx","operations":\#(ops)}"#, chatID: chatID,
                                          messageID: nil, database: db, store: store)
            XCTAssertNotNil(FileOutResult.parse(text), "\(ops): \(text)")
            XCTAssertTrue(text.contains("slide 2 title: Market -> Audience"), text)
            XCTAssertFalse(text.contains("slide 2 text:"), "the body must stay as it was: \(text)")
            try await client.reset(chatID: chatID)
        }
        let (db, store, chatID, _, _, _) = try await OfficeEditIT.chat("pitch.pptx", linked: true)
        let tool = EditOfficeFileTool(runtimePath: { runtime.path }, client: client)
        let merged = try await tool.run(argumentsJSON: #"{"file":"pitch.pptx","operations":[{"op":"set_text","slide":2,"text":"Commuters, Tourists, Freight"}]}"#,
                                        chatID: chatID, messageID: nil, database: db, store: store)
        XCTAssertNil(FileOutResult.parse(merged), merged)
        XCTAssertTrue(merged.contains("were merged into 1"), merged)
        try await client.reset(chatID: chatID)
    }
}

final class OfficeEditRealTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    func testNineInstructionsEditInPlace() async throws {
        guard ProcessInfo.processInfo.environment["ANTICHAT_TIER"] == "T1" else { throw XCTSkip("OfficeEditRealTests requires TIER=T1") }
        let runtime = try await FileToolsIT.runtime()
        let model = PrefixReuseTests.view("chat-9b-q4")
        guard FileManager.default.fileExists(atPath: model.path) else { throw XCTSkip("chat-9b-q4 is not installed") }
        let slot = ModelSlot(engine: .mlx, key: "chat-9b-q4", path: model.path)
        let engine = EngineClient(appBuild: "it-office-edit")
        try await engine.ensureConnected()
        try await engine.setPolicy(SetPolicy(budgetB: UInt64(9.5e9)))
        if let error = await engine.warmup(slot) { throw error }
        defer { engine.disconnect() }
        let client = FileToolsClient(network: false)
        let tag = OfficeEditIT.variant == "main" ? "" : "-\(OfficeEditIT.variant)"
        let outRoot = FileToolsIT.repo.appending(path: "build/at/AT-276/\(FileToolsIT.date)/out\(tag)")
        try? FileManager.default.removeItem(at: outRoot)
        var evidence: [[String: Any]] = []
        var originalsKept = 0
        for row in try OfficeEditIT.rows() {
            let (db, store, chatID, attachment, original, sha) = try await OfficeEditIT.chat(row.file)
            let registry = ToolRegistry([FileToolsTools.editOffice(store: store, database: db, runtimePath: { runtime.path }, client: client)])
            let tools = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(.t1), tier: { .t1 })
            let controller = TurnController(chatID: chatID, database: db, engine: engine, tools: tools) { slot }
            let updates = UpdateBox()
            let listener = Task { for await update in controller.updates { updates.append(update) } }
            let assistantID = StorageID.make()
            await controller.start(.send(userID: StorageID.make(), text: row.instruction + " (edit my \(row.file) in place)", parentID: nil,
                                         attachmentIDs: [attachment]), assistantID: assistantID)
            // A turn that does not finish in time counts as a failed edit (recorded), never aborts the other runs.
            var status = "timeout", replyText = ""
            if let update = try? await updates.finished(assistantID, timeout: .seconds(480)) {
                status = update.status.rawValue; replyText = update.text
            } else {
                await controller.stop()
            }
            listener.cancel()
            // Keyed by id and start: a local engine reuses call ids across steps, so the id alone kept only the
            // last call of a retried edit (h4-4 run 2 showed just the skipped duplicate).
            var calls: [String: ToolActivity] = [:]
            for u in updates.snapshot() where u.assistantID == assistantID {
                if case .activity(let a) = u.kind { calls["\(a.id)@\(a.startedAt.timeIntervalSince1970)"] = a }
            }
            let trace = calls.values.sorted { $0.startedAt < $1.startedAt }.map {
                ["tool": $0.tool, "state": $0.state.rawValue, "args": String($0.argumentsJSON.prefix(400)),
                 "result": String(($0.result ?? "").prefix(400))]
            }
            if try OfficeEditIT.sha(original) == sha { originalsKept += 1 }
            let newest: String? = try db.read { db in
                try String.fetchOne(db, sql: """
                    SELECT b.path FROM artifact_version v JOIN file_blob b ON b.id = v.blob_id
                    WHERE v.n > 1 AND v.artifact_id IN (SELECT artifact_id FROM artifact_version WHERE n = 1 AND spec_json = ?)
                    ORDER BY v.n DESC LIMIT 1
                    """, arguments: [EditOfficeFileTool.linkSpec(attachment)])
            }
            if let newest {
                let dir = outRoot.appending(path: row.id)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: newest), to: dir.appending(path: row.file))
            }
            evidence.append(["id": row.id, "status": status, "edited": newest != nil, "reply": String(replyText.prefix(300)), "calls": trace])
            try await client.reset(chatID: chatID)
        }
        let style = try OfficeEditIT.styleDiff(edited: outRoot, out: outRoot.deletingLastPathComponent().appending(path: "style\(tag).json"))
        FileToolsIT.evidence("AT-276", "real\(tag).json", String(decoding: try JSONSerialization.data(withJSONObject: [
            "runs": evidence, "originals_unchanged": originalsKept, "style_passed": style["passed"] ?? 0,
        ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        let n = try OfficeEditIT.rows().count
        XCTAssertEqual(originalsKept, n, "the original must never be overwritten")
        XCTAssertGreaterThanOrEqual((style["passed"] as? Int ?? 0) * 9, 8 * n, "AT-276 check 1: change + style invariants in >= 8/9")
    }
}
