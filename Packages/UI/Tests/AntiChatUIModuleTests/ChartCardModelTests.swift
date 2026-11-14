// M6.T12 step 4 (R-274 AC2; AT-274 check 2, in-process leg of ChartCardTests): the create_chart step and the ChartCard —
// running → a rendering card, done → the chart from the result's PNG + its snapshot sidecar; Save PNG / Save SVG write
// the files, Copy puts the PNG on the pasteboard, View data shows the exact injected rows; a failed call → spec error
// state with the data_ref's rows.
//   make test-unit FILTER=ChartCardModelTests
import AntiChatHarness
import AppKit
import AntiChatTools
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AntiChatUI

@MainActor
final class RecordingChartActions: ChartActionPerforming {
    var destination: URL?
    var copied: Data?
    func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL? {
        destination?.deletingLastPathComponent().appendingPathComponent(suggestedName)
    }
    func copyImage(_ png: Data) { copied = png }
}

@MainActor
@Suite(.isolatedSettings) struct ChartCardModelTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    static func fixture() throws -> (URL, ChartSnapshot) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chartcard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("abc.png")
        try png.write(to: url)
        let snap = ChartSnapshot(title: "Spend", data_ref: "qr_1", columns: ["category", "total"], rows: [["Rent", "10"], ["Food", nil]],
                                 spec: "{}", svg: "<svg/>")
        try JSONEncoder().encode(snap).write(to: ChartSnapshot.sidecar(for: url))
        return (url, snap)
    }

    @Test func activityStates() throws {
        let (url, _) = try Self.fixture()
        let args = #"{"title":"Spend","vega_lite_spec":{"mark":"bar"},"data_ref":"qr_1"}"#
        let running = ToolActivity(id: "c1", tool: "create_chart", state: .running, argumentsJSON: args)
        #expect(ChartActivity.isChart(running) && !FileOutActivity.isFileOut(running))
        #expect(ChartActivity.label(running)?.string == "Creating Spend.png…")
        #expect(ChartActivity.model(running)?.state == .rendering)
        let result = #"{"artifact_id":"a1","file":"Spend.png","format":"chart","path":"\#(url.path)","size":11,"version":1}"# + "\nDrew."
        let done = ToolActivity(id: "c1", tool: "create_chart", state: .done, argumentsJSON: args, result: result)
        let m = try #require(ChartActivity.model(done))
        #expect(m.state == .ready && m.png == Self.png && m.columns == ["category", "total"] && m.rows.count == 2)
        let failed = ToolActivity(id: "c1", tool: "create_chart", state: .failed, argumentsJSON: args, result: "Rendering failed: spec")
        if case .specError = ChartActivity.model(failed)?.state {} else { Issue.record("spec error state") }
    }

    @Test func saveCopyViewData() async throws {
        let (url, snap) = try Self.fixture()
        let actions = RecordingChartActions()
        actions.destination = url.deletingLastPathComponent().appendingPathComponent("out")
        let m = ChartCardModel(title: "Spend", pngURL: url, state: .ready, actions: actions)
        let p = try #require(await m.savePNG())
        #expect(try p.lastPathComponent == "Spend.png" && Data(contentsOf: p) == Self.png)
        let s = try #require(await m.saveSVG())
        #expect(try s.lastPathComponent == "Spend.svg" && String(contentsOf: s, encoding: .utf8) == snap.svg)
        m.copy()
        #expect(actions.copied == Self.png)
        #expect(!m.showsData)
        m.showsData = true
        #expect(m.rows == snap.rows)
        // Spec error: the data shows at once.
        let e = ChartCardModel(title: "Spend", pngURL: nil, state: .specError("x"),
                               fallback: DataRef(id: "qr_1", sql: "", columns: ["a"], types: ["VARCHAR"], rows: [["1"]], truncated: false))
        #expect(e.showsData && e.columns == ["a"])
        #expect(await e.savePNG() == nil)
    }

    /// M6.T21 visual QA: a chart is shown at most at its own size (the renderer's 2× PNG → half its pixels), never
    /// stretched to the card width.
    @Test func aChartIsNeverStretchedPastItsOwnSize() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let image = try #require(NSImage(data: png))
        #expect(ChartCardView.naturalWidth(image) == 150)
        #expect(ChartCardView.naturalWidth(image) < ChartCardView.width)
    }

    /// VQ-M10 S-15: beside the side panel the column is narrower than the card's 520 pt; the card shrinks with it
    /// (a fixed width made the whole transcript wider than its column, clipping the user bubble and the card).
    @Test func theCardShrinksWithANarrowColumn() {
        let m = ChartCardModel(title: "Spend", pngURL: nil, state: .rendering, actions: RecordingChartActions())
        let narrow = WidthProbe(width: 360)
        _ = NSHostingView(rootView: narrow.layout { ChartCardView(model: m) }).fittingSize
        #expect(narrow.box.measured > 0 && narrow.box.measured <= 360)
        let wide = WidthProbe(width: 900)
        _ = NSHostingView(rootView: wide.layout { ChartCardView(model: m) }).fittingSize
        #expect(wide.box.measured == ChartCardView.width)
    }
}

/// Proposes `width` to its one subview and records the width the subview takes.
private struct WidthProbe: Layout {
    final class Box: @unchecked Sendable { var measured: CGFloat = 0 }
    let width: CGFloat
    let box = Box()

    func layout<V: View>(@ViewBuilder _ content: () -> V) -> some View { self { content() } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        box.measured = size.width
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: nil))
    }
}
