// M6.T08 step 5 (R-272 AC2): the query_data activity line — `act.queried` from the result's summary line, the SQL from
// the arguments, the first 20 rows from the Markdown table; a failed query shows `tool.failed` with DuckDB's reason.
//   make test-unit FILTER=QueryActivityTests
import AntiChatDesign
import AntiChatHarness
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct QueryActivityTests {
    static func result(rows: Int) -> String {
        var s = #"{"columns":["n","v"],"data_ref":"qr_x","elapsed_ms":3,"file":"budget.xlsx","row_count":"# + "\(rows)"
            + #","truncated":false,"types":["BIGINT","DOUBLE"]}"# + "\n| n | v |\n| --- | --- |\n"
        for i in 0..<min(rows, 200) { s += "| \(i) | \(Double(i) / 2) |\n" }
        return s
    }

    @Test func doneLabelAndDetail() throws {
        let a = ToolActivity(id: "c1", tool: "query_data", state: .done, argumentsJSON: #"{"sql":"SELECT n, v FROM t"}"#,
                             result: Self.result(rows: 60))
        #expect(QueryActivity.isQuery(a))
        let label = try #require(QueryActivity.label(a))
        #expect(label.string == "Queried budget.xlsx · 60 rows")
        #expect(QueryActivity.sql(a) == "SELECT n, v FROM t")
        let t = QueryActivity.rows(a)
        #expect(t.header == ["n", "v"] && t.rows.count == 20 && t.rows[1] == ["1", "0.5"])
    }

    @Test func failedLabel() throws {
        let a = ToolActivity(id: "c2", tool: "query_data", state: .failed, argumentsJSON: #"{"sql":"DELETE FROM t"}"#,
                             result: "Error: query_data runs read-only queries only (SELECT, WITH, SUMMARIZE, DESCRIBE, PIVOT); got a DELETE statement.")
        let label = try #require(QueryActivity.label(a))
        #expect(label.string.hasPrefix("query_data didn't work: query_data runs read-only queries only"))
        #expect(!QueryActivity.isQuery(ToolActivity(id: "c3", tool: "echo", state: .done)))
    }
}
