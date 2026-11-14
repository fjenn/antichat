// M6.T07 (A-M6-10, R-272 AC1 XLS): legacy BIFF8 `.xls` through vendored libxls → the `Workbook` model, with numbers,
// dates (ISO text from the XF number format), date-times, booleans and text typed; 2 sheets, 500 data rows.
//   make test-unit FILTER=XLSAdapterTests
import Foundation
import OsaurusVendored
import Testing
@testable import AntiChatKnowledge

@Suite struct XLSAdapterTests {
    static let url = IntakeFixtures.url("docs/office/legacy.xls")

    @Test func legacyWorkbook() throws {
        let wb = try XLSAdapter.workbook(url: Self.url)
        #expect(wb.sheets.map(\.name) == ["Orders", "Staff"])
        #expect(wb.sheets.map { $0.rows.count - 1 } == [450, 50])
        #expect(wb.sheets.map { $0.rows.count - 1 }.reduce(0, +) == 500)
        let orders = wb.sheets[0]
        #expect(orders.rows[0].cells.map(\.value.fallbackText) == ["order_id", "order_date", "customer", "amount", "shipped", "packed_at"])
        let r = orders.rows[1].cells.map(\.value)
        #expect(r[0] == .number(1001))
        guard case .string(let d) = r[1], case .string(let name) = r[2], case .number(let amount) = r[3],
              case .bool = r[4], case .string(let ts) = r[5] else {
            Issue.record("row 2 types: \(r)"); return
        }
        #expect(d.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, "date as ISO: \(d)")
        #expect(ts.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:00/) != nil, "date-time as ISO: \(ts)")
        #expect(ts.hasPrefix(d), "packed on the order day")
        #expect(name.contains(" "))
        #expect(amount > 0 && amount < 2500.01)
        let staff = wb.sheets[1].rows[1].cells.map(\.value)
        guard case .string(let start) = staff[1], case .number = staff[2] else { Issue.record("staff types: \(staff)"); return }
        #expect(start >= "2015-01-01" && start <= "2025-12-31")
    }

    @Test func extractionReadsXLS() async throws {
        let doc = try await ExtractionService().extract(url: Self.url, kind: .xls)
        #expect(doc.units.count == 2)
        #expect(doc.units.map(\.rows) == [450, 50])
        #expect(doc.markdown.contains("## Sheet: Orders"))
        #expect(doc.markdown.contains("| order_id | order_date | customer | amount | shipped | packed_at |"))
    }

    @Test func junkIsAnError() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).xls")
        try Data(repeating: 0x41, count: 2048).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(throws: XLSAdapterError.self) { try XLSAdapter.workbook(url: f) }
    }
}
