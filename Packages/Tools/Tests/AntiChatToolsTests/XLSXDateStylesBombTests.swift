// M6 review #2 (P1): the XLSX date-style pass reads styles/workbook/sheet parts through the shared bounded zip reader;
// a sheet part that inflates past 64 MB is refused instead of inflating in memory.
import AntiChatStorage
import Foundation
import OsaurusVendored
import Testing
@testable import AntiChatTools

@Suite struct XLSXDateStylesBombTests {
    @Test func sheetBombIsRefused() throws {
        var sheet = Data(#"<worksheet><sheetData><row><c r="A1" s="1"><v>1</v></c></row>"#.utf8)
        sheet.append(Data(repeating: 0x20, count: 80 << 20)); sheet.append(Data("</sheetData></worksheet>".utf8))
        var w = ZipArchiveWriter()
        try w.add(path: "xl/styles.xml", data: Data(#"<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>"#.utf8))
        try w.add(path: "xl/workbook.xml", data: Data(#"<workbook><sheets><sheet name="S" r:id="rId1"/></sheets></workbook>"#.utf8))
        try w.add(path: "xl/_rels/workbook.xml.rels", data: Data(#"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>"#.utf8))
        try w.add(path: "xl/worksheets/sheet1.xml", data: sheet)
        let xlsx = try w.finalize()
        #expect(xlsx.count < 1 << 20)
        #expect(throws: BoundedZipError.self) { try XLSXDateStyles.dateCells(xlsx: xlsx) }
    }
}
