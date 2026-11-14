// M6.T12 follow-up (AT-274 T1 runs, A-M6-T12b): a reply that only ran lookups (query_data) and then produced no text
// gets one more step with tool_choice required — never more than one, never after an acting tool, never when text came.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct EmptyLookupReplyTests {
    static func lookup(_ name: String = "lookup") -> RegisteredTool {
        RegisteredTool(name: name, description: "lookup", parametersJSON: #"{"type":"object","properties":{}}"#,
                       outputIsUntrusted: false) { _ in #"{"data_ref":"qr_1","row_count":2}"# }
    }

    static func script(_ tool: String, then second: String) -> String {
        #"{"t":"toolCallDone","id":"call_1","name":"\#(tool)","args":"{}","delayMs":1}"# + "\n{\"t\":\"turn\"}\n" + second
    }

    @Test func emptyAfterLookupReasksOnceWithRequired() async throws {
        // query_data is offered only with a loaded sheet; a stand-in lookup tool takes its place here.
        let h = try ToolLoopHarness(script: Self.script("lookup", then: #"{"t":"done","reason":"stop"}"#),
                                    tools: [Self.lookup()], selection: .off)
        #expect(await h.controller.lookupTools == [QueryDataTool.name])
        await h.controller.setLookupTools(["lookup"])
        let (_, a) = await h.send("chart it")
        #expect(try await h.log.waitFinished(a).status == .done)
        let choices = await h.controller.requests.map(\.toolChoice)
        // lookup step, empty step, the one re-ask (required; the scripted engine answers it with a call), the step after
        // that call — which ends empty again and is not re-asked a second time.
        #expect(choices == [.auto, .auto, .required, .auto], "\(choices.map { String(describing: $0) })")
    }

    @Test func textOrActingToolsAreLeftAlone() async throws {
        let text = try ToolLoopHarness(script: Self.script("lookup", then: #"{"t":"textDelta","v":"Total is 3.","delayMs":1}"#),
                                       tools: [Self.lookup()], selection: .off)
        await text.controller.setLookupTools(["lookup"])
        let (_, a) = await text.send("sum it")
        #expect(try await text.log.waitFinished(a).status == .done)
        #expect(await text.controller.requests.count == 2)
        let acting = try ToolLoopHarness(script: Self.script("make_file", then: #"{"t":"done","reason":"stop"}"#),
                                         tools: [Self.lookup("make_file")], selection: .off)
        await acting.controller.setLookupTools(["lookup"])
        let (_, b) = await acting.send("make it")
        #expect(try await acting.log.waitFinished(b).status == .done)
        #expect(await acting.controller.requests.count == 2, "an acting tool's empty reply is not re-asked")
    }

    /// M6.T21 (AT-274 sc-14): a chart request that only looked data up and then answered in text (plotting code) gets
    /// one step that must call create_chart; a request that is not for a chart does not (textOrActingToolsAreLeftAlone).
    @Test func chartRequestAfterLookupsMustCallCreateChartOnce() async throws {
        let script = Self.script("lookup", then: #"{"t":"textDelta","v":"import plotly","delayMs":1}"#)
            + "\n{\"t\":\"turn\"}\n" + #"{"t":"toolCallDone","id":"call_2","name":"create_chart","args":"{}","delayMs":1}"#
            + "\n{\"t\":\"turn\"}\n" + #"{"t":"textDelta","v":"Done.","delayMs":1}"#
        let h = try ToolLoopHarness(script: script, tools: [Self.lookup(), Self.lookup("create_chart")], selection: .off)
        await h.controller.setLookupTools(["lookup"])
        let (_, a) = await h.send("Make a line chart of the monthly totals.")
        #expect(try await h.log.waitFinished(a).status == .done)
        let choices = await h.controller.requests.map(\.toolChoice)
        // lookup step, the text step, the one forced create_chart step; every later step is free again.
        #expect(Array(choices.prefix(3)) == [.auto, .auto, .function("create_chart")], "\(choices.map { String(describing: $0) })")
        #expect(choices.dropFirst(3).allSatisfy { $0 == .auto } && choices.count > 3)
        #expect(TurnController.asksForChart("Haz un gráfico de barras") && !TurnController.asksForChart("sum the totals"))
    }

    /// M6.T21 (AT-274 sc-03 / sc-06 / sc-10): the step ran into the output limit inside a create_chart call and the
    /// engine dropped it. The model is told (a failed call + notice) and gets one more step with the same choice; once.
    @Test func cutOffCallIsReportedAndRetriedOnce() async throws {
        let cut = #"{"t":"usage","completion":1536,"rejected":"create_chart"}"# + "\n" + #"{"t":"done","reason":"length"}"#
        let script = Self.script("lookup", then: cut) + "\n{\"t\":\"turn\"}\n" + cut
            + "\n{\"t\":\"turn\"}\n" + #"{"t":"toolCallDone","id":"call_9","name":"create_chart","args":"{}","delayMs":1}"#
            + "\n{\"t\":\"turn\"}\n" + #"{"t":"textDelta","v":"Done.","delayMs":1}"#
        let h = try ToolLoopHarness(script: script, tools: [Self.lookup(), Self.lookup("create_chart")], selection: .off)
        await h.controller.setLookupTools(["lookup"])
        let (_, a) = await h.send("Make a bar chart of the totals.")
        #expect(try await h.log.waitFinished(a).status == .done)
        let reqs = await h.controller.requests
        // lookup, cut step, the retry (same choice, auto) which is cut again → no second retry; then the forced chart step.
        let choices = reqs.map(\.toolChoice)
        #expect(Array(choices.prefix(4)) == [.auto, .auto, .auto, .function("create_chart")], "\(choices.map { String(describing: $0) })")
        #expect(choices.dropFirst(4).allSatisfy { $0 == .auto } && choices.count > 4)
        let notice = reqs[2].flattenedMessages.last { $0.role == .tool }?.content ?? ""
        #expect(notice.contains("create_chart call was cut off"), "\(notice)")
        #expect(ToolLoopPolicy.cutOffNotice("x").contains("was not run"))
    }
}
