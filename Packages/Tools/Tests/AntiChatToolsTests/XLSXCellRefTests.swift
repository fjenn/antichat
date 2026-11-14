// M6 review #3 (P1): model-supplied formula and chart cell references must never trap. Out-of-range rows/columns and
// non-ASCII letters are rejected as "not a cell" (the repair turn tells the model), not converted with UInt32()/UInt16().
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct XLSXCellRefTests {
    @Test func validRefs() {
        #expect(XLSXWriter.cell("A1")! == (0, 0))
        #expect(XLSXWriter.cell("$b$14")! == (13, 1))
        #expect(XLSXWriter.cell("XFD1048576")! == (1_048_575, 16_383))
    }

    @Test(arguments: ["A99999999999", "A1048577", "XFE1", "ZZZ1", "合计B14", "ÄB1", "ẞ1", "A0", "A-1", "A", "1", "A1B", "A١"])
    func outOfGridOrNonASCIIIsNotACell(_ ref: String) {
        #expect(XLSXWriter.cell(ref) == nil, "\(ref)")
    }

    @Test func problemsReportsInsteadOfTrapping() {
        let args = #"{"filename":"t","format":"xlsx","sheets":[{"name":"S","columns":[{"header":"a","type":"number"}],"rows":[[1]],"formulas":{"A99999999999":"1","合计B14":"SUM(B2:B13)"},"chart":{"type":"column","categories":"A2:A99999999999","values":["合计B2:B3"]}}]}"#
        let p = CreateSpreadsheetTool.problems(argumentsJSON: args, refs: { _ in nil })
        #expect(p.contains { $0.contains("A99999999999") }, "\(p)")
        #expect(p.contains { $0.contains("合计B14") }, "\(p)")
        #expect(p.contains { $0.contains("合计B2:B3") }, "\(p)")
    }
}
