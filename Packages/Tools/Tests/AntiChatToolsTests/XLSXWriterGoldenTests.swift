// M6.T10 task checks `XLSXWriterGoldenTests` + `CreateSpreadsheetToolTests` (AT-273 checks 1, 2): the 30 `xlsx-30` specs
// render with libxlsxwriter (no model, no network, no process) and their normalised sheet / shared-string / style / chart
// parts equal the frozen goldens; the files read back through the app's own reader (vendored XLSXAdapter → SheetLoader →
// DuckDB) with the right types; raw sheet XML proves formulas, number formats, frozen header, autofilter and native
// charts. The 30 `csv-30` specs are byte-equal (UTF-8 BOM, CRLF, RFC 4180 quoting).
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatTools

@Suite(.serialized, .enabled(if: FileOutFixtures.available, "fixtures/docs/golden-out/specs missing"))
struct XLSXWriterGoldenTests {
    static func render(_ id: String) throws -> URL {
        let spec = try SpreadsheetSpec.parse(FileOutFixtures.specJSON(id))
        let data = try CreateSpreadsheetTool.render(spec)
        FileOutFixtures.dump("\(id).\(spec.format.rawValue)", data)
        let url = try FileOutFixtures.scratch().appendingPathComponent("\(id).\(spec.format.rawValue)")
        try data.write(to: url)
        return url
    }

    /// The workbook's content parts (no docProps: they carry the creation time), one element per line.
    static func normalised(_ url: URL) throws -> String {
        let parts = try FileOutFixtures.entries(url).filter {
            $0.hasPrefix("xl/worksheets/sheet") || $0 == "xl/sharedStrings.xml" || $0 == "xl/styles.xml" || $0 == "xl/workbook.xml"
                || $0.hasPrefix("xl/charts/chart")
        }.sorted()
        return try parts.map { p in
            "== \(p)\n" + (try FileOutFixtures.part(url, p)).replacingOccurrences(of: "><", with: ">\n<")
        }.joined(separator: "\n") + "\n"
    }

    @Test func goldenWorkbookParts() throws {
        var failures: [String] = []
        for id in FileOutFixtures.ids("xlsx") {
            let text = try Self.normalised(try Self.render(id))
            if let diff = try FileOutFixtures.golden("\(id).xlsx.txt", Data(text.utf8)) { failures.append(diff) }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func csvGoldensAreByteEqual() throws {
        var failures: [String] = []
        for id in FileOutFixtures.ids("csv") {
            let data = try Data(contentsOf: try Self.render(id))
            #expect(data.starts(with: [0xEF, 0xBB, 0xBF]), "\(id): UTF-8 BOM")
            #expect(String(decoding: data, as: UTF8.self).hasSuffix("\r\n"), "\(id): CRLF")
            if let diff = try FileOutFixtures.golden("\(id).csv", data) { failures.append(diff) }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func formulasFormatsFreezeAutofilterChart() throws {
        // xlsx-30 "Everything Workbook": formulas, date/currency formats, bool, chart, two sheets.
        let url = try Self.render("xlsx-30")
        let s1 = try FileOutFixtures.part(url, "xl/worksheets/sheet1.xml")
        #expect(s1.contains("<f>C2*D2</f>"), "formula")
        #expect(s1.contains(#"<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>"#), "frozen header")
        #expect(s1.contains(#"<autoFilter ref="A1:F11"/>"#), "autofilter over the data")
        #expect(s1.contains(#"t="b""#), "boolean cells")
        #expect(s1.contains("<drawing "), "chart drawing")
        let styles = try FileOutFixtures.part(url, "xl/styles.xml")
        #expect(styles.contains(#"formatCode="yyyy-mm-dd""#) && styles.contains(##"formatCode="#,##0.00""##), "number formats")
        let chart = try FileOutFixtures.part(url, "xl/charts/chart1.xml")
        #expect(chart.contains("<c:barChart>") && chart.contains("Data'!$E$2:$E$11"), "native column chart on the totals")
        let entries = try FileOutFixtures.entries(url)
        #expect(entries.contains("xl/worksheets/sheet2.xml"), "second sheet")
        let core = try FileOutFixtures.part(url, "docProps/core.xml"), app = try FileOutFixtures.part(url, "docProps/app.xml")
        #expect(core.contains("<dc:creator>AntiChat</dc:creator>") && app.contains("<Company>AntiChat</Company>"))
        // No freeze / no filter when the spec says so (xlsx-17).
        let roster = try FileOutFixtures.part(try Self.render("xlsx-17"), "xl/worksheets/sheet1.xml")
        #expect(!roster.contains("<pane ") && !roster.contains("<autoFilter"))
        // Explicit widths (xlsx-18) and the auto width cap of 60 (xlsx-27 long text).
        let widths = try FileOutFixtures.part(try Self.render("xlsx-18"), "xl/worksheets/sheet1.xml")
        #expect(widths.contains(#"width="50.7109375""#) || widths.contains(#"width="50"#), "explicit width: \(widths.prefix(400))")
        let long = try FileOutFixtures.part(try Self.render("xlsx-27"), "xl/worksheets/sheet1.xml")
        #expect(long.contains(#"<col min="2" max="2" width="60.7109375""#), "auto width capped at 60")
        // Charts of every type.
        for (id, tag) in [("xlsx-08", "<c:lineChart>"), ("xlsx-09", "<c:pieChart>"), ("xlsx-10", "<c:scatterChart>"), ("xlsx-11", "<c:barChart>")] {
            #expect(try FileOutFixtures.part(try Self.render(id), "xl/charts/chart1.xml").contains(tag), "\(id) \(tag)")
        }
    }

    @Test func readsBackTypedThroughTheAppReader() async throws {
        let store = try DuckDBStore(chatID: "xw-\(UUID().uuidString)")
        let tables = try await SheetLoader.load(xlsx: try Self.render("xlsx-30"), into: store)
        #expect(tables.map(\.name) == ["Data", "Info"])
        let data = try #require(tables.first)
        #expect(data.rowCount == 10)
        // "Total" holds only formulas (no cached result) so its loaded type is the reader's empty-column default.
        #expect(Array(data.columns.map(\.type).prefix(4)) == [.varchar, .date, .bigint, .double] && data.columns[5].type == .boolean,
                "\(data.columns.map(\.type))")
        // Formula results are not cached by libxlsxwriter (Excel / Numbers compute them on open); the inputs read back.
        let r = try store.stringRows(#"SELECT sum("Qty"), min("Date"), count(*) FILTER (WHERE "Paid") FROM "Data""#).rows[0]
        #expect(r[0] == "55" && r[1] == "2026-01-31" && r[2] == "5", "\(r)")
        let multi = try await SheetLoader.load(xlsx: try Self.render("xlsx-24"), into: try DuckDBStore(chatID: "xw2-\(UUID().uuidString)"))
        #expect(multi.map(\.name) == ["t_2024", "t_2025", "t_2026"], "digit-led sheet names get the loader's t_ prefix")
        let scripts = try await SheetLoader.load(xlsx: try Self.render("xlsx-12"), into: store)
        #expect(scripts.first?.rowCount == 7)
    }

    // MARK: CreateSpreadsheetToolTests (validation → repair; data_ref; CSV rules)

    @Test func validationProblems() {
        let ref = DataRef(id: "qr_1", sql: "SELECT", columns: ["region", "total"], types: ["VARCHAR", "DOUBLE"],
                          rows: [["East", "10.5"], ["West", "3"]], truncated: false)
        let refs: (String) -> DataRef? = { $0 == "qr_1" ? ref : nil }
        let ok = #"{"filename":"a","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}],"rows":[[1],[2]]}]}"#
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: ok, refs: refs).isEmpty)
        let both = #"{"filename":"a","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}],"rows":[[1]],"data_ref":"qr_1"}]}"#
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: both, refs: refs) == ["$.sheets[0]: give either rows or data_ref, not both"])
        let neither = #"{"filename":"a","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}]}]}"#
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: neither, refs: refs).isEmpty, "a header-only template is fine")
        let byHeader = try! SpreadsheetSpec.parse(#"{"filename":"a","sheets":[{"name":"S","columns":[{"header":"Region","type":"text"},{"header":"Sales","type":"number"}],"rows":[["N",1],["S",2]],"chart":{"type":"bar","categories":"Region","values":["Sales"]}}]}"#)
        #expect(byHeader.sheets[0].chart?.categories == "A2:A3" && byHeader.sheets[0].chart?.values == ["B2:B3"])
        let missing = #"{"filename":"a","sheets":[{"name":"S","data_ref":"qr_9"}]}"#
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: missing, refs: refs) == [#"$.sheets[0].data_ref: no query result "qr_9" in this chat"#])
        let retyped = #"{"filename":"a","sheets":[{"name":"S","columns":[{"header":"Region","type":"text"},{"header":"Total","type":"number"}],"rows":[["East",10.5]]}]}"#
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: retyped, refs: refs, chatRefs: [ref]).contains { $0.contains("pass \"data_ref\": \"qr_1\"") })
        let csvFormula = #"{"filename":"a","format":"csv","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}],"rows":[[1]],"formulas":{"A3":"SUM(A2:A2)"}}]}"#
        #expect(CreateSpreadsheetTool.problems(argumentsJSON: csvFormula, refs: refs).contains { $0.contains("CSV cannot hold formulas") })
        let badCell = #"{"filename":"a","sheets":[{"name":"S","columns":[{"header":"x","type":"number"}],"rows":[[1]],"formulas":{"total":"SUM(A2)"},"chart":{"type":"pie","categories":"rows","values":["A2:A3"]}}]}"#
        let p = CreateSpreadsheetTool.problems(argumentsJSON: badCell, refs: refs)
        #expect(p.contains { $0.contains("\"total\" is not a cell") } && p.contains { $0.contains("\"rows\" is not a cell range") })
        #expect(ExportTableTool.problems(argumentsJSON: #"{"data_ref":"qr_9","format":"csv","filename":"x"}"#, refs: refs)
            == [#"$.data_ref: no query result "qr_9" in this chat"#])
    }

    @Test func missingColumnsTakeTheHeaderRow() throws {
        let x = try SpreadsheetSpec.parse(#"{"filename":"a","sheets":[{"name":"S","rows":[["Day","Hours","Date"],["Mon",7.5,"2026-01-05"],["Tue",8,"2026-01-06"]]}]}"#)
        #expect(x.sheets[0].columns.map(\.header) == ["Day", "Hours", "Date"])
        #expect(x.sheets[0].columns.map(\.type) == [.text, .number, .date] && x.sheets[0].rows.count == 2)
        let y = try SpreadsheetSpec.parse(#"{"filename":"a","sheets":[{"name":"S","rows":[[1,true],[2,false]]}]}"#)
        #expect(y.sheets[0].columns.map(\.header) == ["Column 1", "Column 2"] && y.sheets[0].columns.map(\.type) == [.number, .bool])
    }

    @Test func dataRefSheetsAndExport() throws {
        let ref = DataRef(id: "qr_2", sql: "SELECT", columns: ["region", "total", "day"], types: ["VARCHAR", "DOUBLE", "DATE"],
                          rows: [["East", "10.5", "2026-01-02"], ["West, Inc.", "3", nil]], truncated: false)
        let refs: (String) -> DataRef? = { $0 == "qr_2" ? ref : nil }
        let (spec, _) = try ExportTableTool.spec(#"{"data_ref":"qr_2","format":"csv","filename":"Totals"}"#, refs: refs)
        #expect(spec.outputName == "Totals.csv")
        let csv = String(decoding: try CreateSpreadsheetTool.render(spec), as: UTF8.self)
        #expect(csv == "\u{FEFF}region,total,day\r\nEast,10.5,2026-01-02\r\n\"West, Inc.\",3,\r\n")
        let x = try SpreadsheetSpec.parse(#"{"filename":"T.xlsx","sheets":[{"name":"Q","data_ref":"qr_2"}]}"#, refs: refs)
        #expect(x.outputName == "T.xlsx" && x.sheets[0].columns.map(\.type) == [.text, .number, .date])
        #expect(x.sheets[0].rows[0] == [.text("East"), .number(10.5), .text("2026-01-02")])
        let xlsx = try CreateSpreadsheetTool.render(x)
        #expect(xlsx.starts(with: [0x50, 0x4B]), "zip")
    }

    @Test func sheetNamesAndCells() {
        var used = Set<String>()
        #expect(XLSXWriter.sheetName("P&L [2026]: Q1/Q2", used: &used) == "P&L -2026-- Q1-Q2")
        #expect(XLSXWriter.sheetName("Data", used: &used) == "Data" && XLSXWriter.sheetName("data", used: &used) == "data (2)")
        #expect(XLSXWriter.sheetName(String(repeating: "x", count: 40), used: &used).count == 31)
        #expect(XLSXWriter.cell("B14")! == (13, 1) && XLSXWriter.cell("$AA$1")! == (0, 26) && XLSXWriter.cell("14") == nil)
        #expect(XLSXWriter.range("A2:A13", sheet: "Q's") == "='Q''s'!$A$2:$A$13")
        #expect(CSVWriter.field("a\"b") == "\"a\"\"b\"" && CSVWriter.field("x\ny") == "\"x\ny\"" && CSVWriter.field("plain") == "plain")
    }

    // MARK: VersioningServiceTests (R-273 AC4)

    @Test func revisionsMakeVersionTwoAndKeepVersionOne() throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "v"), other = try ChatRepository(db).create(title: "o")
        let store = ArtifactStore(database: db, mediaRoot: try FileOutFixtures.scratch(), incognito: false)
        let v1 = try CreateSpreadsheetTool.run(argumentsJSON: try FileOutFixtures.specJSON("xlsx-14"), chatID: chat.id, messageID: nil,
                                               store: store, refs: { _ in nil })
        let r1 = try #require(FileOutResult.parse(v1))
        #expect(r1.version == 1 && r1.versions == nil && r1.file == "Timesheet.xlsx")
        let service = VersioningService(store: store)
        #expect(service.problem(revises: r1.artifact_id, chatID: chat.id) == nil)
        #expect(service.problem(revises: r1.artifact_id, chatID: other.id) == "$.revises: that file belongs to another chat")
        #expect(service.problem(revises: "nope", chatID: chat.id)?.contains("no file") == true)
        var spec = try JSONSerialization.jsonObject(with: Data(try FileOutFixtures.specJSON("xlsx-14").utf8)) as! [String: Any]
        spec["revises"] = r1.artifact_id
        var sheets = spec["sheets"] as! [[String: Any]]
        sheets[0]["rows"] = [["Mon", 9], ["Tue", 9]]
        spec["sheets"] = sheets
        let args = String(decoding: try JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
        let r2 = try #require(FileOutResult.parse(try CreateSpreadsheetTool.run(argumentsJSON: args, chatID: chat.id, messageID: nil,
                                                                                store: store, refs: { _ in nil })))
        #expect(r2.artifact_id == r1.artifact_id && r2.version == 2)
        #expect(r2.versions?.map(\.n) == [1, 2] && r2.versions?.first?.path == r1.path)
        #expect(FileManager.default.fileExists(atPath: r1.path) && r1.path != r2.path, "version 1 still opens")
        let parent = try db.read { d in try ArtifactVersionRecord.filter(Column("n") == 2).fetchOne(d)?.parentVersionID }
        let v1id = try db.read { d in try ArtifactVersionRecord.filter(Column("n") == 1).fetchOne(d)?.id }
        #expect(parent == v1id)
    }
}
