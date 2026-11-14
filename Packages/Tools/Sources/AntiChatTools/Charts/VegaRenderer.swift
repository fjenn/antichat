// M6.T12 step 3 (R-274 AC2, P-files-tools-06): Vega-Lite → SVG + PNG@2x headless in RenderHost (`bridge-vega.js`:
// vegaLite.compile → vega.View(renderer "none") → toSVG / toImageURL("png", 2)). No DOM, no network: RenderHost's
// content rules block every URL but its own scheme, the page CSP is default-src 'none', and the spec arrives with
// its data already injected.
import Foundation

public struct ChartRender: Sendable, Equatable {
    public var svg: String
    public var png: Data
    public var warnings: [String]
}

public enum VegaRenderer {
    @MainActor
    public static func render(specJSON: String, scale: Int = 2, host: RenderHost = .shared) async throws -> ChartRender {
        struct Out: Decodable { var svg: String; var png: String; var warnings: [String]? }
        let payload = #"{"scale":\#(scale),"spec":\#(specJSON)}"#
        let raw: String
        do {
            raw = try await host.call("return await AntiChatRender.vega(payload);", payload: payload)
        } catch {
            throw FileOutError.render("\(error)")
        }
        guard let out = try? JSONDecoder().decode(Out.self, from: Data(raw.utf8)), let png = Data(base64Encoded: out.png) else {
            throw FileOutError.render("the chart renderer returned no image")
        }
        return ChartRender(svg: out.svg, png: png, warnings: out.warnings ?? [])
    }
}
