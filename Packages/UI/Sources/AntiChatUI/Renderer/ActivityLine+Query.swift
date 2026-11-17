// M6.T08 step 5 (R-272 AC2): the `query_data` step on the ActivityLine. Done → `act.queried` ("Queried {file} · {rows}
// rows"), expanding to the SQL (monospace) and the first 20 result rows as a small table; failed → `tool.failed` with
// DuckDB's message. The data comes from the persisted activity (arguments + the result's JSON summary line + its
// Markdown table), so a reloaded chat shows the same step.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

enum QueryActivity {
    static func isQuery(_ a: ToolActivity) -> Bool { a.tool == QueryDataTool.name && a.kind == .tool }

    static func sql(_ a: ToolActivity) -> String {
        (try? JSONDecoder().decode(QueryDataTool.Arguments.self, from: Data(a.argumentsJSON.utf8)))?.sql ?? a.argumentsJSON
    }

    static func label(_ a: ToolActivity) -> CopyText? {
        switch a.state {
        case .done:
            guard let s = a.result.flatMap(QueryDataTool.summary(ofResult:)) else { return nil }
            return CopyText(CopyKey("act.queried"), ["file": s.file ?? "data", "rows": "\(s.row_count)"])
        case .failed:
            let reason = (a.result ?? "").replacingOccurrences(of: "Error: ", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
            return CopyText(CopyKey("tool.failed"), ["tool": a.tool, "reason": reason])
        default: return nil
        }
    }

    /// Header + up to 20 rows from the result's Markdown table.
    static func rows(_ a: ToolActivity, limit: Int = 20) -> (header: [String], rows: [[String]]) {
        guard let r = a.result else { return ([], []) }
        // Table lines only: no separator row, no line the 2,000-char activity cap cut in half.
        let lines = r.split(separator: "\n").dropFirst().filter { $0.hasPrefix("| ") && $0.hasSuffix(" |") && !$0.hasPrefix("| ---") }
        func cells(_ l: Substring) -> [String] {
            l.dropFirst(2).dropLast(2).components(separatedBy: " | ")
        }
        guard let head = lines.first else { return ([], []) }
        return (cells(head), lines.dropFirst().prefix(limit).map(cells))
    }
}

struct QueryActivityDetail: View {
    let activity: ToolActivity

    var body: some View {
        let t = QueryActivity.rows(activity)
        VStack(alignment: .leading, spacing: Spacing.space2) {
            // The rows the question returned; never the SQL (a query language is not something to show a person).
            if !t.header.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space1) {
                        GridRow {
                            ForEach(Array(t.header.enumerated()), id: \.offset) { Text(verbatim: $0.element).fontWeight(.semibold) }
                        }
                        Divider()
                        ForEach(Array(t.rows.enumerated()), id: \.offset) { row in
                            GridRow { ForEach(Array(row.element.enumerated()), id: \.offset) { Text(verbatim: $0.element) } }
                        }
                    }
                    .typeStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.textTertiary)
                }
                .accessibilityIdentifier("queryRows")
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("activityDetail")
    }
}
