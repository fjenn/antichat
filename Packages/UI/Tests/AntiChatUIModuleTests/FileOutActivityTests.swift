// M6.T09 step 9 (R-273 AC1/AC2): the create_document step — `act.creating` + a generating card while it runs,
// `act.created` + the ready card (path, size, "Version 1") from the result's summary line, and the error card
// (`file.createFailed`, [Try again]) when it failed.
//   make test-unit FILTER=FileOutActivityTests
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct FileOutActivityTests {
    static let args = ##"{"format":"pdf","title":"Trip Plan","markdown":"# Trip"}"##
    static let result = #"{"artifact_id":"a1","file":"Trip Plan.pdf","format":"pdf","pages":1,"path":"/tmp/x/abc.pdf","size":2048,"version":1}"#
        + "\nCreated Trip Plan.pdf."

    @Test func runningDoneFailed() {
        let running = ToolActivity(id: "c1", tool: "create_document", state: .running, argumentsJSON: Self.args)
        #expect(FileOutActivity.isFileOut(running))
        #expect(FileOutActivity.label(running)?.string == "Creating Trip Plan.pdf…")
        if case .generating = FileOutActivity.item(running)?.state {} else { Issue.record("generating card") }

        let done = ToolActivity(id: "c1", tool: "create_document", state: .done, argumentsJSON: Self.args, result: Self.result)
        #expect(FileOutActivity.label(done)?.string == "Created Trip Plan.pdf")
        let item = FileOutActivity.item(done)
        #expect(item?.url.path == "/tmp/x/abc.pdf" && item?.displayName == "Trip Plan.pdf" && item?.size == 2048 && item?.version == 1)
        #expect(item?.state == .ready)
        #expect(FileCardViewModel(item: item!).subtitle.contains("Version 1"))

        let failed = ToolActivity(id: "c1", tool: "create_document", state: .failed, argumentsJSON: Self.args,
                                  result: #"{"errors":["$.markdown: empty"],"repair":true}"#)
        #expect(FileOutActivity.item(failed)?.state == .error(reason: CopyKey("file.createFailed")))
        #expect(FileOutActivity.label(failed) == nil, "failed keeps the generic act.failed line")
        #expect(CopyText(CopyKey("file.tryAgain")).string == "Try again")
        #expect(!FileOutActivity.isFileOut(ToolActivity(id: "c2", tool: "query_data", state: .done)))
    }

    @Test func spreadsheetNamesAndVersionChain() {
        let running = ToolActivity(id: "s1", tool: "create_spreadsheet", state: .running,
                                   argumentsJSON: #"{"filename":"Budget.xlsx","sheets":[]}"#)
        #expect(FileOutActivity.label(running)?.string == "Creating Budget.xlsx…")
        let csv = ToolActivity(id: "s2", tool: "export_table", state: .running, argumentsJSON: #"{"data_ref":"qr_1","format":"csv","filename":"Totals"}"#)
        #expect(FileOutActivity.filename(csv) == "Totals.csv")
        let v2 = #"{"artifact_id":"a1","file":"Budget.xlsx","format":"xlsx","path":"/tmp/v2.xlsx","size":10,"version":2,"versions":[{"n":1,"path":"/tmp/v1.xlsx","size":9},{"n":2,"path":"/tmp/v2.xlsx","size":10}]}"#
        let done = ToolActivity(id: "s1", tool: "create_spreadsheet", state: .done, argumentsJSON: "{}", result: v2 + "\nCreated.")
        #expect(FileOutActivity.versions(done).map(\.n) == [1, 2])
        let switcher = FileCardVersionSwitcher(latest: FileOutActivity.item(done)!, versions: FileOutActivity.versions(done))
        #expect(FileCardVersionSwitcher.item(switcher.latest, switcher.versions, 0).url.path == "/tmp/v1.xlsx")
        #expect(FileCardVersionSwitcher.item(switcher.latest, switcher.versions, 0).version == 1)
        #expect(FileCardVersionSwitcher.item(switcher.latest, switcher.versions, 1).displayName == "Budget.xlsx")
    }

    /// M6.T11 (AT-275 check 1b, unit leg): a deck's card names the .pptx and the side panel previews it with Quick Look.
    @Test func deckCardAndPanelPreview() throws {
        let a = ToolActivity(id: "p1", tool: "create_presentation", state: .running, argumentsJSON: #"{"filename":"Quarterly Review","slides":[]}"#)
        #expect(FileOutActivity.isFileOut(a) && FileOutActivity.label(a)?.string == "Creating Quarterly Review.pptx…")
        let type = try #require(UTType(filenameExtension: "pptx"))
        #expect(PanelBody(type) == .quickLook)
        let panel = SidePanelModel()
        panel.open(file: URL(fileURLWithPath: "/tmp/Quarterly Review.pptx"))
        #expect(panel.current?.url.lastPathComponent == "Quarterly Review.pptx")
    }

    @Test func runPythonOutputsAndNotices() {
        let summary = #"{"stderr":"","fresh_session":false,"stdout":""}"#
        let chart = #"{"artifact_id":"c","file":"Figure.png","format":"chart","path":"/tmp/figure.png","size":4,"version":1}"#
        let file = #"{"artifact_id":"f","file":"Analysis.xlsx","format":"xlsx","path":"/tmp/analysis.xlsx","size":4,"version":1}"#
        let done = ToolActivity(id: "r", tool: RunPythonTool.name, state: .done, result: [summary, chart, file].joined(separator: "\n"))
        #expect(RunPythonActivity.label(done)?.string == "Created Figure.png")
        #expect(FileOutResult.parseAll(done.result ?? "").count == 2)
        _ = RunPythonOutputCards(activity: done)

        let timeout = #"{"stderr":"","fresh_session":true,"notice_key":"sandbox.timeout","stdout":""}"#
        let stopped = ToolActivity(id: "t", tool: RunPythonTool.name, state: .done, result: timeout)
        #expect(RunPythonActivity.label(stopped)?.string == "The code ran longer than 60 seconds and was stopped.")
    }
}
