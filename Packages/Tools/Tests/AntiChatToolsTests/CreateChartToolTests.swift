// M6.T12 AT-274 check 1 (R-274 AC1): with file data in the chat, model-typed `data.values` are rejected
// (`chart.modelData`) and `data_ref` is required; the host injects the result's exact rows. Without file data, inline
// values are allowed. Fields must be the result's columns; a grouped result is not re-aggregated; no URL data.
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct CreateChartToolTests {
    static let ref = DataRef(id: "qr_1", sql: "SELECT category, sum(amount) AS total FROM t GROUP BY 1",
                             columns: ["category", "total"], types: ["VARCHAR", "DOUBLE"],
                             rows: [["Rent", "4238774.89"], ["Food", "4198006.05"], ["Misc", nil]], truncated: false)
    static func refs(_ id: String) -> DataRef? { id == ref.id ? ref : nil }

    static func args(_ spec: String, dataRef: String? = nil) -> String {
        #"{"title":"Spend by category","vega_lite_spec":\#(spec)"# + (dataRef.map { #","data_ref":"\#($0)""# } ?? "") + "}"
    }
    static let bar = #"{"mark":"bar","encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"total","type":"quantitative"}}}"#
    static let typed = #"{"mark":"bar","data":{"values":[{"category":"Rent","total":4200000}]},"encoding":{"x":{"field":"category","type":"nominal"},"y":{"field":"total","type":"quantitative"}}}"#

    @Test func inlineValuesRejectedWhenTheChatHasFileData() throws {
        // Typed-in values whose fields are not a result's columns: rejected, the hint names the results.
        let other = Self.typed.replacingOccurrences(of: "\"total\"", with: "\"spend\"")
        let p = CreateChartTool.problems(argumentsJSON: Self.args(other), refs: Self.refs, chatRefs: [Self.ref])
        #expect(p.contains { $0.contains(ChartSchemas.modelDataText) && $0.contains("qr_1") }, "\(p)")
        // Fields that are a result's columns: bound to that result, the typed values are dropped (never plotted).
        #expect(CreateChartTool.problems(argumentsJSON: Self.args(Self.typed), refs: Self.refs, chatRefs: [Self.ref]).isEmpty)
        let (spec, ref, _) = try CreateChartTool.injectedSpec(Self.args(Self.typed), refs: Self.refs, chatRefs: [Self.ref])
        let o = try #require(try JSONSerialization.jsonObject(with: Data(spec.utf8)) as? [String: Any])
        let values = try #require((o["data"] as? [String: Any])?["values"] as? [[String: Any]])
        #expect(ref?.id == "qr_1" && values.count == 3 && values[0]["total"] as? Double == 4238774.89)
        // A loaded sheet alone (no query yet) also requires data_ref.
        let q = CreateChartTool.problems(argumentsJSON: Self.args(Self.typed), refs: Self.refs, tableColumns: [["date", "amount"]])
        #expect(q.contains { $0.contains(ChartSchemas.modelDataText) && $0.contains("query_data") }, "\(q)")
        // Inline values next to a data_ref are dropped, never plotted (A-M6-T12a/b; checked in dataRefChecks).
    }

    @Test func specAsJSONStringIsParsed() {
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [Self.bar], options: []), encoding: .utf8)!.dropFirst().dropLast()
        let args = #"{"title":"T","data_ref":"qr_1","vega_lite_spec":\#(quoted)}"#
        #expect(CreateChartTool.problems(argumentsJSON: args, refs: Self.refs, chatRefs: [Self.ref]).isEmpty)
    }

    /// AT-274 T1 run (2026-11-04): the result handle named inside the spec (`data.name` / `data.url` / a `data_ref` key)
    /// becomes the call's `data_ref`; real inline values are never moved.
    @Test func dataRefNamedInsideTheSpecIsLifted() throws {
        for inner in [#""data":{"name":"qr_1"}"#, #""data":{"url":"qr_1"}"#, #""data_ref":"qr_1""#,
                      #""data":{"external":{"name":"qr_1"}}"#] {
            let raw = #"{"title":"T","vega_lite_spec":{"mark":"bar",\#(inner),"encoding":{"x":{"field":"category"},"y":{"field":"total"}}}}"#
            let o = try #require(try JSONSerialization.jsonObject(with: Data(CreateChartTool.normalized(raw).utf8)) as? [String: Any])
            let spec = try #require(o["vega_lite_spec"] as? [String: Any])
            #expect(o["data_ref"] as? String == "qr_1" && spec["data"] == nil && spec["data_ref"] == nil, "\(inner)")
            #expect(CreateChartTool.problems(argumentsJSON: raw, refs: Self.refs, chatRefs: [Self.ref]).isEmpty, "\(inner)")
        }
        let two = #"{"title":"T","vega_lite_spec":{"mark":"bar","data":{"a":{"name":"qr_1"},"b":"qr_2"}}}"#
        #expect(CreateChartTool.normalized(two) == two, "two different handles: nothing is guessed")
        let typed = Self.args(Self.typed)
        #expect(CreateChartTool.normalized(typed) == typed, "inline values stay as sent (the validator decides)")
        let spec = #"{"title":"T","vega_lite_spec":"{\"mark\":\"bar\",\"data\":{\"name\":\"qr_1\"}}"}"#
        #expect(CreateChartTool.normalized(spec).contains(#""data_ref":"qr_1""#), "string spec + named data")
    }

    @Test func conversationNumbersMayBeInline() {
        #expect(CreateChartTool.problems(argumentsJSON: Self.args(Self.typed), refs: Self.refs).isEmpty)
        // Neither values nor data_ref: nothing to draw.
        #expect(!CreateChartTool.problems(argumentsJSON: Self.args(Self.bar), refs: Self.refs).isEmpty)
    }

    @Test func dataRefChecks() {
        #expect(CreateChartTool.problems(argumentsJSON: Self.args(Self.bar, dataRef: "qr_1"), refs: Self.refs, chatRefs: [Self.ref]).isEmpty)
        let unknown = CreateChartTool.problems(argumentsJSON: Self.args(Self.bar, dataRef: "qr_9"), refs: Self.refs)
        #expect(unknown.contains { $0.contains("no query result") })
        // M6.T12 follow-up (A-M6-T12b): a field that is not a column and a re-aggregated grouped result are redrawn
        // from the result's rows (ChartSpecRepair), not refused.
        let badField = Self.bar.replacingOccurrences(of: "\"total\"", with: "\"amount\"")
        #expect(CreateChartTool.problems(argumentsJSON: Self.args(badField, dataRef: "qr_1"), refs: Self.refs).isEmpty)
        let (fixed, _, _) = try! CreateChartTool.injectedSpec(Self.args(badField, dataRef: "qr_1"), refs: Self.refs)
        #expect(fixed.contains(#""field":"total""#) && !fixed.contains("amount"), "\(fixed)")
        let reagg = Self.bar.replacingOccurrences(of: #""type":"quantitative""#, with: #""type":"quantitative","aggregate":"sum""#)
        let (plain, _, _) = try! CreateChartTool.injectedSpec(Self.args(reagg, dataRef: "qr_1"), refs: Self.refs)
        #expect(!plain.contains("aggregate"), "\(plain)")
        let both = Self.args(Self.typed, dataRef: "qr_1")
        #expect(CreateChartTool.problems(argumentsJSON: both, refs: Self.refs).isEmpty)
        let (rows, _, _) = try! CreateChartTool.injectedSpec(both, refs: Self.refs)
        let plotted = ((try? JSONSerialization.jsonObject(with: Data(rows.utf8))) as? [String: Any])
            .flatMap { ($0["data"] as? [String: Any])?["values"] as? [[String: Any]] } ?? []
        #expect(plotted.count == 3 && plotted[0]["total"] as? Double == 4238774.89, "typed numbers next to a data_ref are never plotted")
        let url = #"{"mark":"bar","data":{"url":"https://example.com/x.csv"},"encoding":{}}"#
        #expect(CreateChartTool.problems(argumentsJSON: Self.args(url), refs: Self.refs).contains { $0.contains("cannot load URLs") })
    }

    @Test func injectionCarriesTheExactRows() throws {
        let (spec, ref, title) = try CreateChartTool.injectedSpec(Self.args(Self.bar, dataRef: "qr_1"), refs: Self.refs)
        #expect(ref == Self.ref && title == "Spend by category")
        let o = try #require(try JSONSerialization.jsonObject(with: Data(spec.utf8)) as? [String: Any])
        let values = try #require((o["data"] as? [String: Any])?["values"] as? [[String: Any]])
        #expect(values.count == 3)
        #expect(values[0]["category"] as? String == "Rent")
        #expect(values[0]["total"] as? Double == 4238774.89)
        #expect(values[2]["total"] is NSNull)
        #expect(o["title"] as? String == "Spend by category")
    }

    /// AT-274 T1 shapes (2026-11-04 runs): nested mark.encoding, facets on the plotted field, aggregate objects,
    /// channels without fields, invalid types — redrawn from the rows; a spec string with extra braces still parses.
    @Test func repairDrawsTheRowsAsTheyAre() throws {
        let nested: [String: Any] = ["mark": ["type": "bar", "orient": "horizontal", "encoding": ["x": ["field": "total"], "y": ["field": "category"]],
                                              "color": ["field": "total"]],
                                     "facet": ["row": ["field": "category"]], "encoding": ["axisX": ["title": "T"], "title": ["text": "x"]],
                                     "transform": [["aggregate": [["op": "sum", "field": "total", "as": "t"]], "groupby": ["category"]]]]
        let r = ChartSpecRepair.repair(nested, ref: Self.ref)
        let enc = try #require(r["encoding"] as? [String: Any])
        #expect((enc["x"] as? [String: Any])?["field"] as? String == "total" && (enc["x"] as? [String: Any])?["type"] as? String == "quantitative")
        #expect((enc["y"] as? [String: Any])?["field"] as? String == "category" && (enc["y"] as? [String: Any])?["type"] as? String == "nominal")
        #expect(enc["axisX"] == nil && r["facet"] == nil && r["transform"] == nil && (r["mark"] as? [String: Any])?["encoding"] == nil)
        let bare = ChartSpecRepair.repair(["mark": ["type": "bar", "encoding": ["color": ["field": "category"]]],
                                           "encoding": ["x": ["type": "unit"], "y": ["aggregate": ["expr": "sum", "field": "total"]]]], ref: Self.ref)
        let b = try #require(bare["encoding"] as? [String: Any])
        #expect((b["x"] as? [String: Any])?["field"] as? String == "category" && (b["y"] as? [String: Any])?["field"] as? String == "total")
        #expect((b["y"] as? [String: Any])?["aggregate"] == nil)
        let arc = ChartSpecRepair.repair(["mark": "arc", "encoding": [:]], ref: Self.ref)
        #expect(((arc["encoding"] as? [String: Any])?["theta"] as? [String: Any])?["field"] as? String == "total")
        let plain = ChartSpecRepair.fallback(["mark": "line"], ref: Self.ref, title: "T")
        #expect(plain["mark"] as? String == "line" && ((plain["encoding"] as? [String: Any])?["y"] as? [String: Any])?["field"] as? String == "total")
        #expect(ChartSpecRepair.firstObject(#"{"mark":"bar","encoding":{"x":{"field":"a}"}}}}"#)?["mark"] as? String == "bar")
        // AT-274 shapes: a closer that skips an open list, a missing final brace, a stray closer.
        let extra = #"{"data":{"name":"qr_1"},"mark":"bar","layer":[{"layer":[{"mark":"point"}}, {"mark":"bar"}]}, {"x":1}],"title":"T"}"#
        let e = try #require(ChartSpecRepair.firstObject(extra))
        #expect((e["data"] as? [String: Any])?["name"] as? String == "qr_1" && e["mark"] as? String == "bar")
        let missing = try #require(ChartSpecRepair.firstObject(#"{"mark":{"type":"bar","encoding":{"y":{"field":"category"}}, "title":"T""#))
        #expect((missing["mark"] as? [String: Any])?["type"] as? String == "bar")
        #expect(ChartSpecRepair.firstObject(#"]] {"mark":"line"}"#)?["mark"] as? String == "line")
        #expect(ChartSpecRepair.firstObject("not json") == nil)
        #expect(ChartSpecRepair.isGrouped(Self.ref))
    }

    @Test func fieldsWalker() {
        let spec: [String: Any] = ["layer": [["encoding": ["x": ["field": "a"]]],
                                             ["transform": [["aggregate": [["op": "sum", "field": "b"]], "groupby": ["c"]]]]],
                                   "data": ["values": [["field": "nope"]]]]
        #expect(ChartSpecHelpers.fields(in: spec) == ["a", "b", "c"])
        #expect(ChartSpecHelpers.aggregates(spec))
    }
}
