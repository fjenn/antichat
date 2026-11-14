// M6.T12 AT-274 check 2 (R-274 AC2): the chart renders headless in RenderHost to SVG + PNG@2x, the injected values
// are what is plotted, and the render makes zero network connections (local probe listener).
import AntiChatStorage
import AppKit
import Foundation
import Testing
@testable import AntiChatTools

@MainActor
@Suite(.serialized)
struct VegaRendererTests {
    @Test func rendersSVGAndPNG() async throws {
        let (spec, _, _) = try CreateChartTool.injectedSpec(
            CreateChartToolTests.args(CreateChartToolTests.bar, dataRef: "qr_1"), refs: CreateChartToolTests.refs)
        let r = try await VegaRenderer.render(specJSON: spec)
        #expect(r.svg.hasPrefix("<svg"))
        #expect(r.svg.contains("Rent") && r.svg.contains("Food"), "axis labels from the injected rows")
        let img = try #require(NSImage(data: r.png))
        let px = try #require(img.representations.first)
        #expect(px.pixelsWide >= 200 && px.pixelsHigh >= 150, "PNG@2x \(px.pixelsWide)×\(px.pixelsHigh)")
        #expect(r.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func badSpecIsARenderError() async {
        await #expect(throws: FileOutError.self) {
            _ = try await VegaRenderer.render(specJSON: #"{"mark":"nonsense","data":{"values":[{"a":1}]}}"#)
        }
    }

    @Test func zeroNetworkWhileRendering() async throws {
        let listener = try ProbeListener()
        let port = try await listener.start()
        // A spec that tries every way out: url data, an image mark pointing at the probe, a remote font.
        let spec = """
            {"data":{"values":[{"a":1,"u":"http://127.0.0.1:\(port)/img.png"}]},"mark":"image",\
            "config":{"font":"url(http://127.0.0.1:\(port)/font)"},\
            "encoding":{"x":{"field":"a","type":"quantitative"},"url":{"field":"u","type":"nominal"}}}
            """
        _ = try? await VegaRenderer.render(specJSON: spec)
        let lookup = #"{"data":{"url":"http://127.0.0.1:\#(port)/data.csv"},"mark":"bar"}"#
        _ = try? await VegaRenderer.render(specJSON: lookup)
        try await Task.sleep(for: .milliseconds(500))
        #expect(listener.count == 0, "the chart render reached the network \(listener.count) time(s)")
    }

    @Test func fullToolRunStoresChartArtifact() async throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "chart")
        let store = ArtifactStore(database: db, mediaRoot: try FileOutFixtures.scratch(), incognito: false)
        let out = try await CreateChartTool.run(argumentsJSON: CreateChartToolTests.args(CreateChartToolTests.bar, dataRef: "qr_1"),
                                                chatID: chat.id, messageID: nil, store: store,
                                                refs: CreateChartToolTests.refs)
        let r = try #require(FileOutResult.parse(out))
        #expect(r.format == "chart" && r.file == "Spend by category.png")
        let snap = try #require(ChartSnapshot.load(png: URL(fileURLWithPath: r.path)))
        #expect(snap.rows == CreateChartToolTests.ref.rows && snap.columns == ["category", "total"] && snap.svg.hasPrefix("<svg"))
        #expect(out.contains("4238774.89") == false, "the model gets no numbers back")
        let versions = try ArtifactRepository(db).versions(artifactID: r.artifact_id)
        #expect(versions.count == 1 && ChartSnapshot.decode(versions[0].specJSON ?? "") == snap, "spec_json holds the snapshot")
    }
}
