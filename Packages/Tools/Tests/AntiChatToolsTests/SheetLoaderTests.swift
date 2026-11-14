// M6.T07 (R-272 AC1, AT-272 check 1): sheets load into typed DuckDB tables and the prompt block is a profile only.
//   budget-20k.xlsx: 3 sheets, 20,036 rows, BIGINT/DATE/VARCHAR/DOUBLE/BOOLEAN typed; notes.csv; the profile has
//   schema, row count, first/last rows and SUMMARIZE stats, and shows < 1 % of the rows. legacy.xls (libxls) is
//   AntiChatKnowledge XLSAdapterTests + AntiChatHarnessTests SheetIntakeTests (Tools may not import Knowledge).
//   make test-unit FILTER=SheetLoaderTests
import AntiChatFoundation
import Foundation
import OsaurusVendored
import Testing
@testable import AntiChatTools

@Suite(.serialized) struct SheetLoaderTests {
    static let budget = ToolsFixtures.url("docs/office/budget-20k.xlsx")
    static let notes = ToolsFixtures.url("docs/office/notes.csv")

    @Test func budgetWorkbookTyped() async throws {
        let store = try DuckDBStore(chatID: "sl-\(UUID().uuidString)")
        let tables = try await SheetLoader.load(xlsx: Self.budget, into: store)
        #expect(tables.map(\.name) == ["Transactions", "Monthly", "Categories"])
        #expect(tables.map(\.rowCount) == [20_000, 24, 12])
        #expect(tables.map(\.rowCount).reduce(0, +) == 20_036)
        let tx = tables[0]
        #expect(tx.columns.map(\.name) == ["txn_id", "date", "category", "region", "amount", "qty", "reimbursed"])
        #expect(tx.columns.map(\.type) == [.bigint, .date, .varchar, .varchar, .double, .bigint, .boolean])
        #expect(tables[1].columns.map(\.type) == [.date, .bigint, .bigint])
        #expect(tables[2].columns.map(\.type) == [.varchar, .bigint, .varchar])
        let r = try store.stringRows("""
            SELECT count(*), min(date), max(date), count(DISTINCT category), sum(CASE WHEN reimbursed THEN 1 ELSE 0 END) > 0
            FROM Transactions
            """).rows[0]
        #expect(r[0] == "20000")
        #expect(r[1].map { $0 >= "2025-01-01" } == true && r[2].map { $0 <= "2026-12-31" } == true)
        #expect(r[3] == "12")
        #expect(r[4] == "true")
        let m = try store.stringRows("SELECT month FROM Monthly LIMIT 1").rows[0][0]
        #expect(m == "2025-01-01")
    }

    @Test func csvTyped() async throws {
        let store = try DuckDBStore(chatID: "csv-\(UUID().uuidString)")
        let t = try await SheetLoader.load(csv: Self.notes, into: store)
        #expect(t.count == 1)
        #expect(t[0].name == "notes")
        #expect(t[0].rowCount == 24)
        #expect(t[0].columns.map(\.type) == [.date, .varchar, .varchar, .double])
        let sum = try store.stringRows("SELECT round(sum(amount), 2) FROM notes").rows[0][0]
        #expect(sum != nil)
    }

    @Test func profileBlockIsAProfileOnly() async throws {
        let store = try DuckDBStore(chatID: "prof-\(UUID().uuidString)")
        let tables = try await SheetLoader.load(xlsx: Self.budget, into: store)
            + SheetLoader.load(csv: Self.notes, into: store)
        for cap in [3_000, 1_500] {
            let block = try SheetProfile.block(tables, store: store, tokenCap: cap)
            #expect(block.hasPrefix("<sheet_tables untrusted=\"true\">"))
            #expect(TokenEstimator.estimate(block) <= cap, "cap \(cap): \(TokenEstimator.estimate(block)) tokens")
            #expect(block.contains("Table \"Transactions\" from budget-20k.xlsx › Transactions: 20000 rows"))
            #expect(block.contains("\"date\" DATE"))
            #expect(block.contains("Columns: \"date\" DATE, \"place\" VARCHAR"))
            // Data rows shown: every table row line has a pipe prefix; < 1 % of the 20,060 rows.
            let dataRows = block.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.contains("txn_id") }.count
            #expect(dataRows < 200, "\(dataRows) rows in the block")
            if cap == 3_000 {
                Self.artefact("profile-T1.txt", block)
                #expect(block.contains("Stats (min | max | avg | null % | approx unique)"))
                #expect(block.contains("First rows:") && block.contains("Last rows:"))
                #expect(block.contains("| 20000 |"), "last row of Transactions")
            }
        }
    }

    /// build/at/AT-272/<date>/<name> (the prompt block the model sees, for review).
    static func artefact(_ name: String, _ text: String) {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let dir = root.appendingPathComponent("build/at/AT-272/\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func inference() {
        let s: [Workbook.CellValue] = [.string("2026-01-02"), .empty, .string("2026-01-03 10:00:00")]
        #expect(SheetLoader.infer(s, parseText: false) == .timestamp)
        #expect(SheetLoader.infer([.number(1), .number(2.5)], parseText: false) == .double)
        #expect(SheetLoader.infer([.number(1), .string("x")], parseText: false) == .varchar)
        #expect(SheetLoader.infer([.string("12")], parseText: false) == .varchar, "XLSX text stays text")
        #expect(SheetLoader.infer([.string("12"), .string("-3")], parseText: true) == .bigint)
        #expect(SheetLoader.infer([.string("TRUE"), .string("false")], parseText: true) == .boolean)
        #expect(SheetLoader.infer([.string("inf")], parseText: true) == .varchar)
        #expect(SheetLoader.infer([.string("14:30:00")], parseText: true) == .time)
        #expect(SheetLoader.infer([Workbook.CellValue.empty], parseText: true) == .varchar)
    }

    @Test func spreadsheetDates() {
        #expect(SpreadsheetDates.kind(formatID: 14, code: nil) == .date)
        #expect(SpreadsheetDates.kind(formatID: 0, code: nil) == nil)
        #expect(SpreadsheetDates.kind(formatID: 164, code: "yyyy-mm-dd") == .date)
        #expect(SpreadsheetDates.kind(formatID: 164, code: "#,##0.00") == nil)
        #expect(SpreadsheetDates.kind(formatID: 164, code: "[Red]#,##0;\"d\"0") == nil, "quoted d and colours are no dates")
        #expect(SpreadsheetDates.kind(formatID: 164, code: "YYYY-MM-DD HH:MM:SS") == .dateTime)
        #expect(SpreadsheetDates.kind(formatID: 164, code: "[h]:mm") == .time)
        #expect(SpreadsheetDates.iso(serial: 45658, kind: .date) == "2025-01-01")
        #expect(SpreadsheetDates.iso(serial: 45658.5, kind: .dateTime) == "2025-01-01 12:00:00")
        #expect(SpreadsheetDates.iso(serial: 0, kind: .date, is1904: true) == "1904-01-01")
    }
}
