// M9 review F1 / F2 / F3: the file-out normaliser with no attached pictures (no crash: a visible placeholder and a
// note), the requested *output* format (a source format named in the message is not a request), and totals on a
// query-result sheet placed for the result's real row count.
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct FileOutNormalizerReviewTests {
    static func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: F1

    @Test func numberedImageRefsWithNoAttachedPicturesBecomePlaceholders() throws {
        let ctx = FileOutAdjustContext(userText: "Make a deck with photo1 and photo2")
        let doc = FileOutNormalizer.document(##"{"format":"pdf","title":"Trip","markdown":"# Trip\n\n![](photo1)\n\n![Beach](photo2)"}"##, ctx)
        let markdown = try #require(try Self.object(doc.json)["markdown"] as? String)
        #expect(markdown.contains("*[Image not available: image]*") && markdown.contains("*[Image not available: Beach]*"))
        #expect(doc.notes.contains { $0.contains("No picture is attached") })
        #expect(CreateDocumentTool.problems(argumentsJSON: doc.json, imageExists: ctx.imageExists).isEmpty)

        let deck = FileOutNormalizer.presentation(#"{"filename":"Trip","slides":[{"layout":"title","title":"Trip"},{"layout":"image","title":"Day 1","image_ref":"photo1"},{"layout":"title_bullets_image","title":"Day 2","bullets":["Beach"],"image_ref":"photo0"}]}"#, ctx)
        let slides = try #require(try Self.object(deck.json)["slides"] as? [[String: Any]])
        #expect(slides[1]["image_ref"] == nil && slides[1]["layout"] as? String == "bullets")
        #expect(slides[1]["bullets"] as? [String] == ["[Image not available: photo1]"])
        #expect(slides[2]["bullets"] as? [String] == ["Beach", "[Image not available: photo0]"])
        #expect(deck.notes.contains { $0.contains("No picture is attached") && $0.contains("[Image not available]") })
        #expect(CreatePresentationTool.problems(argumentsJSON: deck.json, imageExists: ctx.imageExists).isEmpty)

        // With pictures attached, a number past the last one is a placeholder too (and photo1 still resolves).
        let one = FileOutAdjustContext(attachedImages: [AttachedImage(id: "att-1", name: "a.jpg")], imageExists: { $0 == "att-1" })
        let mixed = FileOutNormalizer.presentation(#"{"filename":"T","slides":[{"layout":"image","title":"A","image_ref":"photo1"},{"layout":"image","title":"B","image_ref":"photo7"}]}"#, one)
        let s = try #require(try Self.object(mixed.json)["slides"] as? [[String: Any]])
        #expect(s[0]["image_ref"] as? String == "att-1")
        #expect(s[1]["image_ref"] == nil && (s[1]["bullets"] as? [String])?.first == "[Image not available: photo7]")
    }

    // MARK: F2

    @Test func onlyTheRequestedOutputFormatCounts() {
        let cases: [(String, String?)] = [
            ("Put the numbers from this PDF into a spreadsheet", nil),
            ("Write a doc with talking points for my presentation", nil),
            ("Summarize the attached PDF", nil),
            ("Make a spreadsheet from the CSV I uploaded", nil),
            ("Make an Excel file from this PDF", "xlsx"),
            ("Pull the table out of this PDF and export it to CSV", "csv"),
            ("Convert the PDF to a Word document", "docx"),
            ("Turn this CSV into an Excel file", "xlsx"),
            ("Summarize the attached PDF as a Markdown file", "md"),
            ("Use my slides to write a PDF handout", "pdf"),
            ("Excel budget for my trip", "xlsx"),
            ("Make a CSV of my expenses", "csv"),
            ("Create a presentation about our Q3 results", "pptx"),
            ("I need a pdf and a Word document", nil),
        ]
        for (text, want) in cases {
            #expect(FileOutNormalizer.requestedFormat(text) == want, "\(text)")
        }
        #expect(FileOutNormalizer.wrongToolProblem(tool: SpreadsheetSchemas.createName,
                                                   userText: "Put the numbers from this PDF into a spreadsheet") == nil)
        #expect(FileOutNormalizer.wrongToolProblem(tool: FileOutSchemas.createDocumentName,
                                                   userText: "Write a doc with talking points for my presentation") == nil)
        #expect(FileOutNormalizer.wrongToolProblem(tool: FileOutSchemas.createDocumentName,
                                                   userText: "Make an Excel file from this PDF") != nil)
        // The spreadsheet keeps the format the call asked for when the message names a PDF only as its source.
        let ctx = FileOutAdjustContext(userText: "Put the numbers from this PDF into a CSV spreadsheet")
        let out = FileOutNormalizer.spreadsheet(#"{"filename":"Numbers","format":"xlsx","sheets":[{"name":"N","columns":[{"header":"A","type":"number"}],"rows":[[1]]}]}"#, ctx)
        #expect(out.json.contains(#""format":"csv""#))
        let kept = FileOutNormalizer.spreadsheet(#"{"filename":"Numbers","format":"xlsx","sheets":[{"name":"N","columns":[{"header":"A","type":"number"}],"rows":[[1]]}]}"#,
                                                 FileOutAdjustContext(userText: "Put the numbers from this PDF into a spreadsheet"))
        #expect(kept.json.contains(#""format":"xlsx""#) && kept.notes.isEmpty)
    }

    // MARK: F3

    static func ref(rows n: Int) -> DataRef {
        DataRef(id: "qr_1", sql: "select", columns: ["Name", "Hours"], types: ["VARCHAR", "DOUBLE"],
                rows: (1...n).map { ["p\($0)", "\($0)"] }, truncated: false)
    }

    @Test func totalsOnAQueryResultSheetFollowItsRowCount() throws {
        let ctx = FileOutAdjustContext(userText: "Make an Excel file of the hours with a total", dataRefs: ["qr_1"])
        let args = #"{"filename":"Hours","sheets":[{"name":"Data","data_ref":"qr_1","formulas":{"Total":"SUM(Hours)","Double":"Hours*2"}}]}"#
        let out = FileOutNormalizer.spreadsheet(args, ctx)
        for n in [3, 10, 15] {
            let ref = Self.ref(rows: n)
            let refs: (String) -> DataRef? = { $0 == "qr_1" ? ref : nil }
            #expect(CreateSpreadsheetTool.problems(argumentsJSON: out.json, refs: refs).isEmpty, "\(n)")
            let sheet = try #require(try SpreadsheetSpec.parse(out.json, refs: refs).sheets.first)
            #expect(sheet.rows.count == n)
            // The total sits in the first row below the data and sums every data row; no data row is overwritten.
            #expect(sheet.formulas["B\(n + 2)"] == "SUM(B2:B\(n + 1))", "\(n): \(sheet.formulas)")
            #expect(sheet.formulas["A\(n + 2)"] == "\"Total\"")
            #expect(!sheet.formulas.keys.contains { k in (2...(n + 1)).contains { k == "A\($0)" || k == "B\($0)" } })
            // A per-row formula naming a new column fills that column for every data row.
            #expect(sheet.columns.map(\.header) == ["Name", "Hours", "Double"])
            #expect(sheet.formulas["C2"] == "B2*2" && sheet.formulas["C\(n + 1)"] == "B\(n + 1)*2")
            _ = try CreateSpreadsheetTool.render(try SpreadsheetSpec.parse(out.json, refs: refs))
        }
    }
}
