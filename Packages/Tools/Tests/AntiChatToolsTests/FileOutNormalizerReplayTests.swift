// AT-273 / AT-275 (M9.T05 Phase B, round 60, T1 chat-9b-q4): every recorded tool call of every prompt that made no file
// (AT-273: 29 of 150; AT-275: 13 of 20) or a file of the wrong format (AT-273 csv-24) is replayed through the
// file-out normaliser and the tool's own checks. Fixture: Fixtures/fileout-t05-failures.json (the calls' raw arguments
// and recorded errors, copied from build/at/AT-27x/t05/model/fileout-golden.json). Each case must end as a valid spec of
// the requested format, or as the deliberate error named below — never as a file of another format.
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatTools

struct T05Case: Decodable, Sendable, CustomTestStringConvertible {
    var at: String
    var id: String
    var call: Int
    var format: String
    var prompt: String
    var images: [String]
    var produced: String?
    var tool: String
    var args: String
    var recorded_error: String
    var key: String { call == 0 ? id : "\(id)#\(call)" }
    var testDescription: String { "\(at) \(key)" }
}

enum T05Fixture {
    static let cases: [T05Case] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fileout-t05-failures.json")
        struct F: Decodable { var cases: [T05Case] }
        return (try? JSONDecoder().decode(F.self, from: Data(contentsOf: url)).cases) ?? []
    }()

    /// The picture ids of a case: the attachment ids the bench put in the prompt (the UUIDs the model copied into its
    /// arguments, in order), padded with stand-ins up to the prompt's photo count.
    static func attached(_ c: T05Case) -> [AttachedImage] {
        let re = try! NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        var ids: [String] = []
        for m in re.matches(in: c.args, range: NSRange(c.args.startIndex..., in: c.args)) {
            let id = (c.args as NSString).substring(with: m.range)
            if !ids.contains(id) { ids.append(id) }
        }
        ids = Array(ids.prefix(c.images.count))
        while ids.count < c.images.count { ids.append("att-\(c.id)-\(ids.count + 1)") }
        return ids.enumerated().map { AttachedImage(id: $1, name: c.images[$0].replacingOccurrences(of: "img-", with: "") + ".jpg") }
    }

    static func context(_ c: T05Case) -> FileOutAdjustContext {
        let ids = Set(attached(c).map(\.id))
        return FileOutAdjustContext(userText: c.prompt, attachedImages: attached(c), imageExists: { ids.contains($0) })
    }
}

@Suite("FileOutNormalizerReplayTests") struct FileOutNormalizerReplayTests {
    enum Outcome: Equatable {
        /// A valid spec of the requested format.
        case file
        /// The engine cut the call off at the output limit (arguments `{}`): nothing to normalise — the harness's
        /// cut-off retry (now with a concrete size and the 8192-token file step) is the path, not the validator.
        case cutOff
        /// A deliberate, clear error → the repair turn (forced call + example), never a file of another format.
        case error(String)
    }

    /// The expected outcome per recorded call (AT-273 failures, csv-24's wrong format, AT-275 decks).
    static let expected: [String: Outcome] = [
        // AT-273: spreadsheets
        "csv-08": .file,       // CSV + a chart-only second sheet → the data sheet as CSV, chart left out (note)
        "csv-14": .file,       // sheets as a JSON string
        "csv-16": .cutOff,
        "csv-16#1": .file,     // sheets as a JSON string missing its closing "]"
        "csv-24": .error("every sheet is empty"),  // was a silent .xlsx; now CSV as asked, and empty sheets → repair
        "csv-30": .file,       // two sheets + formulas in a CSV → Sheet1 only, formulas left out (notes)
        "xlsx-03": .file,      // sheets as a JSON string
        "xlsx-09": .file,      // chart categories / values as literal lists → the Company / Share columns
        "xlsx-11": .file,      // chart on its own sheet naming the data sheet's headers → moved onto the data sheet
        "xlsx-13": .file,      // formulas keyed by column name with names inside → per-row cell formulas
        "xlsx-14": .file,      // "Total": "SUM(B2:B8)" → C9 + label, the placeholder empty row reused
        "xlsx-16": .cutOff,
        "xlsx-18": .error("every sheet is empty"),  // column_widths ["auto"] fixed, but the sheet has no content
        "xlsx-26": .file,      // sheets as a JSON string
        "xlsx-30": .file,      // invented data_ref (no query in the chat) → header-only sheets; chart w/o data left out
        // AT-273: documents (ids are the chat's attached photos once the bench sends them like the app)
        "docx-04": .file, "docx-22": .file, "docx-25": .file, "docx-29": .file, "docx-30": .file,
        "md-04": .file, "md-16": .cutOff, "md-22": .file, "md-25": .file, "md-30": .file,
        "pdf-04": .file, "pdf-16": .cutOff, "pdf-22": .file, "pdf-25": .file, "pdf-29": .file, "pdf-30": .file,
    ]

    @Test func fixtureHasEveryRecordedFailure() {
        let cases = T05Fixture.cases
        #expect(Set(cases.filter { $0.at == "AT-273" && $0.produced == nil }.map(\.id)).count == 29)
        #expect(Set(cases.filter { $0.at == "AT-275" }.map(\.id)).count == 13)
        #expect(cases.contains { $0.id == "csv-24" && $0.produced == "csv-24.xlsx" })
        for c in cases where c.at == "AT-273" { #expect(Self.expected[c.key] != nil, "no expectation for \(c.key)") }
    }

    static func adjusted(_ c: T05Case) -> FileOutAdjusted {
        let ctx = T05Fixture.context(c)
        switch c.tool {
        case SpreadsheetSchemas.createName: return FileOutNormalizer.spreadsheet(c.args, ctx)
        case PresentationSchemas.name: return FileOutNormalizer.presentation(c.args, ctx)
        default: return FileOutNormalizer.document(c.args, ctx)
        }
    }

    static func problems(_ c: T05Case, json: String) -> [String] {
        let ctx = T05Fixture.context(c)
        let wrong = FileOutNormalizer.wrongToolProblem(tool: c.tool, userText: c.prompt).map { [$0] } ?? []
        switch c.tool {
        case SpreadsheetSchemas.createName: return wrong + CreateSpreadsheetTool.problems(argumentsJSON: json, refs: { _ in nil })
        case PresentationSchemas.name: return wrong + CreatePresentationTool.problems(argumentsJSON: json, imageExists: ctx.imageExists)
        default: return wrong + CreateDocumentTool.problems(argumentsJSON: json, imageExists: ctx.imageExists)
        }
    }

    /// The format the spec would be written as.
    static func format(_ c: T05Case, json: String) -> String? {
        switch c.tool {
        case SpreadsheetSchemas.createName: return (try? SpreadsheetSpec.parse(json))?.format.rawValue
        case PresentationSchemas.name: return "pptx"
        default: return (try? CreateDocumentTool.decode(json))?.format.rawValue
        }
    }

    @Test(arguments: T05Fixture.cases.filter { $0.at == "AT-273" })
    func at273Replay(_ c: T05Case) throws {
        let out = Self.adjusted(c)
        let found = Self.problems(c, json: out.json)
        switch try #require(Self.expected[c.key]) {
        case .file:
            #expect(found.isEmpty, "\(c.key): \(found) — \(out.json.prefix(600))")
            #expect(Self.format(c, json: out.json) == c.format, "\(c.key): requested \(c.format)")
            if c.images.isEmpty { #expect(!Self.problems(c, json: c.args).isEmpty || c.id == "csv-24", "\(c.key) failed before") }
        case .cutOff:
            #expect(c.args == "{}" && c.recorded_error == "cut off at the output limit")
            #expect(!found.isEmpty)
        case .error(let text):
            #expect(found.contains { $0.contains(text) }, "\(c.key): \(found)")
            #expect(Self.format(c, json: out.json) == c.format, "never another format: \(c.key)")
        }
    }

    /// Valid spreadsheet specs render (libxlsxwriter / CSV in-process) and the CSV ones hold the data sheet.
    @Test(arguments: T05Fixture.cases.filter { $0.tool == SpreadsheetSchemas.createName && Self.expected[$0.key] == .file })
    func spreadsheetsRender(_ c: T05Case) throws {
        let spec = try SpreadsheetSpec.parse(Self.adjusted(c).json)
        let data = try CreateSpreadsheetTool.render(spec)
        #expect(data.count > 20)
        if spec.format == .csv {
            #expect(spec.sheets.count == 1 && !spec.sheets[0].rows.isEmpty, "\(c.key)")
            #expect(spec.sheets[0].formulas.isEmpty && spec.sheets[0].chart == nil)
        }
    }

    @Test func notesSayWhatChanged() throws {
        func note(_ key: String) throws -> [String] {
            try Self.adjusted(#require(T05Fixture.cases.first { $0.key == key })).notes
        }
        #expect(try note("csv-08").contains { $0.contains("cannot hold a chart") })
        #expect(try note("csv-30").contains { $0.contains("holds one table") && $0.contains("Sheet2") })
        #expect(try note("csv-30").contains { $0.contains("cannot hold formulas") })
        #expect(try note("csv-24").contains { $0.contains("You asked for a CSV file") })
        #expect(try note("md-30").contains { $0.contains("Image not available") })
        #expect(try note("csv-14").isEmpty, "a pure shape fix needs no note")
    }

    @Test func spreadsheetDetails() throws {
        func spec(_ key: String) throws -> SpreadsheetSpec {
            try SpreadsheetSpec.parse(Self.adjusted(#require(T05Fixture.cases.first { $0.key == key })).json)
        }
        let pie = try #require(spec("xlsx-09").sheets[0].chart)
        #expect(pie.categories == "A2:A4" && pie.values == ["B2:B4"])
        let bar = try spec("xlsx-11")
        #expect(bar.sheets.count == 1 && bar.sheets[0].chart?.categories == "A2:A9")
        let loan = try spec("xlsx-13").sheets[0]
        #expect(loan.formulas["D2"] == "PMT(B2/12, C2*12, -A2)", "\(loan.formulas)")
        #expect(loan.formulas["F4"] == "E4 - A4")
        let hours = try spec("xlsx-14").sheets[0]
        #expect(hours.formulas == ["C9": "SUM(B2:B8)", "A9": "\"Total\""], "\(hours.formulas)")
        #expect(hours.rows.count == 7, "the placeholder empty row is the total row")
        let stock = try spec("csv-16#1").sheets[0]
        #expect(stock.rows.count == 10)
        let csv08 = try spec("csv-08")
        #expect(csv08.format == .csv && csv08.sheets[0].name == "Monthly Temperatures" && csv08.sheets[0].rows.count == 12)
    }

    @Test func documentImageRefs() throws {
        func doc(_ key: String) throws -> (CreateDocumentSpec, [AttachedImage]) {
            let c = try #require(T05Fixture.cases.first { $0.key == key })
            return (try CreateDocumentTool.decode(Self.adjusted(c).json), T05Fixture.attached(c))
        }
        // markdown alt text "Garden Scene" matches the declared image of that alt.
        let (pdf04, att04) = try doc("pdf-04")
        #expect(DocumentAST.imageRefs(DocumentAST.parse(pdf04.markdown)).sorted() == att04.map(\.id).sorted())
        // photo1 → the first attached photo; photo2…6 (one photo attached) → visible placeholders.
        let (md30, att30) = try doc("md-30")
        #expect(DocumentAST.imageRefs(DocumentAST.parse(md30.markdown)) == [att30[0].id])
        #expect(md30.markdown.components(separatedBy: "[Image not available:").count - 1 == 5)
        // photo_<id> → <id>.
        let (md25, att25) = try doc("md-25")
        #expect(md25.images?.map(\.ref) == [att25[0].id])
        // no `images` list but attached ids in the Markdown → listed.
        let (docx04, att04b) = try doc("docx-04")
        #expect(docx04.images?.map(\.ref) == att04b.map(\.id))
    }

    /// Requested format inside one tool wins; another tool's format is an error, never a file.
    @Test func requestedFormat() {
        #expect(FileOutNormalizer.requestedFormat("Make me a CSV file named \"X\": a workbook") == "csv")
        #expect(FileOutNormalizer.requestedFormat("Make me a Excel spreadsheet named \"X\"") == "xlsx")
        #expect(FileOutNormalizer.requestedFormat("Make me a Word document titled \"X\"") == "docx")
        #expect(FileOutNormalizer.requestedFormat("Make me a Markdown file titled \"X\"") == "md")
        #expect(FileOutNormalizer.requestedFormat("Make me a PDF titled \"X\"") == "pdf")
        // M9 review F2: the attached CSV is the source; the Excel file is the request.
        #expect(FileOutNormalizer.requestedFormat("Turn the attached CSV into an Excel file") == "xlsx")
        #expect(FileOutNormalizer.requestedFormat("Make a CSV and an Excel file") == nil, "two outputs: no guess")
        #expect(FileOutNormalizer.requestedFormat("Write a short poem") == nil)
        #expect(FileOutNormalizer.requestedFormat("in a word, summarise") == nil)
        let wrong = FileOutNormalizer.document(##"{"format":"pdf","title":"T","markdown":"# T"}"##,
                                               FileOutAdjustContext(userText: "Make me a Word document titled T"))
        #expect(wrong.json.contains(#""format":"docx""#))
        #expect(FileOutNormalizer.wrongToolProblem(tool: "create_document", userText: "Make me a CSV file of my budget")?
            .contains("call create_spreadsheet instead") == true)
        #expect(FileOutNormalizer.wrongToolProblem(tool: "create_spreadsheet", userText: "Make me a CSV file") == nil)
    }

    @Test func lenientJSON() {
        #expect(FileOutNormalizer.parseLenient(#"[{"a": [1, 2]}"#) as? [[String: [Int]]] == [["a": [1, 2]]])
        #expect(FileOutNormalizer.parseLenient(#"{"a": "x"#) as? [String: String] == ["a": "x"])
        #expect(FileOutNormalizer.parseLenient(#"[{"a": 1]]"#) == nil, "a wrong closer is broken, not cut")
        #expect(FileOutNormalizer.parseLenient("hello") == nil)
    }

    /// T05 round 67 (release candidate e8fe19986): the recorded calls whose `sheets` JSON string was malformed —
    /// csv-30 (rows without their outer `[`), xlsx-01 (rows without their `]`), xlsx-30 (the sheet list closed after
    /// sheet 1) — each the same call on every repair step, then a text answer. Each is now a valid spec of its format.
    @Test func round67MalformedSheets() throws {
        struct C: Decodable { var id: String; var format: String; var prompt: String; var args: String }
        struct F: Decodable { var cases: [C] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fileout-t05-r67-failures.json")
        let cases = try JSONDecoder().decode(F.self, from: Data(contentsOf: url)).cases
        #expect(cases.map(\.id) == ["csv-30", "xlsx-01", "xlsx-30"])
        for c in cases {
            #expect(!CreateSpreadsheetTool.problems(argumentsJSON: c.args, refs: { _ in nil }).isEmpty, "\(c.id) failed as recorded")
            let fixed = FileOutNormalizer.spreadsheet(c.args, FileOutAdjustContext(userText: c.prompt))
            #expect(CreateSpreadsheetTool.problems(argumentsJSON: fixed.json, refs: { _ in nil }).isEmpty, "\(c.id): \(fixed.json.prefix(300))")
            let spec = try SpreadsheetSpec.parse(fixed.json)
            #expect(spec.format.rawValue == c.format, "\(c.id)")
            #expect(spec.sheets.allSatisfy { !$0.rows.isEmpty }, "\(c.id): every sheet keeps its rows")
        }
        // xlsx-30 keeps both sheets
        let x30 = try #require(cases.last)
        #expect(try SpreadsheetSpec.parse(FileOutNormalizer.spreadsheet(x30.args, FileOutAdjustContext(userText: x30.prompt)).json).sheets.count == 2)
    }

    /// T05 round 67 csv-30: `rows` as a run of lists without its outer `[` (the same call three times → no file).
    @Test func bareRowRuns() {
        typealias O = [String: Any]
        func rows(_ s: String) -> [[Any]]? { ((FileOutNormalizer.parseLenient(s) as? [O])?.first?["rows"]) as? [[Any]] }
        // the run ends at the next key
        let keyed = #"[{"name": "S", "rows": ["a", 1, true], ["b", 2, false], "freeze_header": true}]"#
        #expect(rows(keyed)?.count == 2)
        #expect((FileOutNormalizer.parseLenient(keyed) as? [O])?.first?["freeze_header"] as? Bool == true)
        // … at the object's end, then a second sheet
        let twoSheets = #"[{"name": "S", "rows": ["a", 1], ["b", 2], ["c", 3]}, {"name": "T", "rows": [["x"]]}]"#
        #expect(rows(twoSheets)?.map { $0[0] as? String } == ["a", "b", "c"])
        #expect((FileOutNormalizer.parseLenient(twoSheets) as? [O])?.count == 2)
        // … at the stray closer the model did write
        #expect(rows(#"[{"rows": ["a", 1], ["b", 2]], "name": "S"}]"#)?.count == 2)
        // … and cut short inside the run
        #expect(rows(#"[{"name": "S", "rows": ["a", 1], ["b", 2"#)?.count == 2)
        // a list value followed by a key is untouched; a broken text stays broken
        #expect(FileOutNormalizer.wrapBareArrayRuns(#"{"a": [1], "b": 2"#) == nil)
        #expect(FileOutNormalizer.parseLenient(#"[{"a": 1]]"#) == nil)
        // T05 round 67 xlsx-01: the rows list's `]` missing before the sheet's `}`
        let unclosed = #"[{"name": "Budget", "rows": [["Housing", 1500], ["Total", "=SUM(B2:B2)"]}, {"name": "Summary", "rows": [["x"]]}]"#
        #expect(rows(unclosed)?.count == 2)
        #expect((FileOutNormalizer.parseLenient(unclosed) as? [O])?.count == 2)
        // T05 round 67 xlsx-30 / xlsx-01: the sheet list closed after a sheet (and a surplus `}`), then the next sheet
        let early = #"[{"name": "A", "rows": [["x", 1]]}], {"name": "B", "rows": [["y", 2]]}]"#
        #expect((FileOutNormalizer.parseLenient(early) as? [O])?.map { $0["name"] as? String } == ["A", "B"])
        let surplus = #"[{"name": "A", "rows": [["x", 1]}]}, {"name": "B", "rows": [["y", 2]]}]"#
        #expect((FileOutNormalizer.parseLenient(surplus) as? [O])?.map { $0["name"] as? String } == ["A", "B"])
        #expect(FileOutNormalizer.parseLenient(#"[1], 2"#) == nil, "only a list or object continues the list")
        // the whole call: sheets as a JSON string with such rows → a valid CSV spec
        let raw = #"{"filename":"Everything Workbook","format":"csv","sheets":"[{\"name\": \"Sheet1\", \"columns\": [{\"header\": \"Date\", \"type\": \"date\"}, {\"header\": \"Sales\", \"type\": \"number\"}], \"rows\": [\"2024-01-01\", 100], [\"2024-01-02\", 120]}]"}"#
        let fixed = FileOutNormalizer.spreadsheet(raw, FileOutAdjustContext(userText: "Make me a CSV file named \"Everything Workbook\""))
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: fixed.json, refs: { _ in nil }).isEmpty, "\(fixed.json)")
    }

    @Test func repairExamplesAreValid() throws {
        let ctx = FileOutAdjustContext(attachedImages: [AttachedImage(id: "att-1", name: "001.jpg")], imageExists: { $0 == "att-1" })
        func json(_ s: String) -> String { String(s[..<s.range(of: " (")!.lowerBound]) }
        let csv = json(FileOutNormalizer.repairExample(tool: "create_spreadsheet", argumentsJSON: #"{"format":"csv"}"#, ctx: ctx))
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: csv, refs: { _ in nil }).isEmpty)
        #expect(try SpreadsheetSpec.parse(csv).format == .csv)
        let xlsx = json(FileOutNormalizer.repairExample(tool: "create_spreadsheet", argumentsJSON: "{}", ctx: ctx))
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: xlsx, refs: { _ in nil }).isEmpty)
        let doc = json(FileOutNormalizer.repairExample(tool: "create_document", argumentsJSON: #"{"format":"pdf"}"#, ctx: ctx))
        #expect(CreateDocumentTool.problems(argumentsJSON: doc, imageExists: ctx.imageExists).isEmpty)
        #expect(doc.contains(#""format":"pdf""#) && doc.contains("att-1"))
        let deck = json(FileOutNormalizer.repairExample(tool: "create_presentation", argumentsJSON: "{}", ctx: ctx))
        #expect(CreatePresentationTool.problems(argumentsJSON: deck, imageExists: ctx.imageExists).isEmpty)
    }
}

/// AT-275 (7/20 decks): all 13 failures were `$.slides[n].image_ref: no attachment or file with id "<id>"` for the very
/// ids the bench gave. Cause: the bench wrote the attachment rows as drafts (no message) and sent the message without
/// them; the app's composer sends them with the message (`.send(attachmentIDs:)` sets `message_id`), and the lookup
/// rightly ignores drafts (M4 review: an unsent draft is no chat's picture). The replay: the same arguments against the
/// same rows as a draft (the recorded error) and as sent with the message (valid, and normalised unchanged).
@Suite("AttachmentLookupReplayTests") struct AttachmentLookupReplayTests {
    struct Chat {
        let db: AppDatabase
        let store: ArtifactStore
        let chatID: String
        let userID: String
        let root: URL
    }

    static func chat(_ c: T05Case, sent: Bool) throws -> Chat {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: c.id)
        let root = try FileOutFixtures.scratch()
        let user = try MessageTree(db).append(chatID: chat.id, parentID: nil, role: .user)
        for a in T05Fixture.attached(c) {
            let file = root.appendingPathComponent(a.name)
            try Data("jpeg".utf8).write(to: file)
            // As antichat-bench fileout-golden (and AttachmentIntake) write them: a draft row…
            let blob = FileBlobRecord(sha256: UUID().uuidString, size: 4, path: file.path, origin: .upload)
            var att = AttachmentRecord(messageID: nil, blobID: blob.id, displayName: a.name, uti: "public.jpeg")
            att.id = a.id
            try db.write { d in try blob.insert(d); try att.insert(d) }
        }
        if sent {  // …then linked to the user message, as TurnController.write does for `.send(attachmentIDs:)`.
            let ids = T05Fixture.attached(c).map(\.id)
            _ = try db.write { d in
                try AttachmentRecord.filter(ids.contains(Column("id"))).updateAll(d, Column("message_id").set(to: user.id))
            }
        }
        return Chat(db: db, store: ArtifactStore(database: db, mediaRoot: root, incognito: false), chatID: chat.id, userID: user.id, root: root)
    }

    @Test(arguments: T05Fixture.cases.filter { $0.at == "AT-275" })
    func deckReplay(_ c: T05Case) throws {
        let draft = try Self.chat(c, sent: false)
        defer { try? FileManager.default.removeItem(at: draft.root) }
        let before = CreatePresentationTool.problems(argumentsJSON: c.args,
                                                     imageExists: { draft.store.imageData(ref: $0, chatID: draft.chatID) != nil })
        #expect(!before.isEmpty && c.recorded_error.contains(before[0].replacingOccurrences(of: "\"", with: "\\\"")),
                "the round-60 error reproduces with draft rows: \(before)")
        #expect(draft.store.attachedImages(chatID: draft.chatID).isEmpty, "drafts are no chat's pictures")

        let sent = try Self.chat(c, sent: true)
        defer { try? FileManager.default.removeItem(at: sent.root) }
        let exists: @Sendable (String) -> Bool = { [store = sent.store, chat = sent.chatID] in store.imageData(ref: $0, chatID: chat) != nil }
        #expect(CreatePresentationTool.problems(argumentsJSON: c.args, imageExists: exists).isEmpty)
        #expect(sent.store.attachedImages(chatID: sent.chatID).map(\.id) == T05Fixture.attached(c).map(\.id))
        let ctx = FileOutAdjustContext(userText: c.prompt, attachedImages: sent.store.attachedImages(chatID: sent.chatID),
                                       imageExists: exists)
        let out = FileOutNormalizer.presentation(c.args, ctx)
        #expect(CreatePresentationTool.problems(argumentsJSON: out.json, imageExists: exists).isEmpty)
        #expect(out.notes.isEmpty, "\(out.notes)")
        let refs = try CreatePresentationTool.decode(out.json).slides.compactMap(\.image_ref)
        #expect(Set(refs).isSubset(of: Set(T05Fixture.attached(c).map(\.id))) && !refs.isEmpty)
    }

    /// The same AT-273 documents against a real chat store: valid once the photos are sent with the message.
    @Test(arguments: T05Fixture.cases.filter { $0.at == "AT-273" && !$0.images.isEmpty })
    func documentReplay(_ c: T05Case) throws {
        let sent = try Self.chat(c, sent: true)
        defer { try? FileManager.default.removeItem(at: sent.root) }
        let exists: @Sendable (String) -> Bool = { [store = sent.store, chat = sent.chatID] in store.imageData(ref: $0, chatID: chat) != nil }
        let ctx = FileOutAdjustContext(userText: c.prompt, attachedImages: sent.store.attachedImages(chatID: sent.chatID),
                                       imageExists: exists)
        let out = FileOutNormalizer.document(c.args, ctx)
        #expect(CreateDocumentTool.problems(argumentsJSON: out.json, imageExists: exists).isEmpty, "\(c.key)")
        #expect(try CreateDocumentTool.decode(out.json).format.rawValue == c.format)
    }
}
