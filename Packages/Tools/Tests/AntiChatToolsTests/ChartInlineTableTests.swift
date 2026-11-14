// Q-015 r3 (ChartCardTests, AT-274): a chart whose values sit inline in the spec (no data_ref) gets a View data table
// from its `data.values` records.
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct ChartInlineTableTests {
    @Test func inlineRecordsBecomeTheTable() throws {
        let spec = #"{"data":{"values":[{"item":"A","value":3},{"item":"B","value":5.5},{"item":"C","value":8,"note":null}]},"mark":"bar"}"#
        let t = try #require(CreateChartTool.inlineTable(specJSON: spec))
        #expect(t.columns == ["item", "value", "note"])
        #expect(t.rows == [["A", "3", nil], ["B", "5.5", nil], ["C", "8", nil]])
    }

    @Test func noInlineRecordsNoTable() {
        #expect(CreateChartTool.inlineTable(specJSON: #"{"data":{"url":"x.csv"},"mark":"bar"}"#) == nil)
        #expect(CreateChartTool.inlineTable(specJSON: #"{"mark":"bar"}"#) == nil)
    }
}
